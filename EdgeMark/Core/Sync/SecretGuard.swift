import CryptoKit
import Foundation
import OSLog

// MARK: - Thresholds and verdicts

/// Jev score at or above which a file is held back.
///
/// Calibration on 9 samples (jev-1.13.0), credentials score unless noted:
/// password in text 0.79; AWS documented example key 0.05; placeholder
/// `YOUR_API_KEY_HERE` 0.02; prose about password hygiene 0.01; commit hashes 0.02;
/// truncated PEM private key 0.46; 12-word recovery phrase 0.64; home address plus
/// national ID 0.97 (private data); plain study note 0.01.
/// The `public*` values are stricter and apply to public gists.
struct GuardThresholds: Equatable {
    var credentials = 0.4
    var privateData = 0.6
    var publicCredentials = 0.2
    var publicPrivateData = 0.3
}

/// Outcome of the guard for one file. `reasons` are short human phrases, never the
/// matched text. Jev scores are nil when Jev was not asked (regex hit or Jev error).
struct GuardVerdict: Equatable {
    var path: String
    var reasons: [String]
    var credentials: Double?
    var privateData: Double?
    var viaRegex: Bool
    var contentHash: String
    var held: Bool
}

// MARK: - Jev transport

enum JevError: Error, Equatable {
    /// The key provider returned nil or an empty string.
    case noKey
    case http(Int)
    case badResponse
}

/// Asks Jev whether a text contains credentials or private personal data.
protocol JevTransport: Sendable {
    func evaluate(text: String) async throws -> (credentials: Double, privateData: Double)
}

/// TypeSafe System One over HTTPS. Never logs the key or the text.
struct URLSessionJevTransport: JevTransport {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let credentialsInstructions = "Does `text` contain a real credential that grants access to a system (password, API key, access token, private key, recovery phrase)? Placeholders, examples, hashes of public commits, and prose ABOUT passwords do not count."
    static let privateDataInstructions = "Does `text` contain private personal data about a real individual (home address, national ID number, medical or bank account details) that should not be shared publicly?"

    let apiKey: @Sendable () -> String?

    init(apiKey: @escaping @Sendable () -> String?) {
        self.apiKey = apiKey
    }

