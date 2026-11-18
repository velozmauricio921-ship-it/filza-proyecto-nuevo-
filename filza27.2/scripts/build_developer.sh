#!/bin/zsh
# Build the developer Filza 27.2 IPA: public features plus the full terminal,
# apt/dpkg, SSH server, mount, archive extraction and respring.
#
# Required environment:
#   BASE_IPA       path to FilzaSlop-v1.2.0-unsigned.ipa
#   ASHELL_IPA     path to a signed/unsigned a-Shell IPA that supplies the
#                  command frameworks and resources
#   WQ_APP_GROUPS  at least one App Group from the signing profile
# Optional:
#   PROFILE, ENTITLEMENTS, SIGN_IDENTITY, KEYCHAIN
#   BUNDLE_ID (default com.jbjf.filzanb)
#   APP_DISPLAY_NAME (default filza27.2)
set -euo pipefail

ROOT="${0:A:h:h}"
BASE_IPA="${BASE_IPA:-$ROOT/base/FilzaSlop-v1.2.0-unsigned.ipa}"
OUTPUT="${1:-$ROOT/build/filza_develop.ipa}"
export BUNDLE_ID="${BUNDLE_ID:-com.jbjf.filzanb}"
export APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-filza27.2}"
export FILZASLOP_VERSION="${FILZASLOP_VERSION:-wq-27.2-developer}"
export WQ_TERMINAL=full
export ASHELL_IPA="${ASHELL_IPA:-$HOME/Downloads/Terminal.ipa}"
: "${WQ_APP_GROUPS:?set WQ_APP_GROUPS to the App Group(s) in your profile}"
[[ -f "$ASHELL_IPA" ]] || {
  echo "a-Shell IPA not found: $ASHELL_IPA" >&2
  echo "Set ASHELL_IPA to a-Shell (or a-Shell mini) IPA." >&2
  exit 66
}

mkdir -p "${OUTPUT:h}"
exec "$ROOT/scripts/build_wq_ipa.sh" "$BASE_IPA" "$OUTPUT"
