import Foundation

/// Reads and writes one encrypted note file.
@MainActor
enum EncryptedFile {
    /// Plaintext of the age file at `url`. Throws `AgeError`, or a file error.
    static func read(at url: URL, identity: AgeIdentity) throws -> String {
        let armored = try String(contentsOf: url, encoding: .utf8)
        // Strict: a payload that is not text must not open as garbage and be saved back.
        guard let text = String(data: try Age.decrypt(armored, with: identity), encoding: .utf8) else {
            throw AgeError.corruptPayload
        }
        return text
    }

    /// Seals `text` into `url`, unless the file there already decrypts to that same text:
    /// age output differs on every run, and a rewrite would show up as a change in git
    /// on every autosave. The file itself is read for this, never a memory of what was
    /// written, because a rename or a pull can put other content at the same path.
    /// Without an identity (the session locked a moment ago and a pending edit still
    /// has to be saved) there is nothing to compare with and the file is always
    /// written: sealing needs only the recipient. Returns whether the file was written.
    @discardableResult
    static func write(_ text: String, to url: URL, recipient: AgeRecipient, identity: AgeIdentity?) throws -> Bool {
        if let identity, (try? read(at: url, identity: identity)) == text {
            return false
        }
        try Data(Age.encrypt(Data(text.utf8), to: recipient).utf8).write(to: url, options: .atomic)
        return true
    }

    /// Encrypts the plaintext note at `plainURL`, whose text is `text`, into `<name>.age`
    /// next to it and returns that URL. The plaintext file is removed only after the new
    /// file was read back and decrypted to `text` with `identity`; on any failure the
    /// `.age` file is removed and the plaintext file stays.
    static func seal(_ text: String, at plainURL: URL, recipient: AgeRecipient, identity: AgeIdentity) throws -> URL {
        let url = plainURL.appendingPathExtension("age")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        do {
            try Data(Age.encrypt(Data(text.utf8), to: recipient).utf8).write(to: url, options: .atomic)
            guard try read(at: url, identity: identity) == text else { throw AgeError.corruptPayload }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        try FileManager.default.removeItem(at: plainURL)
        return url
    }

    /// The reverse of `seal`: writes `text` to the name without `.age`, then removes the
    /// encrypted file. Returns the plaintext file's URL.
    static func unseal(_ text: String, at url: URL) throws -> URL {
        // Anything else would lose its extension and then be deleted.
        guard url.pathExtension == "age" else { throw CocoaError(.fileReadUnsupportedScheme) }
        let plainURL = url.deletingPathExtension()
        guard !FileManager.default.fileExists(atPath: plainURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data(text.utf8).write(to: plainURL, options: .atomic)
        try FileManager.default.removeItem(at: url)
        return plainURL
    }
}
