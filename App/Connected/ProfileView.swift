import SecureConnect
import SecureCore
import SwiftUI

/// Credit score (self-reported or demo), the access each tier gives, and responsible-play controls.
struct ProfileView: View {
    @Environment(ConnectedModel.self) private var connected
    @State private var scoreText = ""
    @State private var confirmingCoolOff: Int?
    @State private var confirmingExclusion = false

    var body: some View {
        NavigationStack {
            ConnectedGate {
                List {
                    CreditScoreSection()
                    Section {
                        HStack {
                            TextField("Score (300–850)", text: $scoreText).keyboardType(.numberPad)
                            Button("Save") {
                                Task {
                                    await connected.setScore(Int(scoreText) ?? 0, source: .selfReported)
                                    scoreText = ""
                                }
                            }
                            .disabled(CreditScore(Int(scoreText) ?? 0) == nil)
                        }
                        ForEach(DemoCreditProfile.all) { demo in
                            Button {
                                Task { await connected.setScore(demo.score, source: .demoProfile, label: demo.name) }
                            } label: {
                                LabeledContent("Demo: \(demo.name)", value: "\(demo.score) · \(CreditScore(demo.score)!.tier.name)")
                            }
                        }
                    } header: {
                        Text("Set your score")
                    } footer: {
                        Text("Self-reported or demo only: no credit bureau is contacted and nothing leaves the phone.")
                    }
                    TierTableSection()
                    ResponsiblePlaySection(confirmingCoolOff: $confirmingCoolOff, confirmingExclusion: $confirmingExclusion)
                }
            }
            .navigationTitle("Profile")
            .overlay(alignment: .bottom) { ConnectedBanner() }
            .confirmationDialog("Start a cool-off?", isPresented: Binding(get: { confirmingCoolOff != nil }, set: { if !$0 { confirmingCoolOff = nil } }),
                                titleVisibility: .visible, presenting: confirmingCoolOff) { days in
                Button("Start \(days == 1 ? "24-hour" : "\(days)-day") cool-off", role: .destructive) { Task { await connected.startCoolOff(days: days) } }
            } message: { _ in
                Text("You won't be able to buy or bet until it ends, and it can't be shortened. Selling stays possible.")
            }
            .confirmationDialog("Self-exclude for 30 days?", isPresented: $confirmingExclusion, titleVisibility: .visible) {
                Button("Self-exclude for 30 days", role: .destructive) { Task { await connected.selfExclude(days: 30) } }
            } message: {
                Text("Practice markets stay locked for 30 days. This can't be undone early.")
            }
        }
    }
}

struct CreditScoreSection: View {
    @Environment(ConnectedModel.self) private var connected

    var body: some View {
        Section("Credit score") {
            if let profile = connected.creditProfile {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(profile.score.value)").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(profile.tier.name).font(.title3.weight(.semibold)).foregroundStyle(profile.tier.color)
                    Spacer()
                }
                Text([profile.source.displayName, profile.label.map { "persona \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Practice transactions today", value: "\(connected.transactionsToday) of \(profile.tier.limits.transactionsPerDay)")
                LabeledContent("Largest single transaction", value: profile.tier.limits.maxPerTransaction.formatted())
            } else {
                Label("No score set: practice markets are locked.", systemImage: "lock")
            }
        }
    }
}

struct TierTableSection: View {
    @Environment(ConnectedModel.self) private var connected

    var body: some View {
        Section {
            ForEach(CreditTier.allCases, id: \.self) { tier in
                HStack {
                    Circle().fill(tier.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tier.name).fontWeight(connected.tier == tier ? .bold : .regular)
                        Text("\(tier.scoreRange.lowerBound)–\(tier.scoreRange.upperBound)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(tier.limits.transactionsPerDay)/day · ≤ \(tier.limits.maxPerTransaction.formatted())")
                        .font(.callout).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Access by tier")
        } footer: {
            Text("Applies to practice-market transactions only (buys, sells and bets). Wallet transfers between phones are never limited by the credit score.")
        }
    }
}

struct ResponsiblePlaySection: View {
    @Environment(ConnectedModel.self) private var connected
    @Binding var confirmingCoolOff: Int?
    @Binding var confirmingExclusion: Bool

    private static let stakeLimits: [Int64?] = [100_00, 250_00, 500_00, 1_000_00, 2_500_00, nil]

    var body: some View {
        let settings = connected.playSettings
        let nowMS = Date().millisecondsSince1970
        Section {
            Picker("Age confirmed", selection: Binding(get: { settings.age }, set: { age in
                var updated = settings
                updated.age = age
                Task { await connected.updatePlaySettings(updated) }
            })) {
                ForEach(AgeConfirmation.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Daily stake limit", selection: Binding(get: { settings.dailyStakeLimit?.minorUnits }, set: { minor in
                var updated = settings
                updated.dailyStakeLimit = minor.map { Money(minorUnits: $0, currency: .usd) }
                Task { await connected.updatePlaySettings(updated) }
            })) {
                ForEach(Self.stakeLimits, id: \.self) { minor in
                    Text(minor.map { Money(minorUnits: $0, currency: .usd).formatted() } ?? "No limit").tag(minor)
                }
            }
            LabeledContent("Staked today", value: connected.stakedToday.formatted())
            if settings.isCoolingOff(atMS: nowMS), let until = settings.coolOffUntilMS {
                Label("Cooling off until \(Date(millisecondsSince1970: until).formatted(date: .abbreviated, time: .shortened))", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            } else {
                Button("Cool off for 24 hours") { confirmingCoolOff = 1 }
                Button("Cool off for 7 days") { confirmingCoolOff = 7 }
            }
            if settings.isSelfExcluded(atMS: nowMS), let until = settings.selfExcludedUntilMS {
                Label("Self-excluded until \(Date(millisecondsSince1970: until).formatted(date: .abbreviated, time: .omitted))", systemImage: "hand.raised.fill")
                    .foregroundStyle(.red)
            } else {
                Button("Self-exclude for 30 days", role: .destructive) { confirmingExclusion = true }
            }
        } header: {
            Text("Responsible play")
        } footer: {
            Text("Practice money only. Practice markets need 18+\(AppFeatures.sportsBetting ? ", sports 21+" : ""). Cool-offs and self-exclusion can't be shortened once started. If betting stops being fun, the National Council on Problem Gambling (ncpgambling.org) can help.")
        }
    }
}
