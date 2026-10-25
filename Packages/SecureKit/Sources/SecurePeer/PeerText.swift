import Foundation
import SecureCore
import SecureStore

/// Short, plain-language reasons shown on both phones.
public enum PeerText {
    public static func describe(_ error: Error) -> String {
        switch error {
        case PeerError.notConnected: "The other phone isn't connected."
        case PeerError.busy: "Another payment is in progress."
        case PeerError.peer(let failure): failure.message
        case PeerError.timedOut: "The other phone didn't answer in time."
        case PeerError.unexpectedMessage: "The phones got out of step. Try again."
        case PeerError.unconfirmed:
            "Sent, but the other phone hasn't confirmed it yet. Keep both phones on this screen and tap Retry."
        case StoreError.proximity(let failure): describe(failure)
        case StoreError.blocked(let reason): describe(reason)
        case StoreError.needsOverride: "This payment is over budget."
        case StoreError.fork: "This wallet holds double-spend evidence against the other one."
        case StoreError.walletLocked: "The wallet is locked after a failed integrity check."
        case StoreError.chainMoved: "The wallet changed during the payment. Try again."
        case StoreError.invalidTransfer(let reason): "Rejected: \(reason)."
        case is SigningError: "Not approved."
        default: String(describing: error)
        }
    }

    public static func describe(_ failure: ProximityFailure) -> String {
        switch failure {
        case .tooFar(let distance, let limit): "Too far apart: \(distance) cm (the limit is \(limit) cm)."
        case .disagreement(let payer, let payee): "The phones disagree about the distance (\(payer) cm vs \(payee) cm)."
        case .simulatedNotAllowed: "This build only accepts real UWB distance, not simulated."
        case .directionRequired: "Direction is required but wasn't measured."
        case .badSignature: "A distance reading has a bad signature."
        case .nonceMismatch, .wrongParticipants: "The distance readings belong to another session."
        }
    }

    public static func describe(_ reason: BlockReason) -> String {
        switch reason {
        case .hardCap(let status): "Over the hard cap for this budget (\(status.budget.cap.formatted()))."
        case .insufficientFunds(let available, _): "Not enough money: \(available.formatted()) available."
        case .overTransferLimit(let limit, _): "Over the per-payment limit of \(limit.formatted())."
        case .overDailyLimit(let limit, _, _): "Over the daily limit of \(limit.formatted())."
        case .invalidAmount: "Enter an amount above zero."
        }
    }
}
