/// Height map of snow lying on top of one surface.
///
/// Local coordinates: `x` runs from the surface's left edge (0) to `width`;
/// `y` is 0 on the top edge and negative above it, so a column of height `h`
/// occupies `-h...0`. Snow amounts are areas in pt² (height × column spacing).
public final class Drift {
    public private(set) var width: Float
    public let preferredSpacing: Float
    /// Actual distance between columns; never larger than `preferredSpacing`.
    public private(set) var columnSpacing: Float
    public private(set) var heights: [Float]
    public var maxHeight: Float
    /// Largest rise per point of run that snow can hold (tangent of the angle of repose).
    public var reposeSlope: Float
    /// Height the outermost columns can keep, in units of one repose step.
    public var edgeHold: Float = 1

    /// Snow that slid off the left/right edges during settling, waiting to be turned into flakes.
    var pendingSpillLeft: Float = 0
    var pendingSpillRight: Float = 0
    private var reverseSweep = false

    public init(width: Float, columnSpacing: Float = 4, maxHeight: Float = 48, reposeSlope: Float = 0.6) {
        let w = Drift.sanitizedWidth(width)
        let spacing = max(0.5, columnSpacing)
        let n = Drift.makeColumnCount(width: w, spacing: spacing)
        self.width = w
        self.preferredSpacing = spacing
        self.columnSpacing = w / Float(n - 1)
        self.heights = [Float](repeating: 0, count: n)
        self.maxHeight = maxHeight
        self.reposeSlope = reposeSlope
    }

    public var columnCount: Int { heights.count }

    public func columnX(_ index: Int) -> Float {
        Float(index) * columnSpacing
    }

    public var totalSnow: Float {
        var sum: Float = 0
        for h in heights { sum += h }
        return sum * columnSpacing
    }

    public var peakHeight: Float {
        heights.max() ?? 0
    }

    public var isEmpty: Bool {
        !heights.contains { $0 > 0 }
    }

    /// Linearly interpolated snow height; 0 outside the surface.
    public func height(atX localX: Float) -> Float {
        Drift.sample(heights, spacing: columnSpacing, width: width, at: localX)
    }

    /// Adds `amount` pt² of snow around `localX`. Returns what was accepted (columns cap at `maxHeight`).
    @discardableResult
    public func deposit(atX localX: Float, amount: Float) -> Float {
        guard amount > 0, amount.isFinite, localX >= 0, localX <= width else { return 0 }
        let f = localX / columnSpacing
        let i = min(Int(f), heights.count - 2)
        let t = min(1, max(0, f - Float(i)))
        let dh = amount / columnSpacing
        let accepted = add(dh * (1 - t), at: i) + add(dh * t, at: i + 1)
        return accepted * columnSpacing
    }

    /// Relaxes slopes steeper than `reposeSlope`. Mass moves only between neighbours,
    /// except at the two ends where it slides off. Returns the amount that slid off (pt²).
    @discardableResult
    public func settle(passes: Int = 1) -> Float {
        let n = heights.count
        guard n >= 2, passes > 0 else { return 0 }
        let maxStep = reposeSlope * columnSpacing
        let edgeMax = maxStep * edgeHold
        var reverse = reverseSweep
        var spillLeft: Float = 0
        var spillRight: Float = 0

        heights.withUnsafeMutableBufferPointer { h in
            for _ in 0..<passes {
                for k in 0..<(n - 1) {
                    let i = reverse ? n - 2 - k : k
                    let diff = h[i] - h[i + 1]
                    if diff > maxStep {
                        let m = (diff - maxStep) * 0.5
                        h[i] -= m
                        h[i + 1] += m
                    } else if diff < -maxStep {
                        let m = (-diff - maxStep) * 0.5
                        h[i] += m
                        h[i + 1] -= m
                    }
                }
                if h[0] > edgeMax {
                    let m = (h[0] - edgeMax) * 0.5
                    h[0] -= m
                    spillLeft += m
                }
                if h[n - 1] > edgeMax {
                    let m = (h[n - 1] - edgeMax) * 0.5
                    h[n - 1] -= m
                    spillRight += m
                }
                reverse.toggle()
            }
        }

        reverseSweep = reverse
        pendingSpillLeft += spillLeft * columnSpacing
        pendingSpillRight += spillRight * columnSpacing
        return (spillLeft + spillRight) * columnSpacing
    }

