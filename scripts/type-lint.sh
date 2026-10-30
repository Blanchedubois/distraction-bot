#!/bin/sh
# PLAN_DESIGN_CLEANUP §3.3: counts raw type and spacing numbers outside Design/Type.swift.
# Flags: Theme.display/title/body/mono( calls, .font(.system(size:, .padding(<n>) and .padding(.edge, <n>), spacing: <n>.
# Negative paddings (layout fudges), spacing: 0 and lines marked `lint-ok` (a glyph sized by its container) are allowed. Usage: scripts/type-lint.sh [file...]  (default: all of Sources)
cd "$(dirname "$0")/.." || exit 1
files="$*"; [ -z "$files" ] && files=$(find Sources -name '*.swift' | grep -v 'Design/Type.swift' | sort)
total=0
for f in $files; do
  n=$(grep -v 'lint-ok' "$f" | grep -cE 'Theme\.(display|title|body|mono)\(|\.font\(\.system\(size:|\.padding\(([0-9]|\.(horizontal|vertical|top|bottom|leading|trailing), *[0-9])|spacing: *[1-9]' )
  [ "$n" -gt 0 ] && printf '%4d  %s\n' "$n" "$f"
  total=$((total + n))
done
echo "$total"
