import XCTest
@testable import Cli2MCPApp

final class CliPresetCodableTests: XCTestCase {
    func testDecodesServerArgsAndBuildsFullArgs() throws {
        let data = Data("""
        {
          "id": "ripgrep",
          "displayName": "ripgrep",
          "binary": "rg",
          "summary": "Search files.",
          "serverArgs": ["--name", "ripgrep"],
          "tier": "green",
          "origin": "user"
        }
        """.utf8)

        let preset = try JSONDecoder().decode(CliPreset.self, from: data)

        XCTAssertEqual(preset.serverArgs, ["--name", "ripgrep"])
        XCTAssertEqual(
            preset.fullArgs(),
            ["rg"] + CliPreset.baseArgs + ["--name", "ripgrep"]
        )
    }

    func testDecodesLegacyCli2MCPArgs() throws {
        let data = Data("""
        {
          "id": "jq",
          "displayName": "jq",
          "binary": "jq",
          "summary": "Query JSON.",
          "cli2mcpArgs": ["--stderr", "drop"],
          "tier": "green",
          "origin": "user"
        }
        """.utf8)

        let preset = try JSONDecoder().decode(CliPreset.self, from: data)

        XCTAssertEqual(preset.serverArgs, ["--stderr", "drop"])
    }

    func testEncodesServerArgsKeyOnly() throws {
        let preset = CliPreset(
            id: "jq",
            displayName: "jq",
            binary: "jq",
            summary: "Query JSON.",
            serverArgs: ["--stderr", "drop"],
            tier: .green,
            origin: .user
        )

        let data = try JSONEncoder().encode(preset)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["serverArgs"] as? [String], ["--stderr", "drop"])
        XCTAssertNil(object["cli2mcpArgs"])
    }
}
