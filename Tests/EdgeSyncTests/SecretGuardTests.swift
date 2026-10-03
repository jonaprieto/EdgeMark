import XCTest
@testable import EdgeSync

/// Canned Jev answers; never touches the network.
actor StubTransport: JevTransport {
    var credentials: Double
    var privateData: Double
    var fails: Bool
    private(set) var texts: [String] = []

    var calls: Int { texts.count }

    init(credentials: Double = 0.01, privateData: Double = 0.01, fails: Bool = false) {
        self.credentials = credentials
        self.privateData = privateData
        self.fails = fails
    }

    func set(credentials: Double, privateData: Double = 0.01) {
        self.credentials = credentials
        self.privateData = privateData
    }

    func evaluate(text: String) async throws -> (credentials: Double, privateData: Double) {
        texts.append(text)
        if fails { throw JevError.http(503) }
        return (credentials, privateData)
    }
}

final class SecretGuardTests: XCTestCase {
    // MARK: - Regex

    func testRegexHitsKnownFormats() {
        XCTAssertEqual(SecretGuard.regexHits(in: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc"), ["private key block"])
        XCTAssertEqual(SecretGuard.regexHits(in: "-----BEGIN PRIVATE KEY-----"), ["private key block"])
        XCTAssertEqual(SecretGuard.regexHits(in: "key = AKIAABCDEFGHIJKLMNOP"), ["AWS access key id"])
        XCTAssertEqual(SecretGuard.regexHits(in: "ghp_" + String(repeating: "a", count: 36)), ["GitHub token"])
        XCTAssertEqual(SecretGuard.regexHits(in: "github_pat_" + String(repeating: "B", count: 22)), ["GitHub token"])
        XCTAssertEqual(SecretGuard.regexHits(in: "OPENAI=sk-" + String(repeating: "x", count: 24)), ["API secret key"])
        XCTAssertEqual(SecretGuard.regexHits(in: "xoxb-1234567890-abc"), ["Slack token"])
        XCTAssertEqual(SecretGuard.regexHits(in: "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4"), ["JSON web token"])
    }

    func testRegexIgnoresPlainTextAndExampleKeys() {
        XCTAssertEqual(SecretGuard.regexHits(in: "# Study note\n\nUse a password manager.\n"), [])
        XCTAssertEqual(SecretGuard.regexHits(in: "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"), [])
        XCTAssertEqual(SecretGuard.regexHits(in: "ghp_short"), [])
    }

    func testRegexReasonsNeverContainTheSecret() {
        let token = "ghp_" + String(repeating: "Z", count: 40)
        let reasons = SecretGuard.regexHits(in: "\(token)\n\(token)\nAKIAABCDEFGHIJKLMNOP")
        XCTAssertEqual(reasons, ["AWS access key id", "GitHub token"])
        XCTAssertFalse(reasons.joined().contains("ZZZZ"))
    }

    // MARK: - Review

    func testRegexHitHoldsWithoutCallingJev() async {
        let stub = StubTransport(credentials: 0.0)
        let guardian = SecretGuard(transport: stub)
        let result = await guardian.review([(path: "secret.md", text: "-----BEGIN RSA PRIVATE KEY-----\nMIIB\n")])
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertTrue(result.verdicts[0].held)
        XCTAssertTrue(result.verdicts[0].viaRegex)
        XCTAssertNil(result.verdicts[0].credentials)
        let calls = await stub.calls
        XCTAssertEqual(calls, 0)
    }

    func testThresholds() async {
        let stub = StubTransport(credentials: 0.39, privateData: 0.59)
        let guardian = SecretGuard(transport: stub)
        var result = await guardian.review([(path: "a.md", text: "text")])
        XCTAssertFalse(result.verdicts[0].held)
        XCTAssertEqual(result.verdicts[0].credentials, 0.39)
        XCTAssertTrue(result.jevAvailable)

        await stub.set(credentials: 0.4)
        result = await guardian.review([(path: "a.md", text: "text")])
        XCTAssertTrue(result.verdicts[0].held)
        XCTAssertEqual(result.verdicts[0].reasons, ["possible credential"])
        XCTAssertFalse(result.verdicts[0].viaRegex)

        await stub.set(credentials: 0.01, privateData: 0.6)
        result = await guardian.review([(path: "a.md", text: "text")])
        XCTAssertEqual(result.verdicts[0].reasons, ["possible private personal data"])
    }

    func testStrictThresholds() async {
        let stub = StubTransport(credentials: 0.2, privateData: 0.01)
        let guardian = SecretGuard(transport: stub)
        let normal = await guardian.review([(path: "a.md", text: "text")])
        XCTAssertFalse(normal.verdicts[0].held)
        let strict = await guardian.review([(path: "a.md", text: "text")], strict: true)
        XCTAssertTrue(strict.verdicts[0].held)

        await stub.set(credentials: 0.19, privateData: 0.3)
        let privateStrict = await guardian.review([(path: "a.md", text: "text")], strict: true)
        XCTAssertEqual(privateStrict.verdicts[0].reasons, ["possible private personal data"])
        await stub.set(credentials: 0.19, privateData: 0.29)
        let below = await guardian.review([(path: "a.md", text: "text")], strict: true)
        XCTAssertFalse(below.verdicts[0].held)
    }

    func testTextIsCappedAtMaxChars() async {
        let stub = StubTransport()
        let guardian = SecretGuard(transport: stub, maxChars: 10)
        _ = await guardian.review([(path: "a.md", text: String(repeating: "x", count: 50))])
        let texts = await stub.texts
        XCTAssertEqual(texts, [String(repeating: "x", count: 10)])
    }

    func testEmptyTextIsSkipped() async {
        let stub = StubTransport(credentials: 0.9)
        let guardian = SecretGuard(transport: stub)
        let result = await guardian.review([(path: "a.md", text: ""), (path: "b.md", text: " \n\t\n")])
        XCTAssertEqual(result.verdicts, [])
        let calls = await stub.calls
        XCTAssertEqual(calls, 0)
    }

    func testAllowedHashesAreSkipped() async {
        let stub = StubTransport(credentials: 0.9)
        let guardian = SecretGuard(transport: stub)
        let text = "-----BEGIN PRIVATE KEY-----"
        let hash = SecretGuard.contentHash(path: "k.md", text: text)
        let result = await guardian.review([(path: "k.md", text: text)], allowedHashes: [hash])
        XCTAssertEqual(result.verdicts, [])
        // The hash covers the path: the same text elsewhere is still held.
        let moved = await guardian.review([(path: "other.md", text: text)], allowedHashes: [hash])
        XCTAssertTrue(moved.verdicts[0].held)
    }

    func testTransportErrorFailsOpen() async {
        let stub = StubTransport(fails: true)
        let guardian = SecretGuard(transport: stub)
        let result = await guardian.review([
            (path: "a.md", text: "plain"),
            (path: "b.md", text: "AKIAABCDEFGHIJKLMNOP"),
        ])
        XCTAssertFalse(result.jevAvailable)
        XCTAssertEqual(result.verdicts.map(\.held), [false, true])
        XCTAssertEqual(result.verdicts.map(\.path), ["a.md", "b.md"])
    }

    func testManyFilesKeepInputOrder() async {
        let stub = StubTransport()
        let guardian = SecretGuard(transport: stub)
        let items = (0 ..< 10).map { (path: "n\($0).md", text: "note \($0)") }
        let result = await guardian.review(items)
        XCTAssertEqual(result.verdicts.map(\.path), items.map(\.path))
        let calls = await stub.calls
        XCTAssertEqual(calls, 10)
    }

    func testContentHashIsSHA256Hex() {
        // printf 'a.md\nx' | shasum -a 256
        XCTAssertEqual(SecretGuard.contentHash(path: "a.md", text: "x"), "e012185a089561fe22c192d0b946f30628e20d944e77ec7fe5d275a304b849fe")
        XCTAssertNotEqual(SecretGuard.contentHash(path: "a.md", text: "x"), SecretGuard.contentHash(path: "b.md", text: "x"))
    }

    // MARK: - Transport

    func testRequestBodyCarriesBothQuestions() throws {
        let data = try URLSessionJevTransport.requestBody(text: "hello")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "jev-latest")
        XCTAssertEqual((json["state"] as? [String: String])?["text"], "hello")
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: String]])
        XCTAssertEqual(Set(questions.keys), ["has_credentials", "has_private_data"])
        XCTAssertEqual(questions["has_credentials"]?["type"], "noul")
        XCTAssertEqual(questions["has_private_data"]?["instructions"], URLSessionJevTransport.privateDataInstructions)
    }

    func testParseResponse() throws {
        let body = #"{"model":"jev-1.13.0","answers":{"has_credentials":{"type":"noul","noul":0.89},"has_private_data":{"type":"noul","noul":0.02}},"usage":{}}"#
        let scores = try URLSessionJevTransport.parse(Data(body.utf8))
        XCTAssertEqual(scores.credentials, 0.89)
        XCTAssertEqual(scores.privateData, 0.02)
        XCTAssertThrowsError(try URLSessionJevTransport.parse(Data("{}".utf8)))
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        let transport = URLSessionJevTransport(apiKey: { "  " })
        do {
            _ = try await transport.evaluate(text: "x")
            XCTFail("expected noKey")
        } catch {
            XCTAssertEqual(error as? JevError, .noKey)
        }
    }
}
