import Foundation

public enum CLIArgumentParser {
    public enum ParseError: Equatable, LocalizedError, Sendable {
        case helpRequested(String)
        case missingCommand
        case optionRequiresValue(String)
        case optionTakesNoValue(String)
        case invalidOptionValue(flag: String, value: String, reason: String)
        case unknownOption(String)
        case unexpectedArgument(String)

        public var errorDescription: String? {
            switch self {
            case .helpRequested(let helpText):
                helpText
            case .missingCommand:
                "missing required argument 'command'. Pass <command> or set CLI_COMMAND in the environment."
            case .optionRequiresValue(let flag):
                "option '\(flag)' requires a value"
            case .optionTakesNoValue(let flag):
                "option '\(flag)' takes no value"
            case .invalidOptionValue(let flag, let value, let reason):
                "option '\(flag) <value>' argument '\(value)' is invalid. \(reason)"
            case .unknownOption(let flag):
                "unknown option: \(flag)"
            case .unexpectedArgument(let argument):
                "unexpected argument: \(argument)"
            }
        }
    }

    public static let helpText = """
    cli2mcp <command> [options]

    Wrap any CLI as a Model Context Protocol stdio server.

    Options:
      --name <s>                 tool name exposed via MCP (default: <command>)
      --description <s>          tool description (default: first line of --help)
      --timeout <ms>             per-invocation timeout, positive integer (default: 60000)
      --cwd <path>               working directory for child (default: $PWD)
      --env <k=v>                additional env vars (repeatable)
      --env-passthrough <mode>   all | safe | none (default: safe)
      --inherit-shell-env        capture user's login shell env at startup and use
                                 it as the parent env for spawned children
      --stderr <mode>            include | drop | error (default: include)
      --max-concurrent <n>       cap on concurrent tool calls; 0 = unlimited (default: 0)
      -h, --help                 show this help
    """

    public static func parse(
        _ argv: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> ServerOptions {
        let args = Array(argv.dropFirst())
        var name: String?
        var description: String?
        var timeoutMilliseconds = 60_000
        var cwd = currentDirectory
        var env: [String] = []
        var envPassthrough = ServerOptions.EnvPassthrough.safe
        var inheritShellEnvironment = false
        var stderrMode = ServerOptions.StderrMode.include
        var maxConcurrent = 0
        var positionalCommand: String?

        var index = 0
        while index < args.count {
            let argument = args[index]

            if argument == "-h" || argument == "--help" {
                throw ParseError.helpRequested(helpText)
            }

            if argument.hasPrefix("--") {
                let option = parseLongOption(argument)
                let flag = "--\(option.name)"

                switch option.name {
                case "name":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    name = consumed.value
                    index = consumed.nextIndex
                case "description":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    description = consumed.value
                    index = consumed.nextIndex
                case "timeout":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    timeoutMilliseconds = try parsePositiveTimeout(consumed.value)
                    index = consumed.nextIndex
                case "cwd":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    cwd = consumed.value
                    index = consumed.nextIndex
                case "env":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    env.append(consumed.value)
                    index = consumed.nextIndex
                case "env-passthrough":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    envPassthrough = try parseEnvPassthroughMode(consumed.value)
                    index = consumed.nextIndex
                case "inherit-shell-env":
                    if option.inline != nil {
                        throw ParseError.optionTakesNoValue(flag)
                    }
                    inheritShellEnvironment = true
                case "stderr":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    stderrMode = try parseStderrMode(consumed.value)
                    index = consumed.nextIndex
                case "max-concurrent":
                    let consumed = try consumeValue(args: args, index: index, flag: flag, inline: option.inline)
                    maxConcurrent = try parseMaxConcurrent(consumed.value)
                    index = consumed.nextIndex
                default:
                    throw ParseError.unknownOption(flag)
                }

                index += 1
                continue
            }

            if argument.hasPrefix("-") {
                throw ParseError.unknownOption(argument)
            }

            if positionalCommand != nil {
                throw ParseError.unexpectedArgument(argument)
            }
            positionalCommand = argument
            index += 1
        }

        let resolvedCommand = try resolveCommand(positionalCommand, environment: environment)
        let inferredFromPositionalArgument = positionalCommand?.trimmedForCommand().isEmpty == false

        return ServerOptions(
            command: resolvedCommand,
            name: name ?? resolvedCommand,
            description: description ?? defaultDescription(
                for: resolvedCommand,
                inferredFromPositionalArgument: inferredFromPositionalArgument
            ),
            timeoutMilliseconds: timeoutMilliseconds,
            cwd: cwd,
            env: env,
            envPassthrough: envPassthrough,
            inheritShellEnvironment: inheritShellEnvironment,
            stderrMode: stderrMode,
            maxConcurrent: maxConcurrent
        )
    }
}

private extension CLIArgumentParser {
    struct LongOption {
        var name: String
        var inline: String?
    }

