#!/usr/bin/env bash

set -euo pipefail

PROFILE="${NOTARY_PROFILE:-cli2mcp-notary}"

usage() {
  cat <<EOF
Usage:
  $0 path/to/Cli2MCP.app

Environment:
  NOTARY_PROFILE      Keychain profile for notarytool. Default: cli2mcp-notary
  NOTARY_APPLE_ID     Apple ID email used when storing missing credentials.
  NOTARY_TEAM_ID      Developer Team ID used when storing missing credentials.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

prompt() {
  local label="$1"
  local var_name="$2"
  local value

  printf '%s' "$label"
  IFS= read -r value
  printf -v "$var_name" '%s' "$value"
}

resolve_path() {
  local path="$1"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd)" "$path"
  fi
}

notary_profile_available() {
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1
}

store_notary_profile() {
  local apple_id="${NOTARY_APPLE_ID:-}"
  local team_id="${NOTARY_TEAM_ID:-}"
  local args=()

  echo "==> No usable notarytool profile found: $PROFILE"
  echo "==> Storing credentials for future notarization runs"

  if [[ -z "$apple_id" ]]; then
    prompt "Apple ID email: " apple_id
  fi

  if [[ -z "$team_id" ]]; then
    prompt "Developer Team ID: " team_id
  fi

  [[ -n "$apple_id" ]] || fail "Apple ID email is required"
  [[ -n "$team_id" ]] || fail "Developer Team ID is required"

  args=(
    notarytool
    store-credentials "$PROFILE"
    --apple-id "$apple_id"
    --team-id "$team_id"
  )

  echo "==> notarytool will prompt for your app-specific password"

  xcrun "${args[@]}"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage
    fail "missing app bundle path"
    ;;
esac

if [[ $# -ne 1 ]]; then
  usage
  fail "expected exactly one app bundle path"
fi

APP_PATH="$(resolve_path "$1")"
APP_NAME="$(basename "$APP_PATH")"
APP_STEM="${APP_NAME%.app}"
BUILD_DIR="$(dirname "$APP_PATH")"
SUBMIT_ZIP="$BUILD_DIR/$APP_STEM-notarization-submit.zip"
DIST_ZIP="$BUILD_DIR/$APP_STEM-notarized.zip"

[[ -d "$APP_PATH" ]] || fail "app bundle not found: $APP_PATH"
[[ "$APP_NAME" == *.app ]] || fail "expected an .app bundle: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "missing Info.plist: $APP_PATH/Contents/Info.plist"

if notary_profile_available; then
  echo "==> Using notarytool profile: $PROFILE"
else
  store_notary_profile
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

echo "==> Creating notarization upload: $SUBMIT_ZIP"
rm -f "$SUBMIT_ZIP" "$DIST_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notarization service"
xcrun notarytool submit "$SUBMIT_ZIP" \
  --keychain-profile "$PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Validating stapled ticket"
xcrun stapler validate "$APP_PATH"

echo "==> Running Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> Creating distribution zip: $DIST_ZIP"
rm -f "$DIST_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"

echo "Ready for distribution: $DIST_ZIP"
