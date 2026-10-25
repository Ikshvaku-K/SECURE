import Foundation
import SecureCore

/// Deterministic randomness for the simulators: the same inputs always produce the same simulated world,
/// so tests are reproducible and re-syncing or re-reading prices never changes history.
enum SimRandom {
    /// FNV-1a 64-bit hash, for turning names into seeds.
    static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// A generator keyed by several values (e.g. an account and a day).
    static func generator(_ parts: UInt64...) -> SplitMix64 {
        var mixed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for part in parts {
            mixed = (mixed ^ part) &* 0xBF58_476D_1CE4_E5B9
            mixed ^= mixed >> 31
        }
        return SplitMix64(seed: mixed)
    }

    /// Uniform in [0, 1).
    static func uniform(_ g: inout SplitMix64) -> Double {
        Double(g.next() >> 11) / Double(UInt64(1) << 53)
    }

    /// Standard normal via Box–Muller.
    static func normal(_ g: inout SplitMix64) -> Double {
        let u1 = max(uniform(&g), Double.leastNonzeroMagnitude)
        let u2 = uniform(&g)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    static func day(_ value: Int) -> UInt64 { UInt64(bitPattern: Int64(value)) }
}
