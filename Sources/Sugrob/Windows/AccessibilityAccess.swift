import AppKit
import ApplicationServices
import Security
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

extension Notification.Name {
    /// Posted on the main thread when `AccessibilityAccess.isTrusted` flips, and after a
    /// reset of the grant finished. `userInfo["trusted"]` is the current state (`Bool`).
    static let sugrobAccessibilityDidChange = Notification.Name("dev.sugrob.accessibilityDidChange")
}

/// Opt-in Accessibility access, used only to read the exact Dock frame.
///
/// Asked for once, gently, a few seconds after the first launch (`AccessibilityOnboarding`),
/// and otherwise only from «Разрешить…» in the settings window and «Точный размер Dock…»
/// in the status menu. The trust state is re-checked when the system announces a change of
/// the Accessibility list (`com.apple.accessibility.api`, posted slightly before the new
/// state is readable), every second for two minutes after a request, and by `refresh()`,
/// which the settings window calls every 2 s while it is open; `DockLocator` itself
/// re-reads it every second.
///
/// `scripts/bundle.sh` signs with a designated requirement on the bundle identifier, so
/// the grant survives rebuilds. Grants made for older builds were tied to their cdhash
/// and no longer apply: the cdhash of every build that was trusted is remembered, and
/// `looksStale` then offers `resetAndRequest()` (`tccutil reset` plus a new request).
@MainActor
enum AccessibilityAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    /// The system's change notification arrives before `AXIsProcessTrusted` updates.
    static let recheckDelays: [TimeInterval] = [0.5, 1.5, 3]
    /// After a request the state is re-read this often, for at most `watchDuration`.
    static let watchInterval: TimeInterval = 1
    static let watchDuration: TimeInterval = 120
    static let tccutilPath = "/usr/bin/tccutil"

    private static let grantedIdentityKey = "accessibilityGrantedCodeIdentity"
    private static let promptedKey = "accessibilityDidPrompt"

    private static var lastTrusted: Bool?
    private static var observer: ChangeObserver?
    private static var watchTimer: Timer?
    private static var watchDeadline: TimeInterval = 0
    private static var defaults: UserDefaults { .standard }

    /// True after `request()` ran during this launch.
    private(set) static var didRequestThisLaunch = false
    /// The last `tccutil reset` failed; the user has to remove the old entry by hand.
    private(set) static var resetFailed = false
    /// A reset is running.
    private(set) static var isResetting = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The cdhash of the running binary (hex), nil when it cannot be read.
    static let codeIdentity: String? = readCodeIdentity()
    /// `codeIdentity`, or a placeholder when it cannot be read.
    private static var currentIdentity: String { codeIdentity ?? "unknown" }

    /// The code identity recorded the last time Sugrob was seen trusted.
    static var grantedCodeIdentity: String? {
        defaults.string(forKey: grantedIdentityKey)
    }

    /// Not trusted, but some other build of Sugrob was: the entry in the Accessibility
    /// list probably belongs to an old build. The same build being untrusted means the
    /// user switched the access off, which is respected.
    static var looksStale: Bool {
        guard !isTrusted, let granted = grantedCodeIdentity else { return false }
        return granted != currentIdentity
    }

    /// Asks for access with a single dialog: the system prompt the first time, the
    /// Privacy & Security → Accessibility pane on later requests (the system shows its
    /// prompt only once per entry).
    static func request() {
        didRequestThisLaunch = true
        startWatching()
        if isTrusted {
            refresh()
            return
        }
        if defaults.bool(forKey: promptedKey) {
            log.info("accessibility requested, opening the privacy pane")
            if let url = settingsURL {
                NSWorkspace.shared.open(url)
            }
        } else {
            defaults.set(true, forKey: promptedKey)
            // `kAXTrustedCheckOptionPrompt`; the literal avoids the imported global var.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            log.info("accessibility requested with the system prompt, trusted \(trusted)")
        }
        watchForGrant()
        refresh()
    }

    /// Removes Sugrob's entry from the Accessibility list (`tccutil reset`, off the main
    /// thread), then requests access again. If the reset fails, `resetFailed` is set and
    /// the request still opens the pane, where the entry can be removed by hand.
    static func resetAndRequest() {
        guard !isResetting else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            log.error("accessibility reset skipped: no bundle identifier")
            resetFailed = true
            request()
            return
        }
        isResetting = true
        log.info("accessibility reset for \(bundleID, privacy: .public)")
        let path = tccutilPath
        DispatchQueue.global(qos: .userInitiated).async {
            let status = runTCCUtilReset(path: path, bundleID: bundleID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    finishReset(status: status)
                }
            }
        }
    }

    private static func finishReset(status: Int32?) {
        isResetting = false
        let ok = status == 0
        resetFailed = !ok
        if ok {
            log.info("accessibility reset done")
            defaults.removeObject(forKey: grantedIdentityKey)
            // A fresh entry gets the system prompt again.
            defaults.set(false, forKey: promptedKey)
        } else {
            let code = status.map { Int($0) } ?? -1
            log.error("accessibility reset failed, tccutil status \(code)")
        }
        request()
        post(trusted: isTrusted)
    }

    /// Runs `tccutil reset Accessibility <bundle id>`; the exit status or nil.
    nonisolated private static func runTCCUtilReset(path: String, bundleID: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Listens for system changes of the Accessibility list. Safe to call repeatedly.
    static func startWatching() {
        guard observer == nil else { return }
        lastTrusted = isTrusted
        if lastTrusted == true {
            recordGrant()
        }
        let observer = ChangeObserver()
        self.observer = observer
        // An accessory app is usually inactive; the default suspension behavior would hold
        // the notification back until Sugrob is activated.
        DistributedNotificationCenter.default().addObserver(
            observer,
            selector: #selector(ChangeObserver.accessibilityListChanged(_:)),
            name: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    fileprivate static func systemListChanged() {
        for delay in recheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    _ = refresh()
                }
            }
        }
    }

    /// Re-reads the state every `watchInterval` until trusted or `watchDuration` is over.
    private static func watchForGrant() {
        watchDeadline = ProcessInfo.processInfo.systemUptime + watchDuration
        guard watchTimer == nil else { return }
        let timer = Timer(timeInterval: watchInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let trusted = refresh()
                if trusted || ProcessInfo.processInfo.systemUptime >= watchDeadline {
                    stopWatchingForGrant()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private static func stopWatchingForGrant() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// Re-reads the trust state and posts `sugrobAccessibilityDidChange` if it flipped.
    @discardableResult
    static func refresh() -> Bool {
        let trusted = isTrusted
        if trusted {
            recordGrant()
        }
        if trusted != lastTrusted {
            let first = lastTrusted == nil
            lastTrusted = trusted
            if !first {
                log.info("accessibility trusted changed to \(trusted)")
                if trusted {
                    resetFailed = false
                    stopWatchingForGrant()
                }
                post(trusted: trusted)
            }
        }
        return trusted
    }

    private static func post(trusted: Bool) {
        NotificationCenter.default.post(
            name: .sugrobAccessibilityDidChange,
            object: nil,
            userInfo: ["trusted": trusted]
        )
    }

    private static func recordGrant() {
        let identity = currentIdentity
        guard defaults.string(forKey: grantedIdentityKey) != identity else { return }
        defaults.set(identity, forKey: grantedIdentityKey)
        log.debug("accessibility grant recorded for \(identity, privacy: .public)")
    }

    /// `kSecCodeInfoUnique` (the cdhash) of the running code, as hex.
    nonisolated private static func readCodeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info,
              let dictionary = info as NSDictionary as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data,
              !unique.isEmpty
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// Target of the distributed notification, which needs an Objective-C observer.
private final class ChangeObserver: NSObject {
    @objc func accessibilityListChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AccessibilityAccess.systemListChanged()
            }
        }
    }
}
