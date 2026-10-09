/// Hashing and randomness with a frozen, documented algorithm.
///
/// Swift's `Hasher` is randomly seeded per process and the standard library's sampling helpers are
/// not specified across releases, so neither may ever touch the city. Everything here is
/// FNV-1a 64 + the SplitMix64 finalizer: tiny, fully specified, identical on every platform.
public struct StableHasher: Sendable {
    private var state: UInt64 = 0xCBF2_9CE4_8422_2325

    public init() {}

    public init(seed: UInt64) {
        combine(seed)
    }

    @inlinable
    static var prime: UInt64 { 0x0000_0100_0000_01B3 }

    public mutating func combine(byte: UInt8) {
        state = (state ^ UInt64(byte)) &* StableHasher.prime
    }

    public mutating func combine(_ value: UInt64) {
        var remaining = value
        for _ in 0..<8 {
            combine(byte: UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    public mutating func combine(_ value: Int64) {
        combine(UInt64(bitPattern: value))
    }

    public mutating func combine(_ value: Int) {
        combine(Int64(value))
    }

    /// Strings are hashed as UTF-8 followed by a 0xFF terminator (never valid UTF-8), so
    /// ("ab","c") and ("a","bc") cannot collide by concatenation.
    public mutating func combine(_ value: String) {
        for byte in value.utf8 {
            combine(byte: byte)
        }
        combine(byte: 0xFF)
    }

    public func finalize() -> UInt64 {
        SplitMix64.mix(state)
    }

    public static func hash(_ string: String) -> UInt64 {
        var hasher = StableHasher()
        hasher.combine(string)
        return hasher.finalize()
    }
}

/// SplitMix64 (Steele, Lea, Flood 2014).
public struct SplitMix64: Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return SplitMix64.mix(state)
    }

    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1) from the top 53 bits.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

/// A 32-bit detail hash that JavaScript can reproduce exactly with `Math.imul` (the web viewer
/// mirrors this function). Used for every per-window / per-tree decision in the geometry, so the
/// SVG, the widget and the viewer agree on which windows are lit.
@inlinable
public func detailHash(_ seed: UInt32, _ a: Int, _ b: Int) -> UInt32 {
    var h = seed ^ 0x9E37_79B9
    h = (h ^ UInt32(truncatingIfNeeded: a)) &* 0x85EB_CA6B
    h = (h ^ (h >> 13)) &* 0xC2B2_AE35
    h = (h ^ UInt32(truncatingIfNeeded: b)) &* 0x27D4_EB2F
    h ^= h >> 15
    h = h &* 0x1656_67B1
    h ^= h >> 16
    return h
}

/// `detailHash` mapped to [0, 1).
@inlinable
public func detailUnit(_ seed: UInt32, _ a: Int, _ b: Int) -> Double {
    Double(detailHash(seed, a, b)) / 4_294_967_296.0
}

extension UInt64 {
    /// Fixed-width lowercase hex, used for keys in JSON (JS numbers cannot hold 64-bit ints).
    var hex16: String {
        let digits = String(self, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
