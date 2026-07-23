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
have_credential || die "no credential: run 'claude setup-token' and paste it into secret.worker.env (or log in to claude on this host)."
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
  spawn_pool
  mapfile -t WORKERS < <(worker_tasks)
fi

declare -A SEEN BUSY ROUNDS SLICE UNK PROG STALL START
for w in "${WORKERS[@]}"; do SEEN["$w"]="$(worker_head "$w")"; BUSY["$w"]=0; ROUNDS["$w"]=0; SLICE["$w"]=""; UNK["$w"]=0; PROG["$w"]=0; STALL["$w"]=0; START["$w"]=0; done

QUEUE=()                 # pending slices (compact JSON) for the ACTIVE goal
ACTIVE_GOAL=""
GOAL_LANDED=0            # slices of the active goal that LANDED — decides the completion mark:
GOAL_ESCALATED=0         # 0 landed + >0 escalated -> "- [!]" (incomplete), never a silent "[x]"

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

# Persist the assignment state (ledger, lib.sh loop_active_*) on every transition, so a crashed
# heartbeat restores in-flight slices instead of re-planning them onto busy workers. Best-effort.
save_active() {
  local w qjson='[]' busy='{}'
  [ "${#QUEUE[@]}" -gt 0 ] && qjson="$(printf '%s\n' "${QUEUE[@]}" | jq -cs '.' 2>/dev/null || echo '[]')"
  for w in "${WORKERS[@]}"; do
    [ "${BUSY[$w]}" = 1 ] || continue
    busy="$(jq -c --arg w "$w" --arg s "${SLICE[$w]}" --argjson r "${ROUNDS[$w]:-0}" \
            '. + {($w): {slice: $s, rounds: $r}}' <<<"$busy" 2>/dev/null || echo "$busy")"
  done
  loop_active_save "$ACTIVE_GOAL" "$qjson" "$busy" "$GOAL_LANDED" "$GOAL_ESCALATED"
}

# --- subscription usage guard (USAGE_GUARD) ---
# The plan's 5-hour/7-day windows are shared by every worker (same account), so pacing is a
# LOOP concern, not a worker concern: past USAGE_PAUSE_PCT the loop drains (in-flight slices
# finish and land — their tokens are already sunk — but nothing new is assigned); once nothing
# is busy, or immediately when hard-limited, it pauses and auto-resumes after the window reset.
USAGE_DRAIN=0
U_F=none; U_FR=0; U_S=none; U_SR=0    # last probe: five/seven pct + reset epochs
usage_refresh() { # cached probe -> U_* globals; echoes the decision (ok|drain|halt)
  read -r U_F U_FR U_S U_SR <<<"$(usage_status)" || true
  usage_guard_decision "${U_F:-none}" "${U_S:-none}"
}
usage_pause() { # <why> — sleep until the limiting window resets (re-probing), then resume
  local why="$1" target now wait chunk
  echo "loop: USAGE PAUSE — $why"
  progress_log USAGE_PAUSE "-" "-" "$why (5h=${U_F}% 7d=${U_S}%)"
  notify "usage pause: $why"
  while :; do
    target="$(usage_pause_target "$U_F" "$U_FR" "$U_S" "$U_SR")"
    now="$(date +%s)"
    # Unknown reset (probe degraded)? Re-probe on the poll cadence instead of spinning.
    [ "${target:-0}" -gt 0 ] || target=$((now + ${USAGE_POLL_SECS:-300}))
    wait="$(usage_wait_secs "$target" "$now")"
    echo "loop: paused — resuming around $(date -d "@$((now + wait))" 2>/dev/null || echo "+${wait}s") (5h=${U_F}% 7d=${U_S}%)"
    while [ "$wait" -gt 0 ]; do   # chunked so Ctrl-C stays responsive and logs show life
      chunk=$(( wait > 60 ? 60 : wait )); sleep "$chunk"; wait=$((wait - chunk))
    done
    rm -f "$STATE_DIR/usage.cache" 2>/dev/null   # force a LIVE probe after the window reset
    case "$(usage_refresh)" in ok) break;; esac  # still limited (weekly / stale reset) -> wait more
  done
  USAGE_DRAIN=0
  echo "loop: USAGE RESUME — windows clear (5h=${U_F}% 7d=${U_S}%)."
  progress_log USAGE_RESUME "-" "-" "5h=${U_F}% 7d=${U_S}%"
  notify "usage window reset — loop resumed"
  # Resume trigger for in-flight workers: their Claude sat at the limit error; nudge it back to
  # work. Best-effort (herdr) — the stop-gate/feedback hooks still guarantee eventual delivery.
  for w in "${WORKERS[@]}"; do
    [ "${BUSY[$w]:-0}" = 1 ] || continue
    agent_send "$w" "The usage window has reset — continue your task now. Read $(harness_dir "$w")/feedback.md if present, finish the slice and commit." || true
    PROG["$w"]="$(date +%s)"; STALL["$w"]=0   # the pause was not a stall — reset the watchdog
  done
}

