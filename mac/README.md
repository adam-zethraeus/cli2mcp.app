# cli2mcp.app - native macOS frontend

A SwiftUI macOS app for creating MCP client snippets that wrap local CLI tools.
The app ships a native Swift helper, `cli2mcp-server`, inside the app bundle.
Pick a CLI from the whitelist, copy the generated snippet, and run the built-in
probe to confirm the helper can start and answer basic MCP requests.

## What you get

- **Whitelisted CLIs.** Built-in presets cover `jq`, `rg`, `pandoc`, `sed`,
  `curl`, `ffmpeg`, and `yt-dlp`, each with safety tiers and default helper
  flags: `--env-passthrough safe`, `--max-concurrent 4`, and
  `--timeout 60000`. Edit `Sources/Cli2MCPApp/Models/PresetCatalog.swift` to
  change shipped defaults, or add and remove presets at runtime through the UI.
- **Self-contained helper path.** Each snippet sets `command` to the
  `cli2mcp-server` executable inside the current `.app` bundle. The helper
  then receives the wrapped CLI binary and server flags as `args`.
- **Live test runner.** The runner launches the same native helper advertised
  by the snippet, sends `initialize`, `notifications/initialized`, and
  `tools/list`, then shows the stdio transcript.

## Install

```sh
cd mac
make test                 # build helper, run Swift tests, run native smoke
make app                  # -> mac/build/Cli2MCP.app (release, ad-hoc signed)
make sign-distribution SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)"
make install              # -> /Applications/Cli2MCP.app (refuses overwrite)
make reinstall            # replace /Applications/Cli2MCP.app
make run-app              # build + open
```

`make app` does the lot:

1. Builds `Cli2MCPApp` in release mode.
2. Builds the native `cli2mcp-server` helper in release mode.
3. Assembles `Cli2MCP.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}`.
4. Copies `Cli2MCP` and `cli2mcp-server` into `Contents/MacOS/`.
5. Generates `Resources/AppIcon.icns` from `../icon/1024.png` if present and
   adds it to the generated `Info.plist`.
6. Ad-hoc code-signs with `codesign --force --deep --sign -`, enough for local
   non-quarantined use.

For Developer ID distribution, run:

```sh
make sign-distribution SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)"
```

That target rebuilds the app, signs the bundled `cli2mcp-server` helper first,
then signs `Cli2MCP.app` with hardened runtime and a secure timestamp. The
script verifies the signature and prints Gatekeeper assessment output. It does
not notarize the app; notarization should happen against a zipped copy of the
signed bundle.

## How a snippet survives a move

The snippet card renders absolute paths into the app's current location. If you
move the app from `/Applications` to `~/Applications` or anywhere else, an
already-pasted snippet still references the old path and will fail in your MCP
client. Reopen Cli2MCP.app from its new location, copy the snippet again, and
paste over the old one.

The snippet card shows the current install path below the JSON so you can check
it before copying.

## When native helper is missing

If `Cli2MCP.app/Contents/MacOS/cli2mcp-server` is missing or is not executable,
the app launches into a hard-error state. The detail pane shows "Native helper
missing" with a reinstall hint, the test runner is disabled, and the snippet
card is suppressed. The sidebar still renders so you can confirm the app itself
started. Reinstall the app or rebuild with `make app` to recover.

## Customizing the whitelist

The whitelist has two layers:

- **Built-ins.** Compiled into the app and defined in
  `Sources/Cli2MCPApp/Models/PresetCatalog.swift`. They cannot be edited, but
  they can be deleted from the UI. To bring deleted built-ins back, use the
  sidebar toolbar menu's reset action.
- **Custom presets.** Use the toolbar add menu to create a custom CLI preset.
  Fill in display name, binary, summary, safety tier, and helper args. Custom
  presets appear under a custom section and can be edited or deleted.

Both layers persist user state to:

```text
~/Library/Application Support/cli2mcp/state.json
```

The on-disk schema is versioned:

```json
{
  "version": 1,
  "userPresets": [
    {
      "id": "imagemagick",
      "displayName": "ImageMagick",
      "binary": "magick",
      "summary": "Image conversion and inspection",
      "serverArgs": ["--name", "imagemagick"],
      "tier": "yellow",
      "origin": "user"
    }
  ],
  "deletedBuiltIns": ["curl", "ffmpeg"]
}
```

The app coerces every loaded user entry to `origin: "user"`, so a tampered file
cannot smuggle a fake built-in into the editable list.

### Do not add this to the whitelist

Do not add shells, interpreters with inline evaluation flags, or tools that
execute arbitrary scripts supplied as data. The whitelist is the operator's
policy boundary; the editor does not enforce it for you.

## App icon

The icon source is `../icon/1024.png`. The build script uses it to generate a
complete `AppIcon.icns` iconset at bundle time and writes `CFBundleIconFile`
into the generated `Info.plist`.

To replace the icon, update `icon/1024.png` and rerun `make app`. To remove it,
delete `icon/1024.png`; the build script detects the missing file and ships an
app without an icon.

## Dev workflow

```sh
cd mac
make dev
```

`make dev` builds the helper first, then runs the SwiftUI app with `swift run`.
That flow does not produce an `.app` bundle and is meant only for local UI
iteration. Use `make app` when you need the bundled layout that MCP clients
will reference.

## Layout

```text
mac/
├── Package.swift                     # Cli2MCPCore, Cli2MCPServer, Cli2MCPApp
├── Makefile                          # dev / app / install / reinstall / test
├── Scripts/
│   ├── build-app.sh                  # assemble and sign Cli2MCP.app
│   ├── run-native-smoke.sh           # direct helper smoke probe
│   ├── sign-distribution.sh          # Developer ID distribution signing
│   └── test-native.sh                # build helper, test, smoke probe
├── Sources/
│   ├── Cli2MCPCore/                  # parser, schema, MCP, process logic
│   ├── Cli2MCPServer/
│   │   └── main.swift                # native stdio helper entrypoint
│   └── Cli2MCPApp/
│       ├── App.swift                 # SwiftUI app entrypoint
│       ├── Models/                   # presets, catalog, snippet rendering
│       ├── Runner/
│       │   ├── NativeRuntime.swift   # resolves bundled helper
│       │   └── McpRunner.swift       # launches helper for health probe
│       └── Views/                    # sidebar, details, runner transcript
└── Tests/
    ├── Cli2MCPCoreTests/
    ├── Cli2MCPServerIntegrationTests/
    └── Cli2MCPAppTests/

build/Cli2MCP.app/Contents/MacOS/
├── Cli2MCP                            # SwiftUI app executable
└── cli2mcp-server                     # bundled native helper
```

## Limitations / known follow-ups

- No App Sandbox.
- No notarization.
- Host-arch only unless a universal Swift build is added.
- No App Store shipping path.
- `--cwd` is not currently overridable per preset from the UI.
- The runner still only probes `initialize` and `tools/list` unless Task 9
  expands it.

## License

GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). See
[`../LICENSE`](../LICENSE).
