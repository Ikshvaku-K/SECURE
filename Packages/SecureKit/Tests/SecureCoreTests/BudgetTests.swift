import Foundation
import Testing
@testable import SecureCore

@Suite("Budget windows")
struct BudgetWindowTests {
    let utc = Fixtures.utcCalendar()

    @Test func monthlyAnchorIsClampedToShortMonths() throws {
        let period = BudgetPeriod.monthly(anchorDay: 31)
        let early = try #require(period.window(containing: Fixtures.date(2026, 2, 10), calendar: utc))
        #expect(early.start == Fixtures.date(2026, 1, 31, 0))
        #expect(early.end == Fixtures.date(2026, 2, 28, 0))

        let late = try #require(period.window(containing: Fixtures.date(2026, 2, 28, 10), calendar: utc))
        #expect(late.start == Fixtures.date(2026, 2, 28, 0))
        #expect(late.end == Fixtures.date(2026, 3, 31, 0))
    }

    @Test func monthlyFromTheFirst() throws {
        let window = try #require(BudgetPeriod.monthly(anchorDay: 1).window(containing: Fixtures.date(2026, 10, 24), calendar: utc))
        #expect(window.start == Fixtures.date(2026, 10, 1, 0))
        #expect(window.end == Fixtures.date(2026, 11, 1, 0))
    }

    @Test func weeklyStartsOnTheAnchorWeekday() throws {
        // 2026-10-21 is a Wednesday; weekday 2 is Monday.
        let window = try #require(BudgetPeriod.weekly(anchorWeekday: 2).window(containing: Fixtures.date(2026, 10, 21), calendar: utc))
        #expect(window.start == Fixtures.date(2026, 10, 19, 0))
        #expect(window.end == Fixtures.date(2026, 10, 26, 0))
    }

    @Test func weeklyWindowSpansADaylightSavingChange() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // US clocks fall back on 2026-11-01, so this calendar week is 169 hours long.
        let now = Fixtures.date(2026, 10, 29, 12, calendar: newYork)
        let window = try #require(BudgetPeriod.weekly(anchorWeekday: 2).window(containing: now, calendar: newYork))
        #expect(window.end.timeIntervalSince(window.start) == 169 * 3600)
    }

    @Test func rollingCoversTheLastNDays() throws {
        let now = Fixtures.date(2026, 10, 24)
        let window = try #require(BudgetPeriod.rolling(days: 7).window(containing: now, calendar: utc))
        #expect(window.start == Fixtures.date(2026, 10, 17))
        #expect(window.end > now)
    }

    @Test func customRepeatsInBlocks() throws {
        let period = BudgetPeriod.custom(start: Fixtures.date(2026, 10, 1, 0), lengthDays: 10)
        let window = try #require(period.window(containing: Fixtures.date(2026, 10, 24), calendar: utc))
        #expect(window.start == Fixtures.date(2026, 10, 21, 0))
        #expect(window.end == Fixtures.date(2026, 10, 31, 0))
        #expect(period.window(containing: Fixtures.date(2026, 9, 30), calendar: utc) == nil)
    }

    @Test func invalidPeriodsHaveNoWindow() {
        #expect(BudgetPeriod.monthly(anchorDay: 0).window(containing: Date(), calendar: utc) == nil)
        #expect(BudgetPeriod.weekly(anchorWeekday: 8).window(containing: Date(), calendar: utc) == nil)
        #expect(BudgetPeriod.rolling(days: 0).window(containing: Date(), calendar: utc) == nil)
    }
}

@Suite("Budget engine")
struct BudgetEngineTests {
    let clothing = Budget(id: 1, categoryID: 7, cap: Fixtures.dollars(20_000), period: .monthly(anchorDay: 1), alertPercent: 80)
    let now = Fixtures.date(2026, 10, 24)

    func verdict(cents: Int64, spent: Int64, budgets: [Budget]? = nil, available: Int64? = 100_000,
                 limits: OfflineLimits = .none, spentToday: Int64 = 0, category: Int64? = 7) -> BudgetVerdict {
        BudgetEngine.evaluate(amount: Fixtures.dollars(cents), categoryID: category, budgets: budgets ?? [clothing], now: now,
                              calendar: Fixtures.utcCalendar(), available: available.map(Fixtures.dollars), limits: limits,
                              spentToday: spentToday) { _, _ in spent }
    }

    @Test func withinBudgetIsOK() {
        guard case .ok(let statuses) = verdict(cents: 2_500, spent: 10_000) else { Issue.record("expected ok"); return }
        #expect(statuses.first?.spentAfter == 12_500)
    }

    @Test func thePRDExampleRaisesAnAlert() {
        // $180 spent of $200, approving $15 → $195: past the 80 % line, still under the cap.
        guard case .alert(let statuses) = verdict(cents: 1_500, spent: 18_000) else { Issue.record("expected alert"); return }
        #expect(statuses.first?.reachesAlert == true)
        #expect(statuses.first?.isOver == false)
    }

    @Test func goingOverASoftCapNeedsAnOverride() {
        // $180 spent + $25 = $205 > $200.
        let result = verdict(cents: 2_500, spent: 18_000)
        guard case .overBudget = result else { Issue.record("expected overBudget"); return }
        #expect(!result.allowsCommit(overrideOverBudget: false))
        #expect(result.allowsCommit(overrideOverBudget: true))
    }

    @Test func hardCapsBlock() {
        var hard = clothing
        hard.hardCap = true
        guard case .blocked(.hardCap) = verdict(cents: 2_500, spent: 18_000, budgets: [hard]) else {
            Issue.record("expected hard cap"); return
        }
    }

    @Test func balanceAndOfflineLimitsBlockFirst() {
        guard case .blocked(.insufficientFunds) = verdict(cents: 2_500, spent: 0, available: 1_000) else {
            Issue.record("expected insufficient funds"); return
        }
        guard case .blocked(.overTransferLimit) = verdict(cents: 6_000, spent: 0, limits: OfflineLimits(perTransfer: Fixtures.dollars(5_000))) else {
            Issue.record("expected transfer limit"); return
        }
        guard case .blocked(.overDailyLimit) = verdict(cents: 3_000, spent: 0, limits: OfflineLimits(perDay: Fixtures.dollars(10_000)),
                                                       spentToday: 8_000) else {
            Issue.record("expected daily limit"); return
        }
        guard case .blocked(.invalidAmount) = verdict(cents: 0, spent: 0) else { Issue.record("expected invalid"); return }
    }

    @Test func issuersHaveNoBalanceLimit() {
        guard case .ok = verdict(cents: 1_000_000, spent: 0, budgets: [], available: nil) else { Issue.record("expected ok"); return }
    }

    @Test func otherCategoriesAreUnaffected() {
        guard case .ok(let statuses) = verdict(cents: 50_000, spent: 18_000, category: 8) else { Issue.record("expected ok"); return }
        #expect(statuses.isEmpty)
    }
}
