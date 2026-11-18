#!/bin/zsh
# Build the worse_query edition of FilzaSlop and repackage a Filza IPA.
#
# Usage:
#   scripts/build_wq_ipa.sh <base-unsigned.ipa> <output.ipa>
#
# Environment:
#   BUNDLE_ID        Bundle identifier to write into the app (default:
#                    com.filzaslop.worsequery). It must match the App ID in the
#                    provisioning profile used for signing.
#   WQ_APP_GROUPS    Space-separated App Group identifiers. At least one is
#                    required for worse_query at runtime.
#   ENTITLEMENTS     Optional entitlements plist. When omitted, the app is
#                    ad-hoc signed with the groups from WQ_APP_GROUPS.
#   SIGN_IDENTITY    Optional codesign identity. Omit for an unsigned/ad-hoc
#                    IPA suitable for third-party signing.
#   KEYCHAIN         Optional keychain path for SIGN_IDENTITY.
#   PROFILE          Optional .mobileprovision copied to embedded.mobileprovision.
#   FILZASLOP_VERSION Version string shown by the update checker.
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <base-unsigned.ipa> <output.ipa>" >&2
  exit 64
fi

BASE_IPA="${1:A}"
OUTPUT_IPA="${2:A}"
REPO_ROOT="${0:A:h:h}"
THEOS="${THEOS:-$HOME/theos}"
BUNDLE_ID="${BUNDLE_ID:-com.jbjf.filza}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-filza27.2}"
WQ_APP_GROUPS="${WQ_APP_GROUPS:-}"
FILZASLOP_VERSION="${FILZASLOP_VERSION:-wq-27.2-1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
KEYCHAIN="${KEYCHAIN:-}"
PROFILE="${PROFILE:-}"
ENTITLEMENTS="${ENTITLEMENTS:-}"

[[ -f "$BASE_IPA" ]] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
[[ -d "$THEOS" ]] || { echo "Theos not found: $THEOS" >&2; exit 66; }
if [[ -z "$WQ_APP_GROUPS" ]]; then
  echo "WQ_APP_GROUPS is required (space-separated group identifiers)" >&2
  exit 65
fi

export THEOS
export PATH="$THEOS/bin:$PATH"
# Theos' bundled ldid may not run on current macOS builds. codesign is enough
# for the intermediate dylib; final app signing happens below.
export TARGET_CODESIGN="${TARGET_CODESIGN:-codesign}"
export TARGET_CODESIGN_FLAGS="${TARGET_CODESIGN_FLAGS:---force --sign -}"

echo "==> Building FilzaApplySandboxExt.dylib"
cd "$REPO_ROOT"
make clean >/dev/null
make FINALPACKAGE=1
DYLIB="$REPO_ROOT/.theos/obj/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || DYLIB="$REPO_ROOT/.theos/obj/debug/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || { echo "built dylib not found" >&2; exit 70; }

STAGE_ROOT="$(mktemp -d /private/tmp/FilzaSlop-WQ.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
unzip -q "$BASE_IPA" -d "$STAGE_ROOT/stage"
APP="$(find "$STAGE_ROOT/stage/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Payload app not found" >&2; exit 65; }

# The bundled Sharing extension has its own App ID and cannot be authorized by
# the single-App-ID profile used for normal signing.
rm -rf "$APP/PlugIns"

echo "==> Patching Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$APP/Info.plist" 2>/dev/null || \
  plutil -insert CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$APP/Info.plist"
plutil -replace CFBundleName -string "$APP_DISPLAY_NAME" "$APP/Info.plist" 2>/dev/null || \
  plutil -insert CFBundleName -string "$APP_DISPLAY_NAME" "$APP/Info.plist"
plutil -replace FilzaSlopVersion -string "$FILZASLOP_VERSION" "$APP/Info.plist" 2>/dev/null || \
  plutil -insert FilzaSlopVersion -string "$FILZASLOP_VERSION" "$APP/Info.plist"
