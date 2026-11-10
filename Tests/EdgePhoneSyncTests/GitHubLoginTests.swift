@testable import EdgePhoneSync
import XCTest

final class GitHubLoginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testATokenAnswerCarriesItsExpiry() {
        let body: [String: Any] = ["access_token": "ghu_a", "expires_in": 28800, "refresh_token": "ghr_b", "token_type": "bearer"]
        let tokens = GitHubLogin.Tokens(access: "ghu_a", refresh: "ghr_b", expires: now.addingTimeInterval(28800))
        XCTAssertEqual(GitHubLogin.read(body, now: now), .tokens(tokens))
        XCTAssertFalse(tokens.stale(at: now))
        XCTAssertTrue(tokens.stale(at: now.addingTimeInterval(28800 - 30)))
    }

    func testATokenWithNoExpiryNeverGoesStale() {
        guard case let .tokens(tokens) = GitHubLogin.read(["access_token": "ghu_a"], now: now) else { return XCTFail() }
        XCTAssertNil(tokens.refresh)
        XCTAssertFalse(tokens.stale(at: .distantFuture))
    }

    func testPollErrorsTellWhatToDo() {
        XCTAssertEqual(GitHubLogin.read(["error": "authorization_pending"], now: now), .wait)
        XCTAssertEqual(GitHubLogin.read(["error": "slow_down", "interval": 10], now: now), .slower)
        XCTAssertEqual(GitHubLogin.read(["error": "access_denied"], now: now), .failed("access_denied"))
        XCTAssertEqual(GitHubLogin.read([:], now: now), .failed("with nothing readable"))
    }
}
