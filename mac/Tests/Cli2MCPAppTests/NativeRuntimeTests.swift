import XCTest
@testable import Cli2MCPApp

final class NativeRuntimeTests: XCTestCase {
    func testEnvironmentOverrideWinsWhenExecutableExists() throws {
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli2mcp-server-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: helper.path
        )

        let runtime = try XCTUnwrap(
            NativeRuntime.resolve(environment: ["CLI2MCP_SERVER_BIN": helper.path])
        )

        XCTAssertEqual(runtime.serverExecutable, helper.path)
        XCTAssertEqual(runtime.installLocation, helper.deletingLastPathComponent().path)
    }
}
