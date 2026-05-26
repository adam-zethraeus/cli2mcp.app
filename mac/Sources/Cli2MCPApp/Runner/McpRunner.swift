import Foundation
import Combine

/// Drives a single ephemeral native helper process: spawn it, perform the MCP
/// handshake, list tools, render the transcript. Stop tears the child down.
///
/// All UI-visible state mutates on the main actor. The actual I/O lives on a
/// detached Task and posts updates back via `await MainActor.run`.
@MainActor
final class McpRunner: ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case running(toolName: String, toolCount: Int)
        case stopped(exitCode: Int32?)
        case failed(message: String)
    }

    struct LogLine: Identifiable, Hashable {
        enum Kind { case info, sent, recv, stderr, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// JSON-RPC request IDs we send during the handshake. Named so that
    /// `handleResponse(id:)` doesn't switch on bare integers — the coupling
    /// between sender and receiver is now visible at both call sites.
    private enum RequestID {
        static let initialize = 1
        static let toolsList = 2
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript: [LogLine] = []

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var activeRunID: UUID?

    var isRunning: Bool {
        if case .running = status { return true }
        if case .starting = status { return true }
        return false
    }

    func clear() {
        guard !isRunning else { return }
        transcript = []
        status = .idle
    }

    func start(preset: CliPreset, runtime: NativeRuntime, forwardEnvironment: Bool) {
        guard !isRunning else { return }
        transcript = []
        status = .starting

        // Mirror the exact argv the snippet card advertises so that what the
        // user tests in-app matches what their MCP client will spawn.
        var presetArgs = preset.fullArgs()
        if forwardEnvironment {
            presetArgs.append("--inherit-shell-env")
        }

        log(.info, "Launching native helper \(runtime.serverExecutable) \(presetArgs.joined(separator: " "))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.serverExecutable)
        process.arguments = presetArgs
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let runID = UUID()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.activeRunID = runID

        stderrTask = streamData(from: stderr.fileHandleForReading, runID: runID) { runner, data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            runner.log(.stderr, text.trimmingCharacters(in: .newlines))
        }

        let lineReader = LineReader { [weak self] line in
            Task { @MainActor [weak self] in
                guard self?.activeRunID == runID else { return }
                self?.handleServerLine(line)
            }
        }
        stdoutTask = streamData(from: stdout.fileHandleForReading, runID: runID) { _, data in
            lineReader.feed(data: data)
        }

        process.terminationHandler = { [weak self, runID] proc in
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(runID: runID, exitCode: exitCode)
            }
        }

        do {
            try process.run()
        } catch {
            log(.error, "Failed to launch: \(error.localizedDescription)")
            status = .failed(message: error.localizedDescription)
            // The handlers we just installed are now bound to pipes that
            // will never see data. Tear them down so the dispatch sources
            // don't outlive their FileHandles.
            tearDownChildIO(runID: runID)
            return
        }

        // Drive the handshake on a detached task so the UI stays responsive.
        handshakeTask = Task { [weak self, runID] in
            await self?.driveHandshake(runID: runID)
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        log(.info, "Stopping …")
        handshakeTask?.cancel()
        process.terminate()
    }

    // MARK: - Handshake

    private nonisolated func driveHandshake(runID: UUID) async {
        // 1) initialize
        await send(
            id: RequestID.initialize,
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "Cli2MCPApp", "version": "0.1.0"],
            ] as [String: Any],
            runID: runID
        )
        guard !Task.isCancelled else { return }

        // 2) initialized notification
        await sendNotification(method: "notifications/initialized", params: [:], runID: runID)
        guard !Task.isCancelled else { return }

        // 3) tools/list
        await send(id: RequestID.toolsList, method: "tools/list", params: [:], runID: runID)
    }

    private nonisolated func send(id: Int, method: String, params: [String: Any], runID: UUID) async {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        await write(payload: payload, method: method, runID: runID)
    }

    private nonisolated func sendNotification(method: String, params: [String: Any], runID: UUID) async {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        await write(payload: payload, method: method, runID: runID)
    }

    private nonisolated func write(payload: [String: Any], method: String, runID: UUID) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let body = String(data: data, encoding: .utf8) else { return }
        guard !Task.isCancelled else { return }
        let line = body + "\n"

        await MainActor.run {
            guard self.activeRunID == runID else { return }
            self.log(.sent, "→ \(method)")
            guard let handle = self.stdinPipe?.fileHandleForWriting else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    // MARK: - Server messages

    private func handleServerLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log(.recv, "← (unparsed) \(trimmed)")
            return
        }

        if let id = obj["id"] as? Int, let result = obj["result"] as? [String: Any] {
            handleResponse(id: id, result: result)
        } else if let error = obj["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "(no message)"
            log(.error, "← error: \(msg)")
            status = .failed(message: msg)
        } else if let method = obj["method"] as? String {
            log(.recv, "← notification \(method)")
        } else {
            log(.recv, "← \(trimmed)")
        }
    }

    private func handleResponse(id: Int, result: [String: Any]) {
        switch id {
        case RequestID.initialize:
            let serverInfo = result["serverInfo"] as? [String: Any]
            let name = serverInfo?["name"] as? String ?? "(unknown)"
            let version = serverInfo?["version"] as? String ?? "(?)"
            log(.recv, "← initialize ok — \(name) v\(version)")
        case RequestID.toolsList:
            let tools = result["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            log(.recv, "← tools/list — \(tools.count) tool(s): \(names.joined(separator: ", "))")
            if let first = tools.first,
               let name = first["name"] as? String,
               let schema = first["inputSchema"] as? [String: Any],
               let props = schema["properties"] as? [String: Any] {
                let flagCount = props.keys.count
                status = .running(toolName: name, toolCount: flagCount)
                log(.info, "✓ Server is healthy. Tool '\(name)' exposes \(flagCount) input properties.")
            } else {
                status = .running(toolName: names.first ?? "(unnamed)", toolCount: 0)
            }
        default:
            log(.recv, "← response id=\(id)")
        }
    }

    private func handleTermination(runID: UUID, exitCode: Int32) {
        guard activeRunID == runID else { return }
        tearDownChildIO(runID: runID)
        log(.info, "Process exited with code \(exitCode)")
        if case .failed = status {
            // keep failure
        } else {
            status = .stopped(exitCode: exitCode)
        }
    }

    private func streamData(
        from handle: FileHandle,
        runID: UUID,
        receive: @escaping @MainActor (McpRunner, Data) -> Void
    ) -> Task<Void, Never> {
        let readable = SendableFileHandle(handle)
        return Task.detached(priority: .utility) { [weak self, runID, readable] in
            while !Task.isCancelled {
                let data = readable.handle.availableData
                guard !data.isEmpty else {
                    return
                }
                await MainActor.run { [weak self, runID] in
                    guard let self, self.activeRunID == runID else { return }
                    receive(self, data)
                }
            }
        }
    }

    /// Idempotent teardown: cancel owned async work, then drop pipe/process refs.
    /// Reader tasks retain their FileHandles until any blocking read observes EOF.
    private func tearDownChildIO(runID: UUID) {
        guard activeRunID == runID else { return }
        let retired = RetiredChildIO(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdoutTask: stdoutTask,
            stderrTask: stderrTask
        )
        handshakeTask?.cancel()
        activeRunID = nil
        handshakeTask = nil
        stdoutTask = nil
        stderrTask = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            retired.closeParentPipeEnds()
            retired.stdoutTask?.cancel()
            retired.stderrTask?.cancel()
            _ = retired
        }
    }

    private func log(_ kind: LogLine.Kind, _ text: String) {
        transcript.append(LogLine(kind: kind, text: text))
        // Cap transcript at a reasonable size.
        if transcript.count > 500 {
            transcript.removeFirst(transcript.count - 500)
        }
    }
}

// MARK: - LineReader

/// Buffers stdout chunks and emits one callback per newline-delimited message.
/// MCP stdio guarantees no embedded newlines per message.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            if let str = String(data: lineData, encoding: .utf8) {
                lines.append(str)
            }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }
}

private struct SendableFileHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

private struct RetiredChildIO: @unchecked Sendable {
    let process: Process?
    let stdinPipe: Pipe?
    let stdoutPipe: Pipe?
    let stderrPipe: Pipe?
    let stdoutTask: Task<Void, Never>?
    let stderrTask: Task<Void, Never>?

    func closeParentPipeEnds() {
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
    }
}
