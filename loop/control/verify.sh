#!/usr/bin/env bash
# Supervisor loop command. The supervisor runs the tests; workers never do.
#   - PASS -> tells you it's ready to land.
#   - FAIL -> writes the failure log into the worker as /work/.harness/feedback.md and nudges
#             the worker to fix. The worker fixes + commits (auto-pushes); you re-verify.
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

log="$(mktemp)"
# -e-safe: capture the gate's real exit code without letting a non-zero pipeline abort us.
if "$CONTROL_DIR/gate.sh" "$TASK" 2>&1 | tee "$log"; then rc=0; else rc=${PIPESTATUS[0]}; fi

if [ "$rc" -eq 0 ]; then
  echo
  echo "VERIFY PASS: $TASK ready. Land it with:  ./control/land.sh $TASK"
  rm -f "$log"
  exit 0
fi

# Route the failure back to the worker (workers don't run tests; they only get results).
{
  echo "# Supervisor test feedback — $TASK ($BRANCH)"
  echo "# The supervisor ran the acceptance tests on your PUSHED branch and they FAILED (exit $rc)."
  echo "# Fix the issues below, then commit (commits auto-push). The supervisor will re-verify."
  echo "# This file is transient (gitignored); you may delete it once addressed."
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
} | docker exec -i "$CONTAINER" bash -lc 'mkdir -p /work/.harness && cat > /work/.harness/feedback.md' 2>/dev/null \
  && echo "VERIFY FAIL (exit $rc): wrote failures to $TASK:/work/.harness/feedback.md" \
  || echo "VERIFY FAIL (exit $rc): could not reach container '$TASK' (running?)."

# Best-effort: nudge the worker's Claude in its tmux pane (fleet) / window (legacy).
if pane="$(worker_pane "$TASK")"; then
  # Send text and the submitting Enter as SEPARATE send-keys calls (a combined call races the TUI
  # and leaves the nudge typed-but-unsubmitted, so the worker never re-engages on feedback). Same
  # fix as assign.sh.
  tmux send-keys -t "$pane" "Read /work/.harness/feedback.md — the supervisor's tests failed on your branch. Fix the issues, then commit (it auto-pushes)."
  sleep 1
  tmux send-keys -t "$pane" Enter
  echo "nudged worker '$TASK' in tmux."
fi

rm -f "$log"
exit "$rc"
