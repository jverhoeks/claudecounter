import XCTest
@testable import ClaudeCounterCore

final class NotificationsTests: XCTestCase {

    private func stat(_ id: String, warnings: SessionWarnings) -> SessionStat {
        SessionStat(
            sessionID: id, project: "-Users-me-src-proj", model: "claude-opus-4-8",
            costUSD: 1, cost5mUSD: 0.5, cacheCreate5mUSD: 3.0,
            contextTokens: 180_000, contextWindow: 200_000, contextPct: 0.9,
            cacheCreateCostUSD: 3.0, turns: 10, ageSeconds: 120, warnings: warnings)
    }

    func test_context_postsOnce_thenDebounced() {
        let sessions = [stat("s1", warnings: .context)]

        let first = newlyTriggered(active: sessions, alreadyNotified: [])
        XCTAssertEqual(first.toPost.count, 1)
        XCTAssertEqual(first.toPost.first?.condition, "context")
        XCTAssertTrue(first.nextNotified.contains("s1|context"))

        // Same session still active + already-notified → nothing new.
        let second = newlyTriggered(active: sessions, alreadyNotified: first.nextNotified)
        XCTAssertTrue(second.toPost.isEmpty)
    }

    func test_reArms_afterSessionLeavesActiveSet() {
        let warned = [stat("s1", warnings: .context)]
        let first = newlyTriggered(active: warned, alreadyNotified: [])
        XCTAssertEqual(first.toPost.count, 1)

        // Session drops out of the active set — its key must be forgotten.
        let idle = newlyTriggered(active: [], alreadyNotified: first.nextNotified)
        XCTAssertTrue(idle.toPost.isEmpty)
        XCTAssertFalse(idle.nextNotified.contains("s1|context"))

        // Comes back warning → notifies again.
        let back = newlyTriggered(active: warned, alreadyNotified: idle.nextNotified)
        XCTAssertEqual(back.toPost.count, 1)
    }

    func test_cache_notifies_turns_doesNot() {
        let both = [stat("s1", warnings: [.cache, .turns])]
        let r = newlyTriggered(active: both, alreadyNotified: [])
        XCTAssertEqual(r.toPost.map { $0.condition }, ["cache"])
        XCTAssertFalse(r.nextNotified.contains("s1|turns"))
    }

    func test_contextAndCache_bothPost() {
        let s = [stat("s1", warnings: [.context, .cache])]
        let r = newlyTriggered(active: s, alreadyNotified: [])
        XCTAssertEqual(Set(r.toPost.map { $0.condition }), ["context", "cache"])
    }

    func test_noWarnings_postsNothing() {
        let r = newlyTriggered(active: [stat("s1", warnings: [])], alreadyNotified: [])
        XCTAssertTrue(r.toPost.isEmpty)
    }
}
