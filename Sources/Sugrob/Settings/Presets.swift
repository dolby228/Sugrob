import Foundation

/// Labels and values shared by the menu and the settings window, so both stay in sync.
extension Settings {
    struct WindPreset {
        /// Menu title, e.g. «← Влево».
        let title: String
        /// Short label for a segmented control, e.g. «←».
        let shortTitle: String
        let x: Double
        let y: Double

        func matches(x: Double, y: Double) -> Bool {
            abs(self.x - x) < 0.001 && abs(self.y - y) < 0.001
        }
    }

    /// Wind is in screen-local y-down space, so «Вверх» is negative y.
    static let windPresets: [WindPreset] = [
        WindPreset(title: "Штиль", shortTitle: "Штиль", x: 0, y: 0),
        WindPreset(title: "← Влево", shortTitle: "←", x: -0.6, y: 0),
        WindPreset(title: "→ Вправо", shortTitle: "→", x: 0.6, y: 0),
        WindPreset(title: "↑ Вверх", shortTitle: "↑", x: 0, y: -0.6),
        WindPreset(title: "↓ Вниз", shortTitle: "↓", x: 0, y: 0.6),
    ]

    static let snowfallTitles: [(Snowfall, String)] = [
        (.light, "Лёгкий"),
        (.steady, "Ровный"),
        (.blizzard, "Метель"),
    ]

    static let toolTitles: [(Tool, String)] = [
        (.mitten, "Варежка"),
        (.shovel, "Лопата"),
    ]

    static let snowballHint = "⌥ + перетаскивание по сугробу — снежок"
}
