import Foundation

public actor MCPServer {
    private static let serverName = "cli2mcp"
    private static let serverVersion = "0.1.0"
    private static let defaultProtocolVersion = "2025-11-25"
    private static let supportedProtocolVersions: Set<String> = ["2025-11-25", "2025-06-18"]

    private let options: ServerOptions
    private let shape: CLIShape
    private let inputSchema: JSONSchema
    private let tool: MCPTool
    private let childEnvironment: [String: String]
    private let registry: ChildRegistry
    private let runner: ChildProcessRunner
    private var inFlight = 0
    private var closing = false

    public static func start(
        options: ServerOptions,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        registry: ChildRegistry = ChildRegistry()
    ) async throws -> MCPServer {
        var parentEnvironment = parentEnvironment
        if options.inheritShellEnvironment {
            if let shellEnvironment = await captureShellEnvironment(
                registry: registry,
                environment: parentEnvironment
            ) {
                parentEnvironment = shellEnvironment
            } else {
                FileHandle.standardError.write(
                    Data("cli2mcp: --inherit-shell-env requested but the shell capture failed; falling back to launchd env.\n".utf8)
                )
            }
        }

        let overrides = EnvironmentBuilder.parseEnvPairs(options.env)
        let childEnvironment = EnvironmentBuilder.build(
            passthrough: options.envPassthrough,
            overrides: overrides,
            parent: parentEnvironment
        )

        let helpText = try await HelpCapture.captureHelp(
            command: options.command,
            timeoutMilliseconds: 5_000,
            cwd: options.cwd,
            environment: childEnvironment,
            registry: registry
        )
        let shape = HelpParser.extractShape(helpText)

        return MCPServer(
            options: options,
            shape: shape,
            childEnvironment: childEnvironment,
            registry: registry
        )
    }

    public init(
        options: ServerOptions,
        shape: CLIShape,
        childEnvironment: [String: String],
        registry: ChildRegistry = ChildRegistry()
    ) {
        self.options = options
        self.shape = shape
        self.inputSchema = InputSchemaBuilder.schema(for: shape)
        self.tool = MCPTool(
            name: options.name,
            description: options.description ?? shape.description,
            inputSchema: self.inputSchema
        )
        self.childEnvironment = childEnvironment
        self.registry = registry
        self.runner = ChildProcessRunner(registry: registry)
    }

    public func handle(_ message: JSONRPCIncomingMessage) async -> JSONRPCResponse? {
        switch message {
        case .request(let request):
            await handle(request)
        case .notification(let notification):
            await handle(notification)
        }
    }

    public func handle(_ notification: JSONRPCNotification) async -> JSONRPCResponse? {
        switch notification.method {
        case "notifications/initialized":
            return nil
        default:
            return nil
        }
    }

    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return success(id: request.id, result: initializeResult(for: request.params))
        case "tools/list":
            return success(id: request.id, result: MCPListToolsResult(tools: [tool]))
        case "tools/call":
            return await handleToolsCall(request)
        case "ping":
            return .success(id: request.id, result: .object([:]))
        default:
            return .failure(id: request.id, code: -32601, message: "Method not found")
        }
    }

    public func close() async {
        closing = true
        while inFlight > 0 {
            await registry.terminateAllGracefully()
            if inFlight > 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await registry.terminateAllGracefully()
    }
}

private extension MCPServer {
    func initializeResult(for params: JSONValue?) -> MCPInitializeResult {
        let requestedVersion = params?.objectValue?["protocolVersion"]?.stringValue
        let protocolVersion: String
        if let requestedVersion, Self.supportedProtocolVersions.contains(requestedVersion) {
            protocolVersion = requestedVersion
        } else {
            protocolVersion = Self.defaultProtocolVersion
        }

        return MCPInitializeResult(
            protocolVersion: protocolVersion,
            capabilities: MCPServerCapabilities(tools: [:]),
            serverInfo: MCPServerInfo(name: Self.serverName, version: Self.serverVersion)
        )
    }

    func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.objectValue,
              let toolName = params["name"]?.stringValue
        else {
            return .failure(id: request.id, code: -32602, message: "Invalid params")
        }

        if toolName != options.name {
            return success(id: request.id, result: toolError("Unknown tool: \(toolName)"))
        }

        if closing {
            return success(id: request.id, result: toolError("Server shutting down"))
        }

