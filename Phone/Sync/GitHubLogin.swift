import Foundation

/// Sign-in with GitHub's device flow: the phone shows a code, you approve it on github.com, and
/// the app gets a token for the repositories you gave the EdgeMark GitHub App. Device flow needs
/// only the app's public client ID, no secret, so EdgeMark keeps no server.
public struct GitHubLogin: Sendable {
    /// What you type on github.com/login/device.
    public struct Code: Equatable, Sendable {
        public let device: String
        public let user: String
        public let page: URL
        public let interval: Int
        public let expires: Date
    }

    /// A user access token: it lasts 8 hours, and `refresh` renews it for 6 months.
    public struct Tokens: Codable, Equatable, Sendable {
        public let access: String
        public let refresh: String?
        public let expires: Date?

        /// Expired, or about to: renew before using it.
        public func stale(at now: Date) -> Bool {
            expires.map { $0 < now.addingTimeInterval(60) } ?? false
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The code ran out, or the sign-in did: sign in again.
        case expired
        case denied
        case github(String)

        public var description: String {
            switch self {
            case .expired: "The GitHub sign-in ran out; sign in again"
            case .denied: "GitHub sign-in was cancelled"
            case let .github(error): "GitHub answered \(error)"
            }
        }
    }

    /// One poll's answer.
    enum Answer: Equatable {
        case tokens(Tokens)
        case wait
        case slower
        case failed(String)
    }

    let clientID: String
    let session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func start(now: Date = Date()) async throws -> Code {
        let body = try await post("login/device/code", ["client_id": clientID])
        guard let device = body["device_code"] as? String, let user = body["user_code"] as? String,
              let page = (body["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw Failure.github(body["error"] as? String ?? "with no code") }
        let lasts = body["expires_in"] as? Int ?? 900
        return Code(device: device, user: user, page: page, interval: body["interval"] as? Int ?? 5, expires: now.addingTimeInterval(TimeInterval(lasts)))
    }

    /// Polls until you approve or deny, or the code runs out. Cancelling the task stops it.
    public func wait(for code: Code) async throws -> Tokens {
        var interval = code.interval
        while Date() < code.expires {
            try await Task.sleep(for: .seconds(interval))
            let body: [String: Any]
            do {
                body = try await post("login/oauth/access_token", [
                    "client_id": clientID, "device_code": code.device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch {
                // iOS suspends the app while you approve in Safari, and the poll in flight fails;
                // offline does the same. Only GitHub's answer ends the wait.
                try Task.checkCancellation()
                continue
            }
            switch Self.read(body, now: Date()) {
            case let .tokens(tokens): return tokens
            case .wait: continue
            case .slower: interval += 5
            case .failed("access_denied"): throw Failure.denied
            case .failed("expired_token"): throw Failure.expired
            case let .failed(error): throw Failure.github(error)
            }
        }
        throw Failure.expired
    }

    /// A new pair: GitHub retires the old one. Device-flow tokens renew with no client secret.
    public func refresh(_ tokens: Tokens) async throws -> Tokens {
        guard let refresh = tokens.refresh else { throw Failure.expired }
        let body = try await post("login/oauth/access_token", ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        guard case let .tokens(fresh) = Self.read(body, now: Date()) else { throw Failure.expired }
        return fresh
    }

    /// The private repositories you gave the app, as `owner/name`. A public one never holds notes.
    public func privateRepositories(token: String) async throws -> [String] {
        let installations = try await api("user/installations", token: token)["installations"] as? [[String: Any]] ?? []
        var out: [String] = []
        for case let id as Int in installations.map({ $0["id"] }) {
            // ponytail: first 100 per installation; page through if anyone gives the app more.
            let listed = try await api("user/installations/\(id)/repositories?per_page=100", token: token)["repositories"] as? [[String: Any]] ?? []
            out += listed.filter { $0["private"] as? Bool == true }.compactMap { $0["full_name"] as? String }
        }
        return out.sorted()
    }

    static func read(_ body: [String: Any], now: Date) -> Answer {
        if let access = body["access_token"] as? String {
            let expires = (body["expires_in"] as? Int).map { now.addingTimeInterval(TimeInterval($0)) }
            return .tokens(Tokens(access: access, refresh: body["refresh_token"] as? String, expires: expires))
        }
        switch body["error"] as? String {
        case "authorization_pending": return .wait
        case "slow_down": return .slower
        case let error: return .failed(error ?? "with nothing readable")
        }
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://github.com/\(path)")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func api(_ path: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SyncError.github(status: status, message: object["message"] as? String ?? "") }
        return object
    }
}
