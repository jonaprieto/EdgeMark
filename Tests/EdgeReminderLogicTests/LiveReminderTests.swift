@testable import EdgeReminderLogic
import XCTest

/// Calls the real TypeSafe API. Runs only with `JEV_LIVE=1` and `TYPESAFE_API_KEY` set.
final class LiveReminderTests: XCTestCase {
    func testLiveSuggestions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JEV_LIVE"] == "1", let key = env["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set JEV_LIVE=1 and TYPESAFE_API_KEY to run")
        }
        let options = ReminderOption.allCases
        func suggest(_ title: String, _ text: String) async -> ReminderOption? {
            await ReminderSuggestion.suggest(title: title, text: text, now: Date(), options: options, apiKey: key)
        }
        let standup = await suggest("Standup", "Daily standup: what I did yesterday, what I do today, blockers.")
        XCTAssertEqual(standup, .everyWeekday)
        let movie = await suggest("Peli", "Ver la pelicula que recomendo Ana esta noche")
        XCTAssertEqual(movie, .tonight)
        let reference = await suggest("Lean notes", "simp lemma for List.map_append, see Mathlib docs")
        XCTAssertNil(reference)
    }
}
