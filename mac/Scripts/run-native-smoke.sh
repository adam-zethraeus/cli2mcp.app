#!/usr/bin/env bash
set -euo pipefail

SERVER_BIN="${CLI2MCP_SERVER_BIN:-}"
if [[ -z "$SERVER_BIN" ]]; then
  echo "error: CLI2MCP_SERVER_BIN is required" >&2
  exit 1
fi
if [[ ! -x "$SERVER_BIN" ]]; then
  echo "error: CLI2MCP_SERVER_BIN is not executable: $SERVER_BIN" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FIXTURE="$TMP_DIR/fixture"
cat > "$FIXTURE" <<'EOF'
#!/bin/sh
if [ "$1" = "--help" ]; then
  cat <<'HELP'
fixture - smoke test cli

Usage: fixture [options] <args...>

Options:
  --echo <value>    echo a value
HELP
  exit 0
fi

printf '%s\n' "$*"
EOF
chmod +x "$FIXTURE"

STDOUT_FILE="$TMP_DIR/stdout"
STDERR_FILE="$TMP_DIR/stderr"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$SERVER_BIN" "$FIXTURE" "$STDOUT_FILE" "$STDERR_FILE" <<'PY'
import json
import subprocess
import sys

server_bin, fixture, stdout_path, stderr_path = sys.argv[1:5]

messages = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "native-smoke", "version": "0.0.0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]

proc = subprocess.Popen(
    [server_bin, fixture, "--name", "fixture", "--timeout", "5000", "--env-passthrough", "all"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

payload = "".join(json.dumps(message, separators=(",", ":")) + "\n" for message in messages)
timed_out = False
try:
    stdout, stderr = proc.communicate(payload, timeout=5)
except subprocess.TimeoutExpired:
    timed_out = True
    proc.kill()
    stdout, stderr = proc.communicate(timeout=2)
with open(stdout_path, "w", encoding="utf-8") as handle:
    handle.write(stdout)
with open(stderr_path, "w", encoding="utf-8") as handle:
    handle.write(stderr)

if timed_out:
    sys.stderr.write("error: native smoke timed out\n")
    sys.stderr.write(stderr)
    sys.exit(1)

if proc.returncode != 0:
    sys.stderr.write(f"error: cli2mcp-server exited with {proc.returncode}\n")
    sys.stderr.write(stderr)
    sys.exit(1)

if '"tools"' not in stdout:
    sys.stderr.write("error: smoke output did not contain tools\n")
    sys.stderr.write(stderr)
    sys.exit(1)
PY
else
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"native-smoke","version":"0.0.0"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  } | "$SERVER_BIN" "$FIXTURE" --name fixture --timeout 5000 --env-passthrough all > "$STDOUT_FILE" 2> "$STDERR_FILE" || {
    cat "$STDERR_FILE" >&2
    exit 1
  }
fi

if ! grep -q '"tools"' "$STDOUT_FILE"; then
  echo "error: smoke output did not contain tools" >&2
  cat "$STDERR_FILE" >&2
  exit 1
fi

echo "native smoke ok"
