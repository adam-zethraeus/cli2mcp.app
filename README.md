# cli2mcp.app

cli2mcp is a native Swift macOS app plus a bundled Swift stdio helper. It wraps
ordinary command-line tools as Model Context Protocol servers by reading the
wrapped tool's `--help`, inferring an input schema, and returning command output
as MCP tool results.

## What you get

- **Native app and helper.** The SwiftUI app lets you choose a preset, copy an
  MCP snippet, and run a local health probe. The snippet points directly at the
  bundled helper: `Cli2MCP.app/Contents/MacOS/cli2mcp-server`.
- **No bootstrap fetch after checkout.** The checkout builds with the local
  Swift toolchain. It does not need an external scripting runtime, package
  manager, package runner, registry install, or internet download after
  checkout build.
- **Hardened argv.** Tool-call positionals are appended after a POSIX `--`
  end-of-options marker, so user-provided strings cannot be reinterpreted as
  flags by the wrapped CLI.
- **Array-form process launch.** The helper launches children with
  `Foundation.Process` executable and argument arrays, not shell command text.
- **Environment controls.** `--env-passthrough safe` forwards only process
  essentials such as `PATH`, `HOME`, `LANG`, and `TERM`; `all` and `none`
  remain explicit modes, and `--inherit-shell-env` can capture a login-shell
  environment when a preset needs it.
- **Timeouts and concurrency.** Each call defaults to a 60 second timeout, and
  `--max-concurrent N` caps in-flight tool calls.

## MCP snippet shape

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

## Build

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
