#!/usr/bin/env bash
# --done-marker must mean the same thing on both launchers.
#
# Field incident this pins (2026-08-18, three times in one session): a
# finished round whose report lacked the marker was recorded as
# done_marker=absent in both sentinels, but the *exit codes* disagreed —
# grok-run.sh downgraded rc=0 to 70, outsource-run.sh left rc=0. Watchers
# then announced the same fact as "failed with exit code 70" or "completed"
# depending on which sister they launched. 70 was already the documented
# model-identity failure, so the grok path also collided with that meaning.
#
# Asserted here:
#   - marker present  → rc stays 0, sentinel done_marker=found
#   - marker absent   → dedicated code 72, sentinel absent, stderr names
#                       the missing string and leaves the verdict on the tree
#   - both launchers emit that same code and the same-intent line
#   - 70 is still only the model-identity assertion (regression)
#
# Usage: tests/done-marker.test.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GROK_RUN="$HERE/skills/outsource/bin/grok-run.sh"
OUT_RUN="$HERE/skills/outsource/bin/outsource-run.sh"
[ -x "$GROK_RUN" ] || { echo "not executable: $GROK_RUN" >&2; exit 2; }
[ -x "$OUT_RUN" ]  || { echo "not executable: $OUT_RUN" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OUTSOURCE_RUNS_DIR="$TMP/runs"
export GROK_RUN_STARTUP_GRACE=10
export ZAI_API_KEY="test-key-not-a-real-credential"

MARKER="DONE-MARKER-CONTRACT"
# Shared payload both launchers must print on a missing marker (prefix may
# differ: grok-run.sh: vs outsource:). The test greps this, not a tone.
INTENT="the round finished but --done-marker '$MARKER' is absent; not claiming a pass (exit 72). Judge by the tree, not this exit code."

mkdir -p "$TMP/bin" "$TMP/cwd"
printf 'do the thing\n' > "$TMP/spec.md"

# Fake grok: writes one text event (what last-report.sh extracts) then exits 0.
cat > "$TMP/bin/grok" <<'FAKE'
#!/usr/bin/env bash
printf '{"type":"text","data":%s}\n' "$(python3 -c 'import json,os; print(json.dumps(os.environ.get("FAKE_GROK_TEXT","working, no marker")))')"
printf '{"type":"end","stopReason":"end_turn"}\n'
exit 0
FAKE
chmod +x "$TMP/bin/grok"

# Fake crush: stdout is the launcher log (outsource-run greps the log
# itself, not last-report.sh). `crush session last` is a post-round lookup
# the launcher ignores on failure.
cat > "$TMP/bin/crush" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "session" ]; then
  printf '%s\n' '{}'
  exit 0
fi
cat >/dev/null
printf '%s\n' "${FAKE_CRUSH_OUTPUT:-working, no marker}"
exit 0
FAKE
chmod +x "$TMP/bin/crush"

# Fake claude: a JSON result with modelUsage echoing the requested id and
# no session transcript — the unverifiable path that must stay exit 70.
cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"session_id":"sess-identity","usage":{"input_tokens":1},"total_cost_usd":0,"modelUsage":{"glm-5.3":{"inputTokens":1}}}'
exit 0
FAKE
chmod +x "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH"

pass=0
fail=0
note() { fail=$((fail + 1)); echo "FAIL  $*" >&2; }

# ── grok-run.sh ──────────────────────────────────────────────────────────

run_grok() {  # <label> <text-in-report>
  local label="$1"
  FAKE_GROK_TEXT="$2"
  export FAKE_GROK_TEXT
  LOG="$TMP/${label}.ndjson"
  rm -f "$LOG" "$LOG.rc"
  set +e
  GROK_ERR="$TMP/${label}.wrapper.err"
  bash "$GROK_RUN" --cwd "$TMP/cwd" --spec "$TMP/spec.md" --log "$LOG" \
    --label "$label" --done-marker "$MARKER" >"$TMP/${label}.out" 2>"$GROK_ERR"
  GROK_RC=$?
  set -e
}

run_grok "grok-found" "report body $MARKER tail"
if [ "$GROK_RC" -eq 0 ]; then
  grep -q '^done_marker=found$' "$LOG.rc" \
    || note "grok found: sentinel is not done_marker=found: $(cat "$LOG.rc")"
  pass=$((pass + 1))
else
  note "grok found: rc=$GROK_RC want=0; sentinel=$(cat "$LOG.rc" 2>/dev/null); err=$(cat "$GROK_ERR")"
fi

run_grok "grok-absent" "report body, no completion token"
if [ "$GROK_RC" -eq 72 ]; then
  grep -q '^done_marker=absent$' "$LOG.rc" \
    || note "grok absent: sentinel is not done_marker=absent: $(cat "$LOG.rc")"
  grep -qF -- "$INTENT" "$GROK_ERR" \
    || note "grok absent: stderr missing the shared intent line: $(cat "$GROK_ERR")"
  grep -qF -- "$MARKER" "$GROK_ERR" \
    || note "grok absent: stderr does not name the missing marker"
  pass=$((pass + 1))
else
  note "grok absent: rc=$GROK_RC want=72; sentinel=$(cat "$LOG.rc" 2>/dev/null); err=$(cat "$GROK_ERR")"
