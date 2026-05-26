import Foundation

public struct FlagSpec: Equatable, Sendable {
    public enum ValueType: Equatable, Sendable {
        case boolean
        case string
        case number
        case choice([String])
    }

    public var long: String
    public var short: String?
    public var type: ValueType
    public var description: String
    public var repeatable: Bool

    public init(
        long: String,
        short: String? = nil,
        type: ValueType,
        description: String,
        repeatable: Bool
    ) {
        self.long = long
        self.short = short
        self.type = type
        self.description = description
        self.repeatable = repeatable
    }
}

public struct PositionalSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    public var variadic: Bool

    public init(name: String, description: String, variadic: Bool) {
        self.name = name
        self.description = description
        self.variadic = variadic
    }
}

public struct CLIShape: Equatable, Sendable {
    public var description: String
    public var flags: [FlagSpec]
    public var positionals: [PositionalSpec]

    public init(description: String, flags: [FlagSpec], positionals: [PositionalSpec]) {
        self.description = description
        self.flags = flags
        self.positionals = positionals
    }
}

public enum HelpParser {
    public static func extractShape(_ helpText: String) -> CLIShape {
        let text = helpText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CLIShape(description: "", flags: [], positionals: [Self.fallbackPositional])
        }

        let lines = text.components(separatedBy: "\n")
        let description = extractDescription(lines)
        let flags = extractFlags(lines)
        let positionals = extractPositionals(lines)

        return CLIShape(
            description: description,
            flags: flags,
            positionals: positionals.isEmpty ? [Self.fallbackPositional] : positionals
        )
    }
}

private extension HelpParser {
    static let fallbackPositional = PositionalSpec(name: "args", description: "", variadic: true)

    static func extractDescription(_ lines: [String]) -> String {
        for raw in lines {
            let trimmed = raw.cli2mcpTrimmed
            if trimmed.isEmpty {
                continue
            }
            if trimmed.matches(#"^(usage|synopsis|example|examples|options?|commands?|arguments?):"#, caseInsensitive: true) {
                continue
            }
            if trimmed.matches(#"^[A-Z][A-Z\s]+:$"#) {
                continue
            }
            if let nameDash = trimmed.firstCapture(#"^[\w.-]+\s+-+\s+(.+)$"#) {
                return nameDash.cli2mcpTrimmed
            }
            if let first = trimmed.first, first == "-" || first == "<" || first == "[" {
                continue
            }
            if trimmed.matches(#"^\S+\s+v?\d+\.\d+"#) {
                continue
            }
            if trimmed.matches(#"\S+@\S+"#) {
                continue
            }

            return trimmed
        }

        return ""
    }

