import Foundation
import os

private let log = Logger(subsystem: "dev.sugrob", category: "render")

/// Watches Low Power Mode and the thermal state and picks a render budget:
/// normal → full particles at 60 fps; Low Power Mode or `.serious` → half at 30 fps;
/// `.critical` → a quarter at 30 fps.
@MainActor
final class PowerMonitor: NSObject {
    struct Profile: Equatable, Sendable {
        /// Passed to `SnowWorld.particleBudgetScale`.
        let budgetScale: Float
        let framesPerSecond: Int

        static let normal = Profile(budgetScale: 1, framesPerSecond: 60)
        static let reduced = Profile(budgetScale: 0.5, framesPerSecond: 30)
        static let critical = Profile(budgetScale: 0.25, framesPerSecond: 30)
    }

    /// Called on the main actor when the profile changes.
    var onChange: (@MainActor (Profile) -> Void)?

    private(set) var profile: Profile

    override init() {
        profile = Self.currentProfile()
        super.init()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(powerStateDidChange(_:)),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(powerStateDidChange(_:)),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        log.info("power profile \(self.profile.framesPerSecond) fps, budget \(Double(self.profile.budgetScale), privacy: .public)")
    }

    static func profile(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Profile {
        switch thermalState {
        case .critical:
            return .critical
        case .serious:
            return .reduced
        case .nominal, .fair:
            return lowPowerMode ? .reduced : .normal
        @unknown default:
            return lowPowerMode ? .reduced : .normal
        }
    }

    private static func currentProfile() -> Profile {
        let info = ProcessInfo.processInfo
        return profile(lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    /// Both notifications may arrive on any thread.
    @objc private nonisolated func powerStateDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let next = Self.currentProfile()
        guard next != profile else { return }
        profile = next
        log.info("power profile changed: \(next.framesPerSecond) fps, budget \(Double(next.budgetScale), privacy: .public)")
        onChange?(next)
    }
}
