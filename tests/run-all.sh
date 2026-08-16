#!/usr/bin/env bash
# Every test in this directory, one command, one exit code.
#
# This exists because the alternative had already started happening: two test
# files, each documenting its own invocation in a header comment, and nothing
# that ran either of them. A test nobody runs is not a gate — it is a record
# of what someone once checked. The point of a single entry point is that
# adding a file to tests/ is enough to make it part of the suite; nobody has
# to remember to register it anywhere.
#
#   tests/run-all.sh          exit 0 = every suite passed
#
# Each suite prints its own detail. This prints only the roll-up, so a green
# run is quiet and a red one names exactly which file to open.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

suites=()
while IFS= read -r f; do suites+=("$f"); done < <(ls -1 ./*.test.sh 2>/dev/null | sort)

if [ "${#suites[@]}" -eq 0 ]; then
  echo "tests/run-all.sh: no *.test.sh found — that is a broken checkout, not a pass" >&2
  exit 2
fi

failed=()
for s in "${suites[@]}"; do
  printf '\n──── %s ────\n' "${s#./}"
  if bash "$s"; then :; else failed+=("${s#./}"); fi
done

printf '\n════ %d suite(s) ════\n' "${#suites[@]}"
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all green"
  exit 0
fi
printf 'FAILED: %s\n' "${failed[*]}"
exit 1
