import XCTest
@testable import EdgeCrypto

final class AgeTests: XCTestCase {
    private let identity = TestKeys.identity

    func testRoundTrips() throws {
        var big = Data(count: 64 * 1024 * 2 + 17)
        for i in big.indices { big[i] = UInt8(truncatingIfNeeded: i &* 31) }
        for plaintext in [Data(), Data("# Note\n\nbody\n".utf8), Data(count: 64 * 1024), big] {
            let armored = Age.encrypt(plaintext, to: identity.recipient)
            XCTAssertTrue(Age.isArmored(armored))
            XCTAssertEqual(try Age.decrypt(armored, with: identity), plaintext)
        }
    }

    /// Every short length, so the ones whose armor fills its last line exactly (binary
    /// length a multiple of 48 bytes) are covered: that line must not be followed by an
    /// empty one.
    func testRoundTripsEveryShortLength() throws {
        for length in 0 ... 200 {
            let plaintext = Data(repeating: 0x7A, count: length)
            let armored = Age.encrypt(plaintext, to: identity.recipient)
            XCTAssertFalse(armored.contains("\n\n"), "empty armor line at length \(length)")
            XCTAssertEqual(try Age.decrypt(armored, with: identity), plaintext, "length \(length)")
        }
    }

    func testOutputIsRandomized() {
        let data = Data("same".utf8)
        XCTAssertNotEqual(Age.encrypt(data, to: identity.recipient), Age.encrypt(data, to: identity.recipient))
    }

    func testWrongIdentity() {
        let armored = Age.encrypt(Data("x".utf8), to: identity.recipient)
        XCTAssertThrowsError(try Age.decrypt(armored, with: .generate())) {
            XCTAssertEqual($0 as? AgeError, .noMatchingRecipient)
        }
    }

    /// Re-armors `armored` after `change` edits the binary file inside it.
    private func tampered(_ armored: String, _ change: (inout Data) -> Void) -> String {
        let lines = armored.split(separator: "\n")
        var file = Data(base64Encoded: lines.dropFirst().dropLast().joined())!
        change(&file)
        let encoded = file.base64EncodedString()
        var wrapped: [Substring] = []
        var rest = Substring(encoded)
        while !rest.isEmpty {
            wrapped.append(rest.prefix(64))
            rest = rest.dropFirst(64)
        }
        return ([Substring(Age.armorBegin)] + wrapped + [Substring(Age.armorEnd)]).joined(separator: "\n") + "\n"
    }

    func testRejectsTampering() throws {
        let armored = Age.encrypt(Data("secret body".utf8), to: identity.recipient)
        let file = Data(base64Encoded: armored.split(separator: "\n").dropFirst().dropLast().joined())!
        let macLine = file.range(of: Data("\n--- ".utf8))!

        // A byte of the wrapped file key: the stanza no longer unwraps.
        XCTAssertThrowsError(try Age.decrypt(tampered(armored) { $0[macLine.lowerBound - 2] ^= 1 }, with: identity))
        // A byte of the MAC itself.
        XCTAssertThrowsError(try Age.decrypt(tampered(armored) { $0[macLine.upperBound] = $0[macLine.upperBound] == 0x41 ? 0x42 : 0x41 }, with: identity)) {
            XCTAssertEqual($0 as? AgeError, .badHeaderMAC)
        }
        // A header byte the MAC covers but no stanza depends on: an extra stanza argument.
        let withArgument = tampered(armored) { $0.replaceSubrange($0.range(of: Data("-> X25519 ".utf8))!, with: Data("-> X25519  ".utf8)) }
        XCTAssertThrowsError(try Age.decrypt(withArgument, with: identity))
        // The last payload byte.
        XCTAssertThrowsError(try Age.decrypt(tampered(armored) { $0[$0.count - 1] ^= 1 }, with: identity)) {
            XCTAssertEqual($0 as? AgeError, .corruptPayload)
        }
        // A truncated payload.
        XCTAssertThrowsError(try Age.decrypt(tampered(armored) { $0.removeLast(4) }, with: identity)) {
            XCTAssertEqual($0 as? AgeError, .corruptPayload)
        }
    }

