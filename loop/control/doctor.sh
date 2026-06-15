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

echo "doctor: environment"
command -v docker >/dev/null 2>&1 && { docker info >/dev/null 2>&1 && ok "docker reachable" || bad "docker installed but not reachable (is the daemon running?)"; } || bad "docker not found"
command -v git    >/dev/null 2>&1 && ok "git"  || bad "git not found"
command -v tmux   >/dev/null 2>&1 && ok "tmux" || bad "tmux not found"
command -v jq     >/dev/null 2>&1 && ok "jq"   || bad "jq not found (required by hooks and the loop)"

if [ "$QUICK" -eq 0 ]; then
  command -v shellcheck >/dev/null 2>&1 && ok "shellcheck (toolkit tests)" || note "shellcheck absent (tests-toolkit will skip lint)"
  command -v inotifywait >/dev/null 2>&1 && ok "inotifywait" || note "inotifywait absent — watch/loop fall back to ${LOOP_POLL_SECS}s polling (fine)"

  echo "doctor: layout"
  case "$ROOT" in
    /mnt/*) note "ROOT is under $ROOT (/mnt) — Windows FS via WSL2 is slow and weakens isolation. Prefer a Linux-native path (e.g. ~/dev/...)." ;;
    *) ok "ROOT on Linux-native FS ($ROOT)" ;;
  esac

  echo "doctor: secrets / billing mode"
  if [ -f "$CONTROL_DIR/secret.env" ]; then
    perms="$(stat -c '%a' "$CONTROL_DIR/secret.env" 2>/dev/null || echo '?')"
    [ "$perms" = "600" ] && ok "secret.env perms 600" || note "secret.env perms are $perms — tighten with: chmod 600 control/secret.env"
    case "$(auth_mode)" in
      subscription)
        ok "auth = subscription (CLAUDE_CODE_OAUTH_TOKEN set → Pro/Max quota, no metered API)"
        [ -n "${ANTHROPIC_API_KEY:-}" ] && note "ANTHROPIC_API_KEY is ALSO set but will be ignored (OAuth token wins; it is not passed to containers)." ;;
      api)
        ok "auth = api (ANTHROPIC_API_KEY set → pay-as-you-go metered billing)"
        note "metered API: a fleet loop can burn many tokens. To use your subscription instead, run 'claude setup-token' and put CLAUDE_CODE_OAUTH_TOKEN in secret.env." ;;
      none)
        note "no credential set — add CLAUDE_CODE_OAUTH_TOKEN (subscription) or ANTHROPIC_API_KEY (metered) to secret.env" ;;
    esac
    grep -qE 'REPLACE-ME' "$CONTROL_DIR/secret.env" 2>/dev/null && note "secret.env still has a REPLACE-ME placeholder"
  else
    note "control/secret.env missing — copy secret.env.example and add a credential"
  fi
fi

echo "doctor: project state"
if [ -d "$CANONICAL/.git" ]; then
  if git -C "$CANONICAL" show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then ok "canonical has BASE_BRANCH '$BASE_BRANCH'"; else bad "canonical exists but has no '$BASE_BRANCH' branch (fix config.env BASE_BRANCH or create it)"; fi
else
  [ "$QUICK" -eq 1 ] && note "canonical not set up yet — run ./control/setup.sh" || bad "canonical not found — run ./control/setup.sh"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 && ok "worker image '$IMAGE' built" || note "worker image '$IMAGE' not built yet (setup.sh/up.sh builds it)"

if [ "$QUICK" -eq 0 ]; then
  # Orphan detection: state files without a container, and vice versa.
  shopt -s nullglob
  for f in "$STATE_DIR"/*.env; do
    ( source "$f"; container_exists "$TASK" || note "state/$TASK.env exists but container is gone (orphan) — ./control/reap.sh $TASK or ./control/spawn.sh $TASK" )
  done
fi

echo
if [ "$fail" -gt 0 ]; then echo "doctor: $fail blocking issue(s), $warn warning(s)."; exit 1; fi
[ "$QUICK" -eq 1 ] || echo "doctor: ready ($warn warning(s))."
exit 0
