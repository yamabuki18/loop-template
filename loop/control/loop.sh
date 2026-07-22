#!/usr/bin/env bash
# THE LOOP (full autonomy) — the deterministic, host-side heartbeat that runs the
# DISCOVER -> PLAN -> EXECUTE -> VERIFY -> ITERATE cycle with no human in the inner loop.
# It is plain bash on purpose: no LLM runs in the loop process itself, so there is nothing to
# prompt for permission (goal #1) and no secret ever enters an LLM-readable process except the
# one credential each role needs (goal #3, via secret_exec).
#
# One goal at a time (keeps slice ownership clean):
#   DISCOVER/PLAN : take the next "- [ ]" goal from memory/backlog.md -> plan.sh -> slices + tests
#                   (+ optional codex plan critique — independent second opinion)
#   ASSIGN        : hand disjoint slices to free workers (assign.sh; delivered via SessionStart hook)
#   EXECUTE       : worker Claude implements in its worktree, commits -> ref instantly visible
#   VERIFY        : on a new commit + idle agent, run the gate (verify.sh). PASS -> land + sync
#                   others. FAIL (or codex high-severity concerns) -> feedback round.
#   ITERATE       : worker's stop-gate re-engages on feedback; after MAX_FEEDBACK_ROUNDS -> escalate.
# Completion: backlog has no "- [ ]" goals and no worker is busy -> notify + exit.
#
# Run it in the 'loop' herdr pane (up.sh pre-types it). Stop with Ctrl-C; re-run any time.
#   ./control/loop.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"

[ -d "$CANONICAL/.git" ] || die "canonical not found — run ./control/setup.sh first."
have_credential || die "no credential: run 'claude setup-token' then 'loop secrets edit worker' (or log in to claude on this host)."
# Heartbeat exclusivity: watch.sh (also behind `loop supervise`) drives the same gate — running
# both double-gates every commit. Claim loop.pid; refuse while a live watch.pid exists.
if pid="$(heartbeat_pid_alive watch)"; then
  die "watch.sh (pid $pid) is already driving the gate — stop it (or 'loop supervise') before loop.sh."
fi
heartbeat_claim loop
trap 'heartbeat_release loop' EXIT
echo "loop: auth $(auth_mode) mode"
mkdir -p "$LOG_DIR"

# Ensure the worker pool is online (idempotent). up.sh also attaches herdr; here we only need them up.
mapfile -t WORKERS < <(worker_tasks)
if [ "${#WORKERS[@]}" -eq 0 ]; then
  echo "loop: no workers yet — bringing up $WORKER_COUNT (run ./control/up.sh for the herdr view)."
  for i in $(seq 1 "$WORKER_COUNT"); do "$CONTROL_DIR/spawn.sh" "w$i" >/dev/null; done
  mapfile -t WORKERS < <(worker_tasks)
fi

declare -A SEEN BUSY ROUNDS SLICE UNK PROG STALL START
for w in "${WORKERS[@]}"; do SEEN["$w"]="$(worker_head "$w")"; BUSY["$w"]=0; ROUNDS["$w"]=0; SLICE["$w"]=""; UNK["$w"]=0; PROG["$w"]=0; STALL["$w"]=0; START["$w"]=0; done

QUEUE=()                 # pending slices (compact JSON) for the ACTIVE goal
ACTIVE_GOAL=""
ACTIVE_REMAINING=0       # slices of the active goal not yet landed/escalated

# --- backlog helpers (memory/backlog.md is the DISCOVER input) ---
BACKLOG="$MEMORY_DIR/backlog.md"
next_goal() {  # first "- [ ]" goal text (marker stripped), or empty
  [ -f "$BACKLOG" ] || return 0
  grep -m1 -E '^- \[ \] ' "$BACKLOG" 2>/dev/null | sed -E 's/^- \[ \] //'
}
mark_goal() {  # mark_goal <x|~> <goal-text>  — flip that goal's checkbox in place
  local mark="$1" goal="$2" tmp
  [ -f "$BACKLOG" ] || return 0
  # Guard against a silent no-op: the awk below matches the goal line BYTE-EXACTLY, so a backlog
  # edited mid-run, a duplicated goal, or trailing whitespace would flip nothing and the goal
  # could be re-picked (duplicate work) or lost. Warn loudly instead of failing silently.
  if ! grep -qxF -- "- [ ] $goal" "$BACKLOG" && ! grep -qxF -- "- [~] $goal" "$BACKLOG"; then
    echo "loop: WARNING — mark_goal '$mark' found no exact '- [ ] $goal' / '- [~] $goal' line (backlog edited mid-run, duplicate goal, or trailing whitespace?)." >&2
    return 0
  fi
  tmp="$(mktemp)"
  GOAL="$goal" MARK="$mark" awk '
    BEGIN{g=ENVIRON["GOAL"]; m=ENVIRON["MARK"]}
    {
      line=$0
      if (!done && (line=="- [ ] " g || line=="- [~] " g)) {
        sub(/^- \[[ ~]\] /, "- [" m "] ", line); done=1
      }
      print line
    }' "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"
}

