#!/usr/bin/env bash
# Hand an interactively-approved plan to the LOOP (`loop handoff`) — the bridge between
# Claude Code's plan mode and the fleet. Instead of letting the planning session drop into
# auto-edit mode and implement alone, the approved plan becomes a backlog goal whose slices
# the parallel workers implement under the gate.
#
#   ./control/handoff.sh "<goal title>" [--latest | --plan <file> | --plan -]
#
#   --latest      use memory/plans/latest.md (written by harness-plan-capture on every
#                 approved ExitPlanMode). This is the default when latest.md exists.
#   --plan <file> use an explicit plan file;  --plan -  reads the plan from stdin.
#
# What it does (deterministic, no LLM):
#   1. archives the plan to memory/plans/<utc>-<slug>.md (latest.md keeps getting overwritten
#      by newer captures — the archive copy is the one the goal references)
#   2. appends `- [ ] <title> (plan: memory/plans/<archive>)` to memory/backlog.md
#   3. plan.sh sees the reference and decomposes THAT plan faithfully instead of re-planning
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TITLE=""; PLAN_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --latest) PLAN_SRC="$MEMORY_DIR/plans/latest.md"; shift ;;
    --plan)   PLAN_SRC="${2:?--plan needs a file (or - for stdin)}"; shift 2 ;;
    *)        [ -n "$TITLE" ] && die "unexpected argument '$1' (title already given)"; TITLE="$1"; shift ;;
  esac
done
[ -n "$TITLE" ] || die "usage: handoff.sh \"<goal title>\" [--latest | --plan <file>|-]"
: "${PLAN_SRC:=$MEMORY_DIR/plans/latest.md}"

mkdir -p "$MEMORY_DIR/plans"
slug="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-48)"
[ -n "$slug" ] || slug="plan"
dest="$MEMORY_DIR/plans/$(date -u +%Y%m%dT%H%M%SZ)-$slug.md"

if [ "$PLAN_SRC" = "-" ]; then
  cat > "$dest"
else
  [ -f "$PLAN_SRC" ] || die "plan file not found: $PLAN_SRC (approve a plan in plan mode first, or pass --plan <file>)"
  cp "$PLAN_SRC" "$dest"
fi
[ -s "$dest" ] || { rm -f "$dest"; die "plan is empty — nothing to hand off."; }

BACKLOG="$MEMORY_DIR/backlog.md"
[ -f "$BACKLOG" ] || printf '# Backlog\n\n' > "$BACKLOG"
printf -- '- [ ] %s (plan: memory/plans/%s)\n' "$TITLE" "$(basename "$dest")" >> "$BACKLOG"
progress_log HANDOFF "-" "-" "$TITLE -> $(basename "$dest")"

echo "handoff: plan archived  -> $dest"
echo "handoff: goal queued    -> $BACKLOG"
echo "handoff: the planner will decompose THIS plan (not re-plan). Start the fleet with:"
echo "  loop run          # full autonomy (plan -> assign -> gate -> auto-land)"
echo "  loop supervise    # or stay in the loop yourself (dialogue mode)"
