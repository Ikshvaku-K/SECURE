import Foundation

extension Date {
    /// Milliseconds since 1970, as stored in the ledger and signed into messages.
    public var millisecondsSince1970: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }

    public init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
