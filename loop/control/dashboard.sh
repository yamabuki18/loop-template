#!/usr/bin/env bash
# Fleet dashboard — the whole company on one screen. The tmux-company pattern's
# capture-pane monitoring loop, made loop-aware and READ-ONLY: it polls state files, exchange
# push markers, PROGRESS.md and each worker's tmux pane; it never sends keys to anyone.
#
#   ./control/dashboard.sh [interval-seconds]   # up.sh runs this in the supervisor window
#   ./control/dashboard.sh --once               # render one frame and exit (smoke tests)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
set +e   # a dashboard must never die because one probe (docker/tmux/grep) came back non-zero

INTERVAL=3; ONCE=0
case "${1:-}" in
  --once) ONCE=1 ;;
  '') : ;;
  *) INTERVAL="$1" ;;
esac

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

rel_age() { # epoch -> "3m ago" / "-" when never
  local m="$1" s
  [ "$m" = 0 ] && { echo "-"; return; }
  s=$(( $(date +%s) - m ))
  if   [ "$s" -lt 60 ];    then echo "${s}s ago"
  elif [ "$s" -lt 3600 ];  then echo "$((s/60))m ago"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h ago"
  else echo "$((s/86400))d ago"; fi
}

trunc() { # <width> — hard-truncate stdin lines (keeps the dashboard from wrapping)
  awk -v w="$1" '{ if (length($0) > w) print substr($0, 1, w-1) "…"; else print $0 }'
}

render() {
  local cols; cols="$(tput cols 2>/dev/null)"; [ -n "$cols" ] || cols=120
  local ver; ver="$(cat "$ENGINE_DIR/VERSION" 2>/dev/null || echo '?')"

  printf '%s' "$BOLD"
  printf 'LOOP FLEET — %s   auth=%s   engine v%s   %s\n' \
    "$PROJECT_NAME" "$(auth_mode)" "$ver" "$(date +%H:%M:%S)"
  printf '%s' "$RST"

  # Backlog counters + the goal being decomposed right now.
  # NB: `grep -c` prints "0" AND exits 1 on zero matches, so `|| echo 0` would double-print.
  local bl="$MEMORY_DIR/backlog.md" todo doing done_ goal
  todo="$(grep -c '^- \[ \] '  "$bl" 2>/dev/null || true)";  todo="${todo:-0}"
  doing="$(grep -c '^- \[~\] ' "$bl" 2>/dev/null || true)"; doing="${doing:-0}"
  done_="$(grep -c '^- \[x\] ' "$bl" 2>/dev/null || true)"; done_="${done_:-0}"
  goal="$(grep -m1 '^- \[~\] ' "$bl" 2>/dev/null | sed 's/^- \[~\] //')"
  printf 'backlog: %s%s todo%s / %s%s doing%s / %s%s done%s' \
    "$YLW" "$todo" "$RST" "$CYN" "$doing" "$RST" "$GRN" "$done_" "$RST"
  if [ -n "$goal" ]; then
    printf '   %s>> %s%s' "$CYN" "$goal" "$RST" | trunc "$cols"   # trunc ends the line
  else
    printf '\n'
  fi
  printf '\n'

  # Workers: run state, branch, last push, STATUS, and the tail of the live Claude pane.
  printf '%sWORKERS%s\n' "$BOLD" "$RST"
  local f t st stcol branch push status pane line any=0
  shopt -s nullglob
  for f in "$STATE_DIR"/*.env; do
    any=1
    t="$(basename "$f" .env)"
    branch="$(sed -n 's/^BRANCH=//p' "$f" | head -1)"
    if container_running "$t"; then
      st="● running"; stcol="$GRN"
      status="$(docker exec "$(cname "$t")" bash -lc 'tail -1 /work/STATUS 2>/dev/null' 2>/dev/null)"
    else
      st="○ stopped"; stcol="$RED"; status=""
    fi
    push="$(rel_age "$(marker_mtime "$t")")"
    printf ' %s%-6s%s %s%s%s  %-18s push %-9s %s\n' \
      "$BOLD" "$t" "$RST" "$stcol" "$st" "$RST" "$branch" "$push" "${status:+STATUS: $status}" | trunc "$cols"
    # Last lines of the worker's actual pane (capture-pane) — what it is doing RIGHT NOW.
    if pane="$(worker_pane "$t")"; then
      tmux capture-pane -p -t "$pane" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -3 \
        | while IFS= read -r line; do printf '   %s│ %s%s\n' "$DIM" "$line" "$RST"; done | trunc "$cols"
    fi
  done
  [ "$any" = 1 ] || printf ' %s(no workers — run up.sh / spawn.sh)%s\n' "$DIM" "$RST"
  printf '\n'

  # Recent loop events (colorized PROGRESS tail).
  printf '%sEVENTS%s  %s(memory/PROGRESS.md)%s\n' "$BOLD" "$RST" "$DIM" "$RST"
  grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$MEMORY_DIR/PROGRESS.md" 2>/dev/null | tail -6 \
    | while IFS=$'\t' read -r ts ev who _ note; do   # 4th TSV field (branch@sha) unused here
        local c="$RST"
        case "$ev" in
          LANDED|GATE_PASS|GOAL_DONE|LOOP_DONE) c="$GRN" ;;
          GATE_FAIL|LAND_FAIL|PLAN_FAIL)        c="$YLW" ;;
          ESCALATED)                            c="$RED$BOLD" ;;
          PLANNED|PLAN_USAGE|ASSIGNED)          c="$CYN" ;;
        esac
        printf ' %s %s%-10s%s %-4s %s\n' "${ts:11:5}" "$c" "$ev" "$RST" "$who" "$note" | trunc "$cols"
      done
  printf '\n%skeys: fleet window = all workers | Ctrl-b z zoom a pane | Ctrl-b Space retile%s\n' "$DIM" "$RST"
}

if [ "$ONCE" = 1 ]; then render; exit 0; fi
# \033[H\033[J = repaint from home instead of clearing (no flicker).
while true; do
  out="$(render)"
  printf '\033[H\033[J%s\n' "$out"
  sleep "$INTERVAL"
done
