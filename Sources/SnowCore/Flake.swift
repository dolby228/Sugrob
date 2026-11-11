/// One falling snowflake (or a clump of snow knocked off a drift).
public struct Flake: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    /// Diameter in points.
    public var size: Float
    /// Radians.
    public var rotation: Float
    /// Radians per second.
    public var spin: Float
    public var opacity: Float
    /// Sway phase in radians.
    public var phase: Float
    /// Sideways sway speed in points per second.
    public var swayAmplitude: Float
    /// Terminal fall speed in points per second, before wind.
    public var fallSpeed: Float
    /// True for clumps that came off a drift (sweep, shake, crumble).
    public var isDebris: Bool
    /// Surface this flake passes through instead of landing on (the one it fell off).
    public var ignoredSurfaceID: Int?

    public init(
        position: SIMD2<Float>,
        velocity: SIMD2<Float>,
        size: Float,
        rotation: Float = 0,
        spin: Float = 0,
        opacity: Float = 1,
        phase: Float = 0,
        swayAmplitude: Float = 0,
        fallSpeed: Float = 50,
        isDebris: Bool = false,
        ignoredSurfaceID: Int? = nil
    ) {
        self.position = position
        self.velocity = velocity
        self.size = size
        self.rotation = rotation
        self.spin = spin
        self.opacity = opacity
        self.phase = phase
        self.swayAmplitude = swayAmplitude
        self.fallSpeed = fallSpeed
        self.isDebris = isDebris
        self.ignoredSurfaceID = ignoredSurfaceID
    }
}

/// Something snow can pile up on: a window or the Dock. Snow lands on the top edge (`rect.y`).
public struct Surface: Equatable, Sendable {
    public var id: Int
    public var rect: Rect

    public init(id: Int, rect: Rect) {
        self.id = id
        self.rect = rect
    }
}