free_worker() { for w in "${WORKERS[@]}"; do [ "${BUSY[$w]}" = 0 ] && { echo "$w"; return; }; done; }
any_busy()    { for w in "${WORKERS[@]}"; do [ "${BUSY[$w]}" = 1 ] && return 0; done; return 1; }

# Crash reconciliation: a previous run may have died with a goal marked "- [~]" (in progress).
# next_goal only picks "- [ ]", so reset orphaned "~" goals back to unstarted before we begin.
if [ -f "$BACKLOG" ]; then
  reset_n="$(backlog_reset_inprogress "$BACKLOG")"
  [ "${reset_n:-0}" -gt 0 ] && { echo "loop: reconciled $reset_n orphaned in-progress goal(s) from a prior run."; progress_log RECONCILED "-" "-" "reset $reset_n in-progress goal(s)"; }
fi

echo "loop: started. workers: ${WORKERS[*]}   backlog: $BACKLOG"
progress_log LOOP_START "-" "-" "workers=${WORKERS[*]}"
notify "autonomous loop started"

cycle=0
while true; do
  cycle=$((cycle+1))
  if [ "${LOOP_MAX_CYCLES:-0}" -gt 0 ] && [ "$cycle" -gt "$LOOP_MAX_CYCLES" ]; then
    echo "loop: LOOP_MAX_CYCLES ($LOOP_MAX_CYCLES) reached — stopping."; break
  fi

  # ── DISCOVER/PLAN: only when the queue is empty AND nobody is busy (one goal at a time) ──
  if [ "${#QUEUE[@]}" -eq 0 ] && ! any_busy; then
    [ "$ACTIVE_GOAL" ] && { mark_goal x "$ACTIVE_GOAL"; progress_log GOAL_DONE "-" "-" "$ACTIVE_GOAL"; notify "goal complete: $ACTIVE_GOAL"; ACTIVE_GOAL=""; }
    goal="$(next_goal || true)"
    if [ -z "$goal" ]; then
      echo "loop: backlog empty and all workers idle — DONE."; progress_log LOOP_DONE "-" "-" "backlog drained"; notify "loop complete — backlog drained"; break
    fi
    echo "loop: next goal -> $goal"
    mark_goal '~' "$goal"; ACTIVE_GOAL="$goal"
    if [ "${PLANNER_ENABLED:-1}" = 1 ]; then
      if slices_file="$("$CONTROL_DIR/plan.sh" "$goal" 2>>"$LOG_DIR/plan.log" | tail -1)" && [ -f "$slices_file" ]; then
        mapfile -t QUEUE < <(jq -c '.[]' "$slices_file")
      else
        echo "loop: planner produced no usable slices — see $LOG_DIR/plan.log. Skipping goal."
        progress_log PLAN_FAIL "-" "-" "$goal"; mark_goal x "$goal"; ACTIVE_GOAL=""; sleep "$LOOP_POLL_SECS"; continue
      fi
    else
      # PLANNER_ENABLED=0: read human-authored slices from memory/slices/<goal>.json if present.
      human="$MEMORY_DIR/slices/current.json"
      [ -f "$human" ] || { echo "loop: PLANNER_ENABLED=0 but $human missing — write slices yourself."; sleep "$LOOP_POLL_SECS"; continue; }
      mapfile -t QUEUE < <(jq -c '.[]' "$human")
    fi
    ACTIVE_REMAINING="${#QUEUE[@]}"
    echo "loop: ${ACTIVE_REMAINING} slice(s) queued for goal."
  fi

  # ── ASSIGN: give free workers the next queued slices ──
  while [ "${#QUEUE[@]}" -gt 0 ]; do
    w="$(free_worker || true)"; [ -n "$w" ] || break
    slice="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
    name="$(jq -r '.name' <<<"$slice")"
    brief="$(jq -r '.brief' <<<"$slice")"
    mapfile -t paths < <(jq -r '.paths[]' <<<"$slice")
    # Hand the worker its EXACT pass bar: the contract tests the planner wrote for this slice.
    # Without this the worker has to hunt through tests/ for which spec is "its" spec.
    tests_md="$(jq -r '(.tests // [])[] | "  - " + .' <<<"$slice")"
    [ -n "$tests_md" ] && brief="$brief"$'\n\n'"Acceptance tests that define DONE for this slice (read them, make them pass, never edit them):"$'\n'"$tests_md"
    # If the planner gave this slice a wiki page, make its upkeep an explicit part of the task
    # (the worker holds the full implementation context — the cheap moment to write it down).
    wiki_page="$(jq -r '[.paths[] | select(startswith("wiki/"))][0] // empty' <<<"$slice")"
    [ -n "$wiki_page" ] && brief="$brief"$'\n\n'"Also update $wiki_page — your module wiki page — to reflect what you built (role, public interface, data shapes, dependencies). It is part of DONE."
    echo "loop: assign $w <- slice '$name' (paths: ${paths[*]})"
    "$CONTROL_DIR/assign.sh" "$w" --brief "$brief"$'\n\n'"(slice: $name)" "${paths[@]}" >/dev/null 2>&1 || true
    BUSY["$w"]=1; SLICE["$w"]="$name"; ROUNDS["$w"]=0; UNK["$w"]=0; SEEN["$w"]="$(worker_head "$w")"
    PROG["$w"]="$(date +%s)"; STALL["$w"]=0   # start the liveness watchdog clock for this slice
    START["$w"]="${PROG[$w]}"                 # ... and the wall-clock for per-slice telemetry
    progress_log ASSIGNED "$w" "-" "$name"
  done

  # ── VERIFY/ITERATE: react to new worker commits (shared refs replace the v2 push marker) ──
  for w in "${WORKERS[@]}"; do
    [ "${BUSY[$w]}" = 1 ] || continue
    now="$(date +%s)"
    h="$(worker_head "$w")"
    st="$(agent_state "$w")"

    # Liveness: a new commit OR an actively-'working' agent counts as progress — reset the
    # stall clock. (This runs every cycle, before the "no new commit -> skip" short-circuit.)
    if { [ "$h" != "${SEEN[$w]}" ] && [ "$h" != none ]; } || [ "$st" = working ]; then
      PROG["$w"]="$now"; STALL["$w"]=0
    fi

    # WATCHDOG: no progress for too long. A hung / spinning / never-committing worker changes no
    # ref and (with herdr up) shows 'working' forever — without this its slice pins BUSY=1 and
    # the loop's completion condition (backlog empty && no worker busy) is never reached. First
    # a warning nudge; if still stalled after WORKER_HANG_GRACE, auto-respawn (non-destructive:
    # the assignment is kept, only un-committed scratch dies with the reaped worktree) and burn a
    # feedback round so a chronically-stalling slice eventually ESCALATES instead of looping.
    if [ "$st" != working ]; then
      idle_for=$(( now - ${PROG[$w]:-$now} ))
      case "$(worker_watchdog_action "$idle_for" "${STALL[$w]}")" in
        warn)
          echo "loop: $w (slice ${SLICE[$w]}) no progress for ${idle_for}s — nudging before reset."
          hd="$(harness_dir "$w")"; mkdir -p "$hd"
          {
            echo "# Watchdog — no progress detected on $w"
            echo "# No new commit for ${idle_for}s and the agent is not actively working. If you are"
            echo "# stuck, commit what you have (a commit is gated instantly) or simplify. If nothing"
            echo "# changes within ${WORKER_HANG_GRACE:-300}s your worktree is reset and this slice restarts."
          } > "$hd/feedback.md"
          agent_send "$w" "Watchdog: no progress for ${idle_for}s — read $hd/feedback.md, then commit or continue." || true
          progress_log STALL_WARN "$w" "-" "${SLICE[$w]} idle ${idle_for}s"
          STALL["$w"]=1; PROG["$w"]="$now"
          continue ;;
        act)
          ROUNDS["$w"]=$(( ROUNDS["$w"] + 1 ))
          if [ "${ROUNDS[$w]}" -gt "${MAX_FEEDBACK_ROUNDS:-4}" ]; then
            echo "loop: ESCALATE $w (${SLICE[$w]}) — stalled past the watchdog and ${MAX_FEEDBACK_ROUNDS} rounds."
            progress_log ESCALATED "$w" "work/$w" "${SLICE[$w]} (stalled >${MAX_FEEDBACK_ROUNDS} rounds)"
            # Verifier co-evolution seam: frame BOTH hypotheses (bad worker vs bad gate) for the human.
            if rp="$(escalation_report "$w" "${SLICE[$w]}" "${ROUNDS[$w]}")"; then [ -n "$rp" ] && echo "loop: review packet -> $rp"; fi
            notify "needs human: ${SLICE[$w]} on $w stalled"
            BUSY["$w"]=0; SLICE["$w"]=""; ROUNDS["$w"]=0
            ACTIVE_REMAINING=$((ACTIVE_REMAINING-1))
          else
            echo "loop: RESPAWN $w (${SLICE[$w]}) — stalled ${idle_for}s past the nudge; resetting worktree (round ${ROUNDS[$w]}/${MAX_FEEDBACK_ROUNDS})."
            progress_log STALL_RESPAWN "$w" "work/$w" "${SLICE[$w]} round ${ROUNDS[$w]}"
            "$CONTROL_DIR/respawn.sh" "$w" >>"$LOG_DIR/$w.respawn.log" 2>&1 || echo "loop: respawn of $w failed — see $LOG_DIR/$w.respawn.log"
            SEEN["$w"]="$(worker_head "$w")"; PROG["$w"]="$(date +%s)"; STALL["$w"]=0; UNK["$w"]=0
          fi
          continue ;;
      esac
    fi

    # No new commit since we last gated -> nothing to verify this cycle.
    [ "$h" != "${SEEN[$w]}" ] && [ "$h" != none ] || continue
    # Gate only when the worker's burst is over: herdr says idle/blocked/done. 'working' means
    # more commits are likely coming — wait. unknown/none (no herdr, crashed pane) must not
    # strand committed work: force the gate after AGENT_UNKNOWN_GRACE cycles.
    case "$st" in
      working)
        UNK["$w"]=0; continue ;;
      idle|blocked|done)
        UNK["$w"]=0 ;;
      *)
        UNK["$w"]=$(( UNK["$w"] + 1 ))
        if [ "${UNK[$w]}" -lt "${AGENT_UNKNOWN_GRACE:-6}" ]; then continue; fi
        echo "loop: $w agent state '$st' for ${UNK[$w]} cycles — gating anyway." ;;
    esac
    SEEN["$w"]="$h"; UNK["$w"]=0
    echo "loop: new commits on $w (slice ${SLICE[$w]}) — gating."
    if "$CONTROL_DIR/verify.sh" "$w" >>"$LOG_DIR/$w.gate.log" 2>&1; then
      sha="$(git -C "$CANONICAL" rev-parse --short "$(branch_for "$w")" 2>/dev/null || echo '?')"
      # Per-slice telemetry: capture size BEFORE land (afterwards the merge-base moves). Workers
      # have no token/usage capture, so this is the operator's post-hoc signal for a run.
      stats="$(slice_stats "$w") elapsed=$(( $(date +%s) - ${START[$w]:-0} ))s rounds=${ROUNDS[$w]}"
      # verify.sh just ran the gate on this exact branch and it PASSED (including the codex
      # policy), so land with --no-verify to avoid a second (redundant) gate run.
      "$CONTROL_DIR/land.sh" "$w" --no-verify >>"$LOG_DIR/$w.land.log" 2>&1 \
        && { echo "loop: LANDED $w (${SLICE[$w]}) [$stats]"; progress_log LANDED "$w" "work/$w@$sha" "${SLICE[$w]}"; progress_log WORKER_STATS "$w" "work/$w@$sha" "${SLICE[$w]} — $stats"; notify "landed: ${SLICE[$w]}"; } \
        || { echo "loop: land FAILED for $w despite gate pass — see $LOG_DIR/$w.land.log"; progress_log LAND_FAIL "$w" "-" "${SLICE[$w]}"; }
      [ "${AUTO_SYNC:-1}" = 1 ] && "$CONTROL_DIR/sync.sh" --others "$w" >>"$LOG_DIR/sync.log" 2>&1 || true
      BUSY["$w"]=0; SLICE["$w"]=""; ROUNDS["$w"]=0
      ACTIVE_REMAINING=$((ACTIVE_REMAINING-1))
    else
      ROUNDS["$w"]=$(( ROUNDS["$w"] + 1 ))
      if [ "${ROUNDS[$w]}" -gt "${MAX_FEEDBACK_ROUNDS:-4}" ]; then
        echo "loop: ESCALATE $w (${SLICE[$w]}) — exceeded ${MAX_FEEDBACK_ROUNDS} rounds."
        progress_log ESCALATED "$w" "work/$w" "${SLICE[$w]} (>${MAX_FEEDBACK_ROUNDS} rounds, $(slice_stats "$w") elapsed=$(( $(date +%s) - ${START[$w]:-0} ))s)"
        # Verifier co-evolution seam: frame BOTH hypotheses (bad worker vs bad gate) for the human.
        if rp="$(escalation_report "$w" "${SLICE[$w]}" "${ROUNDS[$w]}")"; then [ -n "$rp" ] && echo "loop: review packet -> $rp"; fi
        notify "needs human: ${SLICE[$w]} on $w stuck"
        BUSY["$w"]=0; SLICE["$w"]=""; ROUNDS["$w"]=0
        ACTIVE_REMAINING=$((ACTIVE_REMAINING-1))
      else
        echo "loop: FAIL $w round ${ROUNDS[$w]}/${MAX_FEEDBACK_ROUNDS} — feedback routed; worker will re-engage."
        progress_log GATE_FAIL "$w" "-" "${SLICE[$w]} round ${ROUNDS[$w]}"
      fi
    fi
  done

  sleep "${LOOP_POLL_SECS:-5}"
done
