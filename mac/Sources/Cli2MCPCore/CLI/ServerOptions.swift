import Foundation

public struct ServerOptions: Equatable, Sendable {
    public enum StderrMode: String, Equatable, Sendable {
        case include
        case drop
        case error
    }

    public enum EnvPassthrough: String, Equatable, Sendable {
        case all
        case safe
        case none
    }

    public var command: String
    public var name: String
    public var description: String?
    public var timeoutMilliseconds: Int
    public var cwd: String
    public var env: [String]
    public var envPassthrough: EnvPassthrough
    public var inheritShellEnvironment: Bool
    public var stderrMode: StderrMode
    public var maxConcurrent: Int

    public init(
        command: String,
        name: String,
        description: String? = nil,
        timeoutMilliseconds: Int = 60_000,
        cwd: String,
        env: [String] = [],
        envPassthrough: EnvPassthrough = .safe,
        inheritShellEnvironment: Bool = false,
        stderrMode: StderrMode = .include,
        maxConcurrent: Int = 0
    ) {
        self.command = command
        self.name = name
        self.description = description
        self.timeoutMilliseconds = timeoutMilliseconds
        self.cwd = cwd
        self.env = env
        self.envPassthrough = envPassthrough
        self.inheritShellEnvironment = inheritShellEnvironment
        self.stderrMode = stderrMode
        self.maxConcurrent = maxConcurrent
    }
}