    func testTruncatedAtChunkBoundaryIsRejected() throws {
        let armored = Age.encrypt(Data(count: 64 * 1024 + 5), to: identity.recipient)
        // Drop the whole final chunk (5 bytes and its 16-byte tag): the first chunk was not
        // sealed as final, so it must not be accepted as the end of the file.
        XCTAssertThrowsError(try Age.decrypt(tampered(armored) { $0.removeLast(21) }, with: identity)) {
            XCTAssertEqual($0 as? AgeError, .corruptPayload)
        }
    }

    func testRejectsNonAgeText() {
        for text in ["", "# A note\n", Age.armorBegin + "\n" + Age.armorEnd + "\n", Age.armorBegin + "\nAAAA\n" + Age.armorEnd] {
            XCTAssertThrowsError(try Age.decrypt(text, with: identity), text) {
                XCTAssertEqual($0 as? AgeError, .notAgeFile)
            }
        }
    }

    func testUnsupportedVersion() {
        let file = Data("age-encryption.org/v2\n-> X25519 abc\n\n--- abc\n".utf8).base64EncodedString()
        let armored = "\(Age.armorBegin)\n\(file)\n\(Age.armorEnd)\n"
        XCTAssertThrowsError(try Age.decrypt(armored, with: identity)) {
            XCTAssertEqual($0 as? AgeError, .unsupportedVersion)
        }
    }

    // MARK: - Interop with the age CLI

    /// `printf '# Fixture\n\nWritten by the age CLI.\n' | age -a -r <TestKeys.recipientString>`, age v1.2.1.
    static let cliFixture = """
    -----BEGIN AGE ENCRYPTED FILE-----
    YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBsN0xlbzNmVWRTT3BnT3Ra
    S1RURVo4Qzlud2d6bzRpNlVETGZPTVFJdDJRCncvS0MvZ1N2VnVTNUFxdEZoRVNs
    ck1FVVdYa0VEcTR6aGZTN1NxcWNvNWMKLS0tIG9sRHVZRHVxWUdIUjcxLytzQ3RZ
    bGxjQ29YWFB3MnR2WVpRUGcvVE4rVTgKvSJS72X7bR4/6PZi5N40XWNp6G7sTrRx
    TdqByLRp5RqO1BU+mDpoOfG8ZJmezVY4BCG4NkzkNmmkTwTpiepsvb8jOw==
    -----END AGE ENCRYPTED FILE-----
    """

    func testDecryptsFileWrittenByAgeCLI() throws {
        let plaintext = try Age.decrypt(Self.cliFixture, with: identity)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "# Fixture\n\nWritten by the age CLI.\n")
    }

    func testAgeCLIDecryptsOurOutput() throws {
        let candidates = ["/opt/homebrew/bin/age", "/usr/local/bin/age"] + (ProcessInfo.processInfo.environment["AGE_BIN"].map { [$0] } ?? [])
        guard let age = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("age CLI not installed (brew install age)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFile = dir.appendingPathComponent("key.txt")
        let noteFile = dir.appendingPathComponent("note.md.age")
        try Data((TestKeys.identityString + "\n").utf8).write(to: keyFile)
        var big = Data("# Multi chunk\n".utf8)
        big.append(Data(repeating: 0x61, count: 64 * 1024 * 2))
        // 39, 40 and 88 bytes give a binary file whose length is a multiple of 48.
        let fullLastLine = [39, 40, 88].map { Data(repeating: 0x7A, count: $0) }
        for plaintext in [Data(), Data("# Hi\n".utf8), big] + fullLastLine {
            try Data(Age.encrypt(plaintext, to: identity.recipient).utf8).write(to: noteFile)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: age)
            process.arguments = ["-d", "-i", keyFile.path, noteFile.path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(data, plaintext)
        }
    }
}
