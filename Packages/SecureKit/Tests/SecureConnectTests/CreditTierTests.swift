import Foundation
import Testing
@testable import SecureConnect
@testable import SecureCore

@Suite("Credit tiers")
struct CreditTierTests {
    @Test(arguments: [(300, CreditTier.poor), (579, .poor), (580, .fair), (669, .fair), (670, .good), (739, .good),
                      (740, .veryGood), (799, .veryGood), (800, .exceptional), (850, .exceptional)])
    func bandsMatchFICORanges(score: Int, tier: CreditTier) {
        #expect(CreditScore(score)?.tier == tier)
    }

    @Test func rejectsScoresOutsideTheRange() {
        #expect(CreditScore(299) == nil)
        #expect(CreditScore(851) == nil)
    }

    @Test func everyScoreFallsInExactlyOneBand() {
        for value in CreditScore.range {
            #expect(CreditTier.allCases.filter { $0.scoreRange.contains(value) }.count == 1)
        }
    }

    @Test func accessGrowsWithEachTier() {
        let tiers = CreditTier.allCases
        for (lower, higher) in zip(tiers, tiers.dropFirst()) {
            #expect(lower.limits.transactionsPerDay < higher.limits.transactionsPerDay)
            #expect(lower.limits.maxPerTransaction < higher.limits.maxPerTransaction)
        }
        #expect(CreditTier.poor.limits == TierLimits(transactionsPerDay: 3, maxPerTransaction: Money(minorUnits: 100_00, currency: .usd)))
        #expect(CreditTier.exceptional.limits.transactionsPerDay == 50)
    }

    @Test func profileRoundTrips() throws {
        let profile = CreditProfile(score: CreditScore(615)!, source: .demoProfile, label: "Jordan", updatedAtMS: 42)
        #expect(try CreditProfile(canonicalBytes: profile.canonicalBytes) == profile)
        let bare = CreditProfile(score: CreditScore(800)!, source: .selfReported, updatedAtMS: 7)
        #expect(try CreditProfile(canonicalBytes: bare.canonicalBytes) == bare)
    }

    @Test func demoProfilesCoverEveryTier() {
        let tiers = Set(DemoCreditProfile.all.compactMap { CreditScore($0.score)?.tier })
        #expect(tiers == Set(CreditTier.allCases))
    }
}
