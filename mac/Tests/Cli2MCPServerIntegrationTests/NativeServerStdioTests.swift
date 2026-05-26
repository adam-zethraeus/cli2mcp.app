import Darwin
import Foundation
import XCTest
@testable import Cli2MCPCore

final class NativeServerStdioTests: XCTestCase {
    func testNativeServerHandlesInitializeListAndCallOverLineDelimitedStdio() throws {
        let fixture = try makeIntegrationFixture()
        let serverBinary = try locateServerBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            fixture.path,
            "--name", "fixture",
            "--timeout", "5000",
            "--env-passthrough", "all"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let reader = NonblockingLineReader(fileHandle: stdout.fileHandleForReading)

        try writeLine(
            JSONRPCRequest(
                id: .integer(1),
                method: "initialize",
                params: .object([
                    "protocolVersion": .string("2025-11-25"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("stdio-test"), "version": .string("0.0.0")])
                ])
            ),
            to: stdin
        )
        try writeLine(JSONRPCNotification(method: "notifications/initialized"), to: stdin)
        try writeLine(JSONRPCRequest(id: .integer(2), method: "tools/list"), to: stdin)
        try writeLine(
            JSONRPCRequest(
                id: .integer(3),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object([
                        "upper": .bool(true),
                        "prefix": .string(">> "),
                        "args": .array([.string("hello"), .string("world")])
                    ])
                ])
            ),
            to: stdin
        )

        var responses: [JSONRPCResponse] = []
        for _ in 0..<3 {
            responses.append(try reader.readResponse(timeoutSeconds: 2))
        }

        try stdin.fileHandleForWriting.close()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: stderrData, as: UTF8.self)
        )

        XCTAssertEqual(responses.count, 3)

        let initialize = try XCTUnwrap(responses.first { $0.id == .integer(1) })
        let initializeResult = try XCTUnwrap(initialize.result).decoded(as: MCPInitializeResult.self)
        XCTAssertEqual(initializeResult.protocolVersion, "2025-11-25")
        XCTAssertEqual(initializeResult.serverInfo.name, "cli2mcp")

        let tools = try XCTUnwrap(responses.first { $0.id == .integer(2) })
        let toolsResult = try XCTUnwrap(tools.result).decoded(as: MCPListToolsResult.self)
        XCTAssertEqual(toolsResult.tools.map(\.name), ["fixture"])

        let call = try XCTUnwrap(responses.first { $0.id == .integer(3) })
        let callResult = try XCTUnwrap(call.result).decoded(as: MCPCallToolResult.self)
        XCTAssertEqual(callResult.isError, nil)
        XCTAssertEqual(callResult.content.first?.text, ">> HELLO WORLD")
    }

    func testStdioTransportRespondsToPingWhileToolCallIsStillRunning() throws {
        let fixture = try makeIntegrationFixture()
        let serverBinary = try locateServerBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            fixture.path,
            "--name", "fixture",
            "--timeout", "5000",
            "--env-passthrough", "all"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let reader = NonblockingLineReader(fileHandle: stdout.fileHandleForReading)

        try writeLine(
            JSONRPCRequest(
                id: .integer(10),
                method: "initialize",
                params: .object([
                    "protocolVersion": .string("2025-11-25"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("stdio-test"), "version": .string("0.0.0")])
                ])
            ),
            to: stdin
        )
        _ = try reader.readResponse(timeoutSeconds: 2)
        try writeLine(JSONRPCNotification(method: "notifications/initialized"), to: stdin)
        try writeLine(
            JSONRPCRequest(
                id: .integer(11),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["sleep": .number(1)])
                ])
            ),
            to: stdin
        )

        let start = Date()
        try writeLine(JSONRPCRequest(id: .integer(12), method: "ping"), to: stdin)
        let prompt = try reader.readResponse(timeoutSeconds: 0.5)

        XCTAssertEqual(prompt.id, .integer(12))
        XCTAssertEqual(prompt.result, .object([:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        let slow = try reader.readResponse(timeoutSeconds: 2)
        XCTAssertEqual(slow.id, .integer(11))

        try stdin.fileHandleForWriting.close()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderrData, as: UTF8.self))
    }

    func testSignalDuringStartupHelpCaptureTerminatesHelpChild() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli2mcp-help-pid-\(UUID().uuidString)")
        let fixture = try makeStartupHelpFixture(pidFile: pidFile)
        let serverBinary = try locateServerBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [fixture.path, "--name", "fixture", "--timeout", "10000"]
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        try waitForFile(at: pidFile.path, timeoutSeconds: 2)
        let childPID = try readPID(at: pidFile)

        defer {
            if isProcessAlive(childPID) {
                Darwin.kill(childPID, SIGKILL)
            }
            if process.isRunning {
                process.terminate()
            }
        }

        process.terminate()
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(isProcessAlive(childPID))
    }

    func testEOFWhileToolCallIsRunningTerminatesActiveChild() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli2mcp-hold-pid-\(UUID().uuidString)")
        let fixture = try makeStubbornToolFixture(pidFile: pidFile)
        let serverBinary = try locateServerBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            fixture.path,
            "--name", "fixture",
            "--timeout", "10000",
            "--env-passthrough", "all"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let reader = NonblockingLineReader(fileHandle: stdout.fileHandleForReading)

        try writeLine(JSONRPCRequest(id: .integer(20), method: "initialize"), to: stdin)
        _ = try reader.readResponse(timeoutSeconds: 2)
        try writeLine(
            JSONRPCRequest(
                id: .integer(21),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["hold": .bool(true)])
                ])
            ),
            to: stdin
        )

        try waitForFile(at: pidFile.path, timeoutSeconds: 2)
        let childPID = try readPID(at: pidFile)

        defer {
            if isProcessAlive(childPID) {
                Darwin.kill(childPID, SIGKILL)
            }
        }

        try stdin.fileHandleForWriting.close()
        try waitForProcessExit(process, timeoutSeconds: 4)

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderrData, as: UTF8.self))
        XCTAssertFalse(isProcessAlive(childPID))
    }

    func testSignalShutdownForceKillsStubbornToolChild() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli2mcp-signal-hold-pid-\(UUID().uuidString)")
        let fixture = try makeStubbornToolFixture(pidFile: pidFile)
        let serverBinary = try locateServerBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            fixture.path,
            "--name", "fixture",
            "--timeout", "10000",
            "--env-passthrough", "all"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let reader = NonblockingLineReader(fileHandle: stdout.fileHandleForReading)

        try writeLine(JSONRPCRequest(id: .integer(30), method: "initialize"), to: stdin)
        _ = try reader.readResponse(timeoutSeconds: 2)
        try writeLine(
            JSONRPCRequest(
                id: .integer(31),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["hold": .bool(true)])
                ])
            ),
            to: stdin
        )

        try waitForFile(at: pidFile.path, timeoutSeconds: 2)
        let childPID = try readPID(at: pidFile)

        defer {
            if isProcessAlive(childPID) {
                Darwin.kill(childPID, SIGKILL)
            }
        }

        process.terminate()
        try waitForProcessExit(process, timeoutSeconds: 4)

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderrData, as: UTF8.self))
        XCTAssertFalse(isProcessAlive(childPID))
    }
}

