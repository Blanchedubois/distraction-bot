#!/usr/bin/env bash
# The README's images (PLAN_PUBLIC_RELEASE P2): every shot rendered offscreen from the invented demo set (docs/demo), never from your data.
#   scripts/readme-shots.sh            → docs/images/*.png + end-card.gif, trimmed, ≤ 1600 px wide, compressed
#   scripts/readme-shots.sh home       → only the shots whose name starts with "home"
# Needs: swift, ffmpeg (the GIF), python3 with Pillow (trim + compress). Writes nothing under ~/Library/Application Support.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ONLY="${1:-}"
OUT="$ROOT/docs/images"
WORK="$(mktemp -d -t dbot-shots)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

echo "→ build"
swift build 2>&1 | grep -E ': error:' && exit 1 || true
BIN="$ROOT/.build/debug/DistractionBot"
echo "→ demo data"
swiftc -o "$WORK/demo-data" scripts/demo-data.swift
"$WORK/demo-data" "$WORK/demo" | sed 's/^/  /'

# The demo's ids are fixed by the generator's counter: CS 150 is …001, its "Problem set 5 — heaps" …003.
CS150="DE300000-0000-4000-8000-000000000001"
PSET5="DE300000-0000-4000-8000-000000000003"

# The shipped model choices, whatever this Mac's own defaults say (argument-domain defaults are read, never saved).
DEFAULTS=(-dbot.judgeModel qwen3:14b -dbot.visionModel qwen2.5vl:3b)

# shot <name> <trim|full|top:<px>> [ENV=value …]: one render at 2×, then trimmed or cropped and compressed by post().
shot() {
  local name="$1" mode="$2"; shift 2
  [[ -n "$ONLY" && "$name" != "$ONLY"* ]] && return 0
  cp "$WORK/demo/catalog.json" "$WORK/catalog.json"; cp "$WORK/demo/log.sqlite" "$WORK/log.sqlite"   # a render may write rows; each starts clean
  rm -f "$WORK/session.json" "$WORK/queue.json" "$WORK/prefs.json" "$WORK/settings.json"
  env DBOT_NAME=Sam DBOT_CATALOG_PATH="$WORK/catalog.json" DBOT_LOG_PATH="$WORK/log.sqlite" DBOT_SESSION_PATH="$WORK/session.json" \
      DBOT_QUEUE_PATH="$WORK/queue.json" DBOT_PREFS_PATH="$WORK/prefs.json" DBOT_RULES_PATH="$WORK/settings.json" \
      DBOT_SNAPSHOT_ICS="$ROOT/docs/demo/calendar.ics" DBOT_SNAPSHOT="$WORK/$name.png" "$@" "$BIN" "${DEFAULTS[@]}" >/dev/null 2>&1 || true
  [[ -f "$WORK/$name.png" ]] || { echo "  ✗ $name: no image"; return 1; }
  [[ "$name" == end-card-f* ]] && return 0   # GIF frames are processed together below
  post "$WORK/$name.png" "$OUT/$name.png" "$mode"
}

# post <in> <out> <mode>: trim to the content (overlays), crop to a height (top:<px> at 2×), or keep; scale to ≤ 1600 px; palette-compress when > 400 kB.
post() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
from PIL import Image, ImageChops
src, dst, mode = sys.argv[1:4]
im = Image.open(src).convert("RGB")
if mode == "trim":
    bg = Image.new("RGB", im.size, im.getpixel((2, 2)))
    diff = ImageChops.difference(im, bg).convert("L").point(lambda v: 255 if v > 6 else 0)
    box = diff.getbbox()
    if box:
        m = 48
        im = im.crop((max(0, box[0] - m), max(0, box[1] - m), min(im.width, box[2] + m), min(im.height, box[3] + m)))
elif mode.startswith("top:"):
    im = im.crop((0, 0, im.width, min(im.height, int(mode[4:]))))
if im.width > 1600:
    im = im.resize((1600, round(im.height * 1600 / im.width)), Image.LANCZOS)
