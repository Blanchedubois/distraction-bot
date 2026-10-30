#!/usr/bin/env bash
# The checks CI runs on every push (PLAN_PUBLIC_RELEASE P5), and you can run before a pull request:
# the type lint, the privacy sweep, and every headless `*-check.swift` that needs no real data — each compiled from the `swiftc`
# line in its own header and run on the demo set (scripts/demo-data.swift). No app is opened; nothing outside a temp folder is written.
#   scripts/ci-checks.sh           → exit 1 if any check fails
#   scripts/ci-checks.sh --list    → the checks and their inputs
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d -t dbot-ci)"; trap 'rm -rf "$WORK"' EXIT
DEMO="$WORK/demo"
TODAY="$(date +%F)"

# check name → its arguments. Checks written against a copy of the author's own log (scoring, game) are left to local runs.
CHECKS=(
  "catcher|"
  "hud|"
  "kind-guess|"
  "shutdown|"
  "studyday|"
  "zoom|"
  "ics|"
  "week|$TODAY $DEMO/log.sqlite $DEMO/catalog.json --ics=docs/demo/calendar.ics"
  "planning|$DEMO/catalog.json $DEMO/log.sqlite docs/fixtures"
  "daymodel|$TODAY $DEMO/log.sqlite"
  "jumpbackin|$DEMO/catalog.json $DEMO/log.sqlite"
  "studyday-stats|$DEMO/log.sqlite"
)
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${CHECKS[@]}" | sed 's/|/  ← /'; exit 0; fi

fail=0
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
step "type lint";      scripts/type-lint.sh | tail -1 | grep -qx 0 && echo "  ✓ 0" || { echo "  ✗ type-lint"; scripts/type-lint.sh | tail -5; fail=1; }
step "privacy sweep";  scripts/privacy-sweep.sh | tail -1 | sed 's/^/  /' || true; scripts/privacy-sweep.sh >/dev/null || fail=1
step "demo data";      swiftc -o "$WORK/demo-data" scripts/demo-data.swift && "$WORK/demo-data" "$DEMO" | head -1 | sed 's/^/  /' || fail=1

for entry in "${CHECKS[@]}"; do
  name="${entry%%|*}"; args="${entry#*|}"
  src="scripts/$name-check.swift"
  step "$name-check"
  [[ -f "$src" ]] || { echo "  · no $src, skipped"; continue; }
  # the header's `//   swiftc … -o /tmp/<name>-check …` line, pointed at the temp folder
  line="$(grep -m1 -E '^//[[:space:]]+swiftc ' "$src" | sed -E 's#^//[[:space:]]+##; s#[[:space:]]+&&.*$##; s#[[:space:]]+\(.*$##' | sed "s#/tmp/#$WORK/#g")"
  [[ -n "$line" ]] || { echo "  ✗ no swiftc line in $src"; fail=1; continue; }
  if ! eval "$line" > "$WORK/$name.build" 2>&1; then echo "  ✗ does not compile"; grep -E ': error:' "$WORK/$name.build" | head -5; fail=1; continue; fi
  # shellcheck disable=SC2086
  if "$WORK/$name-check" $args > "$WORK/$name.out" 2>&1; then
    echo "  ✓ exit 0 · $(grep -cE '^[[:space:]]*(✓|PASS|ok)[[:space:]]' "$WORK/$name.out") lines passed"
  else
    rc=$?; echo "  ✗ exit $rc"; grep -E '✗|FAIL' "$WORK/$name.out" | head -8 | cut -c1-200; fail=1
  fi
done
echo
[[ $fail -eq 0 ]] && echo "✓ all checks passed" || echo "✗ some checks failed"
exit $fail