private func writeLine<T: Encodable>(_ value: T, to pipe: Pipe) throws {
    let data = try JSONEncoder().encode(value)
    try pipe.fileHandleForWriting.write(contentsOf: data)
    try pipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
}

private func parseResponses(_ data: Data) throws -> [JSONRPCResponse] {
    let text = String(decoding: data, as: UTF8.self)
    return try text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { line in
            let data = Data(line.utf8)
            return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        }
}

private func locateServerBinary() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["CLI2MCP_SERVER_BIN"],
       FileManager.default.isExecutableFile(atPath: override) {
        return override
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "build", "--product", "cli2mcp-server", "--show-bin-path"]
    process.currentDirectoryURL = packageRoot

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw TestFailure("swift build --show-bin-path failed: \(String(decoding: stderrData, as: UTF8.self))")
    }

    let binPath = String(decoding: stdoutData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = URL(fileURLWithPath: binPath).appendingPathComponent("cli2mcp-server").path
    guard FileManager.default.isExecutableFile(atPath: candidate) else {
        throw TestFailure("cli2mcp-server was not executable at \(candidate)")
    }
    return candidate
}

private func makeIntegrationFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli2mcp-fixture-\(UUID().uuidString)")
    let body = """
    #!/bin/sh
    if [ "$1" = "--help" ]; then
      cat <<'EOF'
    fixture - test cli

    Usage: fixture [options] <args...>

    Options:
      --upper              uppercase output
      --prefix <string>    prefix string
      --sleep <seconds>    sleep before output
      --fail               exit with an error
    EOF
      exit 0
    fi

    prefix=""
    upper=0
    sleep_seconds=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --upper) upper=1 ;;
        --prefix) shift; prefix="$1" ;;
        --sleep) shift; sleep_seconds="$1" ;;
        --fail) echo "boom" >&2; exit 1 ;;
        --) shift; break ;;
        *) break ;;
      esac
      shift
    done

    if [ -n "$sleep_seconds" ]; then
      sleep "$sleep_seconds"
    fi

    text="$prefix$*"
    if [ "$upper" = "1" ]; then
      printf '%s' "$text" | tr '[:lower:]' '[:upper:]'
    else
      printf '%s' "$text"
    fi
    """

    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