    /// Removes snow covered by a circle (mitten). Snow below the circle stays. Returns removed pt².
    @discardableResult
    public func sweep(center: SIMD2<Float>, radius: Float) -> Float {
        guard radius > 0, center.x.isFinite, center.y.isFinite else { return 0 }
        let n = heights.count
        let loF = max(0, ((center.x - radius) / columnSpacing).rounded(.up))
        let hiF = min(Float(n - 1), ((center.x + radius) / columnSpacing).rounded(.down))
        guard loF <= hiF else { return 0 }
        let r2 = radius * radius
        var removed: Float = 0
        for i in Int(loF)...Int(hiF) {
            let h = heights[i]
            guard h > 0 else { continue }
            let dx = columnX(i) - center.x
            let dy = (max(0, r2 - dx * dx)).squareRoot()
            let top = center.y - dy
            let bottom = center.y + dy
            guard top <= 0, bottom >= -h else { continue }
            let remaining = min(h, max(0, -bottom))
            removed += h - remaining
            heights[i] = remaining
        }
        return removed * columnSpacing
    }

    /// Packs snow into a snowball: removes `fraction` (0...1) of every column within
    /// `halfWidth` of `localX`, never more than `limit` pt² in total. Returns removed pt².
    @discardableResult
    public func take(aroundX localX: Float, halfWidth: Float, fraction: Float, limit: Float = .infinity) -> Float {
        let f = fraction.isFinite ? max(0, min(1, fraction)) : 0
        guard f > 0, limit > 0, let range = columnRange(aroundX: localX, halfWidth: halfWidth) else { return 0 }
        var wanted: Float = 0
        for i in range { wanted += heights[i] * f }
        guard wanted > 0 else { return 0 }
        let scale = min(1, (limit / columnSpacing) / wanted)
        var removed: Float = 0
        for i in range {
            let dh = min(heights[i], heights[i] * f * scale)
            heights[i] -= dh
            removed += dh
        }
        return removed * columnSpacing
    }

    /// Shovel blade: shaves the top `depth` points off every column within `halfWidth`
    /// of `localX` (top layers first), never more than `limit` pt². Returns removed pt².
    @discardableResult
    public func scrape(aroundX localX: Float, halfWidth: Float, depth: Float, limit: Float = .infinity) -> Float {
        guard depth > 0, depth.isFinite, limit > 0,
              let range = columnRange(aroundX: localX, halfWidth: halfWidth)
        else { return 0 }
        var wanted: Float = 0
        for i in range { wanted += min(heights[i], depth) }
        guard wanted > 0 else { return 0 }
        let scale = min(1, (limit / columnSpacing) / wanted)
        var removed: Float = 0
        for i in range {
            let dh = min(heights[i], min(heights[i], depth) * scale)
            heights[i] -= dh
            removed += dh
        }
        return removed * columnSpacing
    }