    struct ConsumedValue {
        var value: String
        var nextIndex: Int
    }

    static func parseLongOption(_ argument: String) -> LongOption {
        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return LongOption(name: String(argument.dropFirst(2)), inline: nil)
        }

        let name = argument[argument.index(argument.startIndex, offsetBy: 2)..<equalsIndex]
        let inline = argument[argument.index(after: equalsIndex)...]
        return LongOption(name: String(name), inline: String(inline))
    }

    static func consumeValue(
        args: [String],
        index: Int,
        flag: String,
        inline: String?
    ) throws -> ConsumedValue {
        if let inline {
            return ConsumedValue(value: inline, nextIndex: index)
        }

        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw ParseError.optionRequiresValue(flag)
        }

        return ConsumedValue(value: args[valueIndex], nextIndex: valueIndex)
    }

    static func resolveCommand(_ commandArgument: String?, environment: [String: String]) throws -> String {
        if let command = commandArgument?.trimmedForCommand(), !command.isEmpty {
            return command
        }

        for key in ["CLI_COMMAND", "CLI2MCP_COMMAND"] {
            if let command = environment[key]?.trimmedForCommand(), !command.isEmpty {
                return command
            }
        }

        throw ParseError.missingCommand
    }

    static func defaultDescription(
        for command: String,
        inferredFromPositionalArgument: Bool
    ) -> String? {
        guard !inferredFromPositionalArgument else {
            return nil
        }

        return "Execute \(command) as an MCP tool. Use this for command-line operations that map cleanly to flags and positional args. Output is returned as plain text and non-zero exits are surfaced as tool errors."
    }

    static func parsePositiveTimeout(_ raw: String) throws -> Int {
        guard let value = parseLenientInteger(raw), value > 0 else {
            throw ParseError.invalidOptionValue(
                flag: "--timeout",
                value: raw,
                reason: "must be a positive integer"
            )
        }

        return value
    }

    static func parseMaxConcurrent(_ raw: String) throws -> Int {
        guard let value = parseLenientInteger(raw), value >= 0 else {
            throw ParseError.invalidOptionValue(
                flag: "--max-concurrent",
                value: raw,
                reason: "must be a non-negative integer"
            )
        }

        return value
    }

    static func parseStderrMode(_ raw: String) throws -> ServerOptions.StderrMode {
        guard let mode = ServerOptions.StderrMode(rawValue: raw) else {
            throw ParseError.invalidOptionValue(
                flag: "--stderr",
                value: raw,
                reason: "must be one of: include, drop, error"
            )
        }

        return mode
    }

    static func parseEnvPassthroughMode(_ raw: String) throws -> ServerOptions.EnvPassthrough {
        guard let mode = ServerOptions.EnvPassthrough(rawValue: raw) else {
            throw ParseError.invalidOptionValue(
                flag: "--env-passthrough",
                value: raw,
                reason: "must be one of: all, safe, none"
            )
        }

        return mode
    }

    static func parseLenientInteger(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double

        if trimmed.isEmpty {
            value = 0
        } else if let parsed = Double(trimmed) {
            value = parsed
        } else {
            return nil
        }

        guard value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        guard value >= Double(Int.min), value <= Double(Int.max) else {
            return nil
        }

        return Int(value)
    }
}

private extension String {
    func trimmedForCommand() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
