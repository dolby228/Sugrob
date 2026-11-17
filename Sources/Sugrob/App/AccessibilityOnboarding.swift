import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// Asks for Accessibility once, a few seconds after launch, without nagging.
///
/// Only when not trusted, and only once ever (the flag is stored before anything is
/// shown, so a crash or quit never repeats it). If the grant looks stale (another build
/// was trusted, see `AccessibilityAccess.looksStale`) the offer comes once more per code
/// identity, with «Обновить доступ». When the settings window is already open (the
/// first-launch welcome) its Accessibility row is highlighted instead.
///
/// The offer is a small non-modal floating panel near the menu bar, not `NSAlert.runModal`:
/// a modal run loop would stall the snow and the mouse tools, and the panel never activates
/// Sugrob, so the app in front keeps its focus.
@MainActor
final class AccessibilityOnboarding {
    static let delay: TimeInterval = 3
    static let shownKey = "accessibilityOnboardingShown"
    static let staleOfferKey = "accessibilityStaleOfferIdentity"

    static let title = "Сугроб точно по Dock"
    static let text =
        "Sugrob может уложить сугроб точно по ширине Dock. Для этого нужен Универсальный доступ: через него читается только размер Dock, больше ничего. Без доступа ширина оценивается. Включить можно и позже в настройках."
    static let staleText =
        "Универсальный доступ был выдан старой версии Sugrob и больше не действует. Sugrob сбросит старую запись и попросит доступ заново: через него читается только размер Dock. Это можно сделать и позже в настройках."

    private let defaults: UserDefaults
    private let isSettingsVisible: @MainActor () -> Bool
    private let highlightInSettings: @MainActor () -> Void
    private var pending: DispatchWorkItem?
    private var panel: OfferPanel?

    init(
        defaults: UserDefaults = .standard,
        isSettingsVisible: @escaping @MainActor () -> Bool,
        highlightInSettings: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.isSettingsVisible = isSettingsVisible
        self.highlightInSettings = highlightInSettings
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.run()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        panel?.close()
        panel = nil
    }

    private func run() {
        pending = nil
        guard !AccessibilityAccess.isTrusted else { return }
        let stale = AccessibilityAccess.looksStale
        if stale {
            let identity = AccessibilityAccess.codeIdentity ?? "unknown"
            guard defaults.string(forKey: Self.staleOfferKey) != identity else { return }
            defaults.set(identity, forKey: Self.staleOfferKey)
            defaults.set(true, forKey: Self.shownKey)
        } else {
            guard !defaults.bool(forKey: Self.shownKey) else { return }
            defaults.set(true, forKey: Self.shownKey)
        }
        log.info("offering accessibility, stale \(stale)")
        offer(stale: stale)
    }

    private func offer(stale: Bool) {
        if isSettingsVisible() {
            highlightInSettings()
            return
        }
        panel?.close()
        let panel = OfferPanel(
            title: Self.title,
            text: stale ? Self.staleText : Self.text,
            acceptTitle: stale ? "Обновить доступ" : "Разрешить"
        ) { [weak self] accepted in
            self?.finish(accepted: accepted)
        }
        self.panel = panel
        panel.show()
    }

    private func finish(accepted: Bool) {
        panel = nil
        guard accepted else {
            log.info("accessibility offer declined")
            return
        }
        // A reset is harmless when there is no entry and clears one left by an older
        // build, which would otherwise look granted in the list but not work.
        AccessibilityAccess.resetAndRequest()
    }
}

/// A small floating panel with a title, a text and two buttons. Non-activating and
/// non-modal; closing it counts as «Не сейчас». `onFinish` is called exactly once.
@MainActor
private final class OfferPanel: NSObject, NSWindowDelegate {
    static let width: CGFloat = 340
    static let margin: CGFloat = 16

    private let window: NSPanel
    private var onFinish: (@MainActor (Bool) -> Void)?

    init(title: String, text: String, acceptTitle: String, onFinish: @escaping @MainActor (Bool) -> Void) {
        self.onFinish = onFinish
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Sugrob"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
        ])
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 52
        let texts = NSStackView(views: [titleLabel, textLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let header = NSStackView(views: [icon, texts])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 12

        let later = NSButton(title: "Не сейчас", target: nil, action: nil)
        let accept = NSButton(title: acceptTitle, target: nil, action: nil)
        accept.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, later, accept])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [header, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.margin),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)

        later.target = self
        later.action = #selector(declineClicked(_:))
        accept.target = self
        accept.action = #selector(acceptClicked(_:))
    }

    /// Top right of the main screen, under the menu bar, like a notification banner.
    func show() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - Self.margin,
                y: visible.maxY - size.height - Self.margin
            ))
        } else {
            window.center()
        }
        window.orderFrontRegardless()
    }

    func close() {
        onFinish = nil
        window.close()
    }

    @objc private func acceptClicked(_ sender: NSButton) {
        finish(true)
    }

    @objc private func declineClicked(_ sender: NSButton) {
        finish(false)
    }

    func windowWillClose(_ notification: Notification) {
        finish(false)
    }

    private func finish(_ accepted: Bool) {
        guard let onFinish else { return }
        self.onFinish = nil
        window.orderOut(nil)
        onFinish(accepted)
    }
}
