#!/bin/zsh
# Copy the a-Shell mini ios_system runtime into a Filza app bundle.
# Usage: prepare_mini_terminal.sh <app-path> [ashell-ipa]
set -euo pipefail

APP="${1:A}"
ASHELL_IPA="${2:-$HOME/Downloads/Terminal.ipa}"
FRAMEWORKS=(
  ios_system shell files text network_ios dash tar awk curl_ios jq bc_ios
  calc xxd unrar openrsync mandoc task lua_ios lex lg2 multimarkdown pico
  blink ssh_cmd ssh_agent vim
)

[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 66; }
[[ -f "$ASHELL_IPA" ]] || { echo "a-Shell IPA not found: $ASHELL_IPA" >&2; exit 66; }

TMP="$(mktemp -d /private/tmp/wq-mini.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
unzip -Z1 "$ASHELL_IPA" > "$TMP/list"
ASHELL_APPDIR="$(grep -m1 -E '^Payload/[^/]+\.app/' "$TMP/list" | cut -d/ -f1-2)"
[[ -n "$ASHELL_APPDIR" ]] || { echo "cannot locate app inside IPA" >&2; exit 65; }

echo "==> Extracting mini command frameworks"
mkdir -p "$APP/Frameworks"
for framework in "${FRAMEWORKS[@]}"; do
  archive_path="${ASHELL_APPDIR}/Frameworks/${framework}.framework"
  if ! unzip -q "$ASHELL_IPA" "${archive_path}/*" -d "$TMP/extract" 2>/dev/null; then
    echo "  skip missing ${framework}.framework"
    continue
  fi
  rm -rf "$APP/Frameworks/${framework}.framework"
  cp -R "$TMP/extract/${archive_path}" "$APP/Frameworks/${framework}.framework"
  rm -rf "$APP/Frameworks/${framework}.framework/_CodeSignature"
  echo "  ${framework}.framework"
done

echo "==> Copying mini resources"
RES_SRC="${ASHELL_RESOURCES:-$(dirname "$0")/../Resources_mini}"
if [[ ! -d "$RES_SRC" ]]; then
  RES_SRC="$(dirname "$0")/../../a-shell-master/Resources_mini"
fi
[[ -d "$RES_SRC" ]] || { echo "Resources_mini not found" >&2; exit 66; }
rm -rf "$APP/WQResources"
mkdir -p "$APP/WQResources"
cp -R "$RES_SRC/bin" "$APP/WQResources/bin"
cp -R "$RES_SRC/usr" "$APP/WQResources/usr"
chmod -R u+rwX "$APP/WQResources"

echo "==> Filtering command dictionary"
python3 - "$RES_SRC/commandDictionary.plist" "$APP/commandDictionary.plist" "${FRAMEWORKS[@]}" <<'PY'
import plistlib, sys
source, destination = sys.argv[1], sys.argv[2]
selected = set(sys.argv[3:])
d = plistlib.load(open(source, 'rb'))
out = {}
for command, info in d.items():
    if not isinstance(info, list) or len(info) < 4:
        continue
    path = info[0]
    framework = path.split('/')[0].replace('.framework', '')
    if path == 'SELF' or framework in selected:
        out[command] = info
plistlib.dump(out, open(destination, 'wb'))
print(f"commands: {len(out)} / {len(d)}")
PY

echo "==> Mini terminal payload ready: $(du -sh "$APP/Frameworks" "$APP/WQResources" | tr '\n' ' ')"
