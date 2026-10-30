#!/usr/bin/env bash
# The judge's local models (PLAN_PUBLIC_RELEASE P3, §3.3): checks Ollama, picks a judge model this Mac's memory can run, pulls it
# and the small vision model, and tells the app which judge to use.
#   scripts/setup-ollama.sh            → asks before each download
#   scripts/setup-ollama.sh --dry-run  → says what it would pull and set, changes nothing
#   scripts/setup-ollama.sh --yes      → no questions
#   DBOT_RAM_GB=16 scripts/setup-ollama.sh --dry-run   → as if this Mac had 16 GB
# Writes one setting: `defaults write com.tejasvin.distraction-bot dbot.judgeModel <model>` (the Judge page can change it later).
# Never installs Ollama itself or removes a model.
set -euo pipefail
DRY=0; YES=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; --yes|-y) YES=1 ;; -h|--help) sed -n 2,10p "$0"; exit 0 ;; *) echo "unknown option $a"; exit 2 ;; esac; done
DOMAIN="com.tejasvin.distraction-bot"
API="${DBOT_OLLAMA:-http://localhost:11434}"
VISION="qwen2.5vl:3b"

ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
ask()  { [[ $YES -eq 1 ]] && return 0; [[ ! -t 0 ]] && return 1; read -r -p "  $1 [Y/n] " r || true; [[ "${r:-y}" =~ ^[Yy] ]]; }

# The judge by memory: the 14B model judged the test desk best, but it wants ~10 GB free while you work.
ram="${DBOT_RAM_GB:-$(( $(sysctl -n hw.memsize) / 1073741824 ))}"
if   [[ "$ram" -ge 32 ]]; then JUDGE="qwen3:14b"; size="9.3 GB"; note="the most accurate"
elif [[ "$ram" -ge 16 ]]; then JUDGE="qwen3:8b";  size="5.2 GB"; note="a good balance for $ram GB"
else                           JUDGE="qwen3:4b";  size="2.6 GB"; note="the lightest; on $ram GB judging is slower and rougher"
fi
echo "This Mac: $ram GB memory → judge $JUDGE ($size, $note) + vision $VISION (3.2 GB, the occasional look at the screen)"

# Ollama present and running?
have_cli=0; command -v ollama >/dev/null 2>&1 && have_cli=1
have_app=0; [[ -d /Applications/Ollama.app ]] && have_app=1
if [[ $have_cli -eq 0 && $have_app -eq 0 ]]; then
  warn "Ollama is not installed. Get it from https://ollama.com/download (or: brew install --cask ollama), open it once, then run this again."
  [[ $DRY -eq 1 ]] && { warn "dry run: would stop here"; exit 0; }
  exit 1
fi
ok "Ollama installed"
running=0; curl -fsS --max-time 3 "$API/api/tags" >/dev/null 2>&1 && running=1
if [[ $running -eq 0 ]]; then
  if [[ $DRY -eq 1 ]]; then warn "Ollama is not running — would ask to open it"
  elif [[ $have_app -eq 1 ]] && ask "Ollama is not running. Open it?"; then
    open -ga Ollama
    for _ in $(seq 1 30); do curl -fsS --max-time 2 "$API/api/tags" >/dev/null 2>&1 && { running=1; break; }; sleep 1; done
    [[ $running -eq 1 ]] || { warn "Ollama did not answer on $API within 30 s"; exit 1; }
  else
    warn "start Ollama (open the app, or run: ollama serve) and run this again"; exit 1
  fi
fi
[[ $running -eq 1 ]] && ok "Ollama answering on $API"

installed=""; [[ $running -eq 1 ]] && installed="$(curl -fsS --max-time 5 "$API/api/tags" | tr ',' '\n' | sed -nE 's/.*"name":"([^"]+)".*/\1/p')"
pull() {
  local m="$1" sz="$2"
  if grep -qx "$m" <<<"$installed"; then ok "$m already pulled"; return; fi
  if [[ $DRY -eq 1 ]]; then ok "would pull $m ($sz)"; return; fi
  ask "Download $m ($sz)?" || { warn "skipped $m"; return; }
  if [[ $have_cli -eq 1 ]]; then ollama pull "$m"
  else curl -fsS -N "$API/api/pull" -d "{\"name\":\"$m\"}" | tr ',' '\n' | grep -o '"status":"[^"]*"' | uniq; fi
  ok "$m pulled"
}
pull "$JUDGE" "$size"
pull "$VISION" "3.2 GB"

current="$(defaults read "$DOMAIN" dbot.judgeModel 2>/dev/null || true)"
if [[ "$current" == "$JUDGE" ]]; then
  ok "the app's judge is already $JUDGE"
elif [[ -n "$current" ]]; then
  ok "the app's judge is already set to $current — left as it is (change it on the Judge page)"
elif [[ $DRY -eq 1 ]]; then ok "would set the app's judge to $JUDGE"
else defaults write "$DOMAIN" dbot.judgeModel "$JUDGE"; ok "the app's judge is $JUDGE"
fi
echo "Done. The app's header shows \"judge ready\" when it can reach the model."