plutil -remove CFBundleURLTypes "$APP/Info.plist" 2>/dev/null || true
plutil -insert NSLocalNetworkUsageDescription -string \
  "FilzaSlop runs a local WebDAV server so you can browse device storage from a computer." \
  "$APP/Info.plist" 2>/dev/null || true
plutil -insert NSBonjourServices -json '["_http._tcp.","_webdav._tcp."]' \
  "$APP/Info.plist" 2>/dev/null || true

# Runtime-readable copy of the groups (SecTask is the primary source).
groups_json="["
first=1
for group in ${(s: :)WQ_APP_GROUPS}; do
  [[ -n "$group" ]] || continue
  if (( first == 0 )); then groups_json+=","; fi
  groups_json+="\"$group\""
  first=0
done
groups_json+="]"
plutil -remove WQAppGroups "$APP/Info.plist" 2>/dev/null || true
plutil -insert WQAppGroups -json "$groups_json" "$APP/Info.plist"

echo "==> Adding bundled test files"
mkdir -p "$APP/WQTestFiles"
if [[ -f "$REPO_ROOT/tests/test.deb" ]]; then
  cp "$REPO_ROOT/tests/test.deb" "$APP/WQTestFiles/test.deb"
fi
if [[ -f "$REPO_ROOT/tests/test" ]]; then
  cp "$REPO_ROOT/tests/test" "$APP/WQTestFiles/test"
  chmod 0755 "$APP/WQTestFiles/test"
fi

echo "==> Injecting dylib"
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/FilzaApplySandboxExt.dylib"
codesign --remove-signature "$APP/Frameworks/FilzaApplySandboxExt.dylib" 2>/dev/null || true

if [[ "${WQ_TERMINAL:-0}" == "full" ]]; then
  ASHELL_IPA="${ASHELL_IPA:-$HOME/Downloads/Terminal.ipa}"
  "$REPO_ROOT/scripts/prepare_dev_terminal.sh" "$APP" "$ASHELL_IPA"
  cp "$REPO_ROOT/vendor/libssh/libssh.4.dylib" "$APP/Frameworks/libssh.4.dylib"
elif [[ "${WQ_TERMINAL:-0}" == "1" ]]; then
  ASHELL_IPA="${ASHELL_IPA:-$HOME/Downloads/Terminal.ipa}"
  "$REPO_ROOT/scripts/prepare_mini_terminal.sh" "$APP" "$ASHELL_IPA"
fi

if [[ -n "$PROFILE" ]]; then
  [[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 66; }
  cp "$PROFILE" "$APP/embedded.mobileprovision"
fi

if [[ -n "$ENTITLEMENTS" ]]; then
  [[ -f "$ENTITLEMENTS" ]] || { echo "entitlements not found: $ENTITLEMENTS" >&2; exit 66; }
  plutil -lint "$ENTITLEMENTS" >/dev/null
else
  ENTITLEMENTS="$STAGE_ROOT/wq-entitlements.plist"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '<key>com.apple.security.application-groups</key><array>'
    for group in ${(s: :)WQ_APP_GROUPS}; do
      [[ -n "$group" ]] && echo "<string>$group</string>"
    done
    echo '</array></dict></plist>'
  } > "$ENTITLEMENTS"
fi

echo "==> Signing nested code"
sign_args=(--force --timestamp=none)
if [[ -n "$SIGN_IDENTITY" ]]; then
  sign_args+=(--sign "$SIGN_IDENTITY")
  [[ -n "$KEYCHAIN" ]] && sign_args+=(--keychain "$KEYCHAIN")
else
  sign_args+=(--sign -)
fi

while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign "${sign_args[@]}" "$candidate"
  fi
done < <(find "$APP" -type f -perm +111 -print0)

echo "==> Signing app"
codesign "${sign_args[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$OUTPUT_IPA"
(
  cd "$STAGE_ROOT/stage"
  zip -qry "$OUTPUT_IPA" Payload
)
echo "==> Wrote $OUTPUT_IPA"
shasum -a 256 "$OUTPUT_IPA"
