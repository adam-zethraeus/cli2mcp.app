#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"

cd "$MAC_DIR"

swift build --product cli2mcp-server
SERVER_BIN="$(swift build --product cli2mcp-server --show-bin-path)/cli2mcp-server"

swift test

CLI2MCP_SERVER_BIN="$SERVER_BIN" "$HERE/run-native-smoke.sh"
