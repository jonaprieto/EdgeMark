import XCTest
@testable import EdgeSync

/// Calls the real TypeSafe API. Runs only with `JEV_LIVE=1` and `TYPESAFE_API_KEY` set.
final class LiveJevTests: XCTestCase {
    func testLiveScores() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JEV_LIVE"] == "1", let key = env["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set JEV_LIVE=1 and TYPESAFE_API_KEY to run")
        }
        let transport = URLSessionJevTransport(apiKey: { key })

        let secret = try await transport.evaluate(text: "prod db password: hunter2-Zk39!qq")
        XCTAssertGreaterThan(secret.credentials, 0.4)

        let benign = try await transport.evaluate(text: "Lean 4 notes: simp lemma for List.map_append")
        XCTAssertLessThan(benign.credentials, 0.2)
        XCTAssertLessThan(benign.privateData, 0.2)
    }
}
