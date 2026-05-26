#!/usr/bin/env bash
# Hand-roll a Cli2MCP.app bundle around the SwiftPM executable target.
#
# Output: mac/build/Cli2MCP.app
#
# Usage:
#   Scripts/build-app.sh                       # build and assemble the app bundle
#   VERSION=0.2.0 Scripts/build-app.sh         # override CFBundleShortVersionString
#   SIGN_IDENTITY="Developer ID Application: Foo" Scripts/build-app.sh   # real signing
#
# When SIGN_IDENTITY is unset, we ad-hoc sign with `-`. That's enough for the
# kernel to launch the binary on Apple Silicon (which rejects unsigned arm64
# code) and to satisfy local Gatekeeper for non-quarantined files.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"
REPO_DIR="$(cd "$MAC_DIR/.." && pwd)"

APP_NAME="Cli2MCP"
EXEC_NAME="Cli2MCP"
BUNDLE_ID="${BUNDLE_ID:-dev.cli2mcp.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$MAC_DIR/VERSION")}"
BUILD_VERSION="${BUILD_VERSION:-$VERSION}"

ICON_SOURCE="${ICON_SOURCE:-$REPO_DIR/icon/1024.png}"

OUT_DIR="$MAC_DIR/build"
APP_DIR="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

cd "$MAC_DIR"

echo "==> swift build -c release --product Cli2MCPApp"
swift build -c release --product Cli2MCPApp

echo "==> swift build -c release --product cli2mcp-server"
swift build -c release --product cli2mcp-server

BIN_DIR="$(swift build -c release --show-bin-path)"
APP_EXEC="$BIN_DIR/Cli2MCPApp"
SERVER_EXEC="$BIN_DIR/cli2mcp-server"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "expected executable not found: $APP_EXEC" >&2
  exit 1
fi

if [[ ! -x "$SERVER_EXEC" ]]; then
  echo "expected executable not found: $SERVER_EXEC" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$APP_EXEC" "$MACOS_DIR/Cli2MCP"
cp "$SERVER_EXEC" "$MACOS_DIR/cli2mcp-server"
chmod +x "$MACOS_DIR/Cli2MCP" "$MACOS_DIR/cli2mcp-server"

# App icon (.png source -> AppIcon.icns).
ICON_PLIST_KEYS=""
if [[ -f "$ICON_SOURCE" ]]; then
  echo "==> Building AppIcon.icns from $ICON_SOURCE"
  ICON_TMP="$(mktemp -d)"
  ICONSET="$ICON_TMP/AppIcon.iconset"
  trap 'rm -rf "$ICON_TMP"' EXIT
  mkdir -p "$ICONSET"

  make_icon() {
    local pixels="$1"
    local output="$2"
    sips -s format png -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$output" >/dev/null
  }

  make_icon 16 "$ICONSET/icon_16x16.png"
  make_icon 32 "$ICONSET/icon_16x16@2x.png"
  make_icon 32 "$ICONSET/icon_32x32.png"
  make_icon 64 "$ICONSET/icon_32x32@2x.png"
  make_icon 128 "$ICONSET/icon_128x128.png"
  make_icon 256 "$ICONSET/icon_128x128@2x.png"
  make_icon 256 "$ICONSET/icon_256x256.png"
  make_icon 512 "$ICONSET/icon_256x256@2x.png"
  make_icon 512 "$ICONSET/icon_512x512.png"
  make_icon 1024 "$ICONSET/icon_512x512@2x.png"

  iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"

  ICON_PLIST_KEYS+=$'\n    <key>CFBundleIconFile</key>'
  ICON_PLIST_KEYS+=$'\n    <string>AppIcon</string>'
else
  echo "==> No $ICON_SOURCE — building without an app icon"
fi

# Info.plist
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>cli2mcp</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>${ICON_PLIST_KEYS}
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
EOF

# Classic 8-byte PkgInfo. Optional but cheap.
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> codesign (identity: ${SIGN_IDENTITY})"
codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"

echo "==> Verifying"
codesign --verify --verbose "$APP_DIR" 2>&1 | sed 's/^/    /'
spctl_out=$(spctl --assess --type execute --verbose "$APP_DIR" 2>&1 || true)
echo "    spctl: $spctl_out"

cat <<EOF

==> Built: $APP_DIR
    Open it now:    open "$APP_DIR"
    Install it:     mv "$APP_DIR" /Applications/

EOF
