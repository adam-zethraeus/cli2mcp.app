import XCTest
@testable import Cli2MCPCore

final class CLIArgumentParserTests: XCTestCase {
    func testParsesPositionalCommand() throws {
        let options = try CLIArgumentParser.parse(["cli2mcp-server", "jq"], environment: [:], currentDirectory: "/tmp")

        XCTAssertEqual(options.command, "jq")
    }

    func testDefaults() throws {
        let options = try CLIArgumentParser.parse(["cli2mcp-server", "jq"], environment: [:], currentDirectory: "/tmp")

        XCTAssertEqual(options.name, "jq")
        XCTAssertNil(options.description)
        XCTAssertEqual(options.timeoutMilliseconds, 60_000)
        XCTAssertEqual(options.cwd, "/tmp")
        XCTAssertEqual(options.stderrMode, .include)
        XCTAssertEqual(options.env, [])
        XCTAssertEqual(options.envPassthrough, .safe)
        XCTAssertFalse(options.inheritShellEnvironment)
        XCTAssertEqual(options.maxConcurrent, 0)
    }

    func testFlagsAndInlineValues() throws {
        let options = try CLIArgumentParser.parse([
            "cli2mcp-server", "jq",
            "--name=json-query",
            "--description", "JSON processor",
            "--timeout", "30000",
            "--cwd", "/work",
            "--env", "FOO=bar",
            "--env=BAZ=qux",
            "--env-passthrough", "none",
            "--stderr=drop",
            "--max-concurrent", "4",
            "--inherit-shell-env"
        ], environment: [:], currentDirectory: "/tmp")

        XCTAssertEqual(options.name, "json-query")
        XCTAssertEqual(options.description, "JSON processor")
        XCTAssertEqual(options.timeoutMilliseconds, 30_000)
        XCTAssertEqual(options.cwd, "/work")
        XCTAssertEqual(options.env, ["FOO=bar", "BAZ=qux"])
        XCTAssertEqual(options.envPassthrough, .none)
        XCTAssertEqual(options.stderrMode, .drop)
        XCTAssertEqual(options.maxConcurrent, 4)
        XCTAssertTrue(options.inheritShellEnvironment)
    }

    func testAcceptsAllStderrModes() throws {
        let modes: [(rawValue: String, mode: ServerOptions.StderrMode)] = [
            ("include", .include),
            ("drop", .drop),
            ("error", .error)
        ]

        for (rawValue, mode) in modes {
            let options = try CLIArgumentParser.parse(
                ["cli2mcp-server", "jq", "--stderr", rawValue],
                environment: [:],
                currentDirectory: "/tmp"
            )

            XCTAssertEqual(options.stderrMode, mode)
        }
    }

    func testAcceptsAllEnvPassthroughModes() throws {
        let modes: [(rawValue: String, mode: ServerOptions.EnvPassthrough)] = [
            ("all", .all),
            ("safe", .safe),
            ("none", .none)
        ]

        for (rawValue, mode) in modes {
            let options = try CLIArgumentParser.parse(
                ["cli2mcp-server", "jq", "--env-passthrough", rawValue],
                environment: [:],
                currentDirectory: "/tmp"
            )

            XCTAssertEqual(options.envPassthrough, mode)
        }
    }

    func testCommandEnvironmentFallbacks() throws {
        let cliCommandOptions = try CLIArgumentParser.parse(
            ["cli2mcp-server"],
            environment: ["CLI_COMMAND": " rg "],
            currentDirectory: "/tmp"
        )
        XCTAssertEqual(cliCommandOptions.command, "rg")
        XCTAssertEqual(cliCommandOptions.name, "rg")
        XCTAssertEqual(
            cliCommandOptions.description,
            "Execute rg as an MCP tool. Use this for command-line operations that map cleanly to flags and positional args. Output is returned as plain text and non-zero exits are surfaced as tool errors."
        )

        XCTAssertEqual(
            try CLIArgumentParser.parse(
                ["cli2mcp-server"],
                environment: ["CLI2MCP_COMMAND": "curl"],
                currentDirectory: "/tmp"
            ).command,
            "curl"
        )
    }

    func testPositionalCommandTakesPrecedenceOverEnvironmentFallback() throws {
        let options = try CLIArgumentParser.parse(
            ["cli2mcp-server", "jq"],
            environment: ["CLI_COMMAND": "rg", "CLI2MCP_COMMAND": "curl"],
            currentDirectory: "/tmp"
        )

        XCTAssertEqual(options.command, "jq")
    }

    func testRejectsInvalidValues() {
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--timeout", "0"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--timeout", "-1"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--timeout", "1.5"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--timeout", "Infinity"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--timeout", "nope"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--stderr", "garbage"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--env-passthrough", "garbage"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--max-concurrent", "-1"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--max-concurrent", "1.5"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--max-concurrent", "nope"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--inherit-shell-env=true"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server"], environment: [:], currentDirectory: "/tmp"))
    }

    func testRejectsUnknownOptionsAndUnexpectedArguments() {
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--unknown"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "-x"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "rg"], environment: [:], currentDirectory: "/tmp"))
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "jq", "--name"], environment: [:], currentDirectory: "/tmp"))
    }

    func testHelpFlagsRequestHelp() {
        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "--help"], environment: [:], currentDirectory: "/tmp")) { error in
            guard case CLIArgumentParser.ParseError.helpRequested(let helpText) = error else {
                return XCTFail("Expected helpRequested, got \(error)")
            }

            XCTAssertTrue(helpText.contains("cli2mcp <command> [options]"))
        }

        XCTAssertThrowsError(try CLIArgumentParser.parse(["cli2mcp-server", "-h"], environment: [:], currentDirectory: "/tmp")) { error in
            guard case CLIArgumentParser.ParseError.helpRequested = error else {
                return XCTFail("Expected helpRequested, got \(error)")
            }
        }
    }
}
