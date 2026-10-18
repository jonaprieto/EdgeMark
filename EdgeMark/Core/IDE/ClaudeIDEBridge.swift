import Foundation
import Network
import OSLog

/// Lets Claude Code connect to EdgeMark the way it connects to VS Code: a WebSocket server
/// on localhost plus a lock file under `~/.claude/ide`, so `/ide` (or `claude --ide`) in a
/// session started inside the notes folder finds EdgeMark and sees the editor's selection.
final class ClaudeIDEBridge {
    static let shared = ClaudeIDEBridge()

    private let queue = DispatchQueue(label: "io.github.ender-wang.EdgeMark.claude-ide")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastSelection: Data?
    /// A mention sent while no session was connected, delivered to the next one.
    private var pendingMention: Data?
    private var lockURL: URL?

    private init() {}

    private static var configDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Starts the server for `workspace`, the notes root. At launch it runs only where Claude
    /// Code has a config directory; `create` (Send to Claude) makes `~/.claude/ide` instead.
    /// ponytail: a root switched while running stays the old one in the lock file until relaunch.
    func start(workspace: URL, create: Bool = false) {
        queue.sync { startOnQueue(workspace: workspace, create: create) }
    }

    private func startOnQueue(workspace: URL, create: Bool) {
        let config = Self.configDirectory
        guard listener == nil, create || FileManager.default.fileExists(atPath: config.path),
              let token = IDEProtocol.token() else { return }

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { subprotocols, headers in
            let authorized = headers.contains {
                $0.name.lowercased() == "x-claude-code-ide-authorization" && $0.value == token
            }
            // The CLI asks for the "mcp" subprotocol and drops the connection if it is not echoed.
            return NWProtocolWebSocket.Response(
                status: authorized ? .accept : .reject, subprotocol: subprotocols.first { $0 == "mcp" },
            )
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            Log.app.error("[ClaudeIDE] listener failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                writeLockFile(port: port, workspace: workspace, token: token, config: config)
            case let .failed(error):
                Log.app.error("[ClaudeIDE] listener stopped: \(error.localizedDescription, privacy: .public)")
                stopOnQueue()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Closes connections and removes the lock file.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Shares the editor's selection with connected sessions, and with any that connect later.
    /// Formatted off the main thread, and not at all when the server is not running.
    func sendSelection(text: String, range: NSRange, hiddenPrefix: String, filePath: String) {
        queue.async { [self] in
            guard listener != nil else { return }
            let selection = IDEProtocol.selectionChanged(text: text, range: range, hiddenPrefix: hiddenPrefix, filePath: filePath)
            lastSelection = selection
            for connection in connections {
                send(selection, on: connection)
            }
        }
    }

    /// Puts `@file#Lstart-end` in the prompt of the connected session, starting the server
    /// if needed; with no session yet, the next one to connect gets it.
    func mention(text: String, range: NSRange, hiddenPrefix: String, filePath: String, workspace: URL) {
        start(workspace: workspace, create: true)
        queue.async { [self] in
            let mention = IDEProtocol.atMentioned(text: text, range: range, hiddenPrefix: hiddenPrefix, filePath: filePath)
            if connections.isEmpty {
                pendingMention = mention
            }
            for connection in connections {
                send(mention, on: connection)
            }
        }
    }

    // MARK: - Queue-confined

    private func writeLockFile(port: UInt16, workspace: URL, token: String, config: URL) {
        let directory = config.appendingPathComponent("ide", isDirectory: true)
        let url = directory.appendingPathComponent("\(port).lock")
        let workspacePath = workspace.resolvingSymlinksInPath().path
        let contents = IDEProtocol.lockFile(pid: getpid(), workspace: workspacePath, token: token)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
            )
            guard FileManager.default.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            lockURL = url
            Log.app.info("[ClaudeIDE] listening on port \(port)")
        } catch {
            Log.app.error("[ClaudeIDE] lock file not written: \(error.localizedDescription, privacy: .public)")
            stopOnQueue()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connections.append(connection)
                if let lastSelection {
                    send(lastSelection, on: connection)
                }
                if let pendingMention {
                    send(pendingMention, on: connection)
                    self.pendingMention = nil
                }
            case .failed:
                connection.cancel()
            case .cancelled:
                connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                return
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if let data, let reply = IDEProtocol.reply(to: data, version: version) {
                send(reply, on: connection)
            }
            receive(on: connection)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let context = NWConnection.ContentContext(
            identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)],
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func stopOnQueue() {
        if let lockURL {
            try? FileManager.default.removeItem(at: lockURL)
        }
        lockURL = nil
        connections.forEach { $0.cancel() }
        connections = []
        listener?.cancel()
        listener = nil
    }
}
