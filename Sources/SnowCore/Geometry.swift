/// Axis-aligned rectangle in points. Origin is top-left, y grows down.
public struct Rect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Float { x }
    public var minY: Float { y }
    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
    public var midX: Float { x + width * 0.5 }
    public var midY: Float { y + height * 0.5 }
    public var origin: SIMD2<Float> { SIMD2(x, y) }

    /// Half-open containment: left/top edges are inside, right/bottom are not.
    public func contains(_ p: SIMD2<Float>) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }
}