    /// Drops `amount` pt² as a tall heap centred on `localX` (a tent roughly `slope` times
    /// as high as it is half wide), widening it where columns are full or off the edge.
    /// The heap then relaxes through `settle`. Returns the accepted pt².
    @discardableResult
    public func depositPile(atX localX: Float, amount: Float, slope: Float = 1.2) -> Float {
        guard amount > 0, amount.isFinite, localX.isFinite else { return 0 }
        let cx = max(0, min(width, localX))
        let k = slope.isFinite ? max(0.1, slope) : 1.2
        var halfWidth = max(columnSpacing * 1.5, (amount / k).squareRoot())
        var remaining = amount
        var accepted: Float = 0
        for _ in 0..<10 {
            guard remaining > 1e-3 else { break }
            defer { halfWidth *= 1.5 }
            guard let range = columnRange(aroundX: cx, halfWidth: halfWidth) else { continue }
            var total: Float = 0
            for i in range {
                total += max(0, 1 - abs(columnX(i) - cx) / halfWidth)
            }
            guard total > 0 else { continue }
            let dh = remaining / columnSpacing / total
            var got: Float = 0
            for i in range {
                let w = max(0, 1 - abs(columnX(i) - cx) / halfWidth)
                if w > 0 { got += add(dh * w, at: i) }
            }
            remaining -= got * columnSpacing
            accepted += got * columnSpacing
        }
        return accepted
    }

    /// Columns whose x lies within `halfWidth` of `localX`, or nil if none.
    private func columnRange(aroundX localX: Float, halfWidth: Float) -> ClosedRange<Int>? {
        guard localX.isFinite, halfWidth.isFinite, halfWidth > 0 else { return nil }
        let n = heights.count
        let loF = max(0, ((localX - halfWidth) / columnSpacing).rounded(.up))
        let hiF = min(Float(n - 1), ((localX + halfWidth) / columnSpacing).rounded(.down))
        guard loF <= hiF else { return nil }
        return Int(loF)...Int(hiF)
    }

    /// Removes `fraction` (0...1) of the snow in every column. Returns removed pt².
    @discardableResult
    public func remove(fraction: Float) -> Float {
        let f = max(0, min(1, fraction))
        guard f > 0 else { return 0 }
        var removed: Float = 0
        for i in heights.indices {
            let dh = heights[i] * f
            heights[i] -= dh
            removed += dh
        }
        return removed * columnSpacing
    }

    /// Empties the drift. Returns removed pt².
    @discardableResult
    public func clear() -> Float {
        let removed = totalSnow
        for i in heights.indices { heights[i] = 0 }
        pendingSpillLeft = 0
        pendingSpillRight = 0
        return removed
    }

    /// Resamples to a new width, anchored at the left edge. Snow past the new
    /// right edge is lost. Returns how much snow was lost (pt², never negative).
    @discardableResult
    public func resize(width newWidth: Float) -> Float {
        let w = Drift.sanitizedWidth(newWidth)
        guard w != width else { return 0 }
        let before = totalSnow
        let oldHeights = heights
        let oldSpacing = columnSpacing
        let oldWidth = width

        let n = Drift.makeColumnCount(width: w, spacing: preferredSpacing)
        width = w
        columnSpacing = w / Float(n - 1)
        var resampled = [Float](repeating: 0, count: n)
        for j in 0..<n {
            let x = Float(j) * columnSpacing
            resampled[j] = Drift.sample(oldHeights, spacing: oldSpacing, width: oldWidth, at: x)
        }
        heights = resampled
        return max(0, before - totalSnow)
    }

    private func add(_ dh: Float, at index: Int) -> Float {
        let accepted = min(dh, max(0, maxHeight - heights[index]))
        heights[index] += accepted
        return accepted
    }

    private static func sanitizedWidth(_ width: Float) -> Float {
        width.isFinite ? max(1, width) : 1
    }

    private static func makeColumnCount(width: Float, spacing: Float) -> Int {
        max(2, Int((width / spacing).rounded(.up)) + 1)
    }

    private static func sample(_ heights: [Float], spacing: Float, width: Float, at x: Float) -> Float {
        guard x >= 0, x <= width, heights.count >= 2 else { return 0 }
        let f = x / spacing
        let i = min(Int(f), heights.count - 2)
        let t = min(1, max(0, f - Float(i)))
        return heights[i] + (heights[i + 1] - heights[i]) * t
    }
}
