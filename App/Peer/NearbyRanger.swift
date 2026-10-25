import Foundation
import NearbyInteraction
import SecureCore
import SecurePeer
import Synchronization

enum NearbyRangingError: Error {
    case unavailable
    case badPeerToken
    case noFix
    case invalidated(String)
}

/// UWB ranging to one nearby phone with NearbyInteraction. Each link gets its own `NISession`, whose discovery
/// token travels to the peer in the `hello`. Samples arrive continuously once both phones run their sessions;
/// `measure` summarises fresh samples for one payment session, and the summary is then signed into the proof.
nonisolated final class NearbyRanger: NSObject, PeerRanger, NISessionDelegate, @unchecked Sendable {
    struct Sample {
        let time: TimeInterval
        let distance: Double
        let angle: Double?
        let vertical: VerticalEstimate?
    }

    /// True on iPhones with a UWB chip (iPhone 11 and later, except the SE models), and in the Simulator,
    /// which emulates NearbyInteraction.
    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }

    /// The Simulator's NearbyInteraction is an emulation, so its readings carry the `.simulated` flag:
    /// they exercise this code path, but only debug builds accept them as proof.
    static let readingsAreSimulated: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    private let session = NISession()
    private let queue = DispatchQueue(label: "secure.nearby-ranging")
    private let state = Mutex<(samples: [Sample], failure: String?)>(([], nil))
    /// Live distance in metres for the screen; nil when the peer is out of view.
    private let onUpdate: @Sendable (Double?) -> Void

    init(onUpdate: @escaping @Sendable (Double?) -> Void) {
        self.onUpdate = onUpdate
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    var localToken: Data {
        get throws {
            guard let token = session.discoveryToken else { throw NearbyRangingError.unavailable }
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }
    }

    func start(peerToken: Data) async throws {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: peerToken) else {
            throw NearbyRangingError.badPeerToken
        }
        session.run(NINearbyPeerConfiguration(peerToken: token))
    }

    func stop() async {
        session.invalidate()
    }

    /// Waits for fresh samples (at least 10, or 3 over 1.5 s) and summarises them. Gives up after 5 s.
    func measure(peer: WalletPublicKey, sessionNonce: Digest32) async throws -> RangingSummary {
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            let (samples, failure) = state.withLock { state in (state.samples.filter { $0.time >= started }, state.failure) }
            if let failure { throw NearbyRangingError.invalidated(failure) }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if samples.count >= 10 || (elapsed >= 1.5 && samples.count >= 3) {
                return summarize(samples, durationMS: UInt32(elapsed * 1_000))
            }
            guard elapsed < 5 else { throw NearbyRangingError.noFix }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func summarize(_ samples: [Sample], durationMS: UInt32) -> RangingSummary {
        let device = NISession.deviceCapabilities
        var capabilities: RangingCapabilities = [.preciseDistance]
        if Self.readingsAreSimulated { capabilities.insert(.simulated) }
        let angles = samples.compactMap(\.angle).sorted()
        if device.supportsDirectionMeasurement, !angles.isEmpty { capabilities.insert(.direction) }
        return RangingSummary.summarize(distancesMeters: samples.map(\.distance), capabilities: capabilities,
                                        azimuthRadians: angles.isEmpty ? nil : angles[angles.count / 2],
                                        vertical: samples.last?.vertical, durationMS: durationMS)!
    }

    // MARK: NISessionDelegate (on `queue`)

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first, let distance = object.distance else { return }
        let sample = Sample(time: ProcessInfo.processInfo.systemUptime, distance: Double(distance),
                            angle: object.horizontalAngle.map(Double.init),
                            vertical: VerticalEstimate(rawValue: UInt8(clamping: object.verticalDirectionEstimate.rawValue)))
        state.withLock { state in
            state.samples.append(sample)
            if state.samples.count > 200 { state.samples.removeFirst(state.samples.count - 200) }
        }
        onUpdate(Double(distance))
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        onUpdate(nil)
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let configuration = session.configuration { session.run(configuration) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        state.withLock { $0.failure = error.localizedDescription }
        onUpdate(nil)
    }
}
