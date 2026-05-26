import Foundation

struct NativeRuntime: Sendable {
    let serverExecutable: String
    let installLocation: String

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> NativeRuntime? {
        let fm = FileManager.default
        if let override = environment["CLI2MCP_SERVER_BIN"],
           fm.isExecutableFile(atPath: override) {
            return NativeRuntime(
                serverExecutable: override,
                installLocation: URL(fileURLWithPath: override).deletingLastPathComponent().path
            )
        }

        let appCandidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("cli2mcp-server")

        if fm.isExecutableFile(atPath: appCandidate.path) {
            return NativeRuntime(
                serverExecutable: appCandidate.path,
                installLocation: installLocationDescription(for: appCandidate)
            )
        }

        if let mainExecutable = Bundle.main.executableURL {
            let devCandidate = mainExecutable
                .deletingLastPathComponent()
                .appendingPathComponent("cli2mcp-server")
            if fm.isExecutableFile(atPath: devCandidate.path) {
                return NativeRuntime(
                    serverExecutable: devCandidate.path,
                    installLocation: devCandidate.deletingLastPathComponent().path
                )
            }
        }

        return nil
    }

    private static func installLocationDescription(for executableURL: URL) -> String {
        var url = executableURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url.path }
            url = url.deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent().path
    }
}
