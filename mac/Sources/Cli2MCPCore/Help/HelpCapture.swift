import Foundation

public struct NoHelpError: LocalizedError, Equatable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }

    public var errorDescription: String? {
        #"Failed to capture --help output for "\#(command)": command produced no output"#
    }
}

public enum HelpCapture {
    public static func captureHelp(
        command: String,
        arguments: [String] = ["--help"],
        timeoutMilliseconds: Int = 5_000,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: ChildRegistry = ChildRegistry()
    ) async throws -> String {
        let result = try await ChildProcessRunner(registry: registry).run(
            command: command,
            arguments: arguments,
            options: ChildRunOptions(
                timeoutMilliseconds: timeoutMilliseconds,
                cwd: cwd,
                environment: environment
            )
        )

        if result.exitCode != 0, result.stdout.isEmpty, result.stderr.isEmpty {
            throw NoHelpError(command: command)
        }

        return "\(result.stdout)\n\(result.stderr)"
    }
}
