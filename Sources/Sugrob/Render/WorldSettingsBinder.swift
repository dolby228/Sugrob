import Foundation
import SnowCore

/// Keeps one `SnowView`'s world in sync with `Settings`: snowfall preset, wind and
/// «Очистить сугробы». Pause and debug outlines go through `OverlayController` /
/// `AppDelegate`, which already fan them out to every overlay.
@MainActor
final class WorldSettingsBinder: NSObject {
    private let settings: Settings
    private weak var view: SnowView?

    init(settings: Settings, view: SnowView) {
        self.settings = settings
        self.view = view
        super.init()

        // Selector-based observers are removed automatically when the binder goes away.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .sugrobSettingsDidChange,
            object: settings
        )
        center.addObserver(
            self,
            selector: #selector(clearAll(_:)),
            name: .sugrobClearAll,
            object: nil
        )
        applyAll()
    }

    static func preset(for snowfall: Settings.Snowfall) -> SnowfallPreset {
        switch snowfall {
        case .light: return .light
        case .steady: return .steady
        case .blizzard: return .blizzard
        }
    }

    /// Settings wind is already in screen-local y-down space, same as `Wind`.
    static func wind(x: Double, y: Double) -> Wind {
        Wind(x: Float(x), y: Float(y))
    }

    func applyAll() {
        applyPreset()
        applyWind()
    }

    private func applyPreset() {
        guard let world = view?.world else { return }
        let preset = Self.preset(for: settings.snowfall)
        if world.preset != preset {
            world.preset = preset
        }
    }

    private func applyWind() {
        guard let world = view?.world else { return }
        world.wind = Self.wind(x: settings.windX, y: settings.windY)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let key = notification.userInfo?["key"] as? Settings.Key else {
            applyAll()
            return
        }
        switch key {
        case .snowfall:
            applyPreset()
        case .windX, .windY:
            applyWind()
        case .isPaused, .tool, .showDebugOutlines:
            break
        }
    }

    @objc private func clearAll(_ notification: Notification) {
        view?.world.clearAll()
    }
}
