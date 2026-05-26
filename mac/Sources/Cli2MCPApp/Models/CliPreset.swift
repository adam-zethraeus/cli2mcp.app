import Foundation

/// Safety tier shown in the UI as a colored badge. Reflects the realistic blast
/// radius of the wrapped CLI when an LLM controls its arguments.
enum SafetyTier: String, Codable, Sendable, CaseIterable {
    /// Read-only CLIs with bounded I/O — `jq`, `rg`, `pandoc`, `sed`.
    case green
    /// Network or filesystem write capability — `curl`, `ffmpeg`, `yt-dlp`.
    case yellow
    /// Mutates databases, executes external programs, or touches credentials —
    /// `sqlite3`. Operators see a "review carefully" banner.
    case red

    var label: String {
        switch self {
        case .green: "Low risk"
        case .yellow: "Mid risk"
        case .red: "High risk"
        }
    }
}

/// Where the preset came from. Built-ins ship with the app and are never
/// editable or deletable — only hideable. User presets are stored in
/// `~/Library/Application Support/cli2mcp/state.json` and round-trip freely.
enum PresetOrigin: String, Codable, Sendable {
    case builtIn
    case user
}

/// A whitelisted CLI the app will wrap with the native server helper. The args
/// are server flags that follow the binary name — they are *not* the CLI's own
/// arguments, which are supplied by the LLM at tool-call time.
struct CliPreset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    let binary: String
    let summary: String
    let serverArgs: [String]
    let tier: SafetyTier
    let origin: PresetOrigin

    /// Default server args every preset gets, prepended in front of preset-specific args.
    static let baseArgs: [String] = [
        "--env-passthrough", "safe",
        "--max-concurrent", "4",
        "--timeout", "60000",
    ]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case binary
        case summary
        case serverArgs
        case legacyCli2mcpArgs = "cli2mcpArgs"
        case tier
        case origin
    }

    init(
        id: String,
        displayName: String,
        binary: String,
        summary: String,
        serverArgs: [String],
        tier: SafetyTier,
        origin: PresetOrigin
    ) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.summary = summary
        self.serverArgs = serverArgs
        self.tier = tier
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.binary = try c.decode(String.self, forKey: .binary)
        self.summary = try c.decode(String.self, forKey: .summary)
        self.serverArgs = try c.decodeIfPresent([String].self, forKey: .serverArgs)
            ?? c.decodeIfPresent([String].self, forKey: .legacyCli2mcpArgs)
            ?? []
        self.tier = try c.decode(SafetyTier.self, forKey: .tier)
        self.origin = try c.decode(PresetOrigin.self, forKey: .origin)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(binary, forKey: .binary)
        try c.encode(summary, forKey: .summary)
        try c.encode(serverArgs, forKey: .serverArgs)
        try c.encode(tier, forKey: .tier)
        try c.encode(origin, forKey: .origin)
    }

    /// The full argv vector passed to `cli2mcp-server`.
    func fullArgs() -> [String] {
        [binary] + Self.baseArgs + serverArgs
    }

    var isEditable: Bool { origin == .user }
}
