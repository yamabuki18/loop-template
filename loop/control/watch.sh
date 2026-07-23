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

# Heartbeat exclusivity: refuse while loop.sh drives the gate (and claim watch.pid so loop.sh
# refuses in the other direction). See heartbeat_* in lib.sh.
if pid="$(heartbeat_pid_alive loop)"; then
  die "loop.sh (pid $pid) is already driving the gate — stop it before watch.sh / loop supervise."
fi
heartbeat_claim watch
trap 'heartbeat_release watch' EXIT

echo "watch: commit-driven gate active (poll ${LOOP_POLL_SECS}s). Workers: $(worker_tasks | tr '\n' ' ')"
echo "watch: on PASS you'll be notified to run ./control/land.sh <task>. Ctrl-C to stop."

declare -A SEEN UNK GATEPID
# Prime: treat current refs as already-seen so we only react to NEW commits.
while read -r t; do SEEN["$t"]="$(worker_head "$t")"; UNK["$t"]=0; done < <(worker_tasks)

running_gates() { jobs -rp | wc -l | tr -d ' '; }

while true; do
  while read -r t; do
    [ -n "$t" ] || continue
    # ONE gate per task at a time: a second verify on the same task would race the first's
    # feedback.md and codex verdict (both task-scoped files). Skip WITHOUT updating SEEN, so
    # the new commit re-triggers on the poll after the in-flight gate finishes.
    if [ -n "${GATEPID[$t]:-}" ] && kill -0 "${GATEPID[$t]}" 2>/dev/null; then continue; fi
    h="$(worker_head "$t")"
    st="$(agent_state "$t")"
    # Burst decision shared with loop.sh (lib.sh gate_now_decision): gate on idle/blocked/done,
    # wait while 'working', force past AGENT_UNKNOWN_GRACE when herdr can't tell us.
    read -r act newunk <<<"$(gate_now_decision "$h" "${SEEN[$t]:-none}" "$st" "${UNK[$t]:-0}")"
    UNK["$t"]="$newunk"
    case "$act" in
      none|wait|defer) continue ;;
      force) echo "watch: $t agent state '$st' past the unknown grace — gating anyway." ;;
    esac
    SEEN["$t"]="$h"
    # Cap concurrent gates (GATE_CONCURRENCY) so a burst of commits can't swamp the host.
    while [ "$(running_gates)" -ge "${GATE_CONCURRENCY:-2}" ]; do sleep 1; done
    echo "watch: new commits on $t — running gate."
    (
      if "$CONTROL_DIR/verify.sh" "$t" >/dev/null 2>&1; then
        notify "$t PASSED the gate — ready to land (./control/land.sh $t)"
        echo "watch: PASS $t — ready to land."
      else
        rc=$?
        if [ "$rc" -eq 7 ]; then
          # Exit 7 = the deterministic checks PASSED; only the independent second opinion
          # routed concerns. Saying "gate FAILED" here would misreport a green gate.
          notify "$t passed the checks — second-opinion concerns routed to the worker"
          echo "watch: CONCERNS $t — checks passed; independent review notes routed as feedback."
        else
          notify "$t gate FAILED — feedback routed to the worker"
          echo "watch: FAIL $t — feedback written to the worker."
        fi
      fi
    ) &
    GATEPID["$t"]=$!
  done < <(worker_tasks)
  sleep "${LOOP_POLL_SECS:-5}"
done
