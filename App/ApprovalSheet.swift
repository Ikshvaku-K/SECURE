import SecureCore
import SecureStore
import SwiftUI

/// Shown when the user opens a payment-request notification instead of using its Approve button.
struct ApprovalSheet: View {
    let request: ApprovalRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var verdict: BudgetVerdict?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(request.payee) requests").foregroundStyle(.secondary)
                        Text(request.amount.formatted())
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    if let category = model.categories.first(where: { $0.id == request.categoryID }) {
                        LabeledContent("Category", value: category.name)
                    }
                    LabeledContent("Proximity", value: "Simulated, 0.40 m")
                }
                if let verdict {
                    Section("Budget check") { VerdictView(verdict: verdict) }
                }
                Section {
                    Button {
                        working = true
                        Task {
                            let paid = await model.approve(request)
                            working = false
                            if paid { dismiss() }
                        }
                    } label: {
                        Label(working ? "Approving…" : "Approve with Face ID", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(working)
                    Button("Deny", role: .destructive) {
                        model.deny(request)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Payment request")
            .navigationBarTitleDisplayMode(.inline)
            .task { verdict = await model.evaluate(amount: request.amount, categoryID: request.categoryID) }
        }
        .presentationDetents([.medium, .large])
    }
}
