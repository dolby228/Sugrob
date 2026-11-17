import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// Asks for Accessibility once, a few seconds after launch, without nagging.
///
/// Only when not trusted, and only once ever (the flag is stored before anything is
/// shown, so a crash or quit never repeats it). If the grant looks stale (another build
/// was trusted, see `AccessibilityAccess.looksStale`) the offer comes once more per code
/// identity, with «Обновить доступ». When the settings window is already open (the
/// first-launch welcome) its Accessibility row is highlighted instead of an alert.
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
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Self.title
        alert.informativeText = stale ? Self.staleText : Self.text
        alert.addButton(withTitle: stale ? "Обновить доступ" : "Разрешить")
        alert.addButton(withTitle: "Не сейчас")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            log.info("accessibility offer declined")
            return
        }
        // A reset is harmless when there is no entry and clears one left by an older
        // build, which would otherwise look granted in the list but not work.
        AccessibilityAccess.resetAndRequest()
    }
}
