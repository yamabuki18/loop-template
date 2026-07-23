#!/usr/bin/env bash
# Bring a single worker online. Idempotent: creates what's missing, refreshes the harness
# config, ensures a herdr pane running that worker's Claude.
#   ./control/spawn.sh <task> [branch]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: spawn.sh <task> [branch]}"
BRANCH="${2:-$(branch_for "$TASK")}"
WT="$(worktree_for "$TASK")"
HD="$(harness_dir "$TASK")"
CD="$(claude_cfg_dir "$TASK")"

[ -d "$CANONICAL/.git" ] || die "canonical not found — run ./control/setup.sh first."

# Preflight the worker harness's hard dependencies. The client guards fail CLOSED when jq or
# realpath/python3 is missing (they would otherwise deny every tool and freeze the worker), so
# refuse to materialize a worker whose guards can't run at all — surface it here, not mid-run.
command -v jq >/dev/null 2>&1 || die "jq not found — required by the worker harness guards. Install jq first."
command -v realpath >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
  || die "neither realpath nor python3 found — the harness guards need one to normalize paths."

# 1) Git worktree = the worker's box. It shares canonical's refs/objects, so a worker commit is
#    instantly supervisor-visible (no exchange, no push) and the checked-out BASE_BRANCH in
#    canonical is structurally un-checkout-able by workers (git refuses double checkouts).
mkdir -p "$WORKTREES_DIR"
if [ ! -e "$WT/.git" ]; then
  if git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$CANONICAL" worktree add "$WT" "$BRANCH" >/dev/null
  else
    git -C "$CANONICAL" worktree add -b "$BRANCH" "$WT" "$BASE_BRANCH" >/dev/null
  fi
fi

# 2) Out-of-tree worker state: harness dir (task.md/feedback.md/owned-paths/STATUS) and a
#    per-worker CLAUDE_CONFIG_DIR (hooks + rules + onboarding pre-seed). Regenerated every
#    spawn (idempotent) so engine updates reach live fleets — EXCEPT .claude.json, which
#    accumulates live session state and is only seeded when missing.
mkdir -p "$HD" "$CD"
sed "s|__CONTROL_DIR__|$CONTROL_DIR|g" \
  "$CONTROL_DIR/worker-harness/settings.template.json" > "$CD/settings.json"
# Per-WORKSPACE harness extension (the engine stays generic; project constraints live in the
# workspace, outside both the engine and the project repo):
#   $CONFIG_DIR/worker-harness.d/*  — executable PreToolUse guards, appended for ALL tools.
#     Same contract as the engine guards: JSON on stdin, exit 0 = allow / 2 = block (stderr is
#     shown to the worker). Each guard filters by .tool_name itself.
#   $CONFIG_DIR/CLAUDE.worker.local.md — advisory (L1) project rules appended to CLAUDE.md.
# Escalation ladder stays intact per project: rules start in CLAUDE.worker.local.md, get
# promoted to a worker-harness.d/ guard when repeatedly violated — no engine edit needed.
if [ -d "$CONFIG_DIR/worker-harness.d" ]; then
  proj_hooks="$(find "$CONFIG_DIR/worker-harness.d" -maxdepth 1 -type f -perm -u+x 2>/dev/null | sort \
    | jq -R '{type:"command", command:.}' | jq -s '.')"
  if [ "$(jq 'length' <<<"$proj_hooks")" -gt 0 ]; then
    jq --argjson h "$proj_hooks" '.hooks.PreToolUse += [{hooks: $h}]' \
      "$CD/settings.json" > "$CD/settings.json.tmp" && mv "$CD/settings.json.tmp" "$CD/settings.json"
  fi
fi
cp "$CONTROL_DIR/CLAUDE.worker.md" "$CD/CLAUDE.md"
if [ -f "$CONFIG_DIR/CLAUDE.worker.local.md" ]; then
  { echo; echo "# Project-specific rules (workspace overlay)"; echo;
    cat "$CONFIG_DIR/CLAUDE.worker.local.md"; } >> "$CD/CLAUDE.md"
fi
# Onboarding pre-seed + host-login convenience (shared seam: lib.sh claude_cfg_seed).
claude_cfg_seed "$CD" "$WT"

# 3) Record state for the other scripts.
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/$TASK.env" <<EOF
TASK=$TASK
BRANCH=$BRANCH
WORKTREE=$WT
EOF

# 4) herdr pane running the worker's Claude (via worker-run.sh, which exports the harness env
#    and injects the credential with secret_exec). Best-effort: without a herdr server the
#    worker is still fully materialized — attach later with up.sh, or run worker-run.sh in any
#    terminal. Agent name = task id; herdr's agent-state detection then powers the loop signal.
if herdr_ok; then
  if ! herdr agent get "$TASK" >/dev/null 2>&1; then
    ws="$(herdr_workspace)"
    herdr agent start "$TASK" \
      ${ws:+--workspace "$ws"} \
      --cwd "$WT" --no-focus \
      --env "LOOP_PROJECT=$ROOT" \
      -- bash "$CONTROL_DIR/worker-run.sh" "$TASK" >/dev/null 2>&1 \
      || echo "spawn: herdr pane for '$TASK' could not be started (run: $CONTROL_DIR/worker-run.sh $TASK)"
  fi
else
  echo "spawn: herdr server not running — worker '$TASK' materialized; up.sh will attach it."
fi

echo "worker '$TASK' ready (branch $BRANCH, worktree $WT)"