private func makeStartupHelpFixture(pidFile: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli2mcp-startup-fixture-\(UUID().uuidString)")
    let body = """
    #!/bin/sh
    if [ "$1" = "--help" ]; then
      printf '%s' "$$" > '\(pidFile.path)'
      while :; do sleep 1; done
    fi
    """

    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

private func makeStubbornToolFixture(pidFile: URL) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli2mcp-stubborn-fixture-\(UUID().uuidString)")
    let body = """
    #!/bin/sh
    if [ "$1" = "--help" ]; then
      cat <<'EOF'
    fixture - stubborn cli

    Usage: fixture [options]

    Options:
      --hold               ignore TERM and keep running
    EOF
      exit 0
    fi

    hold=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --hold) hold=1 ;;
        --) shift; break ;;
        *) break ;;
      esac
      shift
    done

    if [ "$hold" = "1" ]; then
      printf '%s' "$$" > '\(pidFile.path)'
      trap '' TERM
      while :; do sleep 1; done
    fi

    printf 'done'
    """

    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

private final class NonblockingLineReader {
    private let fileDescriptor: Int32
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileDescriptor = fileHandle.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags != -1 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func readResponse(timeoutSeconds: TimeInterval) throws -> JSONRPCResponse {
        let line = try readLine(timeoutSeconds: timeoutSeconds)
        return try JSONDecoder().decode(JSONRPCResponse.self, from: line)
    }

    private func readLine(timeoutSeconds: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if let line = popLine() {
                return line
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }

            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                continue
            }

            if count == 0 {
                if let line = popLine() {
                    return line
                }
                throw TestFailure("stdout closed before a complete JSON-RPC line was available")
            }

            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw TestFailure("stdout read failed: errno \(errno)")
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        throw TestFailure("Timed out waiting for JSON-RPC response")
    }

    private func popLine() -> Data? {
        guard let range = buffer.range(of: Data([0x0A])) else {
            return nil
        }
        let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
    }
}

private func waitForFile(at path: String, timeoutSeconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw TestFailure("Timed out waiting for file at \(path)")
}

private func readPID(at url: URL) throws -> pid_t {
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw TestFailure("Invalid PID in \(url.path): \(text)")
    }
    return pid_t(value)
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func waitForProcessExit(_ process: Process, timeoutSeconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    if process.isRunning {
        process.terminate()
        throw TestFailure("Timed out waiting for process \(process.processIdentifier) to exit")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
