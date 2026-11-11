/// How hard it snows.
public enum SnowfallPreset: String, CaseIterable, Sendable {
    case light
    case steady
    case blizzard

    /// Reference screen width the flake caps are tuned for.
    public static let referenceWidth: Float = 1440

    /// New flakes per second for every 1000 pt of width.
    public var spawnRatePer1000: Float {
        switch self {
        case .light: return 18
        case .steady: return 45
        case .blizzard: return 140
        }
    }

    /// Flake diameter in points.
    public var sizeRange: ClosedRange<Float> {
        switch self {
        case .light: return 2...4.5
        case .steady: return 2...5.5
        case .blizzard: return 1.5...6
        }
    }

    /// Terminal fall speed in points per second.
    public var fallSpeedRange: ClosedRange<Float> {
        switch self {
        case .light: return 28...55
        case .steady: return 40...80
        case .blizzard: return 70...150
        }
    }

    /// Flake cap at `referenceWidth`.
    public var baseFlakeCap: Int {
        switch self {
        case .light: return 250
        case .steady: return 600
        case .blizzard: return 1500
        }
    }

    /// Flake cap scaled by screen width and budget (0...1).
    public func flakeCap(forWidth width: Float, budgetScale: Float = 1) -> Int {
        let scale = max(0, min(1, budgetScale))
        let widthScale = max(0, width) / Self.referenceWidth
        return Int((Float(baseFlakeCap) * widthScale * scale).rounded())
    }
}

/// Wind as a vector with components in -1...1.
/// `x > 0` blows right; `y > 0` pushes flakes down faster, `y < 0` slows the fall.
public struct Wind: Equatable, Sendable {
    public var x: Float
    public var y: Float

    /// Horizontal speed in points per second at `x == 1`.
    public static let maxHorizontalSpeed: Float = 140
    /// Relative change of fall speed at `|y| == 1`.
    public static let maxVerticalFactor: Float = 0.6

    public static let calm = Wind(x: 0, y: 0)

    public init(x: Float, y: Float = 0) {
        self.x = Wind.clamp(x)
        self.y = Wind.clamp(y)
    }

    public func adjusted(dx: Float, dy: Float) -> Wind {
        Wind(x: x + dx, y: y + dy)
    }

    /// Horizontal velocity contribution in points per second.
    public var horizontalSpeed: Float { x * Wind.maxHorizontalSpeed }

    /// Multiplier applied to a flake's fall speed.
    public var fallMultiplier: Float { 1 + y * Wind.maxVerticalFactor }

    private static func clamp(_ v: Float) -> Float {
        v.isFinite ? max(-1, min(1, v)) : 0
    }
}
