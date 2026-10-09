import XCTest
@testable import EdgeCrypto

/// The identity and recipient printed as examples in the age specification (c2sp.org/age).
enum TestKeys {
    static let identityString = "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX"
    static let recipientString = "age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj"
    static var identity: AgeIdentity { AgeIdentity(bech32: identityString)! }
}

final class AgeKeysTests: XCTestCase {
    func testSpecVectorsRoundTrip() {
        XCTAssertEqual(TestKeys.identity.string, TestKeys.identityString)
        XCTAssertEqual(TestKeys.identity.recipient.string, TestKeys.recipientString)
        XCTAssertEqual(AgeRecipient(bech32: TestKeys.recipientString)?.publicKey, TestKeys.identity.recipient.publicKey)
    }

    func testRejectsWrongPrefixChecksumAndCase() {
        XCTAssertNil(AgeRecipient(bech32: TestKeys.recipientString.replacingOccurrences(of: "zvkyg", with: "zvkyh")))
        XCTAssertNil(AgeRecipient(bech32: TestKeys.identityString))
        XCTAssertNil(AgeIdentity(bech32: TestKeys.recipientString))
        XCTAssertNil(AgeIdentity(bech32: "Age-secret-key-1" + TestKeys.identityString.dropFirst(16)))
        XCTAssertNil(AgeIdentity(bech32: ""))
    }

    func testGeneratedKeysRoundTrip() {
        let identity = AgeIdentity.generate()
        XCTAssertTrue(identity.string.hasPrefix("AGE-SECRET-KEY-1"))
        XCTAssertTrue(identity.recipient.string.hasPrefix("age1"))
        XCTAssertEqual(AgeIdentity(bech32: identity.string)?.recipient, identity.recipient)
        XCTAssertEqual(AgeIdentity(bech32: " \(identity.string)\n")?.recipient, identity.recipient, "pasted keys carry whitespace")
    }

    func testBech32ReferenceVectors() {
        XCTAssertEqual(Bech32.decode("A12UEL5L")?.hrp, "a")
        XCTAssertEqual(Bech32.decode("a12uel5l")?.data, Data())
        XCTAssertNil(Bech32.decode("A12UEL5M"), "bad checksum")
        XCTAssertNil(Bech32.decode("A12uEL5L"), "mixed case")
        XCTAssertNil(Bech32.decode("nothing"))
        XCTAssertEqual(Bech32.encode(hrp: "a", data: Data()), "a12uel5l")
    }
}
