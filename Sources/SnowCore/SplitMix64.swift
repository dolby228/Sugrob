/// Small deterministic PRNG so simulations are reproducible from a seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in `0..<1`.
    public mutating func unit() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// Uniform value in `range`.
    public mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// Uniform value in `-1..<1`.
    public mutating func signedUnit() -> Float {
        unit() * 2 - 1
    }
}
