#!/usr/bin/env bash
# Supervisor loop command. The supervisor runs the tests; workers never do.
#   - PASS  -> applies the codex second-opinion policy (advisory by default), then reports
#              ready-to-land. High-severity codex concerns may consume a bounded feedback
#              round (exit 7) instead — see codex_gate_policy in lib.sh.
#   - FAIL  -> writes the failure log into the worker's feedback.md and nudges the worker.
#   ./control/verify.sh <task>
# NOTE: lib.sh runs `set -euo pipefail`, which RE-ENABLES -e here even though this script
# opens with `set -uo pipefail`. So a bare failing pipeline (`gate | tee`) would abort the
# script before the FAIL-routing below runs (this was bug D1: the feedback path was dead
# code). Keep every fallible command inside an `if`/`||` so -e cannot kill the FAIL branch.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: verify.sh <task>}"
[ -f "$STATE_DIR/$TASK.env" ] || die "unknown task '$TASK'"
source "$STATE_DIR/$TASK.env"
HD="$(harness_dir "$TASK")"

# Route text back to the worker: feedback.md (out-of-tree state — a plain host file in v3) via
# the merge-aware single choke point (lib.sh feedback_route — unaddressed feedback is appended
# to, never erased), then nudge its Claude. Delivery is guaranteed by the SessionStart/stop-gate
# hooks even when the nudge is dropped.
route_feedback() { # stdin -> feedback.md
  feedback_route "$TASK"
}
nudge() {
  if agent_send "$TASK" "Read $HD/feedback.md — the supervisor's checks failed on your branch. Fix the issues, then commit."; then
    echo "nudged worker '$TASK' in herdr."
  fi
}

log="$(mktemp)"
# -e-safe: capture the gate's real exit code without letting a non-zero pipeline abort us.
if "$CONTROL_DIR/gate.sh" "$TASK" 2>&1 | tee "$log"; then rc=0; else rc=${PIPESTATUS[0]}; fi

if [ "$rc" -eq 0 ]; then
  # Deterministic gate PASSED. Apply the second-opinion policy: rc 0 = pass (advisory notes,
  # if any, went to PROGRESS), rc 7 = route the codex concerns as a bounded feedback round.
  verdict="$STATE_DIR/gate/$TASK.codex.json"
  fb="$(mktemp)"
  if codex_gate_policy "$verdict" "$TASK" > "$fb"; then crc=0; else crc=$?; fi
  if [ "$crc" -eq 7 ]; then
    {
      echo "# Supervisor feedback — $TASK ($BRANCH)"
      echo "# The deterministic checks PASSED, but the independent second-opinion review found"
      echo "# high-severity concerns. Address them (or refute them in code comments), then commit."
      echo
      cat "$fb"
    } | route_feedback \
      && echo "VERIFY: second opinion routed high-severity concerns to $HD/feedback.md" \
      || echo "VERIFY: could not write feedback for '$TASK'."
    nudge
    rm -f "$log" "$fb"
    exit 7
  fi
  rm -f "$fb"
  # Freshness token for land.sh: this exact (base, branch) sha pair passed the full gate AND
  # the codex policy — land may skip its redundant re-gate while both are unchanged.
  printf '%s %s\n' "$(git -C "$CANONICAL" rev-parse "$BASE_BRANCH" 2>/dev/null || echo '?')" \
                   "$(git -C "$CANONICAL" rev-parse "$BRANCH" 2>/dev/null || echo '?')" \
    > "$STATE_DIR/$TASK.verified" 2>/dev/null || true
  echo
  echo "VERIFY PASS: $TASK ready. Land it with:  ./control/land.sh $TASK"
  rm -f "$log"
  exit 0
fi

# Route the failure back to the worker (workers don't run tests; they only get results).
# Record the conflict in the event ontology (best-effort; rc-0 contract).
ontology_event CA gate-fail "gate:$TASK exit $rc" "task:$TASK" "$BRANCH failed acceptance"
{
  echo "# Supervisor test feedback — $TASK ($BRANCH)"
  echo "# The supervisor ran the acceptance tests on your COMMITTED branch and they FAILED (exit $rc)."
  echo "# Fix the issues below, then commit. The supervisor will re-verify."
  echo "# This file is transient (out-of-tree); you may delete it once addressed."
  echo "# How to read failures (F2P/P2P): failures in YOUR slice's contract tests (tests/, named"
  echo "# in your task brief) are F2P — the spec you must newly satisfy. Failures in anything"
  echo "# that passed before your change are P2P regressions YOU introduced — fix those first,"
  echo "# and never by weakening a test."
  echo
  # Distill long gate logs (FEEDBACK_MAX_LINES): a full `npm ci` transcript buries the actual
  # failure and pollutes the worker's context. Keep the head (what the gate ran) and the tail
  # (where test runners print the failures); elide the middle.
  loglines="$(wc -l < "$log")"
  if [ "$loglines" -le "${FEEDBACK_MAX_LINES:-200}" ]; then
    cat "$log"
  else
    keep_head=40; keep_tail=$(( ${FEEDBACK_MAX_LINES:-200} - keep_head ))
    head -n "$keep_head" "$log"
    echo
    echo "... [$((loglines - keep_head - keep_tail)) lines elided — ask the supervisor if you need the full gate log] ..."
    echo
    tail -n "$keep_tail" "$log"
  fi
} | route_feedback \
  && echo "VERIFY FAIL (exit $rc): wrote failures to $HD/feedback.md" \
  || echo "VERIFY FAIL (exit $rc): could not write feedback for '$TASK'."

nudge

rm -f "$log"
exit "$rc"
