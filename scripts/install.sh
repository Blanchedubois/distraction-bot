#!/usr/bin/env bash
# Build from source and install (PLAN_PUBLIC_RELEASE P3, §3.3 path B).
#   git clone … && cd distraction-bot && scripts/install.sh
#   scripts/install.sh --dry-run    → checks this Mac and builds dist/Distraction Bot.app, changes nothing else
#   scripts/install.sh --yes        → answers yes to every question (the signing identity, Ollama, opening the app)
# What it touches: dist/, your login keychain (only if you agree to the signing identity), /Applications/Distraction Bot.app.
# It never writes to ~/Library/Application Support/Distraction Bot — your courses, sessions and settings stay as they are.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="Distraction Bot"
DEST="/Applications/$APP_NAME.app"

DRY=0; YES=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; --yes|-y) YES=1 ;; -h|--help) sed -n 2,8p "$0"; exit 0 ;; *) echo "unknown option $a"; exit 2 ;; esac; done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*"; exit 1; }
# ask "question" default(y|n) → 0 for yes. --yes says yes; --dry-run asks nothing and says what it would do.
ask() {
  local q="$1" def="$2" hint="[Y/n]"; [[ "$def" == n ]] && hint="[y/N]"
  [[ $YES -eq 1 ]] && return 0
  [[ ! -t 0 ]] && { [[ "$def" == y ]]; return; }
  read -r -p "  $q $hint " r || true
  r="${r:-$def}"; [[ "$r" =~ ^[Yy] ]]
}

say "1/5  This Mac"
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 15 ]] || die "macOS 15 or later is needed; this Mac has $(sw_vers -productVersion)."
ok "macOS $(sw_vers -productVersion)"
if [[ "$(uname -m)" == "arm64" ]]; then ok "Apple silicon"; else warn "Intel Mac: the app builds, but the local judge models run slowly (Apple silicon is recommended)."; fi
if ! command -v swift >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  warn "No Swift toolchain. The Xcode Command Line Tools provide it (about 1 GB, no Xcode needed)."
  if [[ $DRY -eq 1 ]]; then die "would run: xcode-select --install"; fi
  if ask "Install the Command Line Tools now? A macOS dialog will open." y; then
    xcode-select --install || true
    die "Finish the Command Line Tools dialog, then run scripts/install.sh again."
  fi
  die "Swift is needed to build from source. Or download the ready-made app from the Releases page."
fi
sv="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)"
read -r smaj smin <<<"${sv:-0 0}"
[[ "$smaj" -ge 6 ]] || die "Swift 6.0 or later is needed; found ${smaj}.${smin}. Update the Command Line Tools (softwareupdate --list)."
ok "Swift $smaj.$smin"

say "2/5  Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Distraction Bot Dev"'; then
  ok "\"Distraction Bot Dev\" identity found — permission grants survive rebuilds"
elif [[ $DRY -eq 1 ]]; then
  ok "would offer scripts/make-dev-cert.sh (a self-signed identity in your login keychain)"
else
  echo "  A local signing identity keeps macOS's Accessibility and Screen Recording grants when you rebuild."
  echo "  Without it every build is signed ad-hoc and you grant both permissions again after each update."
  if ask "Create the \"Distraction Bot Dev\" identity? macOS may ask for your login password once." y; then
    "$ROOT/scripts/make-dev-cert.sh" || warn "the identity was not created; building ad-hoc"
  else warn "building ad-hoc"; fi
fi

say "3/5  Build"
"$ROOT/scripts/bundle.sh" | sed 's/^/  /'
BUILT="$ROOT/dist/$APP_NAME.app"
[[ -d "$BUILT" ]] || die "the build did not produce $BUILT"

say "4/5  Install to /Applications"
if [[ $DRY -eq 1 ]]; then
  pgrep -qf "$DEST/Contents/MacOS/DistractionBot" && ok "would quit the running app first (gracefully)"
  ok "would replace $DEST"
else
  if pgrep -qf "$DEST/Contents/MacOS/DistractionBot"; then
    echo "  Distraction Bot is running. It will be quit to replace it (a session in progress is saved and resumes)."
    ask "Quit it now?" y || die "Not installed. Quit the app and run this again."
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -qf "$DEST/Contents/MacOS/DistractionBot" || break; sleep 0.5; done
    pgrep -qf "$DEST/Contents/MacOS/DistractionBot" && die "The app did not quit — a hard-mode session refuses to. End the session, then run this again."
    ok "quit"
  fi
  rm -rf "$DEST"
  cp -R "$BUILT" "$DEST"
  ok "installed $DEST"
fi

say "5/5  The judge (Ollama)"
if [[ $DRY -eq 1 ]]; then
  "$ROOT/scripts/setup-ollama.sh" --dry-run | sed 's/^/  /'
elif ask "Set up Ollama and the judge's models now? (downloads 5–12 GB)" y; then
  "$ROOT/scripts/setup-ollama.sh" $([[ $YES -eq 1 ]] && echo --yes) || warn "Ollama setup did not finish; run scripts/setup-ollama.sh later. Blocking works without it."
else
  warn "skipped — blocking works without the judge; run scripts/setup-ollama.sh any time"
fi

echo
if [[ $DRY -eq 1 ]]; then say "Dry run finished — nothing outside dist/ was changed."; exit 0; fi
say "Done."
echo "  First open: grant Accessibility and Screen Recording in the app's Settings → Permissions,"
echo "  then quit and reopen it when macOS asks. INSTALL.md walks through it."
if ask "Open Distraction Bot now?" y; then open -a "$DEST"; fi
