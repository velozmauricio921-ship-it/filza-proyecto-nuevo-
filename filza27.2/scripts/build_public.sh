#!/bin/zsh
# Build the public Filza 27.2 IPA (no terminal, SSH server or package CLI).
#
# Required environment:
#   BASE_IPA       path to FilzaSlop-v1.2.0-unsigned.ipa
#   WQ_APP_GROUPS  at least one App Group from the signing profile
# Optional:
#   PROFILE, ENTITLEMENTS, SIGN_IDENTITY, KEYCHAIN
#   BUNDLE_ID (default com.jbjf.filza)
#   APP_DISPLAY_NAME (default filza27.2)
set -euo pipefail

ROOT="${0:A:h:h}"
BASE_IPA="${BASE_IPA:-$ROOT/base/FilzaSlop-v1.2.0-unsigned.ipa}"
OUTPUT="${1:-$ROOT/build/filza_public.ipa}"
export BUNDLE_ID="${BUNDLE_ID:-com.jbjf.filza}"
export APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-filza27.2}"
export FILZASLOP_VERSION="${FILZASLOP_VERSION:-wq-27.2-public}"
: "${WQ_APP_GROUPS:?set WQ_APP_GROUPS to the App Group(s) in your profile}"
unset WQ_TERMINAL

mkdir -p "${OUTPUT:h}"
exec "$ROOT/scripts/build_wq_ipa.sh" "$BASE_IPA" "$OUTPUT"
