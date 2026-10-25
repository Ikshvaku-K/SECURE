import Foundation
import SecureCore

/// Distance measurement for one link to one nearby phone. On a phone this wraps a NearbyInteraction session,
/// whose discovery token travels in the `hello`; in the Simulator and in tests it is simulated.
public protocol PeerRanger: RangingSession {
    /// Sent to the peer in `hello`. Empty when ranging is simulated.
    var localToken: Data { get async throws }
    /// Starts ranging once the peer's token has arrived.
    func start(peerToken: Data) async throws
    func stop() async
}

/// Simulated ranging for the Simulator and tests. Every summary carries the `.simulated` flag, which
/// `ProximityPolicy.device` rejects, so it can never pass on a release build.
public struct SimulatedPeerRanger: PeerRanger {
    public var ranging: SimulatedRanging

    public init(distanceMeters: Double = 0.4, noiseMeters: Double = 0.03, seed: UInt64? = nil) {
        ranging = SimulatedRanging(trueDistanceMeters: distanceMeters, noiseMeters: noiseMeters, seed: seed)
    }

    public var localToken: Data { Data() }
    public func start(peerToken: Data) async throws {}
    public func stop() async {}

    public func measure(peer: WalletPublicKey, sessionNonce: Digest32) async throws -> RangingSummary {
        try await ranging.measure(peer: peer, sessionNonce: sessionNonce)
    }
}