im.save(dst, optimize=True)
import os
if os.path.getsize(dst) > 400_000:
    im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(dst, optimize=True)
print(f"  ✓ {os.path.basename(dst)} {im.width}×{im.height} {os.path.getsize(dst) // 1024} kB")
PY
}

echo "→ screens"
shot home            top:2300 DBOT_SNAPSHOT_TAB=home
shot home-dark       top:2300 DBOT_SNAPSHOT_TAB=home DBOT_APPEARANCE=dark
shot subjects        top:760  DBOT_SNAPSHOT_TAB=subjects
shot course          full     DBOT_SNAPSHOT_TAB=subjects DBOT_SNAPSHOT_OPEN="subject:$CS150" DBOT_SNAPSHOT_HEIGHT=1640
shot calendar        full     DBOT_SNAPSHOT_TAB=calendar DBOT_SNAPSHOT_HEIGHT=1300
shot progress        top:1340 DBOT_SNAPSHOT_TAB=progress
shot rules           top:740  DBOT_SNAPSHOT_TAB=rules
shot judge           top:1800 DBOT_SNAPSHOT_TAB=judge
shot settings        top:1700 DBOT_SNAPSHOT_TAB=settings
echo "→ overlays"
shot mini-panel      trim     DBOT_SNAPSHOT_VIEW=mini-panel DBOT_SNAPSHOT_SESSION=x DBOT_SNAPSHOT_OBJECTIVE="$PSET5" DBOT_SNAPSHOT_EXPANDED=1
shot banner          trim     DBOT_SNAPSHOT_VIEW=banner
shot shield          trim     DBOT_SNAPSHOT_VIEW=shield
shot end-card        trim     DBOT_SNAPSHOT_VIEW=end-card
shot closing         trim     DBOT_SNAPSHOT_VIEW=closing

if [[ -z "$ONLY" || "end-card.gif" == "$ONLY"* ]]; then
  echo "→ end-card.gif (frames 0…6)"
  for f in 0 1 2 3 4 5 6; do shot "end-card-f$f" trim DBOT_SNAPSHOT_VIEW=end-card DBOT_SNAPSHOT_FRAME=$f; done
  # one crop box for every frame (the union of their content), so the card doesn't jump; the last frame holds
  python3 -I - "$WORK" <<'PY'
import sys, glob
from PIL import Image, ImageChops
w = sys.argv[1]
frames = [Image.open(f"{w}/end-card-f{i}.png").convert("RGB") for i in range(7)]
box = None
for im in frames:
    bg = Image.new("RGB", im.size, im.getpixel((2, 2)))
    b = ImageChops.difference(im, bg).convert("L").point(lambda v: 255 if v > 6 else 0).getbbox()
    box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
m = 48
for i, im in enumerate(frames):
    c = im.crop((max(0, box[0] - m), max(0, box[1] - m), min(im.width, box[2] + m), min(im.height, box[3] + m)))
    c.resize((c.width // 2 * 2 // 2, c.height // 2 * 2 // 2), Image.LANCZOS).save(f"{w}/gif-{i}.png")
PY
  # 0.9 s a beat, the settled card for 3 s
  { for i in 0 1 2 3 4 5; do echo "file '$WORK/gif-$i.png'"; echo "duration 0.9"; done; echo "file '$WORK/gif-6.png'"; echo "duration 3"; echo "file '$WORK/gif-6.png'"; } > "$WORK/gif.txt"
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$WORK/gif.txt" -vf "split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none" -loop 0 "$OUT/end-card.gif"
  echo "  ✓ end-card.gif $(( $(stat -f %z "$OUT/end-card.gif") / 1024 )) kB"
fi

total=$(du -sk "$OUT" | cut -f1)
echo "✓ docs/images · $(ls "$OUT" | wc -l | tr -d ' ') files · $((total / 1024)).$(( (total % 1024) * 10 / 1024 )) MB"