# Crash reconciliation, two layers:
#   1. Ledger restore: a previous run persisted its assignment state (state/loop-active.json,
#      written on every transition). If its goal is still "- [~]" in the backlog, restore
#      ACTIVE_GOAL/QUEUE/BUSY instead of re-planning — re-assignment would overwrite
#      task.md/owned-paths under workers that are STILL implementing, and their unlanded
#      commits would hide behind a freshly-primed SEEN. SEEN is blanked for restored-busy
#      workers so already-committed work gates on the next idle burst.
#   2. Backlog reset: every OTHER "- [~]" goal is an orphan from a run that died before
#      assigning anything (no ledger) — flip it back to "- [ ]" so it is re-picked.
RESTORED_GOAL=""
if [ -f "$BACKLOG" ]; then
  if g="$(loop_active_goal "$BACKLOG")" && [ -n "$g" ]; then
    ACTIVE_GOAL="$g"; RESTORED_GOAL="$g"
    mapfile -t QUEUE < <(jq -c '.queue[]?' "$(loop_active_file)" 2>/dev/null)
    nbusy=0
    while IFS=$'\t' read -r w s r; do
      # Unknown worker (fleet changed since the crash)? Skip — its slice re-queues via re-plan.
      [ -n "$w" ] && [ -n "${BUSY[$w]+x}" ] || continue
      BUSY["$w"]=1; SLICE["$w"]="$s"; ROUNDS["$w"]="${r:-0}"
      SEEN["$w"]=""; PROG["$w"]="$(date +%s)"; START["$w"]="${PROG[$w]}"
      nbusy=$((nbusy + 1))
    done < <(jq -r '.busy | to_entries[] | [.key, .value.slice, (.value.rounds // 0)] | @tsv' "$(loop_active_file)" 2>/dev/null)
    GOAL_LANDED="$(jq -r '.landed // 0' "$(loop_active_file)" 2>/dev/null || echo 0)"
    GOAL_ESCALATED="$(jq -r '.escalated // 0' "$(loop_active_file)" 2>/dev/null || echo 0)"
    echo "loop: restored in-flight goal from the ledger — '$g' (${#QUEUE[@]} queued, $nbusy busy)."
    progress_log RESTORED "-" "-" "$g (${#QUEUE[@]} queued, $nbusy busy)"
  fi
  reset_n="$(backlog_reset_inprogress "$BACKLOG" "$RESTORED_GOAL")"
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

  # ── USAGE GUARD: pace the fleet against the plan's shared 5h/7d windows ──
  if [ "${USAGE_GUARD:-0}" = 1 ]; then
    case "$(usage_refresh)" in
      halt)   # hard-limited: nobody can progress — pause immediately, resume after reset
        usage_pause "hard-limited"
        continue ;;
      drain)
        if any_busy; then
          if [ "$USAGE_DRAIN" = 0 ]; then
            echo "loop: usage 5h=${U_F}% 7d=${U_S}% — DRAINING (in-flight slices finish, nothing new starts)."
            progress_log USAGE_DRAIN "-" "-" "5h=${U_F}% 7d=${U_S}%"
            notify "usage ${U_F}% — draining before pause"
          fi
          USAGE_DRAIN=1
        else
          usage_pause "threshold reached with no in-flight work"
          continue
        fi ;;
      ok)
        [ "$USAGE_DRAIN" = 1 ] && echo "loop: usage back under threshold — drain lifted."
        USAGE_DRAIN=0 ;;
    esac
  fi

  # ── DISCOVER/PLAN: only when the queue is empty AND nobody is busy (one goal at a time) ──
  if [ "${#QUEUE[@]}" -eq 0 ] && ! any_busy && [ "$USAGE_DRAIN" = 0 ]; then
    if [ "$ACTIVE_GOAL" ]; then
      # Honest completion mark: a goal whose every slice ESCALATED did not "complete" — mark it
      # "- [!]" (needs-human; next_goal never re-picks it) instead of a silent "[x]".
      if [ "${GOAL_LANDED:-0}" -eq 0 ] && [ "${GOAL_ESCALATED:-0}" -gt 0 ]; then
        mark_goal '!' "$ACTIVE_GOAL"
        progress_log GOAL_INCOMPLETE "-" "-" "$ACTIVE_GOAL (0 landed, ${GOAL_ESCALATED} escalated — review state/escalations/)"
        notify "goal INCOMPLETE (all slices escalated): $ACTIVE_GOAL"
      else
        mark_goal x "$ACTIVE_GOAL"; progress_log GOAL_DONE "-" "-" "$ACTIVE_GOAL"; notify "goal complete: $ACTIVE_GOAL"
      fi
      ACTIVE_GOAL=""; loop_active_clear
    fi
    goal="$(next_goal || true)"
    if [ -z "$goal" ]; then
      echo "loop: backlog empty and all workers idle — DONE."; progress_log LOOP_DONE "-" "-" "backlog drained"; notify "loop complete — backlog drained"; break
    fi
    echo "loop: next goal -> $goal"
    mark_goal '~' "$goal"; ACTIVE_GOAL="$goal"; GOAL_LANDED=0; GOAL_ESCALATED=0
    if [ "${PLANNER_ENABLED:-1}" = 1 ]; then
      if slices_file="$("$CONTROL_DIR/plan.sh" "$goal" 2>>"$LOG_DIR/plan.log" | tail -1)" && [ -f "$slices_file" ]; then
        mapfile -t QUEUE < <(jq -c '.[]' "$slices_file")
      else
        echo "loop: planner produced no usable slices — see $LOG_DIR/plan.log. Skipping goal."
        progress_log PLAN_FAIL "-" "-" "$goal"; mark_goal x "$goal"; ACTIVE_GOAL=""; loop_active_clear; sleep "$LOOP_POLL_SECS"; continue
      fi
    else
      # PLANNER_ENABLED=0: human-authored slices. Resolution: memory/slices/<goal-slug>.json
      # (goal-scoped) first, else current.json. The consumed file is ARCHIVED (*.consumed-<utc>)
      # so the next goal can never silently reuse stale slices meant for this one.
      gslug="$(printf '%s' "$goal" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-48)"
      human="$MEMORY_DIR/slices/current.json"
      [ -n "$gslug" ] && [ -f "$MEMORY_DIR/slices/$gslug.json" ] && human="$MEMORY_DIR/slices/$gslug.json"
      if [ ! -f "$human" ]; then
        echo "loop: PLANNER_ENABLED=0 but no slices file (memory/slices/${gslug:-goal}.json or current.json) — write slices yourself."
        mark_goal ' ' "$goal"; ACTIVE_GOAL=""   # un-claim so the goal is re-picked once slices exist
        sleep "$LOOP_POLL_SECS"; continue
      fi
      mapfile -t QUEUE < <(jq -c '.[]' "$human")
      mv "$human" "$human.consumed-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
    fi
    echo "loop: ${#QUEUE[@]} slice(s) queued for goal."
    save_active
  fi

  # ── ASSIGN: give free workers the next queued slices (suspended while draining) ──
  while [ "$USAGE_DRAIN" = 0 ] && [ "${#QUEUE[@]}" -gt 0 ]; do
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
    save_active
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
          hd="$(harness_dir "$w")"
          {
            echo "# Watchdog — no progress detected on $w"
            echo "# No new commit for ${idle_for}s and the agent is not actively working. If you are"
            echo "# stuck, commit what you have (a commit is gated instantly) or simplify. If nothing"
            echo "# changes within ${WORKER_HANG_GRACE:-300}s your worktree is reset and this slice restarts."
          } | feedback_route "$w" || true
          agent_send "$w" "Watchdog: no progress for ${idle_for}s — read $hd/feedback.md, then commit or continue." || true
          progress_log STALL_WARN "$w" "-" "${SLICE[$w]} idle ${idle_for}s"
          STALL["$w"]=1; PROG["$w"]="$now"
          continue ;;
        act)
          # A worker that stalled because the ACCOUNT is limited is not a hung worker: nothing
          # would change after a respawn except a burned feedback round. Re-probe live and
          # pause instead — the resume nudge restarts the same session with its context intact.
          if [ "${USAGE_GUARD:-0}" = 1 ]; then
            rm -f "$STATE_DIR/usage.cache" 2>/dev/null
            if [ "$(usage_refresh)" != ok ]; then
              echo "loop: $w stalled but the usage window is exhausted (5h=${U_F}% 7d=${U_S}%) — pausing, not respawning."
              usage_pause "worker stall coincides with an exhausted window"
              continue
            fi
          fi
          ROUNDS["$w"]=$(( ROUNDS["$w"] + 1 ))
          if [ "${ROUNDS[$w]}" -gt "${MAX_FEEDBACK_ROUNDS:-4}" ]; then
            echo "loop: ESCALATE $w (${SLICE[$w]}) — stalled past the watchdog and ${MAX_FEEDBACK_ROUNDS} rounds."
            progress_log ESCALATED "$w" "work/$w" "${SLICE[$w]} (stalled >${MAX_FEEDBACK_ROUNDS} rounds)"
            # Verifier co-evolution seam: frame BOTH hypotheses (bad worker vs bad gate) for the human.
            if rp="$(escalation_report "$w" "${SLICE[$w]}" "${ROUNDS[$w]}")"; then [ -n "$rp" ] && echo "loop: review packet -> $rp"; fi
            notify "needs human: ${SLICE[$w]} on $w stalled"
            BUSY["$w"]=0; SLICE["$w"]=""; ROUNDS["$w"]=0
            GOAL_ESCALATED=$((GOAL_ESCALATED+1))
          else
            echo "loop: RESPAWN $w (${SLICE[$w]}) — stalled ${idle_for}s past the nudge; resetting worktree (round ${ROUNDS[$w]}/${MAX_FEEDBACK_ROUNDS})."
            progress_log STALL_RESPAWN "$w" "work/$w" "${SLICE[$w]} round ${ROUNDS[$w]}"
            "$CONTROL_DIR/respawn.sh" "$w" >>"$LOG_DIR/$w.respawn.log" 2>&1 || echo "loop: respawn of $w failed — see $LOG_DIR/$w.respawn.log"
            SEEN["$w"]="$(worker_head "$w")"; PROG["$w"]="$(date +%s)"; STALL["$w"]=0; UNK["$w"]=0
          fi
          save_active
          continue ;;
      esac
    fi

    # Gate only when the worker's burst is over — shared decision (lib.sh gate_now_decision:
    # wait while 'working', gate on idle/blocked/done, force past AGENT_UNKNOWN_GRACE so a
    # crashed pane cannot strand committed work).
    read -r act newunk <<<"$(gate_now_decision "$h" "${SEEN[$w]}" "$st" "${UNK[$w]}")"
    UNK["$w"]="$newunk"
    case "$act" in
      none|wait|defer) continue ;;
      force) echo "loop: $w agent state '$st' past the unknown grace — gating anyway." ;;
    esac
    SEEN["$w"]="$h"
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
      GOAL_LANDED=$((GOAL_LANDED+1))
      save_active
    else
      ROUNDS["$w"]=$(( ROUNDS["$w"] + 1 ))
      if [ "${ROUNDS[$w]}" -gt "${MAX_FEEDBACK_ROUNDS:-4}" ]; then
        echo "loop: ESCALATE $w (${SLICE[$w]}) — exceeded ${MAX_FEEDBACK_ROUNDS} rounds."
        progress_log ESCALATED "$w" "work/$w" "${SLICE[$w]} (>${MAX_FEEDBACK_ROUNDS} rounds, $(slice_stats "$w") elapsed=$(( $(date +%s) - ${START[$w]:-0} ))s)"
        # Verifier co-evolution seam: frame BOTH hypotheses (bad worker vs bad gate) for the human.
        if rp="$(escalation_report "$w" "${SLICE[$w]}" "${ROUNDS[$w]}")"; then [ -n "$rp" ] && echo "loop: review packet -> $rp"; fi
        notify "needs human: ${SLICE[$w]} on $w stuck"
        BUSY["$w"]=0; SLICE["$w"]=""; ROUNDS["$w"]=0
        GOAL_ESCALATED=$((GOAL_ESCALATED+1))
      else
        echo "loop: FAIL $w round ${ROUNDS[$w]}/${MAX_FEEDBACK_ROUNDS} — feedback routed; worker will re-engage."
        progress_log GATE_FAIL "$w" "-" "${SLICE[$w]} round ${ROUNDS[$w]}"
      fi
      save_active
    fi
  done

  sleep "${LOOP_POLL_SECS:-5}"
done