        if options.maxConcurrent > 0, inFlight >= options.maxConcurrent {
            return success(
                id: request.id,
                result: toolError("Concurrency limit reached (\(options.maxConcurrent) in flight). Retry shortly.")
            )
        }

        let rawInput: JSONValue
        if let arguments = params["arguments"], arguments != .null {
            rawInput = arguments
        } else {
            rawInput = .object([:])
        }
        let validation = InputValidator.validate(rawInput, against: inputSchema)
        guard validation.ok else {
            return success(
                id: request.id,
                result: toolError("Invalid arguments: \(InputValidator.formatValidationErrors(validation.errors))")
            )
        }

        guard let input = rawInput.objectValue else {
            return success(
                id: request.id,
                result: toolError("Invalid arguments: \(InputValidator.formatValidationErrors(validation.errors))")
            )
        }

        inFlight += 1
        defer {
            inFlight -= 1
        }

        if closing {
            return success(id: request.id, result: toolError("Server shutting down"))
        }

        let argv = ArgvBuilder.build(shape: shape, input: input)
        let stdin = input["stdin"]?.stringValue

        do {
            let result = try await runner.run(
                command: options.command,
                arguments: argv,
                options: ChildRunOptions(
                    timeoutMilliseconds: options.timeoutMilliseconds,
                    cwd: options.cwd,
                    environment: childEnvironment,
                    stdin: stdin
                )
            )
            return success(id: request.id, result: callResult(from: result))
        } catch ChildProcessRunnerError.spawnFailed(let command, let message) {
            return success(id: request.id, result: toolError(spawnFailureText(command: command, message: message)))
        } catch ChildProcessRunnerError.outputLimitExceeded(let stream, let limitBytes) {
            return success(
                id: request.id,
                result: toolError("Command output exceeded \(stream.rawValue) limit (\(limitBytes) bytes)")
            )
        } catch is CancellationError {
            return success(id: request.id, result: toolError("Command cancelled"))
        } catch {
            return success(id: request.id, result: toolError(spawnFailureText(command: options.command, message: error.localizedDescription)))
        }
    }

    func callResult(from result: ChildResult) -> MCPCallToolResult {
        if result.exitCode != 0 {
            return toolError(errorText(result: result, mode: options.stderrMode))
        }

        if options.stderrMode == .error, !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return toolError(stderrText(result.stderr))
        }

        let text: String
        if options.stderrMode == .include, !result.stderr.isEmpty {
            text = result.stdout.isEmpty ? result.stderr : "\(result.stdout)\n\(result.stderr)"
        } else {
            text = result.stdout
        }

        return MCPCallToolResult(content: [MCPTextContentBlock(text: text)])
    }

    func errorText(result: ChildResult, mode: ServerOptions.StderrMode) -> String {
        let head = "Command failed (exit \(result.exitCode))"
        if mode == .drop {
            return head
        }

        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = stderr.isEmpty ? stdout : stderr
        return tail.isEmpty ? head : "\(head): \(tail)"
    }

    func stderrText(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Command wrote to stderr" : "Command wrote to stderr: \(trimmed)"
    }

    func spawnFailureText(command: String, message: String) -> String {
        #"Failed to start command "\#(command)": \#(message)"#
    }

    func toolError(_ text: String) -> MCPCallToolResult {
        MCPCallToolResult(content: [MCPTextContentBlock(text: text)], isError: true)
    }

    func success<T: Encodable>(id: JSONRPCID, result: T) -> JSONRPCResponse {
        .success(id: id, result: try! JSONValue(encoding: result))
    }

    static func captureShellEnvironment(
        registry: ChildRegistry,
        environment: [String: String]
    ) async -> [String: String]? {
        let shell = environment["SHELL"] ?? "/bin/zsh"

        do {
            let result = try await ChildProcessRunner(registry: registry).run(
                command: shell,
                arguments: ["-l", "-i", "-c", "exec /usr/bin/env -0"],
                options: ChildRunOptions(
                    timeoutMilliseconds: ShellEnvironmentCapture.defaultTimeoutMilliseconds,
                    environment: environment
                )
            )

            guard result.exitCode == 0 else {
                return nil
            }

            return ShellEnvironmentCapture.parseEnvOutput(Data(result.stdout.utf8))
        } catch {
            return nil
        }
    }
}
