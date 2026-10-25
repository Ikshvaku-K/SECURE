import SecureConnect
import SecureCore
import SwiftUI

/// Shows the feature content once the connected store has opened.
struct ConnectedGate<Content: View>: View {
    @Environment(ConnectedModel.self) private var connected
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch connected.phase {
        case .loading:
            ProgressView("Loading…")
        case .failed(let message):
            ContentUnavailableView("Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            content()
        }
    }
}

struct ConnectedBanner: View {
    @Environment(ConnectedModel.self) private var connected

    var body: some View {
        if let banner = connected.banner {
            Label(banner.text, systemImage: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .foregroundStyle(banner.kind == .success ? Color.primary : Color.red)
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner.id) {
                    // Several screens host a banner. A cancelled timer (hidden screen) must not clear it early.
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    withAnimation { if connected.banner?.id == banner.id { connected.banner = nil } }
                }
                .onTapGesture { withAnimation { connected.banner = nil } }
        }
    }
}

/// "Simulated · practice money" tag used on every market screen.
struct SimulatedBadge: View {
    var text = "Simulated · practice money"

    var body: some View {
        Label(text, systemImage: "testtube.2")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15), in: .capsule)
            .foregroundStyle(.orange)
    }
}

extension CreditTier {
    var color: Color {
        switch self {
        case .poor: .red
        case .fair: .orange
        case .good: Color(red: 0.55, green: 0.41, blue: 0.08)
        case .veryGood: .green
        case .exceptional: .teal
        }
    }
}

func cents(_ value: Int) -> String { "\(value)¢" }

func signed(_ money: Money) -> String {
    (money.minorUnits > 0 ? "+" : "") + money.formatted()
}

func oddsText(_ american: Int) -> String { american > 0 ? "+\(american)" : "\(american)" }

func percent(_ value: Double, digits: Int = 1) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(digits))) + " %"
}
