import Foundation

/// Reads a variable from the user's login shell. An app launched from Finder or the Dock does
/// not inherit variables exported in `~/.zshrc` or `~/.zprofile`, so asking the shell once at
/// launch lets the TypeSafe key live in the same place as the user's other credentials.
/// The value is cached in memory only and never logged.
nonisolated enum ShellEnvironmentKey {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// Cached value from `load`, or nil when the shell had none (or `load` has not run).
    static func cached(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[name]
    }

    /// Runs the login shell once and caches the variable. Safe to call repeatedly.
    static func load(_ name: String) async {
        guard isValidName(name) else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive login shell so both profile and rc files run. Markers separate the value
        // from whatever the user's rc files print.
        let script = "printf '\\n__EM_BEGIN__%s__EM_END__' \"${\(name)-}\""
        let result = await Shell.run(shell, ["-l", "-i", "-c", script], timeout: 8)
        guard let value = parse(result.stdout), !value.isEmpty else { return }
        lock.lock(); cache[name] = value; lock.unlock()
    }

    /// Value between the markers, or nil when they are missing.
    static func parse(_ output: String) -> String? {
        guard let begin = output.range(of: "__EM_BEGIN__"),
              let end = output.range(of: "__EM_END__", range: begin.upperBound ..< output.endIndex)
        else { return nil }
        return String(output[begin.upperBound ..< end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
