# cli2mcp.app

Turn any macOS command-line tool into a Model Context Protocol server — with no
Node, no Python, and no `npx` bootstrap. cli2mcp is a native SwiftUI app that
inspects a CLI's `--help`, infers an input schema, and hands you a ready-to-paste
MCP snippet for Claude Desktop or any other MCP client. A bundled stdio helper
does the actual wrapping at runtime, and ships inside the same `.app`.

## Why cli2mcp

- **Pick, copy, paste.** Choose a preset (`jq`, `rg`, `pandoc`, `sed`, `curl`,
  `ffmpeg`, `yt-dlp`, or your own), copy the generated JSON, and paste it into
  your MCP client. The snippet points directly at the helper inside the bundle:
  `Cli2MCP.app/Contents/MacOS/cli2mcp-server`.
- **Verify before you trust.** A built-in health probe launches the same helper
  your client will use, exchanges `initialize` and `tools/list`, and shows the
  full stdio transcript — so you see exactly what an MCP client will see.
- **Self-contained.** Pure Swift, single bundle. No package manager, no
  registry, no scripting runtime, no post-checkout download. If you have the
  Swift toolchain, you can build it offline.
- **Safe by construction.**
  - Tool-call positionals are appended after a POSIX `--` end-of-options
    marker, so user-provided strings can never be reinterpreted as flags by
    the wrapped CLI.
  - Children launch via `Foundation.Process` with executable and argument
    arrays — never shell command text.
  - `--env-passthrough safe` forwards only essentials (`PATH`, `HOME`, `LANG`,
    `TERM`); `all` and `none` remain explicit, and `--inherit-shell-env` can
    opt into a login-shell environment when a preset needs it.
  - Per-call timeout defaults to 60 seconds; `--max-concurrent N` caps
    in-flight calls.

## What a snippet looks like

Snippets copied from the app use an absolute command path for the helper:

```json
{
  "mcpServers": {
    "jq": {
      "command": "/Applications/Cli2MCP.app/Contents/MacOS/cli2mcp-server",
      "args": ["jq", "--env-passthrough", "safe", "--max-concurrent", "4", "--timeout", "60000"]
    }
  }
}
```

If you move the app, reopen it from the new location and copy the snippet again
so the absolute helper path stays current.

## Build it yourself

```sh
cd mac && make test
make app
make sign-distribution SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)"
make install
make reinstall
make run-app
```

`make app` produces `mac/build/Cli2MCP.app`, with both the SwiftUI executable
and `cli2mcp-server` copied into `Contents/MacOS/`.

See [`mac/README.md`](mac/README.md) for macOS app details.

## License

GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). See
[`LICENSE`](LICENSE).
