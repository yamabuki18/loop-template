#!/usr/bin/env bash
# Commit-driven auto-verify (A1) — the SEMI-AUTO heartbeat. Watches every worker's branch ref
# (shared worktree refs make a worker commit instantly host-visible); when a worker's burst
# ends (new commits + agent no longer 'working'), runs the acceptance gate (via verify.sh,
# which also routes FAIL logs back to the worker's feedback.md). On PASS it NOTIFIES that the
# slice is ready to land — it does NOT land (that stays a human decision in semi-auto mode).
#
# This is the CI-push-trigger equivalent for a human supervisor: you stop polling and just react
# to "ready to land" notifications. For FULL autonomy (auto-land + auto-assign), run loop.sh
# instead — do NOT run both at once (they would both drive the gate).
#
#   ./control/watch.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "watch: commit-driven gate active (poll ${LOOP_POLL_SECS}s). Workers: $(worker_tasks | tr '\n' ' ')"
echo "watch: on PASS you'll be notified to run ./control/land.sh <task>. Ctrl-C to stop."

declare -A SEEN UNK
# Prime: treat current refs as already-seen so we only react to NEW commits.
while read -r t; do SEEN["$t"]="$(worker_head "$t")"; UNK["$t"]=0; done < <(worker_tasks)

running_gates() { jobs -rp | wc -l | tr -d ' '; }

while true; do
  while read -r t; do
    [ -n "$t" ] || continue
    h="$(worker_head "$t")"
    if [ "${SEEN[$t]:-none}" != "$h" ] && [ "$h" != none ]; then
      # Same burst logic as loop.sh: gate on idle/blocked/done; wait while 'working';
      # force after AGENT_UNKNOWN_GRACE cycles when herdr can't tell us.
      st="$(agent_state "$t")"
      case "$st" in
        working) UNK["$t"]=0; continue ;;
        idle|blocked|done) UNK["$t"]=0 ;;
        *) UNK["$t"]=$(( ${UNK[$t]:-0} + 1 ))
           [ "${UNK[$t]}" -lt "${AGENT_UNKNOWN_GRACE:-6}" ] && continue ;;
      esac
      SEEN["$t"]="$h"; UNK["$t"]=0
      # Cap concurrent gates (GATE_CONCURRENCY) so a burst of commits can't swamp the host.
      while [ "$(running_gates)" -ge "${GATE_CONCURRENCY:-2}" ]; do sleep 1; done
      echo "watch: new commits on $t — running gate."
      (
        if "$CONTROL_DIR/verify.sh" "$t" >/dev/null 2>&1; then
          notify "$t PASSED the gate — ready to land (./control/land.sh $t)"
          echo "watch: PASS $t — ready to land."
        else
          notify "$t gate FAILED — feedback routed to the worker"
          echo "watch: FAIL $t — feedback written to the worker."
        fi
      ) &
    fi
  done < <(worker_tasks)
  sleep "${LOOP_POLL_SECS:-5}"
done