    static func extractFlags(_ lines: [String]) -> [FlagSpec] {
        var flags: [FlagSpec] = []
        var seen: Set<String> = []

        for (index, line) in lines.enumerated() {
            guard let match = matchFlagLine(line), !seen.contains(match.long) else {
                continue
            }

            let indent = line.leadingWhitespaceCount
            let split = splitTail(match.tail)
            let description = split.sameLineDescription.isEmpty
                ? takeContinuation(lines: lines, flagLineIndex: index, flagIndent: indent)
                : split.sameLineDescription
            let repeatable = description.matches(
                #"multiple times|may be (?:given|specified|used|provided|repeated)|can be (?:given|specified|used|provided|repeated)|repeatable"#,
                caseInsensitive: true
            ) || split.valueSpec.matches(#"\.{3,}"#)
            let hint = split.valueSpec.firstCapture(#"(<[^>]+>)"#) ?? (split.valueSpec.isEmpty ? nil : split.valueSpec)

            flags.append(
                FlagSpec(
                    long: match.long,
                    short: match.short,
                    type: TypeInference.inferType(hint),
                    description: description.cli2mcpTrimmed,
                    repeatable: repeatable
                )
            )
            seen.insert(match.long)
        }

        return flags
    }

    static func matchFlagLine(_ line: String) -> (short: String?, long: String, tail: String)? {
        let pattern = #"^\s*(?:-([A-Za-z0-9])(?:\s+[A-Z][A-Z0-9_]*|\s+<[^>]+>)?,\s+)?--([a-zA-Z][\w-]*)([=\s].*)?$"#
        let nsLine = line as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
              match.range(at: 2).location != NSNotFound
        else {
            return nil
        }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else {
                return nil
            }
            return nsLine.substring(with: range)
        }

        return (short: group(1), long: group(2) ?? "", tail: group(3) ?? "")
    }

    static func splitTail(_ tail: String) -> (valueSpec: String, sameLineDescription: String) {
        guard !tail.isEmpty else {
            return ("", "")
        }

        if tail.hasPrefix("=") {
            let parts = splitOnceOnTwoOrMoreWhitespace(String(tail.dropFirst()))
            return (
                valueSpec: "=\(parts.first ?? "")".cli2mcpTrimmed,
                sameLineDescription: (parts.dropFirst().first ?? "").cli2mcpTrimmed
            )
        }

        let parts = splitOnceOnTwoOrMoreWhitespace(tail)
        return (
            valueSpec: (parts.first ?? "").cli2mcpTrimmed,
            sameLineDescription: (parts.dropFirst().first ?? "").cli2mcpTrimmed
        )
    }

    static func splitOnceOnTwoOrMoreWhitespace(_ text: String) -> [String] {
        guard let firstRange = text.range(of: #"\s{2,}"#, options: .regularExpression) else {
            return [text]
        }

        let remainder = text[firstRange.upperBound...]
        let secondRange = remainder.range(of: #"\s{2,}"#, options: .regularExpression)
        let secondPart = secondRange.map { String(remainder[..<$0.lowerBound]) } ?? String(remainder)

        return [
            String(text[..<firstRange.lowerBound]),
            secondPart
        ]
    }

    static func takeContinuation(lines: [String], flagLineIndex: Int, flagIndent: Int) -> String {
        let nextIndex = flagLineIndex + 1
        guard nextIndex < lines.count else {
            return ""
        }

        let next = lines[nextIndex]
        guard !next.cli2mcpTrimmed.isEmpty else {
            return ""
        }

        guard next.leadingWhitespaceCount > flagIndent else {
            return ""
        }

        return next.cli2mcpTrimmed
    }

    static func extractPositionals(_ lines: [String]) -> [PositionalSpec] {
        var positionals: [PositionalSpec] = []
        var seen: Set<String> = []

        for raw in lines {
            let trimmed = raw.cli2mcpTrimmed
            guard let usage = trimmed.firstCapture(#"^(?:usage|synopsis):\s*(.+)$"#, caseInsensitive: true) else {
                continue
            }

            for inner in usage.positionalsFromUsageTokens() {
                let cleaned = inner.cli2mcpTrimmed
                guard !cleaned.isEmpty else {
                    continue
                }

                let variadic = cleaned.matches(#"\.{3,}"#)
                let nameRaw = cleaned
                    .replacingOccurrences(of: #"\.{3,}"#, with: "", options: .regularExpression)
                    .cli2mcpTrimmed
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first ?? ""

                guard !nameRaw.isEmpty,
                      !nameRaw.matches(#"^options?$"#, caseInsensitive: true),
                      nameRaw.matches(#"^[\w-]+$"#),
                      !seen.contains(nameRaw)
                else {
                    continue
                }

                seen.insert(nameRaw)
                positionals.append(PositionalSpec(name: nameRaw, description: "", variadic: variadic))
            }

            return positionals
        }

        return positionals
    }
}

private extension String {
    var cli2mcpTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var leadingWhitespaceCount: Int {
        prefix { $0.isWhitespace }.count
    }

    func matches(_ pattern: String, caseInsensitive: Bool = false) -> Bool {
        var options: String.CompareOptions = [.regularExpression]
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return range(of: pattern, options: options) != nil
    }

    func firstCapture(_ pattern: String, caseInsensitive: Bool = false) -> String? {
        let nsString = self as NSString
        var options: NSRegularExpression.Options = []
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound
        else {
            return nil
        }

        return nsString.substring(with: match.range(at: 1))
    }

    func positionalsFromUsageTokens() -> [String] {
        let nsString = self as NSString
        let pattern = #"<([^>]+)>|\[([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return regex.matches(in: self, range: NSRange(location: 0, length: nsString.length)).compactMap { match in
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                if range.location != NSNotFound {
                    return nsString.substring(with: range).cli2mcpTrimmed
                }
            }
            return nil
        }
    }
}
