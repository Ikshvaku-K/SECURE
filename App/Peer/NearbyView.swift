@preconcurrency import MultipeerConnectivity
import SecureCore
import SecurePeer
import SecureStore
import SwiftUI

/// Pay or get paid by a phone next to you. Both people open this screen; nothing goes over the internet.
struct NearbyView: View {
    @Environment(AppModel.self) private var model
    @Environment(NearbyModel.self) private var nearby
    @State private var payee: NearbyModel.Phone?

    var body: some View {
        @Bindable var nearby = nearby
        List {
            Section {
                Label {
                    Text(nearby.phones.isEmpty ? "Looking for nearby phones…" : "Visible to nearby phones")
                } icon: {
                    Image(systemName: "iphone.radiowaves.left.and.right").symbolEffect(.variableColor.iterative, isActive: nearby.isRunning)
                }
                LabeledContent("Your name") {
                    TextField("Name", text: $nearby.displayName).multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Both people open this screen and hold their phones close. A payment needs both people's Face ID and goes through only when the phones measure each other within 1 m. Nothing is sent over the internet.")
            }

            Section("Nearby") {
                if nearby.phones.isEmpty {
                    Text("No phones yet. Open S.E.C.U.R.E ▸ Wallet ▸ Pay or get paid nearby on the other phone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(nearby.phones) { phone in
                    Button { payee = phone } label: { NearbyPhoneRow(phone: phone) }
                        .disabled(!phone.isReady || nearby.progress != nil || model.integrity.isLocked)
                }
            }

            ForEach(nearby.phones.filter { !$0.pending.isEmpty }) { phone in
                Section {
                    ForEach(phone.pending, id: \.seq) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(entry.amount.formatted()) to \(phone.name)")
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Retry") { Task { await nearby.retry(entry, to: phone.id) } }
                                .buttonStyle(.bordered)
                                .disabled(nearby.progress != nil)
                        }
                    }
                } header: {
                    Text("Waiting for confirmation")
                } footer: {
                    Text("Sent from this wallet, but \(phone.name) hasn't countersigned yet. Retry sends the same signed payment again; it can't be credited twice.")
                }
            }
        }
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nearby.start(model) }
        .onDisappear { nearby.stop() }
        .sheet(item: $payee) { phone in NearbyPaySheet(phone: phone) }
        .sheet(item: $nearby.incoming) { offer in IncomingOfferSheet(offer: offer) }
        .overlay {
            if let progress = nearby.progress, nearby.incoming == nil, payee == nil {
                NearbyProgressCard(progress: progress)
            }
        }
    }
}

struct NearbyPhoneRow: View {
    let phone: NearbyModel.Phone

