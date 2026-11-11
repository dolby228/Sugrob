/// A ball of packed snow. Rolled out of a drift with the cursor, then dropped onto a
/// surface or onto another ball; three stacked balls become a `Snowman`.
public struct Snowball: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Dragged by the user along a drift, picking up snow.
        case rolling
        /// Dragged by the user through the air.
        case held
        /// Flying under gravity.
        case falling
        /// Lying on a surface's drift or on top of another ball.
        case resting
    }

    /// Distance between the centres of two stacked balls, as a fraction of their radii sum.
    public static let stackOverlap: Float = 0.85

    public let id: Int
    public internal(set) var center: SIMD2<Float>
    public internal(set) var radius: Float
    public internal(set) var velocity: SIMD2<Float>
    public internal(set) var state: State
    /// Surface the ball rolls on or rests on (also set for the upper balls of a stack).
    public internal(set) var surfaceID: Int?
    /// Centre x relative to the surface's left edge while attached to it.
    public internal(set) var localX: Float
    /// Ball this one sits on.
    public internal(set) var parentID: Int?
    /// Ball sitting on this one.
    public internal(set) var childID: Int?
    /// Rolling angle in radians.
    public internal(set) var rotation: Float
    /// Surface a falling ball passes through (the one it was knocked off).
    var ignoredSurfaceID: Int?

    init(id: Int, center: SIMD2<Float>, radius: Float, state: State) {
        self.id = id
        self.center = center
        self.radius = radius
        self.velocity = .zero
        self.state = state
        self.surfaceID = nil
        self.localX = 0
        self.parentID = nil
        self.childID = nil
        self.rotation = 0
        self.ignoredSurfaceID = nil
    }

    /// Snow packed into the ball, in pt² (same units as `Drift` snow).
    public var area: Float { Float.pi * radius * radius }
}

/// Three stacked snowballs standing on a surface: bottom, middle and head.
public struct Snowman: Equatable, Sendable {
    public let id: Int
    public internal(set) var surfaceID: Int
    /// Centre x of the bottom ball relative to the surface's left edge.
    public internal(set) var localX: Float
    public internal(set) var bottomRadius: Float
    public internal(set) var middleRadius: Float
    public internal(set) var headRadius: Float
    /// 1 when the nose points right, -1 when it points left.
    public internal(set) var facing: Float
    /// Centre of the bottom ball in world coordinates.
    public internal(set) var position: SIMD2<Float>

    init(
        id: Int,
        surfaceID: Int,
        localX: Float,
        radii: (Float, Float, Float),
        facing: Float,
        position: SIMD2<Float>
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.localX = localX
        self.bottomRadius = radii.0
        self.middleRadius = radii.1
        self.headRadius = radii.2
        self.facing = facing
        self.position = position
    }

    /// Radii from the bottom up.
    public var radii: [Float] { [bottomRadius, middleRadius, headRadius] }

    public var bottomCenter: SIMD2<Float> { position }

    public var middleCenter: SIMD2<Float> {
        SIMD2(position.x, position.y - (bottomRadius + middleRadius) * Snowball.stackOverlap)
    }

    public var headCenter: SIMD2<Float> {
        let middle = middleCenter
        return SIMD2(middle.x, middle.y - (middleRadius + headRadius) * Snowball.stackOverlap)
    }

    /// Ball centres from the bottom up.
    public var centers: [SIMD2<Float>] { [bottomCenter, middleCenter, headCenter] }

    /// Snow in all three balls, in pt².
    public var area: Float {
        Float.pi * (bottomRadius * bottomRadius + middleRadius * middleRadius + headRadius * headRadius)
    }
}
