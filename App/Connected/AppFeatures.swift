import SecureConnect

/// Switches for the additional features. Turning one off hides it in the app and makes the store refuse its orders;
/// the engine and its tests stay, so it can come back by flipping the switch.
enum AppFeatures {
    /// Practice sports betting. Off for now.
    nonisolated static let sportsBetting = false

    nonisolated static var enabledMarkets: Set<MarketKind> {
        sportsBetting ? Set(MarketKind.allCases) : [.equity, .prediction]
    }
}
