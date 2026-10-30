#!/usr/bin/env bash
# Remove Distraction Bot (PLAN_PUBLIC_RELEASE P3, §3.3).
#   scripts/uninstall.sh            → removes the app, its login item and the hard-mode guard; asks before anything of yours
#   scripts/uninstall.sh --dry-run  → lists what it would remove, removes nothing
# Your courses, sessions and settings are kept unless you answer yes to deleting them. Ollama and its models are never touched.
set -euo pipefail
DRY=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; -h|--help) sed -n 2,6p "$0"; exit 0 ;; *) echo "unknown option $a"; exit 2 ;; esac; done
APP_NAME="Distraction Bot"
APP="/Applications/$APP_NAME.app"
ID="com.tejasvin.distraction-bot"
AGENTS="$HOME/Library/LaunchAgents"
DATA="$HOME/Library/Application Support/$APP_NAME"
LOGS="$HOME/Library/Logs/$APP_NAME"

ok()   { printf '  ✓ %s\n' "$*"; }
would(){ printf '  · would %s\n' "$*"; }
ask()  { [[ ! -t 0 ]] && return 1; read -r -p "  $1 [y/N] " r || true; [[ "${r:-n}" =~ ^[Yy] ]]; }
# run <description> <command…>: does it, or says it would.
run()  { local d="$1"; shift; if [[ $DRY -eq 1 ]]; then would "$d"; else "$@" >/dev/null 2>&1 || true; ok "$d"; fi; }

echo "The app, its login item and the hard-mode guard"
# the guard first: while it is loaded it brings the app back after a quit
for label in "$ID.guard" "$ID"; do
  plist="$AGENTS/$label.plist"
  if [[ -f "$plist" ]]; then
    run "unload $label" launchctl bootout "gui/$(id -u)/$label"
    run "remove $plist" rm -f "$plist"
  fi
done
if pgrep -qf "$APP/Contents/MacOS/DistractionBot"; then
  if [[ $DRY -eq 1 ]]; then would "quit the running app"
  else
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -qf "$APP/Contents/MacOS/DistractionBot" || break; sleep 0.5; done
    if pgrep -qf "$APP/Contents/MacOS/DistractionBot"; then echo "  ✗ the app refused to quit (a hard-mode session?). End the session, then run this again."; exit 1; fi
    ok "quit the app"
  fi
fi
[[ -d "$APP" ]] && run "delete $APP" rm -rf "$APP"
[[ -f "$DATA/guard.sh" ]] && run "remove the guard script" rm -f "$DATA/guard.sh"

echo
echo "Yours — kept unless you say so"
if [[ -d "$DATA" ]]; then
  echo "  $DATA — your courses, objectives, sessions, rules and settings ($(du -sh "$DATA" | cut -f1))"
  if [[ $DRY -eq 1 ]]; then would "ask before deleting it (default: keep)"
  elif ask "Delete it? This cannot be undone."; then rm -rf "$DATA"; ok "deleted"; else ok "kept"; fi
fi
if [[ -d "$LOGS" ]]; then
  if [[ $DRY -eq 1 ]]; then would "ask before deleting the logs in $LOGS (default: keep)"
  elif ask "Delete the logs in $LOGS?"; then rm -rf "$LOGS"; ok "deleted"; else ok "kept"; fi
fi
if defaults read "$ID" >/dev/null 2>&1; then
  if [[ $DRY -eq 1 ]]; then would "ask before deleting the app's preferences (defaults domain $ID, default: keep)"
  elif ask "Delete the app's preferences (the judge model, window size)?"; then defaults delete "$ID"; ok "deleted"; else ok "kept"; fi
fi

echo
echo "Left for you to remove by hand, if you want"
echo "  · the permission entries: System Settings → Privacy & Security → Accessibility and Screen Recording → select Distraction Bot → −"
security find-identity -v -p codesigning 2>/dev/null | grep -q '"Distraction Bot Dev"' && \
  echo "  · the signing identity \"Distraction Bot Dev\": Keychain Access → login → My Certificates (only if you built from source)"
echo "  · Ollama and its models: ollama rm qwen3:14b (or the model you pulled) · the Ollama app from /Applications"
[[ $DRY -eq 1 ]] && echo && echo "Dry run — nothing was removed."
exit 0
