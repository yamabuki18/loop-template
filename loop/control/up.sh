#!/usr/bin/env bash
# The everyday command. Idempotent & resumable: brings the supervisor window plus
# WORKER_COUNT workers online, then attaches you to tmux. Run it as often as you like.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Lightweight preflight (full check: ./control/doctor.sh).
[ -x "$CONTROL_DIR/doctor.sh" ] && "$CONTROL_DIR/doctor.sh" --quick || true
[ -d "$CANONICAL/.git" ] || die "canonical not found. Run ./control/setup.sh first."
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image missing — building ..."; docker build -t "$IMAGE" "$CONTROL_DIR"; }
have_credential \
  && echo "auth: $(auth_mode) mode" \
  || echo "WARNING: no credential set — workers can't run Claude. Set CLAUDE_CODE_OAUTH_TOKEN (subscription) or ANTHROPIC_API_KEY (metered API) in control/secret.env."

# Supervisor window. Top pane = canonical shell. Bottom pane = the autonomous loop, pre-typed
# (NOT auto-run): review the backlog, then press Enter to start ./control/loop.sh. For semi-auto
# instead, run ./control/watch.sh there.
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -n supervisor -c "$CANONICAL"
  tmux send-keys -t "$SESSION:supervisor" \
    "clear; echo 'SUPERVISOR — canonical repo.'; echo 'goals: edit memory/backlog.md   progress: memory/PROGRESS.md'; echo 'full auto: ./control/loop.sh   semi-auto: ./control/watch.sh   status: ./control/status.sh'" C-m
  tmux split-window -v -t "$SESSION:supervisor" -c "$ROOT"
  tmux send-keys -t "$SESSION:supervisor.1" \
    "clear; echo 'LOOP pane — edit memory/backlog.md first, then press Enter to launch loop.sh:'" C-m
  # Pre-type the launch command WITHOUT Enter, so the human reviews the backlog then starts it.
  tmux send-keys -t "$SESSION:supervisor.1" "./control/loop.sh"
  tmux select-pane -t "$SESSION:supervisor.0"
fi

# Bring up the default pool of workers (idempotent)
for i in $(seq 1 "$WORKER_COUNT"); do
  "$CONTROL_DIR/spawn.sh" "w$i" >/dev/null
done

echo "attaching to tmux session '$SESSION' (detach: Ctrl-b then d)"
tmux select-window -t "$SESSION:supervisor"
exec tmux attach -t "$SESSION"
