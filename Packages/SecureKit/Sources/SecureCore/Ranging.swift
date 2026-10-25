import Foundation

/// What the measuring phone could do during this measurement. Signed into every proof,
/// so a verifier can tell a UWB fix from a simulated one.
public struct RangingCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let preciseDistance = RangingCapabilities(rawValue: 1 << 0)
    public static let direction = RangingCapabilities(rawValue: 1 << 1)
    public static let cameraAssistance = RangingCapabilities(rawValue: 1 << 2)
    public static let extendedDistance = RangingCapabilities(rawValue: 1 << 3)
    /// Produced by `SimulatedRanging`. Real devices reject these unless the policy allows them.
    public static let simulated = RangingCapabilities(rawValue: 1 << 7)
}

/// Mirrors `NINearbyObject.VerticalDirectionEstimate`.
public enum VerticalEstimate: UInt8, Sendable {
    case unknown = 0, same = 1, above = 2, below = 3, aboveOrBelow = 4
}

/// One phone's summary of a ranging window.
public struct RangingSummary: Equatable, Sendable {
    /// Median distance.
    public var distanceCM: UInt16
    /// Spread between the 10th and 90th percentile samples.
    public var spreadCM: UInt16
    public var samples: UInt16
    /// Horizontal angle to the peer in hundredths of a degree, when the hardware reports one.
    public var azimuthCentiDegrees: Int16?
    public var vertical: VerticalEstimate?
    public var capabilities: RangingCapabilities
    public var durationMS: UInt32

    public init(distanceCM: UInt16, spreadCM: UInt16, samples: UInt16, azimuthCentiDegrees: Int16? = nil,
                vertical: VerticalEstimate? = nil, capabilities: RangingCapabilities, durationMS: UInt32) {
        self.distanceCM = distanceCM
        self.spreadCM = spreadCM
        self.samples = samples
        self.azimuthCentiDegrees = azimuthCentiDegrees
        self.vertical = vertical
        self.capabilities = capabilities
        self.durationMS = durationMS
    }

    /// Reduces raw distance samples (metres) to a summary.
    public static func summarize(distancesMeters: [Double], capabilities: RangingCapabilities,
                                 azimuthRadians: Double? = nil, vertical: VerticalEstimate? = nil,
                                 durationMS: UInt32) -> RangingSummary? {
        guard !distancesMeters.isEmpty else { return nil }
        let sorted = distancesMeters.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
        func centimetres(_ metres: Double) -> UInt16 { UInt16(clamping: Int((max(0, metres) * 100).rounded())) }
        let azimuth = azimuthRadians.map { Int16(clamping: Int(($0 * 180 / .pi * 100).rounded())) }
        return RangingSummary(distanceCM: centimetres(percentile(0.5)),
                              spreadCM: centimetres(percentile(0.9) - percentile(0.1)),
                              samples: UInt16(clamping: sorted.count),
                              azimuthCentiDegrees: azimuth, vertical: vertical,
                              capabilities: capabilities, durationMS: durationMS)
    }
}

/// Measures the distance to a peer during a live session. On device this is NearbyInteraction (Phase 3).
public protocol RangingSession: Sendable {
    func measure(peer: WalletPublicKey, sessionNonce: Digest32) async throws -> RangingSummary
}

/// Stand-in for UWB on the Simulator and in tests. Every summary it produces carries the `.simulated` flag.
public struct SimulatedRanging: RangingSession {
    public var trueDistanceMeters: Double
    public var noiseMeters: Double
    public var sampleCount: Int
    public var seed: UInt64?

    public init(trueDistanceMeters: Double = 0.4, noiseMeters: Double = 0.03, sampleCount: Int = 20, seed: UInt64? = nil) {
        self.trueDistanceMeters = trueDistanceMeters
        self.noiseMeters = noiseMeters
        self.sampleCount = sampleCount
        self.seed = seed
    }

    public func measure(peer: WalletPublicKey, sessionNonce: Digest32) async throws -> RangingSummary {
        var generator = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))
        let samples = (0..<max(1, sampleCount)).map { _ in
            trueDistanceMeters + Double.random(in: -noiseMeters...noiseMeters, using: &generator)
        }
        return RangingSummary.summarize(distancesMeters: samples, capabilities: [.preciseDistance, .simulated],
                                        durationMS: UInt32(sampleCount) * 50)!
    }
}

/// Small deterministic generator so simulated measurements are reproducible in tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
