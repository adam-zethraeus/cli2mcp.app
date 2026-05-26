import Darwin
import Foundation
import XCTest
@testable import Cli2MCPCore

final class ChildProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndStderrAsUTF8Strings() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf '\\303\\251-out\\n'
            printf '\\342\\230\\203-err\\n' >&2
            """
        )

        let result = try await ChildProcessRunner().run(
            command: script.path,
            arguments: [],
            options: ChildRunOptions(timeoutMilliseconds: 2_000)
        )

        let stdoutPrefix = String(decoding: [0xC3, 0xA9], as: UTF8.self)
        let stderrPrefix = String(decoding: [0xE2, 0x98, 0x83], as: UTF8.self)
        XCTAssertEqual(result.stdout, "\(stdoutPrefix)-out\n")
        XCTAssertEqual(result.stderr, "\(stderrPrefix)-err\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testWritesStdinThenClosesIt() async throws {
        let result = try await ChildProcessRunner().run(
            command: "/bin/cat",
            arguments: [],
            options: ChildRunOptions(timeoutMilliseconds: 2_000, stdin: "hello stdin")
        )

        XCTAssertEqual(result.stdout, "hello stdin")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNonZeroExitReturnsChildResultInsteadOfThrowing() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf 'problem\\n' >&2
            exit 42
            """
        )

        let result = try await ChildProcessRunner().run(
            command: script.path,
            arguments: [],
            options: ChildRunOptions(timeoutMilliseconds: 2_000)
        )

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "problem\n")
        XCTAssertEqual(result.exitCode, 42)
    }

    func testSpawnFailureThrowsTypedError() async {
        let missingCommand = "/definitely/not/a/cli2mcp-test-command"

        do {
            _ = try await ChildProcessRunner().run(
                command: missingCommand,
                arguments: [],
                options: ChildRunOptions(timeoutMilliseconds: 2_000)
            )
            XCTFail("Expected spawn failure")
        } catch ChildProcessRunnerError.spawnFailed(let command, _) {
            XCTAssertEqual(command, missingCommand)
        } catch {
            XCTFail("Expected ChildProcessRunnerError.spawnFailed, got \(error)")
        }
    }

    func testBareCommandResolvesAgainstCustomPath() async throws {
        let binDirectory = try makeTemporaryDirectory()
        try makeExecutableScript(
            named: "custom-tool",
            in: binDirectory,
            """
            #!/bin/sh
            printf 'resolved-from-path'
            """
        )

        let result = try await ChildProcessRunner().run(
            command: "custom-tool",
            arguments: [],
            options: ChildRunOptions(
                timeoutMilliseconds: 2_000,
                environment: ["PATH": binDirectory.path]
            )
        )

        XCTAssertEqual(result.stdout, "resolved-from-path")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRelativeSlashCommandResolvesAgainstWorkingDirectory() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        try makeExecutableScript(
            named: "relative-tool",
            in: workingDirectory,
            """
            #!/bin/sh
            printf 'resolved-from-cwd'
            """
        )

        let result = try await ChildProcessRunner().run(
            command: "./relative-tool",
            arguments: [],
            options: ChildRunOptions(
                timeoutMilliseconds: 2_000,
                cwd: workingDirectory.path
            )
        )

        XCTAssertEqual(result.stdout, "resolved-from-cwd")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testOutputLimitThrowsTypedError() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf 'abcdef'
            """
        )

        do {
            _ = try await ChildProcessRunner().run(
                command: script.path,
                arguments: [],
                options: ChildRunOptions(timeoutMilliseconds: 2_000, outputLimitBytes: 3)
            )
            XCTFail("Expected output limit failure")
        } catch ChildProcessRunnerError.outputLimitExceeded(let stream, let limitBytes) {
            XCTAssertEqual(stream, .stdout)
            XCTAssertEqual(limitBytes, 3)
        } catch {
            XCTFail("Expected ChildProcessRunnerError.outputLimitExceeded, got \(error)")
        }
    }

    func testOutputLimitEscalatesToForceKillWhenChildIgnoresSIGTERM() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            while :; do
              printf 'abcdefghijklmnopqrstuvwxyz'
            done
            """
        )
        let start = Date()

        do {
            _ = try await ChildProcessRunner().run(
                command: script.path,
                arguments: [],
                options: ChildRunOptions(
                    timeoutMilliseconds: 900,
                    forceKillAfterMilliseconds: 100,
                    outputLimitBytes: 8
                )
            )
            XCTFail("Expected output limit failure")
        } catch ChildProcessRunnerError.outputLimitExceeded(let stream, let limitBytes) {
            XCTAssertEqual(stream, .stdout)
            XCTAssertEqual(limitBytes, 8)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.75)
        } catch {
            XCTFail("Expected ChildProcessRunnerError.outputLimitExceeded, got \(error)")
        }
    }

    func testCancellationEscalatesToForceKillWhenChildIgnoresSIGTERM() async throws {
        let marker = temporaryFileURL().path
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            printf 'started' > "$1"
            while :; do
              sleep 1
            done
            """
        )
        let start = Date()

        let task = Task {
            try await ChildProcessRunner().run(
                command: script.path,
                arguments: [marker],
                options: ChildRunOptions(
                    timeoutMilliseconds: 900,
                    forceKillAfterMilliseconds: 100
                )
            )
        }

        try await waitForFile(at: marker, timeoutSeconds: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.75)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testTimeoutStillFiresWhileWritingLargeStdinToChildThatNeverReads() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            while :; do
              sleep 1
            done
            """
        )
        let largeInput = String(repeating: "x", count: 4 * 1024 * 1024)
        let start = Date()
        let task = Task {
            try await ChildProcessRunner().run(
                command: script.path,
                arguments: [],
                options: ChildRunOptions(
                    timeoutMilliseconds: 100,
                    forceKillAfterMilliseconds: 100,
                    stdin: largeInput
                )
            )
        }

        let result = try await awaitTaskValue(task, timeoutSeconds: 0.75)

        XCTAssertEqual(result.exitCode, 137)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.75)
    }

    func testTimeoutUsesProcessGroupWhenAvailableAndDocumentsDirectPIDFallback() async throws {
        let descendantPIDFile = temporaryFileURL().path
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            sleep 30 &
            printf '%s' "$!" > "$1"
            trap '' TERM
            while :; do
              sleep 1
            done
            """
        )

        let result = try await ChildProcessRunner().run(
            command: script.path,
            arguments: [descendantPIDFile],
            options: ChildRunOptions(
                timeoutMilliseconds: 100,
                forceKillAfterMilliseconds: 100
            )
        )

        XCTAssertEqual(result.exitCode, 137)
        let descendantPID = try readPID(at: descendantPIDFile)
        try await Task.sleep(nanoseconds: 50_000_000)

        defer {
            if isProcessAlive(descendantPID) {
                Darwin.kill(descendantPID, SIGKILL)
            }
        }

        if canUseProcessGroupAfterFoundationLaunch() {
            XCTAssertFalse(isProcessAlive(descendantPID))
        } else {
            XCTAssertTrue(isProcessAlive(descendantPID))
        }
    }

    func testTimeoutForceKillsChildThatIgnoresSIGTERM() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            while :; do
              sleep 1
            done
            """
        )

        let result = try await ChildProcessRunner().run(
            command: script.path,
            arguments: [],
            options: ChildRunOptions(
                timeoutMilliseconds: 100,
                forceKillAfterMilliseconds: 100
            )
        )

        XCTAssertEqual(result.exitCode, 137)
    }

    func testTerminateAllTerminatesActiveChild() async throws {
        let registry = ChildRegistry()
        let runner = ChildProcessRunner(registry: registry)
        let marker = temporaryFileURL().path
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf 'started' > "$1"
            while :; do
              sleep 1
            done
            """
        )
        let command = script.path

        let task = Task {
            try await runner.run(
                command: command,
                arguments: [marker],
                options: ChildRunOptions(timeoutMilliseconds: 10_000)
            )
        }

        try await waitForFile(at: marker, timeoutSeconds: 2)
        await registry.terminateAll()
        let result = try await task.value

        XCTAssertEqual(result.exitCode, 143)
    }
}

private func makeExecutableScript(_ body: String) throws -> URL {
    let url = temporaryFileURL()
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

@discardableResult
private func makeExecutableScript(named name: String, in directory: URL, _ body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

private func makeTemporaryDirectory() throws -> URL {
    let url = temporaryFileURL()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cli2mcp-\(UUID().uuidString)")
}

private func waitForFile(at path: String, timeoutSeconds: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for file at \(path)")
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func awaitTaskValue<T: Sendable>(_ task: Task<T, Error>, timeoutSeconds: TimeInterval) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let box = ContinuationBox(continuation)

        Task {
            do {
                box.resume(.success(try await task.value))
            } catch {
                box.resume(.failure(error))
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            guard box.resume(.failure(TestTimeoutError.timedOut)) else {
                return
            }

            task.cancel()
            Task {
                _ = try? await task.value
            }
        }
    }
}

private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }

        return true
    }
}

private func readPID(at path: String) throws -> pid_t {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let value = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    return pid_t(value)
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func canUseProcessGroupAfterFoundationLaunch() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]

    do {
        try process.run()
    } catch {
        return false
    }

    let pid = process.processIdentifier
    let succeeded = getpgid(pid) == pid || setpgid(pid, pid) == 0
    Darwin.kill(succeeded ? -pid : pid, SIGKILL)
    process.waitUntilExit()
    return succeeded
}
