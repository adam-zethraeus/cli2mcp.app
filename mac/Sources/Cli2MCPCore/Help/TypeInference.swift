import Foundation

public enum TypeInference {
    public static func inferType(_ valueHint: String?) -> FlagSpec.ValueType {
        guard let valueHint, !valueHint.isEmpty else {
            return .boolean
        }

        let trimmed = valueHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else {
            return .string
        }

        let inner = String(trimmed.dropFirst().dropLast())
        if inner.contains("|") {
            return .choice(inner.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            })
        }

        let lower = inner.lowercased()
        if Self.numberHints.contains(lower) {
            return .number
        }
        if Self.stringHints.contains(lower) {
            return .string
        }
        return .string
    }
}

private extension TypeInference {
    static let stringHints: Set<String> = ["path", "file", "dir", "string", "name", "s"]
    static let numberHints: Set<String> = ["n", "num", "ms", "seconds", "count", "size"]
}
