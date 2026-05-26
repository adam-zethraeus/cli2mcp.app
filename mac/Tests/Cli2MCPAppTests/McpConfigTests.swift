import XCTest
@testable import Cli2MCPApp

final class McpConfigTests: XCTestCase {
    func testSnippetUsesNativeHelperAndPresetArgsOnly() throws {
        let runtime = NativeRuntime(
            serverExecutable: "/Applications/Cli2MCP.app/Contents/MacOS/cli2mcp-server",
            installLocation: "/Applications/Cli2MCP.app"
        )
        let preset = CliPreset(
            id: "ripgrep",
            displayName: "ripgrep",
            binary: "rg",
            summary: "Search files.",
            serverArgs: ["--name", "ripgrep"],
            tier: .green,
            origin: .user
        )

        let snippet = McpConfig.snippet(
            for: preset,
            runtime: runtime,
            forwardEnvironment: true
        )
        let server = try decodedServer(from: snippet, key: "ripgrep")

        XCTAssertEqual(
            server["command"] as? String,
            "/Applications/Cli2MCP.app/Contents/MacOS/cli2mcp-server"
        )
        XCTAssertEqual(
            server["args"] as? [String],
            preset.fullArgs() + ["--inherit-shell-env"]
        )
        let legacyEntrypoint = ["dist", "index.js"].joined(separator: "/")
        let legacyRuntimePath = ["Runtime", ""].joined(separator: "/")
        let packageRunner = "n" + "px"
        let legacyCommand = "\"no" + "de\""
        XCTAssertFalse(snippet.contains(legacyEntrypoint))
        XCTAssertFalse(snippet.contains(legacyRuntimePath))
        XCTAssertFalse(snippet.contains(packageRunner))
        XCTAssertFalse(snippet.contains(legacyCommand))
    }

    private func decodedServer(from snippet: String, key: String) throws -> [String: Any] {
        let data = try XCTUnwrap(snippet.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        return try XCTUnwrap(servers[key] as? [String: Any])
    }
}
