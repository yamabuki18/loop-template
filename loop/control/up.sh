#!/usr/bin/env bash
# The everyday command. Idempotent & resumable: brings the herdr workspace (supervisor panes +
# WORKER_COUNT workers) online, then attaches you to herdr. Run it as often as you like.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Lightweight preflight (full check: ./control/doctor.sh).
[ -x "$CONTROL_DIR/doctor.sh" ] && "$CONTROL_DIR/doctor.sh" --quick || true
[ -d "$CANONICAL/.git" ] || die "canonical not found. Run setup.sh first ($CONTROL_DIR/setup.sh)."
command -v herdr >/dev/null 2>&1 || die "herdr not found — install it: curl -fsSL https://herdr.dev/install.sh | sh"
have_credential \
  && echo "auth: $(auth_mode) mode" \
  || echo "WARNING: no credential — workers can't run Claude. Run: claude setup-token, then: loop secrets edit worker"

mkdir -p "$STATE_DIR"

# herdr server (persistent, shared across projects — down.sh never stops it).
if ! herdr_ok; then
  echo "up: starting herdr server ..."
  ( herdr server >/dev/null 2>&1 & )
  for _ in $(seq 1 20); do herdr_ok && break; sleep 0.5; done
  herdr_ok || die "herdr server did not come up (try running 'herdr' once interactively)."
fi

# One herdr workspace per project. The id is persisted so spawn.sh/agents land in it; the
# create-output format is not contract, so parse defensively and fall back to the list.
ws="$(herdr_workspace)"
if [ -z "$ws" ] || ! herdr workspace list 2>/dev/null | grep -q "$ws"; then
  out="$(herdr workspace create --cwd "$CANONICAL" --label "$PROJECT_NAME" 2>/dev/null || true)"
  ws="$(printf '%s\n' "$out" | grep -oE '\bw[A-Za-z0-9_-]{1,32}\b' | head -1)"
  if [ -z "$ws" ]; then
    ws="$(herdr workspace list 2>/dev/null | grep -F "$PROJECT_NAME" | grep -oE '\bw[A-Za-z0-9_-]{1,32}\b' | head -1)"
  fi
  if [ -n "$ws" ]; then echo "$ws" > "$STATE_DIR/herdr-workspace"; else
    echo "up: WARNING — could not determine the workspace id; panes will open in the focused workspace."
  fi
fi

# Supervisor panes. 'loop' = a shell with loop.sh PRE-TYPED (not run): review the backlog,
# then press Enter. 'dashboard' = the read-only fleet dashboard. Idempotent by agent name.
if ! herdr agent get dashboard >/dev/null 2>&1; then
  herdr agent start dashboard ${ws:+--workspace "$ws"} --cwd "$ROOT" --no-focus \
    --env "LOOP_PROJECT=$ROOT" -- bash "$CONTROL_DIR/dashboard.sh" >/dev/null 2>&1 || true
fi
if ! herdr agent get loop >/dev/null 2>&1; then
  herdr agent start loop ${ws:+--workspace "$ws"} --cwd "$ROOT" --no-focus \
    --env "LOOP_PROJECT=$ROOT" -- bash >/dev/null 2>&1 || true
  sleep 1
  # Pre-type the launch command WITHOUT Enter, so the human reviews the backlog then starts it.
  herdr agent send loop "$CONTROL_DIR/loop.sh" 2>/dev/null || true
fi

# Bring up the default pool of workers (idempotent).
for i in $(seq 1 "$WORKER_COUNT"); do
  "$CONTROL_DIR/spawn.sh" "w$i" >/dev/null
done

echo "attaching to herdr (workspace '${ws:-?}' / $PROJECT_NAME). goals: $MEMORY_DIR/backlog.md"
exec herdr
