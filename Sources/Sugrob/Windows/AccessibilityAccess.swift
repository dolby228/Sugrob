import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

extension Notification.Name {
    /// Posted on the main thread when `AccessibilityAccess.isTrusted` flips.
    static let sugrobAccessibilityDidChange = Notification.Name("dev.sugrob.accessibilityDidChange")
}

/// Opt-in Accessibility access, used only to read the exact Dock frame.
///
/// Never requested on launch: only «Разрешить…» in the settings window and «Точный размер
/// Dock…» in the status menu ask. The trust state is re-checked when the system announces
/// a change of the Accessibility list (`com.apple.accessibility.api`, posted slightly
/// before the new state is readable) and by `refresh()`, which the settings window calls
/// every 2 s while it is open; `DockLocator` itself re-reads it every second.
///
/// With the ad-hoc signature of `scripts/bundle.sh` the grant is tied to the binary's
/// cdhash, so every new build has to be granted again.
@MainActor
enum AccessibilityAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    /// The system's change notification arrives before `AXIsProcessTrusted` updates.
    static let recheckDelays: [TimeInterval] = [0.5, 1.5, 3]

    private static var lastTrusted: Bool?
    private static var watching = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens Privacy & Security → Accessibility.
    static func request() {
        // `kAXTrustedCheckOptionPrompt`; the literal avoids the imported global var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.info("accessibility requested, trusted \(trusted)")
        if !trusted, let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
        startWatching()
        refresh()
    }

    /// Listens for system changes of the Accessibility list. Safe to call repeatedly.
    static func startWatching() {
        guard !watching else { return }
        watching = true
        lastTrusted = isTrusted
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for delay in recheckDelays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated {
                            refresh()
                        }
                    }
                }
            }
        }
    }

    /// Re-reads the trust state and posts `sugrobAccessibilityDidChange` if it flipped.
    @discardableResult
    static func refresh() -> Bool {
        let trusted = isTrusted
        if trusted != lastTrusted {
            let first = lastTrusted == nil
            lastTrusted = trusted
            if !first {
                log.info("accessibility trusted changed to \(trusted)")
                NotificationCenter.default.post(name: .sugrobAccessibilityDidChange, object: nil)
            }
        }
        return trusted
    }
}
