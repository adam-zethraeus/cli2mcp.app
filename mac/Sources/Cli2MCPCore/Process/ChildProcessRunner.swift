import Darwin
import Foundation

public struct ChildResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct ChildRunOptions: Sendable {
    public var timeoutMilliseconds: Int
    public var forceKillAfterMilliseconds: Int
    public var cwd: String?
    public var environment: [String: String]
    public var stdin: String?
    public var outputLimitBytes: Int

    public init(
        timeoutMilliseconds: Int,
        forceKillAfterMilliseconds: Int = 1_000,
        cwd: String? = nil,
        environment: [String: String] = [:],
        stdin: String? = nil,
        outputLimitBytes: Int = 1_048_576
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.forceKillAfterMilliseconds = forceKillAfterMilliseconds
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.outputLimitBytes = outputLimitBytes
    }
}

public enum ChildOutputStream: String, Equatable, Sendable {
    case stdout
    case stderr
}

public enum ChildProcessRunnerError: Error, Equatable, Sendable {
    case spawnFailed(command: String, message: String)
    case outputLimitExceeded(stream: ChildOutputStream, limitBytes: Int)
}

public final class ChildProcessRunner: @unchecked Sendable {
    private let registry: ChildRegistry

    public init(registry: ChildRegistry = ChildRegistry()) {
        self.registry = registry
    }

    public func run(
        command: String,
        arguments: [String],
        options: ChildRunOptions
    ) async throws -> ChildResult {
        let cancellation = ChildCancellationState()

        return try await withTaskCancellationHandler {
            try await runUncancelled(
                command: command,
                arguments: arguments,
                options: options,
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.escalate()
        }
    }
}

private extension ChildProcessRunner {
    func runUncancelled(
        command: String,
        arguments: [String],
        options: ChildRunOptions,
        cancellation: ChildCancellationState
    ) async throws -> ChildResult {
        let process = Process()
        process.executableURL = try resolveExecutableURL(command: command, options: options)
        process.arguments = arguments
        process.environment = options.environment
        if let cwd = options.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer(limitBytes: options.outputLimitBytes, stream: .stdout)
        let stderrBuffer = OutputBuffer(limitBytes: options.outputLimitBytes, stream: .stderr)
        let child = ChildProcess(process: process)
        let escalator = ProcessTerminationEscalator(
            child: child,
            forceKillAfterMilliseconds: options.forceKillAfterMilliseconds
        )

        let termination = ProcessTerminationContinuation(process: process)
        installReadHandler(for: stdoutPipe, buffer: stdoutBuffer, escalator: escalator)
        installReadHandler(for: stderrPipe, buffer: stderrBuffer, escalator: escalator)
        let registrationID = await registry.insert(child)

        do {
            try process.run()
        } catch {
            clearReadHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            closePipe(stdinPipe.fileHandleForWriting)
            await registry.remove(registrationID)
            throw ChildProcessRunnerError.spawnFailed(command: command, message: error.localizedDescription)
        }

        child.configureProcessGroupIfPossible()
        child.applyPendingTerminationIfNeeded()
        cancellation.set(escalator)
        let timeoutTask = makeTimeoutTask(
            escalator: escalator,
            timeoutMilliseconds: options.timeoutMilliseconds,
        )
        writeStdin(options.stdin, to: stdinPipe.fileHandleForWriting)

        let status = await termination.value()
        timeoutTask?.cancel()
        escalator.cancel()
        clearReadHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        drain(stdoutPipe, into: stdoutBuffer)
        drain(stderrPipe, into: stderrBuffer)
        await registry.remove(registrationID)

        if let exceeded = stdoutBuffer.exceededLimit() ?? stderrBuffer.exceededLimit() {
            throw ChildProcessRunnerError.outputLimitExceeded(
                stream: exceeded.stream,
                limitBytes: exceeded.limitBytes
            )
        }

        if Task.isCancelled {
            throw CancellationError()
        }

        return ChildResult(
            stdout: stdoutBuffer.stringValue(),
            stderr: stderrBuffer.stringValue(),
            exitCode: exitCode(for: status)
        )
    }

    func resolveExecutableURL(command: String, options: ChildRunOptions) throws -> URL {
        guard !command.isEmpty else {
            throw ChildProcessRunnerError.spawnFailed(command: command, message: "empty command")
        }

        if command.contains("/") {
            if command.hasPrefix("/") {
                return URL(fileURLWithPath: command).standardizedFileURL
            }

            if let cwd = options.cwd {
                return URL(fileURLWithPath: cwd, isDirectory: true)
                    .appendingPathComponent(command)
                    .standardizedFileURL
            }

            return URL(fileURLWithPath: command).standardizedFileURL
        }

        let searchPath = options.environment["PATH"] ?? defaultExecutableSearchPath
        for pathEntry in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = executableSearchDirectory(String(pathEntry), cwd: options.cwd)
            let candidate = directory.appendingPathComponent(command).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ChildProcessRunnerError.spawnFailed(command: command, message: "command not found in PATH")
    }