    var body: some View {
        HStack {
            Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name).foregroundStyle(.primary)
                Text(phone.identity?.walletKey.fingerprint ?? "Connecting…").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let distance = phone.distance {
                    Text(distance.formatted(.number.precision(.fractionLength(2))) + " m").monospacedDigit()
                        .foregroundStyle(distance <= 1 ? Color.green : Color.orange)
                    if phone.simulatedRanging {
                        Text("Simulated").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text(distance <= 1 ? "Close enough" : "Move closer").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if phone.simulatedRanging {
                    Text("0.40 m").monospacedDigit()
                    Text("Simulated").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NearbyPaySheet: View {
    let phone: NearbyModel.Phone
    @Environment(AppModel.self) private var model
    @Environment(NearbyModel.self) private var nearby
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var categoryID: Int64?
    @State private var verdict: BudgetVerdict?
    @State private var confirmingOverBudget = false
    @State private var working = false
    @FocusState private var amountFocused: Bool

    private var amount: Money? { Money.parse(amountText, currency: .usd, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .focused($amountFocused)
                }
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("None").tag(Int64?.none)
                        ForEach(model.categories) { category in
                            Label(category.name, systemImage: category.iconName ?? "tag").tag(Int64?.some(category.id))
                        }
                    }
                }
                Section {
                    LabeledContent("To", value: phone.name)
                    LabeledContent("Wallet") { Text(phone.identity?.walletKey.fingerprint ?? "").font(.caption.monospaced()) }
                    if let progress = nearby.progress, working {
                        Label(NearbyProgressCard.text(for: progress), systemImage: NearbyProgressCard.icon(for: progress.step))
                    }
                } footer: {
                    Text("Check the wallet code with the other person. The category stays on this phone; they see the amount and both signed distance readings.")
                }
                if let verdict {
                    Section("Budget check") { VerdictView(verdict: verdict) }
                }
            }
            .navigationTitle("Pay nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: {
                        if working { ProgressView() } else { Label("Send", systemImage: "faceid") }
                    }
                    .disabled(amount == nil || amount?.minorUnits == 0 || working || isBlocked)
                }
            }
            .interactiveDismissDisabled(working)
            .task(id: "\(amountText)|\(String(describing: categoryID))") {
                guard let amount, amount.minorUnits > 0 else { verdict = nil; return }
                verdict = await model.evaluate(amount: amount, categoryID: categoryID)
            }
            .confirmationDialog("Over budget", isPresented: $confirmingOverBudget, titleVisibility: .visible) {
                Button("Pay anyway", role: .destructive) { submit(overrideOverBudget: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This payment goes over your budget. Approving it still needs Face ID.")
            }
            .onAppear { amountFocused = true }
        }
    }

    private var isBlocked: Bool {
        if case .blocked = verdict { return true }
        return false
    }

    private func submit(overrideOverBudget: Bool = false) {
        guard let amount else { return }
        if case .overBudget = verdict, !overrideOverBudget {
            confirmingOverBudget = true
            return
        }
        working = true
        amountFocused = false
        Task {
            let paid = await nearby.pay(phone.id, amount: amount, categoryID: categoryID, overrideOverBudget: overrideOverBudget)
            working = false
            if paid { dismiss() }
        }
    }
}

struct IncomingOfferSheet: View {
    let offer: IncomingOffer
    @Environment(NearbyModel.self) private var nearby

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(offer.isRedelivery ? "\(offer.from.displayName) is re-sending" : "\(offer.from.displayName) wants to pay you")
                            .foregroundStyle(.secondary)
                        Text(offer.amount.formatted()).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Wallet") { Text(offer.from.walletKey.fingerprint).font(.caption.monospaced()) }
                    if let phone = nearby.phones.first(where: { $0.identity?.walletKey == offer.from.walletKey }) {
                        LabeledContent("Distance", value: (phone.distance.map { $0.formatted(.number.precision(.fractionLength(2))) + " m" }
                                                           ?? (phone.simulatedRanging ? "0.40 m" : "Measuring…"))
                                       + (phone.simulatedRanging ? " (simulated)" : ""))
                    }
                } footer: {
                    Text(offer.isRedelivery
                         ? "They paid this earlier but your phone didn't confirm it. Confirming records it once and countersigns a receipt."
                         : "Accepting asks for Face ID, then both phones measure the distance and sign it.")
                }
                Section {
                    Button { nearby.answer(true) } label: {
                        Label(offer.isRedelivery ? "Confirm with Face ID" : "Accept with Face ID", systemImage: "faceid")
                    }
                    Button("Decline", role: .destructive) { nearby.answer(false) }
                }
            }
            .navigationTitle("Incoming payment")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

struct NearbyProgressCard: View {
    let progress: NearbyModel.Progress

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Label(Self.text(for: progress), systemImage: Self.icon(for: progress.step)).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .padding(40)
    }

    static func text(for progress: NearbyModel.Progress) -> String {
        switch progress.step {
        case .waitingForPeer: "Waiting for \(progress.peerName)…"
        case .approving: "Approve with Face ID"
        case .measuring: "Measuring the distance…"
        case .confirming: "Confirming…"
        }
    }

    static func icon(for step: PeerPaymentStep) -> String {
        switch step {
        case .waitingForPeer: "hourglass"
        case .approving: "faceid"
        case .measuring: "ruler"
        case .confirming: "checkmark.seal"
        }
    }
}
