import Foundation

/// Curated whitelist of CLIs the app will wrap. Each entry was picked for being
/// realistically useful as an LLM tool while staying inside the safety
/// envelope cli2mcp documents in its README "Security" section.
enum PresetCatalog {
    static let presets: [CliPreset] = [
        CliPreset(
            id: "jq",
            displayName: "jq",
            binary: "jq",
            summary: "Query and transform JSON via stdin. Read-only, deterministic.",
            serverArgs: ["--stderr", "drop"],
            tier: .green,
            origin: .builtIn
        ),
        CliPreset(
            id: "ripgrep",
            displayName: "ripgrep (rg)",
            binary: "rg",
            summary: "Fast recursive regex search. Read-only filesystem access.",
            serverArgs: ["--name", "ripgrep"],
            tier: .green,
            origin: .builtIn
        ),
        CliPreset(
            id: "pandoc",
            displayName: "pandoc",
            binary: "pandoc",
            summary: "Convert documents between markup formats. File I/O bounded by --cwd.",
            serverArgs: [],
            tier: .green,
            origin: .builtIn
        ),
        CliPreset(
            id: "sed",
            displayName: "sed",
            binary: "sed",
            summary: "Stream editor for text on stdin. Read-only when used via stdin.",
            serverArgs: ["--stderr", "drop"],
            tier: .green,
            origin: .builtIn
        ),
        CliPreset(
            id: "curl",
            displayName: "curl",
            binary: "curl",
            summary: "HTTP client. Network egress — review prompts for SSRF risk.",
            serverArgs: ["--stderr", "drop"],
            tier: .yellow,
            origin: .builtIn
        ),
        CliPreset(
            id: "ffmpeg",
            displayName: "ffmpeg",
            binary: "ffmpeg",
            summary: "Media transcoder. Writes files; constrain with --cwd.",
            serverArgs: ["--timeout", "300000"],
            tier: .yellow,
            origin: .builtIn
        ),
        CliPreset(
            id: "yt-dlp",
            displayName: "yt-dlp",
            binary: "yt-dlp",
            summary: "Download media from URLs. Network + filesystem writes.",
            serverArgs: ["--timeout", "600000"],
            tier: .yellow,
            origin: .builtIn
        ),
    ]
}
