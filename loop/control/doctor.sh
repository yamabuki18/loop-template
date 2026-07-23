#!/usr/bin/env bash
# Preflight & self-diagnosis (C1). Turns "mysterious error 20 minutes in" into "doctor told me".
#   ./control/doctor.sh           # full report
#   ./control/doctor.sh --quick   # essentials only (used by up.sh/loop.sh on startup)
set -uo pipefail
source "$(dirname "$0")/lib.sh"

QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
warn=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
note() { printf '  \033[33mwarn\033[0m %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

ver="$(cat "$ENGINE_DIR/VERSION" 2>/dev/null || echo '?')"
[ "$CONFIG_DIR" = "$CONTROL_DIR" ] && mode="legacy (copy-deployed)" || mode="workspace"
echo "doctor: engine v$ver at $ENGINE_DIR — mode: $mode, project: $ROOT"

echo "doctor: environment"
command -v git    >/dev/null 2>&1 && ok "git"    || bad "git not found"
command -v jq     >/dev/null 2>&1 && ok "jq"     || bad "jq not found (required by hooks and the loop)"
command -v claude >/dev/null 2>&1 && ok "claude CLI" || bad "claude CLI not found (planner/workers cannot run)"
if command -v herdr >/dev/null 2>&1; then
  herdr_ok && ok "herdr (server reachable)" || note "herdr installed but server not running — up.sh starts it (or run 'herdr' once)"
else
  bad "herdr not found — install: curl -fsSL https://herdr.dev/install.sh | sh"
fi

if [ "$QUICK" -eq 0 ]; then
  command -v shellcheck >/dev/null 2>&1 && ok "shellcheck (toolkit tests)" || note "shellcheck absent (tests-toolkit will skip lint)"
  if command -v codex >/dev/null 2>&1; then
    ok "codex CLI (second opinion available; mode: ${SECOND_OPINION:-advise})"
  else
    [ "${SECOND_OPINION:-advise}" = off ] \
      && ok "codex absent, SECOND_OPINION=off (by choice)" \
      || note "codex CLI absent — second opinion auto-skips (CODEX_SKIP in PROGRESS). Install codex + 'codex login' or set OPENAI_API_KEY in secret.codex.env."
  fi

  echo "doctor: layout"
  case "$ROOT" in
    /mnt/*) note "ROOT is under $ROOT (/mnt) — Windows FS via WSL2 is slow. Prefer a Linux-native path (e.g. ~/dev/...)." ;;
    *) ok "ROOT on Linux-native FS ($ROOT)" ;;
  esac

  echo "doctor: secrets / billing mode"
  # Plaintext scoped env files (secret.<scope>.env, gitignored). Verify each file that holds
  # values is not group/world-readable — that is the only at-rest protection left.
  for s in worker gate codex; do
    f="$(secret_file "$s")"
    if secret_present "$s"; then
      perms="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
      case "$perms" in
        600|400) ok "secret.$s configured (perms $perms)" ;;
        *)       note "secret.$s configured but perms are $perms — tighten: chmod 600 $f" ;;
      esac
    elif [ -f "$f" ]; then
      note "secret.$s is an empty template — fill in values or leave it (missing scope = run bare)"
    fi
  done
  case "$(auth_mode)" in
    subscription) ok "auth = subscription (OAuth token in worker scope → Pro/Max quota, no metered API)" ;;
    api)          ok "auth = api (metered billing)"
                  note "metered API: a fleet loop can burn many tokens. Prefer 'claude setup-token' -> secret.worker.env." ;;
    host)         ok "auth = host (workers ride this host's claude login)"
                  note "host login is your PERSONAL credential; for a scoped one: claude setup-token -> secret.worker.env" ;;
    none)         note "no credential — run: claude setup-token and paste into secret.worker.env (or log in to claude on this host)" ;;
  esac
fi

echo "doctor: project state"
if [ -d "$CANONICAL/.git" ]; then
  if git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then ok "canonical has BASE_BRANCH '$BASE_BRANCH'"; else bad "canonical exists but has no '$BASE_BRANCH' branch (fix config.env BASE_BRANCH or create it)"; fi
else
  [ "$QUICK" -eq 1 ] && note "canonical not set up yet — run ./control/setup.sh" || bad "canonical not found — run ./control/setup.sh"
fi

if [ "$QUICK" -eq 0 ]; then
  # Orphan detection: state files without a worktree, and worktrees without state.
  shopt -s nullglob
  for f in "$STATE_DIR"/*.env; do
    ( source "$f"
      [ -e "${WORKTREE:-$(worktree_for "$TASK")}/.git" ] \
        || note "state/$TASK.env exists but its worktree is gone (orphan) — ./control/reap.sh $TASK or ./control/spawn.sh $TASK" )
  done
  for d in "$WORKTREES_DIR"/*/; do
    [ -d "$d" ] || continue
    t="$(basename "$d")"
    [ -f "$STATE_DIR/$t.env" ] || note "worktree '$t' has no state file — ./control/spawn.sh $t re-adopts it"
  done
fi

echo
if [ "$fail" -gt 0 ]; then echo "doctor: $fail blocking issue(s), $warn warning(s)."; exit 1; fi
[ "$QUICK" -eq 1 ] || echo "doctor: ready ($warn warning(s))."
exit 0