    func executableSearchDirectory(_ pathEntry: String, cwd: String?) -> URL {
        if pathEntry.isEmpty {
            return URL(
                fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        }

        if pathEntry.hasPrefix("/") {
            return URL(fileURLWithPath: pathEntry, isDirectory: true)
        }

        return URL(
            fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(pathEntry)
        .standardizedFileURL
    }

    func installReadHandler(for pipe: Pipe, buffer: OutputBuffer, escalator: ProcessTerminationEscalator) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            if !buffer.append(data) {
                escalator.start()
            }
        }
    }

    func clearReadHandlers(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    func drain(_ pipe: Pipe, into buffer: OutputBuffer) {
        let handle = pipe.fileHandleForReading
        let fileDescriptor = handle.fileDescriptor
        let originalFlags = fcntl(fileDescriptor, F_GETFL)
        if originalFlags != -1 {
            _ = fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }

        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }

            if count > 0 {
                _ = buffer.append(Data(chunk.prefix(count)))
                continue
            }

            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            if errno == EINTR {
                continue
            }

            break
        }

        if originalFlags != -1 {
            _ = fcntl(fileDescriptor, F_SETFL, originalFlags)
        }
    }

    func writeStdin(_ stdin: String?, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            if let stdin {
                try handle.write(contentsOf: Data(stdin.utf8))
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    func closePipe(_ handle: FileHandle) {
        try? handle.close()
    }

    func makeTimeoutTask(
        escalator: ProcessTerminationEscalator,
        timeoutMilliseconds: Int
    ) -> Task<Void, Never>? {
        guard timeoutMilliseconds > 0 else {
            return nil
        }

        return Task {
            try? await Task.sleep(nanoseconds: millisecondsToNanoseconds(timeoutMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            escalator.start()
        }
    }

    func exitCode(for termination: ProcessTermination) -> Int32 {
        switch termination.reason {
        case .exit:
            termination.status
        case .uncaughtSignal:
            128 + termination.status
        @unknown default:
            termination.status == 0 ? 1 : termination.status
        }
    }

}

private let defaultExecutableSearchPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

private struct ProcessTermination: Sendable {
    var reason: Process.TerminationReason
    var status: Int32
}

private final class ProcessTerminationContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessTermination, Never>?
    private var resolved: ProcessTermination?

    init(process: Process) {
        process.terminationHandler = { [weak self] process in
            self?.resolve(
                ProcessTermination(
                    reason: process.terminationReason,
                    status: process.terminationStatus
                )
            )
        }
    }

    func value() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolved {
                lock.unlock()
                continuation.resume(returning: resolved)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func resolve(_ termination: ProcessTermination) {
        let continuation: CheckedContinuation<ProcessTermination, Never>?

        lock.lock()
        if resolved != nil {
            lock.unlock()
            return
        }
        resolved = termination
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: termination)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceeded: OutputLimitExceeded?
    private let limitBytes: Int
    private let stream: ChildOutputStream

    init(limitBytes: Int, stream: ChildOutputStream) {
        self.limitBytes = max(0, limitBytes)
        self.stream = stream
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard exceeded == nil else {
            return false
        }

        let remaining = limitBytes - data.count
        if chunk.count > remaining {
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            exceeded = OutputLimitExceeded(stream: stream, limitBytes: limitBytes)
            return false
        }

        data.append(chunk)
        return true
    }

    func exceededLimit() -> OutputLimitExceeded? {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func stringValue() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

private struct OutputLimitExceeded: Sendable {
    var stream: ChildOutputStream
    var limitBytes: Int
}

private final class ProcessTerminationEscalator: @unchecked Sendable {
    private let lock = NSLock()
    private let child: ChildProcess
    private let forceKillAfterMilliseconds: Int
    private var task: Task<Void, Never>?

    init(child: ChildProcess, forceKillAfterMilliseconds: Int) {
        self.child = child
        self.forceKillAfterMilliseconds = forceKillAfterMilliseconds
    }

    func start() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }

        let child = self.child
        let forceKillAfterMilliseconds = self.forceKillAfterMilliseconds
        task = Task {
            child.terminate(signal: SIGTERM)

            try? await Task.sleep(nanoseconds: millisecondsToNanoseconds(forceKillAfterMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            child.terminate(signal: SIGKILL)
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()

        task?.cancel()
    }
}

private final class ChildCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var escalator: ProcessTerminationEscalator?
    private var cancellationRequested = false

    func set(_ escalator: ProcessTerminationEscalator) {
        lock.lock()
        self.escalator = escalator
        let shouldStart = cancellationRequested
        lock.unlock()

        if shouldStart {
            escalator.start()
        }
    }

    func escalate() {
        lock.lock()
        guard let escalator else {
            cancellationRequested = true
            lock.unlock()
            return
        }
        lock.unlock()

        escalator.start()
    }
}

private func millisecondsToNanoseconds(_ milliseconds: Int) -> UInt64 {
    guard milliseconds > 0 else {
        return 0
    }
    return UInt64(milliseconds) * 1_000_000
}
