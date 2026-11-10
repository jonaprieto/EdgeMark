@testable import EdgePhoneSync
import XCTest

/// Answers each poll from a script: a network failure, or a JSON body.
final class FakeDeviceFlow: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [[String: Any]?] = []

    static func set(_ answers: [[String: Any]?]) {
        lock.lock()
        defer { lock.unlock() }
        script = answers
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let next = Self.script.isEmpty ? ["error": "authorization_pending"] : Self.script.removeFirst()
        Self.lock.unlock()
        guard let next else {
            return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: next))
        client!.urlProtocolDidFinishLoading(self)
    }
}

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

    /// iOS suspends the app while you approve in Safari, and the poll in flight fails: that
    /// must not end the sign-in.
    func testALostConnectionKeepsPolling() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeDeviceFlow.self]
        FakeDeviceFlow.set([nil, ["error": "authorization_pending"], nil, ["access_token": "ghu_a", "expires_in": 28800, "refresh_token": "ghr_b"]])
        let login = GitHubLogin(clientID: "Iv1", session: URLSession(configuration: config))
        let code = GitHubLogin.Code(device: "d", user: "ABCD-1234", page: URL(string: "https://github.com/login/device")!, interval: 0, expires: .distantFuture)
        let tokens = try await login.wait(for: code)
        XCTAssertEqual(tokens.access, "ghu_a")
    }

    func testADenialEndsTheSignIn() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeDeviceFlow.self]
        FakeDeviceFlow.set([["error": "access_denied"]])
        let login = GitHubLogin(clientID: "Iv1", session: URLSession(configuration: config))
        let code = GitHubLogin.Code(device: "d", user: "ABCD-1234", page: URL(string: "https://github.com/login/device")!, interval: 0, expires: .distantFuture)
        do {
            _ = try await login.wait(for: code)
            XCTFail("signed in after a denial")
        } catch {
            XCTAssertEqual(error as? GitHubLogin.Failure, .denied)
        }
    }
}
