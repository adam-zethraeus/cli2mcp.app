import Foundation

public enum ArgvBuilder {
    public static func build(shape: CLIShape, input: [String: JSONValue]) -> [String] {
        var argv: [String] = []

        for flag in shape.flags {
            guard let value = input[flag.long] else {
                continue
            }
            appendFlag(to: &argv, flag: flag, value: value)
        }

        if case .array(let positionals)? = input["args"], !positionals.isEmpty {
            argv.append("--")
            argv.append(contentsOf: positionals.map(\.argvString))
        }

        return argv
    }
}

private extension ArgvBuilder {
    static func appendFlag(to argv: inout [String], flag: FlagSpec, value: JSONValue) {
        if flag.repeatable, case .array(let values) = value {
            for value in values {
                if flag.type == .boolean {
                    if value == .bool(true) {
                        argv.append("--\(flag.long)")
                    }
                    continue
                }

                guard value != .null else {
                    continue
                }
                argv.append("--\(flag.long)")
                argv.append(value.argvString)
            }
            return
        }

        if flag.type == .boolean {
            if value == .bool(true) {
                argv.append("--\(flag.long)")
            }
            return
        }

        guard value != .null else {
            return
        }

        argv.append("--\(flag.long)")
        argv.append(value.argvString)
    }
}

private extension JSONValue {
    var argvString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite,
               value.rounded(.towardZero) == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return values.map(\.argvString).joined(separator: ",")
        case .object:
            return "[object Object]"
        case .null:
            return "null"
        }
    }
}
