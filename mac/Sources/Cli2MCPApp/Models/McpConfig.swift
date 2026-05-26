import Foundation

/// Renders the JSON snippet that operators paste into Claude Desktop / Cursor /
/// Cline / Windsurf / Continue / Zed. Every supported client expects the same
/// shape — `command` + `args` — so one snippet covers all of them.
///
/// The snippet always points at the native helper shipped inside this `.app`.
/// Nothing on the user's `$PATH` is consulted; the goal is a fully
/// self-contained bundle the user pastes from once and forgets about.
/// If the user moves the `.app`, they need to reopen it and re-copy the snippet
/// — the absolute paths reflect the bundle's current location.
///
/// When `forwardEnvironment` is true, the snippet's args include
/// `--inherit-shell-env`. cli2mcp itself reads this at startup, sources the
/// user's login shell once, and uses the resulting env (PATH additions,
/// OAuth tokens, etc.) as the parent env for spawned children. The snippet's
/// JSON deliberately carries no `env` block: secrets stay in the user's shell
/// dotfiles and are never written into Claude Desktop's config.
enum McpConfig {
    static func snippet(
        for preset: CliPreset,
        runtime: NativeRuntime,
        forwardEnvironment: Bool
    ) -> String {
        let serverKey = preset.id
        var presetArgs = preset.fullArgs()
        if forwardEnvironment {
            // preset.fullArgs() == [binary] + server options. The binary is
            // the positional command; everything else is options. Order among
            // the options doesn't matter to the server's argv parser.
            presetArgs.append("--inherit-shell-env")
        }
        return render(serverKey: serverKey, command: runtime.serverExecutable, args: presetArgs)
    }

    private static func render(serverKey: String, command: String, args: [String]) -> String {
        let payload: [String: Any] = [
            "mcpServers": [
                serverKey: [
                    "command": command,
                    "args": args,
                ]
            ]
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let data, let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
