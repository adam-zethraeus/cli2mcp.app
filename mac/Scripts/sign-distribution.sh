#!/usr/bin/env bash
# Sign Cli2MCP.app for Developer ID distribution.
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
#     Scripts/sign-distribution.sh
#
# Optional:
#   APP_PATH=build/Cli2MCP.app Scripts/sign-distribution.sh
#   APP_ENTITLEMENTS=path/to/App.entitlements Scripts/sign-distribution.sh
#   HELPER_ENTITLEMENTS=path/to/Helper.entitlements Scripts/sign-distribution.sh
#
# This script signs the nested helper first, then the app bundle. It does not
# notarize the app; notarization should happen against a zipped, signed bundle.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"

APP_PATH="${APP_PATH:-$MAC_DIR/build/Cli2MCP.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-}"
HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-}"
SKIP_SPCTL="${SKIP_SPCTL:-0}"

usage() {
  cat <<EOF
Usage:
  SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" Scripts/sign-distribution.sh

Environment:
  APP_PATH             App bundle to sign. Default: $MAC_DIR/build/Cli2MCP.app
  SIGN_IDENTITY        Codesigning identity. If omitted, the script uses the
                       only Developer ID Application identity in the keychain.
  APP_ENTITLEMENTS     Optional entitlements plist for the app executable.
  HELPER_ENTITLEMENTS  Optional entitlements plist for bundled helper binaries.
  SKIP_SPCTL=1         Skip Gatekeeper assessment output.

The script signs with hardened runtime and a secure timestamp. It does not
submit the app for notarization.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

resolve_app_path() {
  local path="$1"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd)" "$path"
  fi
}

find_developer_id_identity() {
  local identities=()
  local candidate

  while IFS= read -r candidate; do
    identities+=("$candidate")
  done < <(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '/Developer ID Application/ { print $2 }')

  case "${#identities[@]}" in
    0)
      fail "no Developer ID Application identity found; set SIGN_IDENTITY explicitly"
      ;;
    1)
      printf '%s\n' "${identities[0]}"
      ;;
    *)
      echo "Multiple Developer ID Application identities found:" >&2
      local identity
      for identity in "${identities[@]}"; do
        echo "  $identity" >&2
      done
      fail "set SIGN_IDENTITY to the distribution identity to use"
      ;;
  esac
}

identity_display_name() {
  local identity="$1"

  { security find-identity -p codesigning -v 2>/dev/null || true; } \
    | awk -F '"' -v needle="$identity" 'index($0, needle) { print $2; exit }'
}

codesign_args() {
  local entitlements="$1"

  printf '%s\0' \
    --force \
    --timestamp \
    --options runtime \
    --sign "$SIGN_IDENTITY"

  if [[ -n "$entitlements" ]]; then
    printf '%s\0' --entitlements "$entitlements"
  fi
}

sign_code() {
  local label="$1"
  local path="$2"
  local entitlements="$3"
  local args=()
  local arg

  if [[ -n "$entitlements" && ! -f "$entitlements" ]]; then
    fail "$label entitlements file not found: $entitlements"
  fi

  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(codesign_args "$entitlements")

  echo "==> Signing $label"
  codesign "${args[@]}" "$path"
}

is_macho() {
  local path="$1"

  file "$path" | grep -q 'Mach-O'
}

sign_nested_macos_executables() {
  local contents="$APP_PATH/Contents"
  local macos_dir="$contents/MacOS"
  local plist="$contents/Info.plist"
  local main_exec
  local path

  main_exec=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
  [[ -n "$main_exec" ]] || fail "could not read CFBundleExecutable from $plist"

  while IFS= read -r -d '' path; do
    if [[ "$(basename "$path")" == "$main_exec" ]]; then
      continue
    fi

    if [[ -x "$path" ]] && is_macho "$path"; then
      sign_code "nested executable: $path" "$path" "$HELPER_ENTITLEMENTS"
    fi
  done < <(find "$macos_dir" -maxdepth 1 -type f -print0)
}

verify_signature() {
  echo "==> Verifying code signature"
  codesign --verify --strict --verbose=4 "$APP_PATH" 2>&1 | sed 's/^/    /'

  echo "==> Signature details"
  codesign -dvvv --entitlements :- "$APP_PATH" 2>&1 | sed 's/^/    /'

  if [[ "$SKIP_SPCTL" != "1" ]]; then
    echo "==> Gatekeeper assessment"
    if spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 | sed 's/^/    /'; then
      :
    else
      echo "    Gatekeeper may reject a Developer ID app until it is notarized." >&2
    fi
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    APP_PATH="$1"
    ;;
esac

APP_PATH="$(resolve_app_path "$APP_PATH")"

[[ -d "$APP_PATH" ]] || fail "app bundle not found: $APP_PATH; run 'make app' first"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "missing Info.plist: $APP_PATH/Contents/Info.plist"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(find_developer_id_identity)"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  fail "ad-hoc signing is not a distribution signature; set SIGN_IDENTITY to a Developer ID Application identity"
fi

resolved_identity="$(identity_display_name "$SIGN_IDENTITY")"
if [[ -n "$resolved_identity" && "$resolved_identity" != *"Developer ID Application"* ]]; then
  echo "warning: '$resolved_identity' does not look like a Developer ID Application identity" >&2
fi

echo "==> App: $APP_PATH"
echo "==> Identity: $SIGN_IDENTITY"

sign_nested_macos_executables
sign_code "app bundle: $APP_PATH" "$APP_PATH" "$APP_ENTITLEMENTS"
verify_signature

cat <<EOF

==> Signed for distribution: $APP_PATH
    Next distribution step: notarize a zipped copy of this signed app.

EOF
