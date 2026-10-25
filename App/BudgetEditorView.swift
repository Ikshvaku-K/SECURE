import SecureCore
import SecureStore
import SwiftUI

struct BudgetEditorView: View {
    enum PeriodChoice: String, CaseIterable, Identifiable {
        case monthly = "Monthly", weekly = "Weekly", rolling = "Rolling", custom = "Custom"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: Int64?
    @State private var newCategoryName = ""
    @State private var capText = ""
    @State private var period: PeriodChoice = .monthly
    @State private var monthDay = 1
    @State private var weekday = 2
    @State private var lengthDays = 30
    @State private var customStart = Date()
    @State private var alertPercent = 80
    @State private var hardCap = false

    private var cap: Money? { Money.parse(capText, currency: .usd, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("New category…").tag(Int64?.none)
                        ForEach(model.categories) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    if categoryID == nil {
                        TextField("Name, e.g. Groceries", text: $newCategoryName)
                    }
                }
                Section("Limit") {
                    TextField("Amount, e.g. 200", text: $capText).keyboardType(.decimalPad)
                    Picker("Period", selection: $period) {
                        ForEach(PeriodChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch period {
                    case .monthly: Stepper("Starts on day \(monthDay)", value: $monthDay, in: 1...31)
                    case .weekly:
                        Picker("Starts on", selection: $weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                    case .rolling: Stepper("Last \(lengthDays) days", value: $lengthDays, in: 1...365)
                    case .custom:
                        DatePicker("Starts", selection: $customStart, displayedComponents: .date)
                        Stepper("Every \(lengthDays) days", value: $lengthDays, in: 1...365)
                    }
                }
                Section {
                    Stepper("Alert at \(alertPercent) %", value: $alertPercent, in: 50...100, step: 5)
                    Toggle("Hard cap (block instead of warn)", isOn: $hardCap)
                }
            }
            .navigationTitle("New budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(cap == nil || (categoryID == nil && newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    private func save() async {
        guard let cap else { return }
        var id = categoryID
        if id == nil {
            await model.addCategory(name: newCategoryName, iconName: "tag")
            id = model.categories.first { $0.name == newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines) }?.id
        }
        guard let id else { return }
        let budgetPeriod: BudgetPeriod = switch period {
        case .monthly: .monthly(anchorDay: monthDay)
        case .weekly: .weekly(anchorWeekday: weekday)
        case .rolling: .rolling(days: lengthDays)
        case .custom: .custom(start: customStart, lengthDays: lengthDays)
        }
        await model.saveBudget(Budget(id: 0, categoryID: id, cap: cap, period: budgetPeriod, alertPercent: alertPercent, hardCap: hardCap))
        dismiss()
    }
}
