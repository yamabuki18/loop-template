#!/usr/bin/env bash
# Bring a single worker online. Idempotent: creates what's missing, starts what's stopped,
# ensures a tmux window attached to that worker's Claude.
#   ./control/spawn.sh <task> [branch]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TASK="${1:?usage: spawn.sh <task> [branch]}"
BRANCH="${2:-$(branch_for "$TASK")}"
EX="$EXCHANGE_DIR/$TASK.git"

# 1) Exchange bare repo = the worker's credential-less origin (file protocol, no tokens).
if [ ! -d "$EX" ]; then
  git clone --bare "$CANONICAL" "$EX" >/dev/null
  git -C "$EX" branch -f "$BRANCH" "$BASE_BRANCH"
  # The container user (dev, uid 1001) differs from the host owner (e.g. 1000), so without this
  # the worker's push fails with "unable to create temporary object directory". core.sharedRepository
  # makes git create new objects group/world-writable; the chmod opens the existing tree. The
  # exchange holds only this branch's git data (no secrets) and the host is trusted, so this is safe.
  git -C "$EX" config core.sharedRepository 0777
fi
# Install/refresh exchange hooks every spawn (idempotent): pre-receive guards protected
# branches; post-receive emits a host-visible push marker for watch.sh (the loop heartbeat).
for h in pre-receive post-receive; do
  if [ -f "$CONTROL_DIR/hooks/$h" ]; then
    cp "$CONTROL_DIR/hooks/$h" "$EX/hooks/$h" && chmod +x "$EX/hooks/$h"
  fi
done
chmod -R a+rwX "$EX" 2>/dev/null || true   # keep the exchange writable by the container user

# 2) Container. The ONLY host path mounted is this worker's own exchange repo (no secrets,
#    just this branch's git data). No $HOME, no SSH keys, no /mnt/c — that's the read isolation.
if ! container_exists "$TASK"; then
  # Inject ONLY the chosen credential (subscription OAuth token OR metered API key — never both,
  # so subscription billing is not silently overridden by a stray API key). See lib.sh.
  mapfile -t CRED < <(cred_docker_args)
  # Join the worker<->broker network. Workers get BROKER_URL (NOT the dev secrets): they call
  # $BROKER_URL/<alias>/... and the broker injects the token. With WORKER_EGRESS=broker-only this
  # network is --internal, so the broker is the only reachable outbound path.
  ensure_worker_network
  docker run -d --name "$(cname "$TASK")" \
    --network "$(netname)" \
    "${CRED[@]}" \
    -e TASK="$TASK" -e FEAT_BRANCH="$BRANCH" -e BASE_BRANCH="$BASE_BRANCH" \
    -e PROTECTED_PATHS="$PROTECTED_PATHS" \
    -e BROKER_URL="http://$(brokername):$BROKER_PORT" \
    -v "$EX":/origin.git \
    -v "$(volname "$TASK")":/work \
    "$IMAGE" >/dev/null
elif ! container_running "$TASK"; then
  docker start "$(cname "$TASK")" >/dev/null
fi

# 3) Record state for the other scripts.
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/$TASK.env" <<EOF
TASK=$TASK
BRANCH=$BRANCH
CONTAINER=$(cname "$TASK")
EXCHANGE=$EX
EOF

# 4) tmux pane in the shared 'fleet' window — company-style: EVERY worker visible on one
#    screen as a titled tile (full TTY per pane; zoom with Ctrl-b z to intervene, z to unzoom).
if tmux has-session -t "$SESSION" 2>/dev/null; then
  if ! worker_pane "$TASK" >/dev/null; then
    cmd="docker exec -it -w /work $(cname "$TASK") bash -lc 'worker-prepare; cd /work; claude --dangerously-skip-permissions; exec bash'"
    if ! tmux list-windows -t "$SESSION" -F '#W' | grep -qx fleet; then
      pid="$(tmux new-window -d -t "$SESSION" -n fleet -P -F '#{pane_id}' "$cmd")"
      # Show each pane's worker name on its border (the fleet's name tags).
      tmux set-option -w -t "$SESSION:fleet" pane-border-status top
      tmux set-option -w -t "$SESSION:fleet" pane-border-format ' #{pane_title} '
    else
      # Tile first so a crowded window still has room for one more pane.
      tmux select-layout -t "$SESSION:fleet" tiled >/dev/null 2>&1 || true
      pid="$(tmux split-window -d -t "$SESSION:fleet" -P -F '#{pane_id}' "$cmd")"
      tmux select-layout -t "$SESSION:fleet" tiled >/dev/null 2>&1 || true
    fi
    tmux select-pane -t "$pid" -T "$TASK"
  fi
fi

echo "worker '$TASK' ready (branch $BRANCH)"
