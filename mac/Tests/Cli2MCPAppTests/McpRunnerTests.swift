import XCTest
@testable import Cli2MCPApp

@MainActor
final class McpRunnerTests: XCTestCase {
    func testStopTerminatesHealthyCustomServer() throws {
        let helper = try makeFakeServer()
        defer { try? FileManager.default.removeItem(at: helper) }
        let runner = McpRunner()
        let preset = CliPreset(
            id: "custom",
            displayName: "Custom",
            binary: "custom",
            summary: "Custom test server",
            serverArgs: [],
            tier: .red,
            origin: .user
        )

        defer { runner.stop() }

        for attempt in 1...10 {
            runner.start(
                preset: preset,
                runtime: NativeRuntime(serverExecutable: helper.path, installLocation: helper.deletingLastPathComponent().path),
                forwardEnvironment: false
            )

            do {
                try waitUntil("runner becomes healthy on attempt \(attempt)") {
                    if case .running(let toolName, _) = runner.status {
                        return toolName == "custom"
                    }
                    return false
                }
            } catch {
                XCTFail("Transcript before healthy timeout: \(runner.transcript.map(\.text))")
                throw error
            }

            runner.stop()

            try waitUntil("runner stops on attempt \(attempt)") {
                if case .stopped = runner.status {
                    return true
                }
                return false
            }

            XCTAssertFalse(runner.isRunning)
            XCTAssertTrue(runner.transcript.contains { $0.text.contains("Stopping") })
        }
    }

    private func makeFakeServer() throws -> URL {
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli2mcp-fake-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        trap 'i=0; while [ "$i" -lt 25 ]; do printf "terminating %s\\n" "$i" >&2; i=$((i + 1)); done; exit 143' TERM
        while IFS= read -r line; do
          printf 'received request\\n' >&2
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"0.0.0"}}}'
              ;;
            *tools*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"custom","inputSchema":{"type":"object","properties":{"args":{"type":"array"}}}}]}}'
              ;;
          esac
        done
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: helper.path
        )
        return helper
    }

    private func waitUntil(_ description: String, condition: @MainActor @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(description)")
        throw WaitError.timedOut(description)
    }

    private enum WaitError: Error {
        case timedOut(String)
    }
}
