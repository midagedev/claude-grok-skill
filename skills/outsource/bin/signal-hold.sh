# signal-hold.sh — sourced by the launchers (grok-run.sh, outsource-run.sh).
#
# A launcher's job after the child starts is paperwork: wait, then write the
# sentinel and close the registry entry. That paperwork is the only record a
# watcher has, so a signal to the *wrapper* must never destroy it. The field
# incident (twice in one week, 2026-08-17): a caller's timeout SIGTERMed the
# foreground wrapper, the child round survived and finished correctly, and
# the sentinel writer died with the wrapper — every watcher keyed on the
# `.rc` file waited on a round that had already delivered.
#
# So: TERM/INT/HUP mean "hold and finish the paperwork", not "abandon it".
# The child is deliberately NOT forwarded the signal — the observed incident
# is a healthy round outliving a disposable wrapper, and forwarding would
# turn a caller's bookkeeping timeout into a round kill. To abort a round,
# kill the child pid itself (runs.sh shows it); a terminal Ctrl-C already
# reaches the child through the foreground process group.
#
# SIGKILL cannot be held; the launcher's EXIT-trap last resort does not run
# for it either. That residue is accepted and documented here.

WRAPPER_SIGNAL=""

# hold_signals — install the hold. Call once, before launching the child.
hold_signals() {
  trap 'WRAPPER_SIGNAL=TERM' TERM
  trap 'WRAPPER_SIGNAL=INT'  INT
  trap 'WRAPPER_SIGNAL=HUP'  HUP
}

# await_child <pid> — wait to the child's REAL exit, surviving trapped-signal
# interrupts (a trapped signal makes `wait` return 128+sig with the child
# still running). Sets AWAIT_RC to the child's status. Must run in the main
# shell — `wait` cannot see the child from a command-substitution subshell.
AWAIT_RC=0
await_child() {
  local pid="$1"
  while :; do
    wait "$pid"
    AWAIT_RC=$?
    kill -0 "$pid" 2>/dev/null || return 0
  done
}
