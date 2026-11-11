import AppKit
import ApplicationServices
import CoreGraphics
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// «Скопировать диагностику»: a JSON report for bug reports.
///
/// Contains screens, on-screen window bounds (owner, pid, layer, bounds, alpha; never
/// window titles), the Accessibility trust flag, settings and the status item frame.
@MainActor
enum Diagnostics {
    static func copyToPasteboard(settings: Settings, statusItem: [String: Any]) {
        let text = report(settings: settings, statusItem: statusItem)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log.info("copied diagnostics, \(text.count) characters")
    }

    static func report(settings: Settings, statusItem: [String: Any]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let root: [String: Any] = [
            "appVersion": info["CFBundleShortVersionString"] as? String ?? SnowCore.version,
            "bundlePath": Bundle.main.bundlePath,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "axIsProcessTrusted": AXIsProcessTrusted(),
            "screens": NSScreen.screens.enumerated().map { screenInfo(index: $0.offset, screen: $0.element) },
            "windows": windowInfo(),
            "settings": settingsInfo(settings),
            "statusItem": statusItem,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            log.error("diagnostics serialization failed: \(error.localizedDescription, privacy: .public)")
            return String(describing: root)
        }
    }

    static func rect(_ rect: CGRect?) -> Any {
        guard let rect else { return NSNull() }
        return [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.size.width),
            "height": Double(rect.size.height),
        ]
    }

    private static func screenInfo(index: Int, screen: NSScreen) -> [String: Any] {
        let insets = screen.safeAreaInsets
        return [
            "index": index,
            "name": screen.localizedName,
            "frame": rect(screen.frame),
            "visibleFrame": rect(screen.visibleFrame),
            "safeAreaInsets": [
                "top": Double(insets.top),
                "left": Double(insets.left),
                "bottom": Double(insets.bottom),
                "right": Double(insets.right),
            ],
            "auxiliaryTopLeftArea": rect(screen.auxiliaryTopLeftArea),
            "auxiliaryTopRightArea": rect(screen.auxiliaryTopRightArea),
            "backingScaleFactor": Double(screen.backingScaleFactor),
        ]
    }

    /// Raw `CGWindowListCopyWindowInfo` entries without window names.
    private static func windowInfo() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.map { entry in
            var result: [String: Any] = [:]
            result["owner"] = orNull(entry[kCGWindowOwnerName as String] as? String)
            result["pid"] = orNull((entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue)
            result["number"] = orNull((entry[kCGWindowNumber as String] as? NSNumber)?.intValue)
            result["layer"] = orNull((entry[kCGWindowLayer as String] as? NSNumber)?.intValue)
            result["alpha"] = orNull((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
               let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                result["bounds"] = rect(cgRect)
            } else {
                result["bounds"] = NSNull()
            }
            return result
        }
    }

    private static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private static func settingsInfo(_ settings: Settings) -> [String: Any] {
        [
            "isPaused": settings.isPaused,
            "snowfall": settings.snowfall.rawValue,
            "windX": settings.windX,
            "windY": settings.windY,
            "tool": settings.tool.rawValue,
            "showDebugOutlines": settings.showDebugOutlines,
            "launchAtLogin": LaunchAtLogin.isEnabled,
        ]
    }
}
