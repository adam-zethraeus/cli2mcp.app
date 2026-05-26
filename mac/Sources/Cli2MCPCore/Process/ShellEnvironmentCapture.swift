import Foundation

public enum ShellEnvironmentCapture {
    public static let defaultTimeoutMilliseconds = 5_000

    public static func capture(
        shell: String? = nil,
        timeoutMilliseconds: Int = defaultTimeoutMilliseconds,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> [String: String]? {
        let resolvedShell = shell ?? environment["SHELL"] ?? "/bin/zsh"

        do {
            let result = try await ChildProcessRunner().run(
                command: resolvedShell,
                arguments: ["-l", "-i", "-c", "exec /usr/bin/env -0"],
                options: ChildRunOptions(
                    timeoutMilliseconds: timeoutMilliseconds,
                    environment: environment
                )
            )

            guard result.exitCode == 0 else {
                return nil
            }

            return parseEnvOutput(Data(result.stdout.utf8))
        } catch {
            return nil
        }
    }

    public static func parseEnvOutput(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var env: [String: String] = [:]

        for entry in text.split(separator: "\0", omittingEmptySubsequences: true) {
            if let pair = parseEnvRecord(entry) {
                env[pair.key] = pair.value
            }
        }

        return env
    }
}

private func parseEnvRecord(_ entry: Substring) -> (key: String, value: String)? {
    if let pair = parseEnvLine(entry) {
        return pair
    }

    for line in entry.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        if let pair = parseEnvLine(line) {
            return pair
        }
    }

    return nil
}

private func parseEnvLine(_ line: Substring) -> (key: String, value: String)? {
    guard let equalsIndex = line.firstIndex(of: "="),
          equalsIndex > line.startIndex else {
        return nil
    }

    let key = line[..<equalsIndex]
    guard isValidEnvironmentKey(key) else {
        return nil
    }

    let valueStart = line.index(after: equalsIndex)
    return (String(key), String(line[valueStart...]))
}

private func isValidEnvironmentKey(_ key: Substring) -> Bool {
    guard let first = key.utf8.first,
          first == UInt8(ascii: "_") || isASCIIAlpha(first) else {
        return false
    }

    for byte in key.utf8.dropFirst() {
        guard byte == UInt8(ascii: "_") || isASCIIAlpha(byte) || isASCIIDigit(byte) else {
            return false
        }
    }

    return true
}

private func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
}

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
}
