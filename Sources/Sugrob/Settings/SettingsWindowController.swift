import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "settings")

/// Settings window with every menu control. It is the fallback when the status item is
/// not visible (for example hidden by the notch), so it must offer pause and quit too.
/// Bound to the same `Settings` object as the menu: both refresh from its observers.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// «Скопировать диагностику».
    var onCopyDiagnostics: (() -> Void)?

    private let settings: Settings

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let pauseCheckbox = NSButton(checkboxWithTitle: "Пауза", target: nil, action: nil)
    private let snowfallControl = NSSegmentedControl(
        labels: Settings.snowfallTitles.map { $0.1 },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let windControl = NSSegmentedControl(
        labels: Settings.windPresets.map { $0.shortTitle },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let toolControl = NSSegmentedControl(
        labels: Settings.toolTitles.map { $0.1 },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let toolHint = NSTextField(wrappingLabelWithString: "")
    private let debugCheckbox = NSButton(checkboxWithTitle: "Показывать контуры окон", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Запускать при входе", target: nil, action: nil)
    private let copiedLabel = NSTextField(labelWithString: "")

    private static let toolHints: [Settings.Tool: String] = [
        .mitten: "Варежка: ведите курсором по сугробу, снег смахивается по ходу движения.",
        .shovel: "Лопата: тяните по сугробу, чтобы набрать снег; отпустите, и ком полетит.",
    ]

    init(settings: Settings) {
        self.settings = settings
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sugrob — настройки"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        refresh()

        settings.addObserver { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(launchAtLoginChanged(_:)),
            name: .sugrobLaunchAtLoginDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window in front of other apps. `message` is an optional hint line on top.
    func show(message: String? = nil) {
        guard let window else { return }
        if let message {
            messageLabel.stringValue = message
            messageLabel.isHidden = false
        }
        copiedLabel.stringValue = ""
        refresh()
        fitWindow()
        if !window.isVisible {
            window.center()
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        // An accessory app may be refused activation; the window must still come up.
        window.orderFrontRegardless()
        log.debug("settings window shown")
    }

    var isShowingMessage: Bool {
        (window?.isVisible ?? false) && !messageLabel.isHidden
    }

    func windowWillClose(_ notification: Notification) {
        messageLabel.isHidden = true
        messageLabel.stringValue = ""
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        messageLabel.isHidden = true
        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        messageLabel.preferredMaxLayoutWidth = 420

        pauseCheckbox.target = self
        pauseCheckbox.action = #selector(pauseChanged(_:))
        snowfallControl.target = self
        snowfallControl.action = #selector(snowfallChanged(_:))
        windControl.target = self
        windControl.action = #selector(windChanged(_:))
        toolControl.target = self
        toolControl.action = #selector(toolChanged(_:))
        debugCheckbox.target = self
        debugCheckbox.action = #selector(debugChanged(_:))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged(_:))

        for (index, preset) in Settings.windPresets.enumerated() {
            windControl.setToolTip(preset.title, forSegment: index)
        }

        toolHint.textColor = .secondaryLabelColor
        toolHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        toolHint.preferredMaxLayoutWidth = 300

        let clearButton = NSButton(title: "Очистить сугробы", target: self, action: #selector(clearAll(_:)))

        let grid = NSGridView(views: [
            [label("Снег:"), pauseCheckbox],
            [label("Снегопад:"), snowfallControl],
            [label("Ветер:"), windControl],
            [label("Инструмент:"), toolControl],
            [NSGridCell.emptyContentView, toolHint],
            [NSGridCell.emptyContentView, clearButton],
            [label("Прочее:"), debugCheckbox],
            [NSGridCell.emptyContentView, loginCheckbox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let diagnosticsButton = NSButton(
            title: "Скопировать диагностику",
            target: self,
            action: #selector(copyDiagnostics(_:))
        )
        copiedLabel.textColor = .secondaryLabelColor
        copiedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let quitButton = NSButton(title: "Выйти из Sugrob", target: self, action: #selector(quit(_:)))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [diagnosticsButton, copiedLabel, spacer, quitButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [messageLabel, grid, separator(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        fitWindow()
    }

    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    // MARK: State

    private func refresh() {
        pauseCheckbox.state = settings.isPaused ? .on : .off

        snowfallControl.selectedSegment = Settings.snowfallTitles.firstIndex { $0.0 == settings.snowfall } ?? -1

        let windX = settings.windX
        let windY = settings.windY
        windControl.selectedSegment = Settings.windPresets.firstIndex { $0.matches(x: windX, y: windY) } ?? -1

        let tool = settings.tool
        toolControl.selectedSegment = Settings.toolTitles.firstIndex { $0.0 == tool } ?? -1
        toolHint.stringValue = (Self.toolHints[tool] ?? "") + "\n" + Settings.snowballHint + "."

        let forced = DebugOverlayView.environmentForcesOutlines
        debugCheckbox.state = (settings.showDebugOutlines || forced) ? .on : .off
        debugCheckbox.isEnabled = !forced
        debugCheckbox.toolTip = forced ? "Включено через SUGROB_DEBUG_WINDOWS=1" : nil

        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: Actions

    @objc private func pauseChanged(_ sender: NSButton) {
        settings.isPaused = sender.state == .on
    }

    @objc private func snowfallChanged(_ sender: NSSegmentedControl) {
        guard Settings.snowfallTitles.indices.contains(sender.selectedSegment) else { return }
        settings.snowfall = Settings.snowfallTitles[sender.selectedSegment].0
    }

    @objc private func windChanged(_ sender: NSSegmentedControl) {
        guard Settings.windPresets.indices.contains(sender.selectedSegment) else { return }
        let preset = Settings.windPresets[sender.selectedSegment]
        settings.setWind(x: preset.x, y: preset.y)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        guard Settings.toolTitles.indices.contains(sender.selectedSegment) else { return }
        settings.tool = Settings.toolTitles[sender.selectedSegment].0
    }

    @objc private func clearAll(_ sender: NSButton) {
        NotificationCenter.default.post(name: .sugrobClearAll, object: nil)
    }

    @objc private func debugChanged(_ sender: NSButton) {
        settings.showDebugOutlines = sender.state == .on
    }

    @objc private func loginChanged(_ sender: NSButton) {
        LaunchAtLogin.toggle()
    }

    @objc private func launchAtLoginChanged(_ notification: Notification) {
        refresh()
    }

    @objc private func copyDiagnostics(_ sender: NSButton) {
        onCopyDiagnostics?()
        copiedLabel.stringValue = "Скопировано"
    }

    @objc private func quit(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

/// Closes on Esc and ⌘W: an accessory app has no main menu to provide them.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