    func evaluate(text: String) async throws -> (credentials: Double, privateData: Double) {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw JevError.noKey
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(text: text)

        // One retry on a network error or a 5xx answer.
        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let status: Int
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                if attempt < 2 { continue }
                SyncLog.log.error("[Jev] request failed after retry")
                throw error
            }
            if (500 ... 599).contains(status), attempt < 2 { continue }
            guard status == 200 else {
                SyncLog.log.error("[Jev] HTTP \(status)")
                throw JevError.http(status)
            }
            return try Self.parse(data)
        }
    }

    /// JSON body with both questions, so they run in one request.
    static func requestBody(text: String) throws -> Data {
        let body: [String: Any] = [
            "state": ["text": text],
            "model": "jev-latest",
            "questions": [
                "has_credentials": ["type": "noul", "instructions": credentialsInstructions],
                "has_private_data": ["type": "noul", "instructions": privateDataInstructions],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Reads `answers.<question>.noul` for both questions.
    static func parse(_ data: Data) throws -> (credentials: Double, privateData: Double) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let credentials = (answers["has_credentials"] as? [String: Any])?["noul"] as? Double,
              let privateData = (answers["has_private_data"] as? [String: Any])?["noul"] as? Double
        else { throw JevError.badResponse }
        return (credentials, privateData)
    }
}

// MARK: - Guard

/// Decides per file whether it must stay on this Mac. Known secret formats are matched
/// locally and never sent anywhere; everything else is scored by Jev. Jev errors fail
/// open (the file is not held) and are reported through `jevAvailable`.
struct SecretGuard {
    let transport: JevTransport
    let thresholds: GuardThresholds
    let maxChars: Int

    /// Requests to Jev in flight at once.
    static let maxConcurrent = 4

    init(transport: JevTransport, thresholds: GuardThresholds = .init(), maxChars: Int = 8000) {
        self.transport = transport
        self.thresholds = thresholds
        self.maxChars = maxChars
    }

    /// SHA-256 hex of `path + "\n" + text`; the key for allowed and cached verdicts.
    static func contentHash(path: String, text: String) -> String {
        SHA256.hash(data: Data((path + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Known secret formats: reason shown to the user, and the pattern.
    private static let rules: [(reason: String, pattern: String)] = [
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("AWS access key id", #"AKIA[0-9A-Z]{16}"#),
        ("GitHub token", #"gh[pousr]_[A-Za-z0-9]{36,}"#),
        ("GitHub token", #"github_pat_[A-Za-z0-9_]{20,}"#),
        ("API secret key", #"sk-[A-Za-z0-9_-]{20,}"#),
        ("Slack token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
        ("JSON web token", #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
    ]

    private static let compiled: [(reason: String, regex: NSRegularExpression)] = rules.map {
        ($0.reason, try! NSRegularExpression(pattern: $0.pattern))
    }

    /// Reasons for every known secret format found in `text`, without duplicates. A match
    /// whose whitespace-delimited token contains `EXAMPLE` is ignored (documentation keys).
    static func regexHits(in text: String) -> [String] {
        let ns = text as NSString
        var reasons: [String] = []
        for rule in compiled where !reasons.contains(rule.reason) {
            let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if matches.contains(where: { !token(around: $0.range, in: ns).contains("EXAMPLE") }) {
                reasons.append(rule.reason)
            }
        }
        return reasons
    }

    /// The match widened to the surrounding run of non-whitespace characters.
    private static func token(around range: NSRange, in text: NSString) -> String {
        let spaces = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return spaces.contains(scalar)
        }
        var start = range.location
        while start > 0, !isSpace(start - 1) {
            start -= 1
        }
        var end = range.location + range.length
        while end < text.length, !isSpace(end) {
            end += 1
        }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    /// One verdict per reviewed file, in input order. Empty or whitespace-only texts and
    /// files whose hash is in `allowedHashes` are skipped and get no verdict. `strict`
    /// applies the public thresholds. `jevAvailable` is false when any Jev call failed.
    func review(
        _ items: [(path: String, text: String)],
        strict: Bool = false,
        allowedHashes: Set<String> = [],
    ) async -> (verdicts: [GuardVerdict], jevAvailable: Bool) {
        var verdicts: [GuardVerdict?] = Array(repeating: nil, count: items.count)
        var pending: [(index: Int, text: String)] = []
        for (i, item) in items.enumerated() {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hash = Self.contentHash(path: item.path, text: item.text)
            guard !allowedHashes.contains(hash) else { continue }
            let hits = Self.regexHits(in: item.text)
            if !hits.isEmpty {
                verdicts[i] = GuardVerdict(path: item.path, reasons: hits, credentials: nil, privateData: nil,
                                           viaRegex: true, contentHash: hash, held: true)
            } else {
                verdicts[i] = GuardVerdict(path: item.path, reasons: [], credentials: nil, privateData: nil,
                                           viaRegex: false, contentHash: hash, held: false)
                pending.append((i, String(item.text.prefix(maxChars))))
            }
        }

        let credentialsLimit = strict ? thresholds.publicCredentials : thresholds.credentials
        let privateLimit = strict ? thresholds.publicPrivateData : thresholds.privateData
        var jevAvailable = true
        let transport = transport
        await withTaskGroup(of: (Int, (credentials: Double, privateData: Double)?).self) { group in
            var next = 0
            func addNext() {
                guard next < pending.count else { return }
                let (index, text) = pending[next]
                next += 1
                group.addTask { (index, try? await transport.evaluate(text: text)) }
            }
            for _ in 0 ..< Self.maxConcurrent {
                addNext()
            }
            while let (index, scores) = await group.next() {
                addNext()
                guard let scores else {
                    jevAvailable = false
                    continue
                }
                var verdict = verdicts[index]!
                verdict.credentials = scores.credentials
                verdict.privateData = scores.privateData
                if scores.credentials >= credentialsLimit { verdict.reasons.append("possible credential") }
                if scores.privateData >= privateLimit { verdict.reasons.append("possible private personal data") }
                verdict.held = !verdict.reasons.isEmpty
                verdicts[index] = verdict
            }
        }
        let held = verdicts.compactMap { $0 }.filter(\.held).count
        SyncLog.log.info("[Guard] reviewed \(items.count) file(s), \(held) held, jev \(jevAvailable ? "ok" : "unavailable", privacy: .public)")
        return (verdicts.compactMap { $0 }, jevAvailable)
    }
}
