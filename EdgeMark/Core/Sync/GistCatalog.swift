import Foundation

/// Message from a failed gh or git step, shown to the user as is.
struct GHError: Error, Equatable {
    let message: String
}

struct Gist: Equatable {
    let id: String
    let description: String
    let htmlURL: String
    let files: [String]
}

/// Everything that talks to `gh`, plus the pure parsing it needs.
enum GistCatalog {
    // MARK: - Pure helpers

    /// Logins from `gh auth status` output, in the order printed. ANSI colour codes are
    /// stripped, any line ending is accepted, and a token that is not a valid GitHub
    /// login is dropped (logins are embedded in clone URLs).
    static func accounts(fromAuthStatus text: String) -> [String] {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let pattern = #/Logged in to github\.com account (\S+)/#
        // "\r\n" is one Character in Swift, so splitting on "\n" would miss CRLF text.
        return plain.components(separatedBy: .newlines).compactMap { line in
            guard let login = line.firstMatch(of: pattern).map({ String($0.1) }), isValidLogin(login) else { return nil }
            return login
        }
    }

    /// True for a GitHub login: alphanumerics and hyphens, not starting with a hyphen, at most 39 characters.
    static func isValidLogin(_ login: String) -> Bool {
        login.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]{0,38}/#) != nil
    }

    /// True for a gist id as GitHub issues them: 1 to 64 lowercase hex digits.
    static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: #/[0-9a-f]{1,64}/#) != nil
    }

    /// Longest name `directoryName` returns, in UTF-8 bytes. Leaves room for the
    /// `-<7 hex>` suffix a clash adds while staying within 100 bytes.
    static let maxDirectoryNameBytes = 92

    /// Folder name for a gist clone: the description made filename-safe, else the id,
    /// else `gist` when the id is not a valid gist id (it comes from the network).
    static func directoryName(description: String, id: String) -> String {
        var name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        name = name.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        while name.utf8.count > maxDirectoryNameBytes {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if !name.isEmpty { return name }
        return isValidID(id) ? id : "gist"
    }

    /// Gist id from a clone URL such as `https://u@gist.github.com/ID.git` or `git@gist.github.com:ID.git`.
    /// The whole URL must match, so another host or trailing path segments give nil.
    static func gistID(fromOrigin url: String) -> String? {
        let pattern = #/(?:https:\/\/(?:[^@\/\s]+@)?gist\.github\.com\/|git@gist\.github\.com:)([0-9a-f]{1,64})(?:\.git)?/#
        return url.wholeMatch(of: pattern).map { String($0.1) }
    }

    /// Login embedded in an HTTPS gist clone URL (`https://<login>@gist.github.com/...`),
    /// else nil (no login, SSH, or not a gist URL).
    static func login(fromOrigin url: String) -> String? {
        guard gistID(fromOrigin: url) != nil else { return nil }
        return url.firstMatch(of: #/^https:\/\/([^@\/\s]+)@gist\.github\.com\//#).map { String($0.1) }
    }

    /// Gist id from `gh gist create` output (the URL is the last line).
    static func gistID(fromCreateOutput text: String) -> String? {
        text.firstMatch(of: #/gist\.github\.com\/(?:[^\/\s]+\/)?([0-9a-f]+)/#).map { String($0.1) }
    }

    /// Parses the NDJSON produced by `list`'s jq filter. Entries with an invalid id are
    /// dropped, since the id becomes part of a clone URL and a folder name.
    static func parseGistLines(_ ndjson: String) -> [Gist] {
        struct Line: Decodable {
            let id: String
            let description: String?
            let html_url: String
            let files: [String]
        }
        return ndjson.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let l = try? JSONDecoder().decode(Line.self, from: data), isValidID(l.id) else { return nil }
            return Gist(id: l.id, description: l.description ?? "", htmlURL: l.html_url, files: l.files)
        }
    }

    /// GitHub's per-file anchor: `file-` + lowercased name with runs of non-alphanumerics as `-`.
    static func anchor(forFile name: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "file-\(slug)"
    }

    /// Web URL of a gist; the account segment is omitted when `account` is nil or empty.
    static func webURL(account: String?, id: String, file: String?) -> URL {
        var s = "https://gist.github.com/"
        if let account, !account.isEmpty { s += "\(account)/" }
        s += id
        if let file { s += "#\(anchor(forFile: file))" }
        return URL(string: s)!
    }

    /// HTTPS clone URL with the login embedded so gh's credential helper picks that account.
    static func cloneURL(account: String, id: String) -> String {
        "https://\(account)@gist.github.com/\(id).git"
    }

    // MARK: - gh calls

    static func accounts() async -> [String] {
        let r = await Shell.run("gh", ["auth", "status"])
        return accounts(fromAuthStatus: r.stdout + "\n" + r.stderr)
    }

    static func token(account: String) async -> String? {
        let r = await Shell.run("gh", ["auth", "token", "--user", account])
        let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !t.isEmpty ? t : nil
    }

    private static func env(account: String) async -> [String: String]? {
        guard let token = await token(account: account) else { return nil }
        return ["GH_TOKEN": token]
    }

    /// All gists of `account`, newest first. One JSON object per line so pagination is trivial.
    static func list(account: String) async -> Result<[Gist], GHError> {
        guard let env = await env(account: account) else { return .failure(GHError(message: "gh has no token for \(account)")) }
        // `gh api --paginate` prints one JSON array per page; `.[]` flattens them to one object per line.
        let jq = ".[] | {id, description, html_url, files: (.files | keys)}"
        let r = await Shell.run("gh", ["api", "--paginate", "/gists?per_page=100", "--jq", jq], env: env, timeout: 120)
        guard r.ok else { return .failure(GHError(message: r.errorLine)) }
        return .success(parseGistLines(r.stdout))
    }

    /// Creates a gist from one file and returns its id. Secret (unlisted) unless `isPublic`.
    static func create(account: String, file: URL, description: String, isPublic: Bool = false) async -> Result<String, GHError> {
        guard let env = await env(account: account) else { return .failure(GHError(message: "gh has no token for \(account)")) }
        var args = ["gist", "create", "--desc", description, file.path]
        if isPublic { args.append("--public") }
        let r = await Shell.run("gh", args, env: env, timeout: 120)
        guard r.ok, let id = gistID(fromCreateOutput: r.stdout + "\n" + r.stderr) else {
            return .failure(GHError(message: r.ok ? "could not read gist id from gh output" : r.errorLine))
        }
        return .success(id)
    }
}
