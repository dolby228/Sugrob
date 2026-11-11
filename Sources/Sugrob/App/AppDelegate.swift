import AppKit
import SnowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Sugrob %@ started", SnowCore.version)
    }
}
