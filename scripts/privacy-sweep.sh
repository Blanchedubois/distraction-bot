#!/usr/bin/env bash
# The release gate's privacy sweep (PLAN_PUBLIC_RELEASE §2.3, §3.6): searches every file git would publish
# (tracked + untracked, minus .gitignore) for the author's identifiers and calendar secrets.
#   scripts/privacy-sweep.sh        → exit 1 on any hard hit; course-code warnings (P1 replaces them) never fail
# Run from anywhere; reads nothing outside the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Hard: the author's names, email, school, calendar id and secret-address shapes, home paths.
HARD='tejasvin ?shrikanth|balajee|shrikanth@|case\.edu|txs712|calendar\.google\.com/calendar/ical/[^ ]*/private-|private-[0-9a-f]{16,}|/Users/tejasvin'
# Allowed: the bundle id and launchd labels, kept on purpose (§5a Q4).
ALLOW='com\.tejasvin\.distraction-bot'
# Soft: real course codes still in fixtures and snapshot data until P1's demo set replaces them.
SOFT='MATH 305|PHYS 320|PHYS-320'

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard)
self="scripts/privacy-sweep.sh"

hard=0; soft=0; bytes=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  bytes=$(( bytes + $(stat -f %z "$f") ))
  [[ "$f" == "$self" ]] && continue
  file -b --mime "$f" | grep -q 'charset=binary' && continue
  while IFS= read -r line; do
    stripped=$(sed -E "s/$ALLOW//g" <<<"$line")
    if grep -qiE "$HARD" <<<"$stripped"; then echo "HARD  $f:$line" | cut -c1-200; hard=$((hard + 1)); fi
  done < <(grep -niE "$HARD" "$f" || true)
  n=$(grep -cE "$SOFT" "$f" || true)
  if [[ "$n" -gt 0 ]]; then echo "soft  $f: $n course-code line(s)"; soft=$((soft + n)); fi
done

big=$(for f in "${files[@]}"; do [[ -f "$f" ]] && [[ $(stat -f %z "$f") -gt 5000000 ]] && echo "$f"; done || true)
[[ -n "$big" ]] && { echo "HARD  files over 5 MB:"; echo "$big"; hard=$((hard + 1)); }

printf 'files %d · %.1f MB · hard %d · soft %d\n' "${#files[@]}" "$(bc -l <<<"$bytes/1048576")" "$hard" "$soft"
[[ $hard -eq 0 ]]
