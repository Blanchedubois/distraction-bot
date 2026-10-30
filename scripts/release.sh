#!/usr/bin/env bash
# A downloadable release (PLAN_PUBLIC_RELEASE P3, §3.3 path A): an ad-hoc signed, Apple-silicon app, zipped, with its SHA-256.
#   scripts/release.sh 0.1.0            → dist/release/Distraction-Bot-0.1.0.zip + SHA256SUMS
#   scripts/release.sh                  → the version from the current git tag (v0.1.0 → 0.1.0)
#   scripts/release.sh 0.1.0 --dry-run  → says what it would build, builds nothing
# Never signs with your local "Distraction Bot Dev" identity, never touches dist/Distraction Bot.app or /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY=0; VERSION=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; -*) echo "unknown option $a"; exit 2 ;; *) VERSION="$a" ;; esac; done
if [[ -z "$VERSION" ]]; then VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"; fi
[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <version> [--dry-run]   (or run it on a v<version> tag)"; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 0.1.0, got $VERSION"; exit 2; }

OUT="$ROOT/dist/release"
STAGE="$OUT/stage-$VERSION"
ZIP="$OUT/Distraction-Bot-$VERSION.zip"
if [[ $DRY -eq 1 ]]; then
  echo "would build: release, ad-hoc signed, version $VERSION, $(uname -m)"
  echo "would write: $ZIP and $OUT/SHA256SUMS"
  exit 0
fi

rm -rf "$STAGE"; mkdir -p "$STAGE"
DBOT_DIST="$STAGE" DBOT_VERSION="$VERSION" DBOT_SIGN=adhoc "$ROOT/scripts/bundle.sh"
APP="$STAGE/Distraction Bot.app"
codesign --verify --deep --strict "$APP"
echo "→ zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
( cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS )
rm -rf "$STAGE"
echo "✓ $ZIP ($(( $(stat -f %z "$ZIP") / 1024 / 1024 )) MB)"
cat "$OUT/SHA256SUMS"
