import Foundation

extension Notification.Name {
    /// Posted by `Settings` after any property changed. `userInfo["key"]` is a `Settings.Key`.
    static let sugrobSettingsDidChange = Notification.Name("dev.sugrob.settingsDidChange")
    /// «Очистить сугробы»: remove all accumulated snow.
    static let sugrobClearAll = Notification.Name("dev.sugrob.clearAll")
}

/// User preferences persisted in `UserDefaults`.
@MainActor
final class Settings {
    enum Snowfall: String, CaseIterable, Sendable {
        case light
        case steady
        case blizzard
    }

    enum Tool: String, CaseIterable, Sendable {
        case mitten
        case shovel
    }

    enum Key: String, CaseIterable, Sendable {
        case isPaused
        case snowfall
        case windX
        case windY
        case tool
        case showDebugOutlines
        case showInDock
    }

    private let defaults: UserDefaults
    private var observers: [@MainActor (Key) -> Void] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isPaused.rawValue: false,
            Key.snowfall.rawValue: Snowfall.steady.rawValue,
            Key.windX.rawValue: 0.0,
            Key.windY.rawValue: 0.0,
            Key.tool.rawValue: Tool.mitten.rawValue,
            Key.showDebugOutlines.rawValue: false,
            Key.showInDock.rawValue: true,
        ])
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Key.isPaused.rawValue) }
        set { store(newValue, for: .isPaused) }
    }

    var snowfall: Snowfall {
        get { Snowfall(rawValue: defaults.string(forKey: Key.snowfall.rawValue) ?? "") ?? .steady }
        set { store(newValue.rawValue, for: .snowfall) }
    }

    /// Horizontal wind, screen-local y-down space: negative blows left.
    var windX: Double {
        get { defaults.double(forKey: Key.windX.rawValue) }
        set { store(newValue, for: .windX) }
    }

    /// Vertical wind, screen-local y-down space: negative blows up.
    var windY: Double {
        get { defaults.double(forKey: Key.windY.rawValue) }
        set { store(newValue, for: .windY) }
    }

    var tool: Tool {
        get { Tool(rawValue: defaults.string(forKey: Key.tool.rawValue) ?? "") ?? .mitten }
        set { store(newValue.rawValue, for: .tool) }
    }

    var showDebugOutlines: Bool {
        get { defaults.bool(forKey: Key.showDebugOutlines.rawValue) }
        set { store(newValue, for: .showDebugOutlines) }
    }

    /// Regular app with a Dock icon instead of a menu-bar-only accessory. On by default:
    /// on notched Macs the status item is often hidden, and the Dock icon is the only handle.
    var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock.rawValue) }
        set { store(newValue, for: .showInDock) }
    }

    /// Sets both wind components with a single change notification per component.
    func setWind(x: Double, y: Double) {
        windX = x
        windY = y
    }

    /// `handler` runs on the main actor after each change, with the key that changed.
    func addObserver(_ handler: @escaping @MainActor (Key) -> Void) {
        observers.append(handler)
    }

    private func store(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        for observer in observers {
            observer(key)
        }
        NotificationCenter.default.post(
            name: .sugrobSettingsDidChange,
            object: self,
            userInfo: ["key": key]
        )
    }
}
