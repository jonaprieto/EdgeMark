import Foundation

/// Runs command-line tools (git, gh) with a timeout and captured output.
/// Never prompts: terminal prompts are disabled and stdin is /dev/null.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { status == 0 }

        /// Last non-empty stderr line, short enough for a status tooltip.
        var errorLine: String {
            let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return lines.last(where: { !$0.isEmpty }) ?? "exit status \(status)"
        }
    }

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Absolute path of a tool, or nil when it is not installed in any search path.
    static func find(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        return searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(
        _ tool: String,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval = 60,
    ) async -> Result {
        guard let exe = find(tool) else {
            return Result(status: 127, stdout: "", stderr: "\(tool) not found in \(searchPaths.joined(separator: ":"))")
        }
        return await Task.detached(priority: .utility) {
            runBlocking(exe: exe, args: args, cwd: cwd, env: env, timeout: timeout)
        }.value
    }

    // MARK: - Private

    /// Mutable buffer that a reader thread fills while the main flow waits for exit.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }
    }

    /// Thread-safe flag recording that the timeout killer actually fired.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static func runBlocking(exe: String, args: [String], cwd: URL?, env: [String: String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: 126, stdout: "", stderr: error.localizedDescription)
        }

        // Drain both pipes on background threads. A grandchild that inherited the
        // pipes can keep them open after the tool exits, so the final wait is bounded.
        let outBuffer = Buffer()
        let errBuffer = Buffer()
        let readers = DispatchGroup()
        for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                // Append chunk by chunk so a bounded wait still returns what arrived.
                while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                    buffer.append(chunk)
                }
                readers.leave()
            }
        }

        let timedOut = Flag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        _ = readers.wait(timeout: .now() + 2)

        let stdout = String(decoding: outBuffer.data, as: UTF8.self)
        let stderr = String(decoding: errBuffer.data, as: UTF8.self)
        if timedOut.isSet {
            return Result(status: -1, stdout: stdout, stderr: stderr + "\n\(exe.split(separator: "/").last ?? "") timed out after \(Int(timeout))s")
        }
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
