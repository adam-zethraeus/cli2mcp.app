import Foundation
import XCTest
@testable import Cli2MCPCore

final class MCPServerTests: XCTestCase {
    func testInitializeReturnsProtocolCapabilitiesAndServerInfo() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(1),
                method: "initialize",
                params: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("test"), "version": .string("0.0.0")])
                ])
            )
        )

        let result = try decodeResult(MCPInitializeResult.self, from: response)
        XCTAssertEqual(result.protocolVersion, "2025-06-18")
        XCTAssertNotNil(result.capabilities.tools)
        XCTAssertEqual(result.serverInfo.name, "cli2mcp")
    }

    func testToolsListReturnsOneToolBuiltFromHelpShapeAndOptions() async throws {
        let server = try await makeServer(
            options: { script in
                ServerOptions(
                    command: script.path,
                    name: "fixture",
                    description: "custom description",
                    timeoutMilliseconds: 2_000,
                    cwd: FileManager.default.temporaryDirectory.path,
                    envPassthrough: .all
                )
            }
        )

        let response = await server.handle(JSONRPCRequest(id: .string("list"), method: "tools/list"))

        let result = try decodeResult(MCPListToolsResult.self, from: response)
        XCTAssertEqual(result.tools.count, 1)
        let tool = try XCTUnwrap(result.tools.first)
        XCTAssertEqual(tool.name, "fixture")
        XCTAssertEqual(tool.description, "custom description")
        XCTAssertEqual(tool.inputSchema.type, "object")
        XCTAssertNotNil(tool.inputSchema.properties["upper"])
        XCTAssertNotNil(tool.inputSchema.properties["prefix"])
        XCTAssertNotNil(tool.inputSchema.properties["args"])
        XCTAssertNotNil(tool.inputSchema.properties["stdin"])
    }

    func testToolsCallValidatesBuildsArgvAndReturnsStdoutText() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(2),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object([
                        "upper": .bool(true),
                        "prefix": .string(">> "),
                        "args": .array([.string("hello"), .string("world")])
                    ])
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(result.content, [MCPTextContentBlock(type: "text", text: ">> HELLO WORLD")])
    }

    func testToolsCallPipesOptionalStdin() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(3),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["stdin": .string("{\"hello\":\"world\"}")])
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertEqual(result.content, [MCPTextContentBlock(type: "text", text: "{\"hello\":\"world\"}")])
    }

    func testToolsCallTreatsNullArgumentsAsEmptyObject() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(31),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .null
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(result.content, [MCPTextContentBlock(type: "text", text: "")])
    }

    func testUnknownToolNameReturnsToolError() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(4),
                method: "tools/call",
                params: .object(["name": .string("missing"), "arguments": .object([:])])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.content.first?.text, "Unknown tool: missing")
    }

    func testInvalidArgumentKeyReturnsValidationToolError() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(5),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["unexpected": .string("value")])
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(result.content.first?.text.hasPrefix("Invalid arguments: ") == true)
        XCTAssertTrue(result.content.first?.text.contains("must NOT have additional properties") == true)
    }

    func testNonZeroChildExitReturnsCommandFailedToolError() async throws {
        let server = try await makeServer()

        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(6),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object(["fail": .bool(true)])
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.content.first?.text, "Command failed (exit 42): boom")
    }

    func testStderrDropIncludeAndErrorModesMatchExpectedBehavior() async throws {
        let include = try await makeServer(stderrMode: .include)
        let includeResult = try await callWarn(include)
        XCTAssertEqual(includeResult.isError, nil)
        XCTAssertEqual(includeResult.content.first?.text, "ok\nwarning")

        let drop = try await makeServer(stderrMode: .drop)
        let dropResult = try await callWarn(drop)
        XCTAssertEqual(dropResult.isError, nil)
        XCTAssertEqual(dropResult.content.first?.text, "ok")

        let error = try await makeServer(stderrMode: .error)
        let errorResult = try await callWarn(error)
        XCTAssertEqual(errorResult.isError, true)
        XCTAssertEqual(errorResult.content.first?.text, "Command wrote to stderr: warning")
    }

    func testConcurrencyCapReturnsFailFastToolError() async throws {
        let marker = temporaryURL().path
        let server = try await makeServer(
            options: { script in
                ServerOptions(
                    command: script.path,
                    name: "fixture",
                    timeoutMilliseconds: 10_000,
                    cwd: FileManager.default.temporaryDirectory.path,
                    env: ["CLI2MCP_TEST_MARKER=\(marker)"],
                    envPassthrough: .all,
                    maxConcurrent: 1
                )
            }
        )

        let first = Task {
            await server.handle(
                JSONRPCRequest(
                    id: .integer(7),
                    method: "tools/call",
                    params: .object([
                        "name": .string("fixture"),
                        "arguments": .object(["hold": .bool(true)])
                    ])
                )
            )
        }
        try await waitForFile(at: marker, timeoutSeconds: 2)

        let second = await server.handle(
            JSONRPCRequest(
                id: .integer(8),
                method: "tools/call",
                params: .object(["name": .string("fixture"), "arguments": .object([:])])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: second)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(
            result.content.first?.text,
            "Concurrency limit reached (1 in flight). Retry shortly."
        )

        await server.close()
        _ = await first.value
    }

    func testUnknownMethodReturnsJSONRPCMethodNotFound() async throws {
        let server = try await makeServer()

        let response = await server.handle(JSONRPCRequest(id: .integer(9), method: "missing/method"))

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(response.error?.message, "Method not found")
    }

    func testNotificationInitializedDoesNotReturnResponse() async throws {
        let server = try await makeServer()

        let response = await server.handle(JSONRPCNotification(method: "notifications/initialized"))

        XCTAssertNil(response)
    }

    func testPingReturnsEmptyResult() async throws {
        let server = try await makeServer()

        let response = await server.handle(JSONRPCRequest(id: .integer(10), method: "ping"))

        XCTAssertEqual(response.result, .object([:]))
        XCTAssertNil(response.error)
    }

    func testToolsCallAfterCloseReturnsShutdownToolError() async throws {
        let server = try await makeServer()

        await server.close()
        let response = await server.handle(
            JSONRPCRequest(
                id: .integer(34),
                method: "tools/call",
                params: .object([
                    "name": .string("fixture"),
                    "arguments": .object([:])
                ])
            )
        )

        let result = try decodeResult(MCPCallToolResult.self, from: response)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.content.first?.text, "Server shutting down")
    }

    func testHelpCaptureReturnsStdoutNewlineStderr() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf 'out'
            printf 'err' >&2
            exit 0
            """
        )

        let help = try await HelpCapture.captureHelp(command: script.path)

        XCTAssertEqual(help, "out\nerr")
    }

    func testHelpCaptureUsesProvidedEnvironmentPathForBareCommand() async throws {
        let binDirectory = try makeTemporaryDirectory()
        try makeExecutableScript(
            named: "path-help-tool",
            in: binDirectory,
            """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
              printf 'path tool - found through PATH'
              exit 0
            fi
            """
        )

        let help = try await HelpCapture.captureHelp(
            command: "path-help-tool",
            environment: ["PATH": binDirectory.path]
        )

        XCTAssertEqual(help, "path tool - found through PATH\n")
    }

    func testMCPServerStartAppliesEnvOverridesBeforeCapturingHelp() async throws {
        let binDirectory = try makeTemporaryDirectory()
        try makeExecutableScript(
            named: "env-help-tool",
            in: binDirectory,
            """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
              printf '%s\\n' 'env tool - help from overridden PATH'
              printf '%s\\n' ''
              printf '%s\\n' 'Usage: env-tool [options]'
              printf '%s\\n' ''
              printf '%s\\n' 'Options:'
              printf '%s\\n' '  --from-env     env flag'
              exit 0
            fi
            """
        )

        let server = try await MCPServer.start(
            options: ServerOptions(
                command: "env-help-tool",
                name: "env-help-tool",
                timeoutMilliseconds: 2_000,
                cwd: FileManager.default.temporaryDirectory.path,
                env: ["PATH=\(binDirectory.path)"],
                envPassthrough: .none
            ),
            parentEnvironment: [:]
        )

        let response = await server.handle(JSONRPCRequest(id: .integer(32), method: "tools/list"))
        let result = try decodeResult(MCPListToolsResult.self, from: response)
        XCTAssertNotNil(result.tools.first?.inputSchema.properties["from-env"])
    }

    func testMCPServerStartAppliesWorkingDirectoryBeforeCapturingRelativeHelp() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        try makeExecutableScript(
            named: "relative-help-tool",
            in: workingDirectory,
            """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
              cat <<'EOF'
            relative tool - help from cwd

            Usage: relative-tool [options]

            Options:
              --from-cwd     cwd flag
            EOF
              exit 0
            fi
            """
        )

        let server = try await MCPServer.start(
            options: ServerOptions(
                command: "./relative-help-tool",
                name: "relative-help-tool",
                timeoutMilliseconds: 2_000,
                cwd: workingDirectory.path,
                envPassthrough: .none
            ),
            parentEnvironment: [:]
        )

        let response = await server.handle(JSONRPCRequest(id: .integer(33), method: "tools/list"))
        let result = try decodeResult(MCPListToolsResult.self, from: response)
        XCTAssertNotNil(result.tools.first?.inputSchema.properties["from-cwd"])
    }

    func testHelpCaptureRegistersStartupChildInProvidedRegistry() async throws {
        let registry = ChildRegistry()
        let marker = temporaryURL().path
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
              printf 'started' > "$2"
              while :; do sleep 1; done
            fi
            """
        )

        let task = Task {
            try await HelpCapture.captureHelp(
                command: script.path,
                arguments: ["--help", marker],
                timeoutMilliseconds: 10_000,
                registry: registry
            )
        }

        try await waitForFile(at: marker, timeoutSeconds: 2)
        await registry.terminateAll()

        do {
            _ = try await task.value
            XCTFail("Expected help capture to fail after registry termination")
        } catch let error as NoHelpError {
            XCTAssertEqual(error.command, script.path)
        } catch {
            XCTFail("Expected NoHelpError, got \(error)")
        }
    }

    func testHelpCaptureThrowsNoHelpErrorForNonZeroNoOutput() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            exit 7
            """
        )

        do {
            _ = try await HelpCapture.captureHelp(command: script.path)
            XCTFail("Expected NoHelpError")
        } catch let error as NoHelpError {
            XCTAssertEqual(error.command, script.path)
        } catch {
            XCTFail("Expected NoHelpError, got \(error)")
        }
    }
}

private func makeServer(
    stderrMode: ServerOptions.StderrMode = .include,
    options: (URL) -> ServerOptions = { script in
        ServerOptions(
            command: script.path,
            name: "fixture",
            timeoutMilliseconds: 2_000,
            cwd: FileManager.default.temporaryDirectory.path,
            envPassthrough: .all,
            stderrMode: .include
        )
    }
) async throws -> MCPServer {
    let script = try makeFixtureScript()
    var serverOptions = options(script)
    serverOptions.stderrMode = stderrMode
    return try await MCPServer.start(options: serverOptions)
}

private func callWarn(_ server: MCPServer) async throws -> MCPCallToolResult {
    let response = await server.handle(
        JSONRPCRequest(
            id: .integer(100),
            method: "tools/call",
            params: .object([
                "name": .string("fixture"),
                "arguments": .object(["warn": .bool(true)])
            ])
        )
    )
    return try decodeResult(MCPCallToolResult.self, from: response)
}

private func decodeResult<T: Decodable>(_ type: T.Type, from response: JSONRPCResponse) throws -> T {
    XCTAssertNil(response.error)
    let result = try XCTUnwrap(response.result)
    return try result.decoded(as: type)
}

private func makeFixtureScript() throws -> URL {
    try makeExecutableScript(
        """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          cat <<'EOF'
        fixture - test cli

        Usage: fixture [options] <args...>

        Options:
          --upper              uppercase output
          --prefix <string>    prefix string
          --fail               exit with an error
          --warn               write a warning to stderr
          --hold               stay running until terminated
        EOF
          exit 0
        fi

        prefix=""
        upper=0
        fail=0
        warn=0
        hold=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --upper) upper=1 ;;
            --prefix) shift; prefix="$1" ;;
            --fail) fail=1 ;;
            --warn) warn=1 ;;
            --hold) hold=1 ;;
            --) shift; break ;;
            *) break ;;
          esac
          shift
        done

        if [ "$hold" = "1" ]; then
          printf 'started' > "$CLI2MCP_TEST_MARKER"
          while :; do sleep 1; done
        fi

        if [ "$fail" = "1" ]; then
          echo "boom" >&2
          exit 42
        fi

        if [ "$warn" = "1" ]; then
          printf 'ok'
          printf 'warning' >&2
          exit 0
        fi

        if [ -n "$CLI2MCP_READ_STDIN" ] || [ "$#" -eq 0 ]; then
          cat
          exit 0
        fi

        text="$prefix$*"
        if [ "$upper" = "1" ]; then
          printf '%s' "$text" | tr '[:lower:]' '[:upper:]'
        else
          printf '%s' "$text"
        fi
        """
    )
}

private func makeExecutableScript(_ body: String) throws -> URL {
    let url = temporaryURL()
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
    let url = temporaryURL()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryURL() -> URL {
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
