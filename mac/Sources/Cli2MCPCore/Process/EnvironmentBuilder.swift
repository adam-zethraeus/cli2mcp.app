import Foundation

public enum EnvironmentBuilder {
    public static func parseEnvPairs(_ pairs: [String]) -> [String: String] {
        var env: [String: String] = [:]

        for pair in pairs {
            guard let equalsIndex = pair.firstIndex(of: "="),
                  equalsIndex > pair.startIndex else {
                continue
            }

            let key = String(pair[..<equalsIndex])
            let valueStart = pair.index(after: equalsIndex)
            env[key] = String(pair[valueStart...])
        }

        return env
    }

    public static func build(
        passthrough: ServerOptions.EnvPassthrough,
        overrides: [String: String],
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        switch passthrough {
        case .all:
            return parent.merging(overrides) { _, override in override }
        case .none:
            return overrides
        case .safe:
            var env: [String: String] = [:]
            for (key, value) in parent where safeKeys.contains(key) || key.hasPrefix("LC_") {
                env[key] = value
            }
            return env.merging(overrides) { _, override in override }
        }
    }
}

private let safeKeys: Set<String> = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TERM",
    "TZ",
    "LANG",
    "LANGUAGE",
    "TMPDIR",
    "TMP",
    "TEMP",
    "PWD"
]
