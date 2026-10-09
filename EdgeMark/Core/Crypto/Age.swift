import CryptoKit
import Foundation

nonisolated enum AgeError: Error, Equatable {
    /// Not ASCII armor, or the header inside it is malformed.
    case notAgeFile
    /// An age file of a version other than v1.
    case unsupportedVersion
    /// No X25519 stanza in the header unwraps with the identity.
    case noMatchingRecipient
    case badHeaderMAC
    /// The payload is truncated or was modified.
    case corruptPayload
}

/// The age v1 file format (c2sp.org/age) for one X25519 recipient, always ASCII armored.
nonisolated enum Age {
    static let versionLine = "age-encryption.org/v1"
    static let armorBegin = "-----BEGIN AGE ENCRYPTED FILE-----"
    static let armorEnd = "-----END AGE ENCRYPTED FILE-----"
    private static let x25519Info = Data("age-encryption.org/v1/X25519".utf8)
    private static let chunkSize = 64 * 1024
    private static let tagSize = 16
    private static let zeroNonce = try! ChaChaPoly.Nonce(data: Data(count: 12))

    /// True when `text` starts with the armor header, ignoring leading whitespace.
    static func isArmored(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix(armorBegin)
    }

    // MARK: - Encrypt

    /// `plaintext` as an armored age file readable by `recipient`'s identity. Output is
    /// different on every call (fresh file key, ephemeral key and nonce).
    static func encrypt(_ plaintext: Data, to recipient: AgeRecipient) -> String {
        var generator = SystemRandomNumberGenerator()
        let fileKey = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let nonce = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // A recipient is only built from 32 bytes, which CryptoKit accepts as a public key.
        let recipientKey = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        // Key agreement fails only for a low-order recipient key. A random wrap key then
        // seals a file nobody can open, which is the right outcome for a bogus recipient.
        let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = secret.map { wrapKey(from: $0, share: share, recipient: recipient.publicKey) }
            ?? SymmetricKey(size: .bits256)
        let wrapped = try! ChaChaPoly.seal(fileKey, using: wrappingKey, nonce: zeroNonce)

        var header = "\(versionLine)\n-> X25519 \(base64(share))\n"
        header += wrap64(base64(wrapped.ciphertext + wrapped.tag)) + "\n---"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: macKey(fileKey))
        header += " \(base64(Data(mac)))\n"

        var file = Data(header.utf8) + nonce
        let key = payloadKey(fileKey, nonce: nonce)
        var offset = 0
        var counter: UInt64 = 0
        repeat {
            let end = min(offset + chunkSize, plaintext.count)
            let isLast = end == plaintext.count
            let chunk = plaintext.subdata(in: plaintext.startIndex + offset ..< plaintext.startIndex + end)
            let sealed = try! ChaChaPoly.seal(chunk, using: key, nonce: streamNonce(counter, last: isLast))
            file += sealed.ciphertext + sealed.tag
            offset = end
            counter += 1
        } while offset < plaintext.count

        return "\(armorBegin)\n\(armorLines(file.base64EncodedString()))\n\(armorEnd)\n"
    }

    // MARK: - Decrypt

    static func decrypt(_ armored: String, with identity: AgeIdentity) throws -> Data {
        let file = try dearmor(armored)
        let header = try parseHeader(file)
        guard let fileKey = header.stanzas.lazy.compactMap({ unwrap($0, with: identity) }).first else {
            throw AgeError.noMatchingRecipient
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: header.macInput, using: macKey(fileKey)) else {
            throw AgeError.badHeaderMAC
        }
        let payload = file.subdata(in: file.startIndex + header.length ..< file.endIndex)
        guard payload.count >= 16 + tagSize else { throw AgeError.corruptPayload }
        let key = payloadKey(fileKey, nonce: payload.prefix(16))
        let body = payload.dropFirst(16)
        var plaintext = Data()
        var offset = body.startIndex
        var counter: UInt64 = 0
        while offset < body.endIndex {
            let end = min(offset + chunkSize + tagSize, body.endIndex)
            let isLast = end == body.endIndex
            let chunk = body[offset ..< end]
            // An empty final chunk is only valid as the whole payload.
            guard chunk.count > tagSize || (counter == 0 && chunk.count == tagSize),
                  let box = try? ChaChaPoly.SealedBox(
                      nonce: streamNonce(counter, last: isLast),
                      ciphertext: chunk.dropLast(tagSize),
                      tag: chunk.suffix(tagSize),
                  ),
                  let opened = try? ChaChaPoly.open(box, using: key)
            else { throw AgeError.corruptPayload }
            plaintext += opened
            offset = end
            counter += 1
        }
        return plaintext
    }

    // MARK: - Header

    private struct Stanza {
        let arguments: [String]
        let body: Data
    }

    private struct Header {
        let stanzas: [Stanza]
        /// Header bytes up to and including the `---` of the last line.
        let macInput: Data
        let mac: Data
        /// Bytes the header occupies in the file, final line feed included.
        let length: Int
    }

    private static func parseHeader(_ file: Data) throws -> Header {
        let bytes = [UInt8](file)
        var position = 0
        /// The next line without its line feed, or nil at the end of the data.
        func nextLine() -> String? {
            guard let newline = bytes[position...].firstIndex(of: 0x0A) else { return nil }
            defer { position = newline + 1 }
            return String(bytes: bytes[position ..< newline], encoding: .utf8)
        }
        guard let version = nextLine(), version.hasPrefix("age-encryption.org/") else { throw AgeError.notAgeFile }
        guard version == versionLine else { throw AgeError.unsupportedVersion }

        var stanzas: [Stanza] = []
        while true {
            let lineStart = position
            guard let line = nextLine() else { throw AgeError.notAgeFile }
            if line.hasPrefix("--- ") {
                guard !stanzas.isEmpty, let mac = decodeBase64(String(line.dropFirst(4))), mac.count == 32 else {
                    throw AgeError.notAgeFile
                }
                return Header(stanzas: stanzas, macInput: Data(bytes[..<(lineStart + 3)]), mac: mac, length: position)
            }
            guard line.hasPrefix("-> ") else { throw AgeError.notAgeFile }
            let arguments = line.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard !arguments.contains(where: \.isEmpty) else { throw AgeError.notAgeFile }
            var encoded = ""
            while true {
                guard let bodyLine = nextLine(), bodyLine.count <= 64 else { throw AgeError.notAgeFile }
                encoded += bodyLine
                if bodyLine.count < 64 { break }
            }
            guard let body = decodeBase64(encoded) else { throw AgeError.notAgeFile }
            stanzas.append(Stanza(arguments: arguments, body: body))
        }
    }

    /// The file key when `stanza` is an X25519 stanza addressed to `identity`.
    private static func unwrap(_ stanza: Stanza, with identity: AgeIdentity) -> Data? {
        guard stanza.arguments.first == "X25519", stanza.arguments.count == 2,
              let share = decodeBase64(stanza.arguments[1]), share.count == 32,
              stanza.body.count == 32,
              let shareKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: share),
              let secret = try? identity.privateKey.sharedSecretFromKeyAgreement(with: shareKey),
              !secret.withUnsafeBytes({ $0.allSatisfy { $0 == 0 } }),
              let box = try? ChaChaPoly.SealedBox(
                  nonce: zeroNonce, ciphertext: stanza.body.prefix(16), tag: stanza.body.suffix(16),
              )
        else { return nil }
        let key = wrapKey(from: secret, share: share, recipient: identity.recipient.publicKey)
        return try? ChaChaPoly.open(box, using: key)
    }

    // MARK: - Keys and nonces

    private static func wrapKey(from secret: SharedSecret, share: Data, recipient: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: share + recipient, sharedInfo: x25519Info, outputByteCount: 32)
    }

    private static func macKey(_ fileKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), info: Data("header".utf8), outputByteCount: 32)
    }

    private static func payloadKey(_ fileKey: Data, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: fileKey), salt: nonce, info: Data("payload".utf8), outputByteCount: 32,
        )
    }

    /// STREAM nonce: an 11-byte big-endian chunk counter, then 0x01 for the final chunk.
    private static func streamNonce(_ counter: UInt64, last: Bool) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0 ..< 8 {
            bytes[10 - i] = UInt8((counter >> UInt64(8 * i)) & 0xFF)
        }
        bytes[11] = last ? 1 : 0
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }

    // MARK: - Encoding

    /// Standard base64 without `=` padding, as age headers use.
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64; nil for padding, stray characters or a non-canonical encoding.
    private static func decodeBase64(_ text: String) -> Data? {
        guard !text.contains("=") else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64(data) == text else { return nil }
        return data
    }

    /// `text` in lines of 64 characters. A text that fills its last line gets an empty
    /// line after it, so the last line is always shorter than 64 (the stanza body rule).
    private static func wrap64(_ text: String) -> String {
        var lines: [Substring] = []
        var rest = Substring(text)
        while rest.count >= 64 {
            lines.append(rest.prefix(64))
            rest = rest.dropFirst(64)
        }
        lines.append(rest)
        return lines.joined(separator: "\n")
    }

    /// `base64` in lines of 64 characters for the armor. Unlike a stanza body, armor
    /// never has an empty line: a text that fills its last line simply ends there.
    private static func armorLines(_ base64: String) -> String {
        var lines: [Substring] = []
        var rest = Substring(base64)
        while !rest.isEmpty {
            lines.append(rest.prefix(64))
            rest = rest.dropFirst(64)
        }
        return lines.joined(separator: "\n")
    }

    /// The binary file inside strict PEM armor (RFC 7468): the two marker lines, 64-column
    /// padded base64 between them, nothing but whitespace around.
    private static func dearmor(_ armored: String) throws -> Data {
        let lines = armored.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.count >= 3, lines.first == armorBegin, lines.last == armorEnd else { throw AgeError.notAgeFile }
        let body = lines[1 ..< lines.count - 1]
        guard body.dropLast().allSatisfy({ $0.count == 64 }), let last = body.last, (1 ... 64).contains(last.count),
              let data = Data(base64Encoded: body.joined()), data.base64EncodedString() == body.joined()
        else { throw AgeError.notAgeFile }
        return data
    }
}
