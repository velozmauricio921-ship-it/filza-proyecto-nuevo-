#!/bin/zsh
# Build both release artifacts:
#   build/filza_public.ipa
#   build/filza_develop.ipa
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build_public.sh" "$ROOT/build/filza_public.ipa"
"$ROOT/scripts/build_developer.sh" "$ROOT/build/filza_develop.ipa"

echo
echo "==> Release artifacts"
ls -lh "$ROOT/build/filza_public.ipa" "$ROOT/build/filza_develop.ipa"
shasum -a 256 "$ROOT/build/filza_public.ipa" "$ROOT/build/filza_develop.ipa"
