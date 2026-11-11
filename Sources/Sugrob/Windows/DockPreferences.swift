import AppKit

/// The parts of the `com.apple.dock` preferences (and the running apps) that size the Dock.
///
/// ESTIMATE ONLY: used when Accessibility is not granted and no Dock window has the size
/// of the tile row. The tile count follows how the Dock lays itself out:
/// - Finder, then every `persistent-apps` entry (spacers count as full tiles);
/// - running apps with `activationPolicy == .regular` that are not kept in the Dock
///   (Sugrob itself too while its Dock icon is shown);
/// - with `show-recents`, up to 3 `recent-apps` that are neither kept nor running;
/// - a separator before the recents section, if it is shown and not empty;
/// - a separator, then `persistent-others` (folders, stacks) and the Trash.
///
/// Length along the Dock edge:
///
///     slots * tilesize + separators * tilesize * 0.4 + 2 * tilesize * 0.3
///
/// Icons are packed with almost no gap, a separator is about 0.4 tile wide and the glass
/// adds about 0.3 tile at each end. `magnification` is ignored: the magnified state is
/// transient. `DockLocator.centered` clamps the result to the reserved strip.
struct DockPreferences: Equatable, CustomStringConvertible {
    /// Used when `tilesize` is missing from the preferences.
    static let defaultTileSize: CGFloat = 48
    static let maxRecents = 3
    static let separatorShare: CGFloat = 0.4
    static let endPaddingShare: CGFloat = 0.3

    var tileSize: CGFloat
    var persistentApps: Int
    var persistentOthers: Int
    /// Running regular apps that are not kept in the Dock; they get tiles too.
    var runningNotInDock: Int
    /// Recent apps shown in the recents section that are neither kept nor running.
    var recentsNotRunning: Int
    var showRecents: Bool
    var autohide: Bool
    var orientation: String
    /// `tilesize` was missing or invalid and `defaultTileSize` is used.
    var tileSizeIsDefault: Bool

    var slots: Int {
        Self.slots(
            persistentApps: persistentApps,
            runningNotInDock: runningNotInDock,
            recentsNotRunning: recentsNotRunning,
            persistentOthers: persistentOthers
        )
    }

    var separators: Int {
        Self.separators(showRecents: showRecents, recentsSection: runningNotInDock + recentsNotRunning)
    }

    /// Estimated length of the Dock along its edge, in points.
    var estimatedLength: CGFloat {
        Self.estimatedLength(tileSize: tileSize, slots: slots, separators: separators)
    }

    /// Finder + kept apps + running and recent apps + folders/stacks + Trash.
    static func slots(persistentApps: Int, runningNotInDock: Int, recentsNotRunning: Int, persistentOthers: Int) -> Int {
        1 + max(0, persistentApps) + max(0, runningNotInDock) + max(0, recentsNotRunning) + max(0, persistentOthers) + 1
    }

    /// One before folders and the Trash, one more before a non-empty recents section.
    /// Without `show-recents` the running apps follow the kept ones with no separator.
    static func separators(showRecents: Bool, recentsSection: Int) -> Int {
        showRecents && recentsSection > 0 ? 2 : 1
    }

    static func estimatedLength(tileSize: CGFloat, slots: Int, separators: Int) -> CGFloat {
        CGFloat(slots) * tileSize
            + CGFloat(separators) * tileSize * separatorShare
            + 2 * tileSize * endPaddingShare
    }

    /// Running apps not kept in the Dock (one tile per bundle id, apps without one count
    /// each) and recent apps that are neither kept nor running, at most `maxRecents`.
    static func extraTiles(
        kept: Set<String>,
        running: [String?],
        recent: [String],
        showRecents: Bool
    ) -> (running: Int, recents: Int) {
        var runningIDs: Set<String> = []
        var anonymous = 0
        for id in running {
            if let id {
                runningIDs.insert(id)
            } else {
                anonymous += 1
            }
        }
        let runningTiles = runningIDs.subtracting(kept).count + anonymous
        guard showRecents else { return (runningTiles, 0) }

        var recents: [String] = []
        for id in recent where !kept.contains(id) && !runningIDs.contains(id) && !recents.contains(id) {
            recents.append(id)
        }
        return (runningTiles, min(recents.count, maxRecents))
    }

    var description: String {
        let defaultMark = tileSizeIsDefault ? " (default)" : ""
        return "tile \(tileSize)\(defaultMark) apps \(persistentApps) others \(persistentOthers) running \(runningNotInDock) recents \(recentsNotRunning) show-recents \(showRecents) slots \(slots) separators \(separators) length \(estimatedLength) autohide \(autohide) \(orientation)"
    }

    /// The estimate inputs and result, for «Скопировать диагностику».
    var diagnostics: [String: Any] {
        [
            "tileSize": Double(tileSize),
            "tileSizeIsDefault": tileSizeIsDefault,
            "persistentApps": persistentApps,
            "persistentOthers": persistentOthers,
            "runningNotInDock": runningNotInDock,
            "recentsNotRunning": recentsNotRunning,
            "showRecents": showRecents,
            "slots": slots,
            "separators": separators,
            "estimatedLength": Double(estimatedLength),
            "autohide": autohide,
            "orientation": orientation,
        ]
    }

    /// Nil when the Dock preferences cannot be read.
    static func read() -> DockPreferences? {
        guard let defaults = UserDefaults(suiteName: DockLocator.bundleID) else { return nil }
        let apps = defaults.array(forKey: "persistent-apps")
        let tileSizeValue = defaults.object(forKey: "tilesize") as? NSNumber
        guard apps != nil || tileSizeValue != nil else { return nil }

        var kept: Set<String> = ["com.apple.finder"]
        kept.formUnion(bundleIDs(in: apps))
        let showRecents = (defaults.object(forKey: "show-recents") as? NSNumber)?.boolValue ?? true
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { $0.bundleIdentifier }
        let extra = extraTiles(
            kept: kept,
            running: running,
            recent: bundleIDs(in: defaults.array(forKey: "recent-apps")),
            showRecents: showRecents
        )

        let size = CGFloat(tileSizeValue?.doubleValue ?? Double(defaultTileSize))
        let valid = tileSizeValue != nil && size.isFinite && size > 0
        return DockPreferences(
            tileSize: valid ? size : defaultTileSize,
            persistentApps: apps?.count ?? 0,
            persistentOthers: defaults.array(forKey: "persistent-others")?.count ?? 0,
            runningNotInDock: extra.running,
            recentsNotRunning: extra.recents,
            showRecents: showRecents,
            autohide: defaults.bool(forKey: "autohide"),
            orientation: defaults.string(forKey: "orientation") ?? "bottom",
            tileSizeIsDefault: !valid
        )
    }

    /// `tile-data.bundle-identifier` of every Dock entry that has one.
    private static func bundleIDs(in entries: [Any]?) -> [String] {
        var result: [String] = []
        for case let entry as [String: Any] in entries ?? [] {
            if let data = entry["tile-data"] as? [String: Any], let id = data["bundle-identifier"] as? String {
                result.append(id)
            }
        }
        return result
    }
}