fi
GROK_ABSENT_RC=$GROK_RC
GROK_ABSENT_ERR="$(cat "$GROK_ERR")"

# ── outsource-run.sh (crush harness: no model-identity assertion) ────────

run_glm() {  # <label> <log-body>
  local label="$1"
  FAKE_CRUSH_OUTPUT="$2"
  export FAKE_CRUSH_OUTPUT
  LOG="$TMP/${label}.log"
  rm -f "$LOG" "$LOG.rc"
  set +e
  GLM_ERR="$TMP/${label}.wrapper.err"
  bash "$OUT_RUN" --cwd "$TMP/cwd" --spec "$TMP/spec.md" --log "$LOG" \
    --harness crush --label "$label" --done-marker "$MARKER" \
    --config-dir "$TMP/cfg-$label" >"$TMP/${label}.out" 2>"$GLM_ERR"
  GLM_RC=$?
  set -e
}

run_glm "glm-found" "crush log $MARKER tail"
if [ "$GLM_RC" -eq 0 ]; then
  grep -q '^done_marker=found' "$LOG.rc" \
    || note "glm found: sentinel is not done_marker=found: $(cat "$LOG.rc")"
  pass=$((pass + 1))
else
  note "glm found: rc=$GLM_RC want=0; sentinel=$(cat "$LOG.rc" 2>/dev/null); err=$(cat "$GLM_ERR")"
fi

run_glm "glm-absent" "crush log, no completion token"
if [ "$GLM_RC" -eq 72 ]; then
  grep -q '^done_marker=absent' "$LOG.rc" \
    || note "glm absent: sentinel is not done_marker=absent: $(cat "$LOG.rc")"
  grep -qF -- "$INTENT" "$GLM_ERR" \
    || note "glm absent: stderr missing the shared intent line: $(cat "$GLM_ERR")"
  grep -qF -- "$MARKER" "$GLM_ERR" \
    || note "glm absent: stderr does not name the missing marker"
  pass=$((pass + 1))
else
  note "glm absent: rc=$GLM_RC want=72; sentinel=$(cat "$LOG.rc" 2>/dev/null); err=$(cat "$GLM_ERR")"
fi
GLM_ABSENT_RC=$GLM_RC
GLM_ABSENT_ERR="$(cat "$GLM_ERR")"

# ── the round's core assertion: same code, same-intent line ──────────────
if [ "$GROK_ABSENT_RC" -eq 72 ] && [ "$GLM_ABSENT_RC" -eq 72 ] \
   && printf '%s' "$GROK_ABSENT_ERR" | grep -qF -- "$INTENT" \
   && printf '%s' "$GLM_ABSENT_ERR" | grep -qF -- "$INTENT"; then
  pass=$((pass + 1))
else
  note "parity: grok rc=$GROK_ABSENT_RC glm rc=$GLM_ABSENT_RC (want both 72 and the shared intent line)"
  echo "      grok stderr: $GROK_ABSENT_ERR" >&2
  echo "      glm  stderr: $GLM_ABSENT_ERR" >&2
fi

# ── 70 stays model-identity (unverifiable transcript) ────────────────────
ID_LOG="$TMP/identity.log"
rm -f "$ID_LOG" "$ID_LOG.rc"
set +e
bash "$OUT_RUN" --cwd "$TMP/cwd" --spec "$TMP/spec.md" --log "$ID_LOG" \
  --harness claude-code --label identity-70 --done-marker "$MARKER" \
  --config-dir "$TMP/cfg-identity" >"$TMP/identity.out" 2>"$TMP/identity.err"
ID_RC=$?
set -e
if [ "$ID_RC" -eq 70 ]; then
  grep -q 'MODEL ASSERTION FAILED' "$TMP/identity.err" \
    || note "identity 70: stderr does not name the model-identity failure: $(cat "$TMP/identity.err")"
  # Marker-absent must not steal 70. The sentinel may still record absent.
  [ "$ID_RC" -ne 72 ] || note "identity 70: marker path overwrote the assertion rc"
  pass=$((pass + 1))
else
  note "identity 70: rc=$ID_RC want=70; err=$(cat "$TMP/identity.err"); sentinel=$(cat "$ID_LOG.rc" 2>/dev/null)"
fi

# ── vision refusal copy (condition unchanged; wording must distinguish) ──
printf 'wire a capture harness; write frames/shot.png then decode pixels\n' > "$TMP/vision-spec.md"
set +e
bash "$OUT_RUN" --cwd "$TMP/cwd" --spec "$TMP/vision-spec.md" --log "$TMP/vision.log" \
  --label vision-copy --config-dir "$TMP/cfg-vision" \
  >"$TMP/vision.out" 2>"$TMP/vision.err"
VIS_RC=$?
set -e
if [ "$VIS_RC" -eq 65 ] \
   && grep -q -- '--no-vision-check' "$TMP/vision.err" \
   && grep -qi 'verdict' "$TMP/vision.err"; then
  pass=$((pass + 1))
else
  note "vision copy: rc=$VIS_RC want=65 plus --no-vision-check and a verdict/artifact distinction; err=$(cat "$TMP/vision.err")"
fi

echo "done-marker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
