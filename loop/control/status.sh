#!/usr/bin/env bash
# Show all workers, their branch, agent state, and last STATUS line.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

printf "%-8s %-16s %-9s %s\n" TASK BRANCH STATE STATUS
shopt -s nullglob
for f in "$STATE_DIR"/*.env; do
  (
    source "$f"
    state="$(agent_state "$TASK")"
    st="$(tail -1 "$(harness_dir "$TASK")/STATUS" 2>/dev/null || true)"
    printf "%-8s %-16s %-9s %s\n" "$TASK" "$BRANCH" "$state" "${st:--}"
  )
done

# Aggregate run summary from the loop's external memory. Workers have no token capture, so this
# rollup (landed/escalated/gate-fails/respawns + cumulative planner cost) is the quick health
# read an operator gets without grepping PROGRESS.md by hand.
P="$MEMORY_DIR/PROGRESS.md"
echo
echo "── run summary ($P) ──"
if [ -f "$P" ]; then
  awk -F'\t' '
    $2=="LANDED"        {land++}
    $2=="ESCALATED"     {esc++}
    $2=="GATE_FAIL"     {gf++}
    $2=="STALL_RESPAWN" {resp++}
    $2=="PLAN_USAGE"    { if (match($0, /cost_usd=[0-9.]+/)) cost += substr($0, RSTART+9, RLENGTH-9) }
    END { printf "  landed=%d  escalated=%d  gate_fails=%d  stall_respawns=%d  planner_cost_usd=%.4f\n",
                 land+0, esc+0, gf+0, resp+0, cost+0 }
  ' "$P"
else
  echo "  (no PROGRESS.md yet)"
fi
