#!/usr/bin/env bash
# Assemble "Distraction Bot.app" from the SwiftPM build. No Xcode needed (Ledger's script).
#   scripts/bundle.sh            → dist/Distraction Bot.app (release build)
#   scripts/bundle.sh install    → also copies to /Applications
# Signs with "Distraction Bot Dev" when it exists (scripts/make-dev-cert.sh) so the
# Accessibility and Screen Recording grants survive rebuilds; otherwise ad-hoc.
# For scripts/release.sh: DBOT_DIST=<dir> builds there instead of dist/, DBOT_VERSION=0.1.0 sets the version,
# DBOT_SIGN=adhoc signs ad-hoc even when the dev identity exists (a release is never signed with your local identity).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DBOT_DIST:-$ROOT/dist}"
VERSION="${DBOT_VERSION:-0.1}"
APP="$DIST/Distraction Bot.app"
SYMBOL="${DBOT_ICON_SYMBOL:-shield.lefthalf.filled}"
cd "$ROOT"
mkdir -p "$DIST"
echo "→ building release"
if ! swift build -c release > "$DIST/last-build.log" 2>&1; then grep -E "error:" "$DIST/last-build.log" | sort -u | head -12; echo "build FAILED"; exit 1; fi
BIN="$ROOT/.build/release/DistractionBot"
RES_BUNDLE="$ROOT/.build/release/DistractionBot_DistractionBot.bundle"
if [[ ! -f "$DIST/AppIcon.icns" || scripts/icon.swift -nt "$DIST/AppIcon.icns" ]]; then
  echo "→ icon ($SYMBOL)"
  mkdir -p "$DIST/icon.iconset"
  swift "$ROOT/scripts/icon.swift" "$DIST/icon-1024.png" "$SYMBOL" >/dev/null
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$DIST/icon-1024.png" --out "$DIST/icon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$DIST/icon-1024.png" --out "$DIST/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$DIST/icon.iconset" -o "$DIST/AppIcon.icns"
  rm -rf "$DIST/icon.iconset" "$DIST/icon-1024.png"
fi
echo "→ bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DistractionBot"
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Distraction Bot</string>
  <key>CFBundleDisplayName</key><string>Distraction Bot</string>
  <key>CFBundleIdentifier</key><string>com.tejasvin.distraction-bot</string>
  <key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>DistractionBot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSAppleEventsUsageDescription</key><string>Distraction Bot redirects a blocked Safari tab during a focus session.</string>
  <key>NSHumanReadableCopyright</key><string>Local-first. Nothing leaves this Mac.</string>
</dict></plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"
if [[ "${DBOT_SIGN:-}" != "adhoc" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Distraction Bot Dev"'; then
  codesign --force --deep --sign "Distraction Bot Dev" --timestamp=none "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "signed: Distraction Bot Dev"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  if [[ "${DBOT_SIGN:-}" == "adhoc" ]]; then echo "signed: ad-hoc"; else echo "signed: ad-hoc (run scripts/make-dev-cert.sh once to keep the permission grants across builds)"; fi
fi
echo "✓ $APP"
if [[ "${1:-}" == "install" ]]; then
  rm -rf "/Applications/Distraction Bot.app"; cp -R "$APP" /Applications/; echo "✓ installed to /Applications/Distraction Bot.app"
fi
