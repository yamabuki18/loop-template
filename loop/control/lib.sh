#!/usr/bin/env bash
# Shared helpers for the parallel-dev toolkit. Sourced by every script.
# shellcheck disable=SC2034  # vars here (CANONICAL/REVIEW_DIR/SKILLS_DIR/...) are used by the
#                            # scripts that source this lib, so they look "unused" to a lone check.
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$CONTROL_DIR/.." && pwd)"

# Where central (out-of-tree) workspaces live: $LOOP_HOME/workspaces/<path-slug>. This is what
# keeps a project's git history clean — the loop never writes a single file into the project.
: "${LOOP_HOME:=$HOME/.loop}"

# Stable slug for an absolute path (same scheme Claude Code uses for ~/.claude/projects).
path_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# --- project resolution: one engine, many workspaces ------------------------------------------
# Three layouts are supported, resolved in this order:
#   explicit  : $LOOP_PROJECT points at the workspace (always wins).
#   workspace : a directory holding a `.loop-workspace` marker — either an ancestor of $PWD
#               (in-tree workspace made by `loop init`), or the CENTRAL one for this project at
#               $LOOP_HOME/workspaces/<slug-of-git-toplevel-or-PWD> (made by `loop here`; the
#               project repo itself stays untouched — zero-footprint daily-dev mode).
#   legacy    : the whole template was copied into the project (scaffold.sh). ROOT is control/'s
#               parent and config/secret live inside control/ — exactly the historical behavior.
# Every script goes through $ROOT / $CONFIG_DIR / $CONTROL_DIR; none may hardcode layout.
ROOT=""; CONFIG_DIR=""
if [ -n "${LOOP_PROJECT:-}" ]; then
  [ -d "$LOOP_PROJECT" ] || { echo "ERROR: LOOP_PROJECT='$LOOP_PROJECT' is not a directory" >&2; exit 1; }
  ROOT="$(cd "$LOOP_PROJECT" && pwd)"; CONFIG_DIR="$ROOT"
else
  _d="$PWD"
  while [ "$_d" != "/" ]; do
    if [ -f "$_d/.loop-workspace" ]; then ROOT="$_d"; CONFIG_DIR="$_d"; break; fi
    _d="$(dirname "$_d")"
  done
  unset _d
fi
if [ -z "$ROOT" ]; then  # central workspace for the project containing $PWD?
  _p="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  _ws="$LOOP_HOME/workspaces/$(path_slug "$_p")"
  if [ -f "$_ws/.loop-workspace" ]; then ROOT="$_ws"; CONFIG_DIR="$_ws"; fi
  unset _p _ws
fi
if [ -z "$ROOT" ]; then  # legacy copy-deployed layout
  ROOT="$ENGINE_DIR"; CONFIG_DIR="$CONTROL_DIR"
fi

STATE_DIR="$ROOT/state"
WORKTREES_DIR="$ROOT/worktrees"
CANONICAL="$ROOT/canonical"
REVIEW_DIR="$ROOT/review"
SKILLS_DIR="$ROOT/skills"
MEMORY_DIR="$ROOT/memory"
LOG_DIR="$STATE_DIR/logs"

# --- load config (no error if absent). Secrets are NEVER sourced into this shell: they stay
# encrypted at rest and are injected per-scope into exactly one child process by secret_exec().
if [ -f "$CONFIG_DIR/config.env" ]; then source "$CONFIG_DIR/config.env"; fi

: "${PROJECT_NAME:=claudeparallel}"
: "${WORKER_COUNT:=3}"
: "${BASE_BRANCH:=main}"
: "${PROTECTED_PATHS:=tests/}"
# Model routing (claude --model). Empty = the claude CLI's default. Defaults stay empty here so
# an older config.env keeps its exact pre-3.1 behavior; the config template routes workers to a
# cheaper model (sonnet) and the interactive supervisor to a strong one (opus).
: "${WORKER_MODEL:=}"
: "${PLANNER_MODEL:=}"
: "${SUPERVISOR_MODEL:=}"
# Loop knobs (defaults mirror config.env so loop scripts work even on an older config).
: "${MAX_FEEDBACK_ROUNDS:=4}"
: "${LOOP_MAX_CYCLES:=0}"
: "${GATE_CONCURRENCY:=2}"
: "${LOOP_POLL_SECS:=5}"
: "${AUTO_SYNC:=1}"
: "${PLANNER_ENABLED:=1}"
: "${PLANNER_MAX_SLICES:=3}"
: "${NOTIFY:=1}"
# Context-hygiene knobs: cap what the loop feeds back into LLM contexts (planner/worker).
: "${PROGRESS_MAX_LINES:=400}"   # compact memory/PROGRESS.md when it grows past this
: "${PROGRESS_KEEP_LINES:=200}"  # ... keeping this many recent events verbatim
: "${FEEDBACK_MAX_LINES:=200}"   # cap the gate log routed into a worker's feedback.md
: "${WIKI_ENABLED:=1}"           # scoped LLM wiki: slice-owned wiki/modules/ pages + scripted index
# AIF-style event ontology (memory/ontology/graph.jsonl): host-appended CA/PA nodes derived
# from loop events (gate FAIL, codex concerns, land, handoff). Zero hand-maintenance by design —
# the research behind it says hand-curated knowledge structures rot (their staleness then harms
# like a degraded verifier), so ONLY loop events may write here. 0 = no ontology writes at all.
: "${ONTOLOGY_ENABLED:=1}"
# Test-gaming monitor (gate.sh): scan the worker diff for verifier-weakening patterns
# (.skip/xit/xdescribe/pytest.mark.skip added, assertions deleted wholesale, `|| true` added to
# check scripts). off | warn (log + PROGRESS, default) | block (fail the gate, exit 6).
: "${GATE_TESTGAMING:=warn}"
# Structurally deny worker edits to harness/ (the gate's own check scripts run FROM THE MERGED
# TREE, so a worker editing harness/check.sh could neuter its own gate — the cheapest reward
# hack there is). Enforced in gate.sh like PROTECTED_PATHS (exit 4). 1 = on (default).
: "${GATE_PROTECT_HARNESS:=1}"
# Design SSOT direct-read (plan.sh): absolute path to a typed-design tree (e.g. a Spec Atlas
# atlas/ in an external design repo) the planner reads directly. Empty = auto-detect
# <repo>/atlas/ when present.
: "${DESIGN_SSOT_DIR:=}"
# Host-mode worker signals: cycles the loop tolerates an unknown/gone herdr agent state before
# gating anyway (a crashed pane must not strand committed work).
: "${AGENT_UNKNOWN_GRACE:=6}"
# Worker liveness watchdog (loop.sh). A hung / spinning / never-committing worker changes no ref
# and (with herdr up) shows 'working' forever, so without this it pins BUSY=1 and the loop's
# completion condition is never reached. WORKER_TIMEOUT_SECS = seconds of NO progress (no new
# commit AND agent state not 'working') before the watchdog nudges the worker; WORKER_HANG_GRACE
# = extra seconds after that nudge before it auto-respawns (non-destructive: assignment kept,
# only un-committed scratch dies) and consumes a feedback round. 0 = watchdog OFF (default here
# keeps an older config's behavior unchanged; the config template turns it on).
: "${WORKER_TIMEOUT_SECS:=0}"
: "${WORKER_HANG_GRACE:=300}"
# sync.sh anti-corruption fallback when herdr can't report a worker's state (server down/crashed
# pane): rather than blindly rebasing a possibly-live worktree, defer unless it has been quiet
# (no new commit) for at least this many seconds. 0 = heuristic off (pre-3.3 behavior: rebase any
# non-'working' worker). The config template turns it on.
: "${SYNC_IDLE_SECS:=0}"
# Archive a worker's Claude session transcript(s) to state/logs/<task>.session/ when it is
# reaped/respawned (best-effort). Workers run in an interactive TUI so there is no --output-format
# capture; this preserves the *.jsonl session logs so a stalled/derailed worker's reasoning can be
# reconstructed post-hoc. 0 = off (default; the transcripts die with the reaped config dir).
: "${LOOP_WORKER_TRANSCRIPT:=0}"
# Secrets backend: sops (default; sops+age, free, no account) | op (1Password CLI) | plain
# (legacy cleartext env file — doctor warns loudly).
: "${SECRET_BACKEND:=sops}"
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
# Codex second opinion (independent cross-architecture review). off | advise | block.
: "${SECOND_OPINION:=advise}"
: "${SECOND_OPINION_PLAN:=}"     # per-phase override; empty = inherit SECOND_OPINION
: "${SECOND_OPINION_GATE:=}"     # per-phase override; empty = inherit SECOND_OPINION
: "${CODEX_MODEL:=}"             # empty = codex CLI default
: "${CODEX_TIMEOUT:=300}"        # seconds; a hung codex must never block the loop
: "${CODEX_GATE_MAX_ROUNDS:=1}"  # advise mode: max feedback rounds codex-only HIGH concerns may consume
: "${CODEX_DIFF_MAX_LINES:=4000}" # cap on the diff embedded in the gate-review prompt

# --- naming ---
branch_for()     { echo "work/$1"; }                        # default branch per task
worktree_for()   { echo "$WORKTREES_DIR/$1"; }              # the worker's git worktree
harness_dir()    { echo "$STATE_DIR/workers/$1/harness"; }  # task.md / feedback.md / owned-paths / STATUS
claude_cfg_dir() { echo "$STATE_DIR/workers/$1/claude"; }   # per-worker CLAUDE_CONFIG_DIR

die() { echo "ERROR: $*" >&2; exit 1; }

# --- secrets (scoped, encrypted at rest, injected into exactly one child process) -------------
# Scopes: worker (the Claude credential), gate (test-time secrets), codex (OPENAI_API_KEY).
# The file for a scope is secret.<scope>.sops.env (sops backend). A missing scope file is NOT an
# error: secret_exec then runs the command bare (e.g. codex may use its own `codex login`).
secret_file() {
  case "$SECRET_BACKEND" in
    sops)  echo "$CONFIG_DIR/secret.$1.sops.env" ;;
    op)    echo "$CONFIG_DIR/secret.$1.op.env" ;;
    plain) echo "$CONFIG_DIR/secret.$1.env" ;;
    *)     echo "$CONFIG_DIR/secret.$1.sops.env" ;;
  esac
}
secret_present() { [ -f "$(secret_file "$1")" ]; }

# printf %q-quote every arg into ONE string (sops exec-env historically takes the command as a
# single shell string; multi-arg only landed in sops >= 3.10 — quote for version robustness).
shell_quote() { local out="" a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }

# Claude Code auth precedence: if ANTHROPIC_API_KEY is present it WINS and forces metered API
# billing. So for the worker scope, when the OAuth token is set, the API key must be dropped
# INSIDE the decrypted child env (this shell never sees the values). See auth_mode() below.
cred_precedence_prelude() {
  if [ "${1:-}" = worker ]; then
    printf '%s' 'if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then unset ANTHROPIC_API_KEY; fi; '
  fi
}

# secret_exec <scope> -- <cmd> [args...] — run cmd with that scope's secrets in its env ONLY.
# No scope file -> run bare. All backends route through `sh -c` so the precedence prelude and
# the version-robust single-string sops contract are identical everywhere.
secret_exec() {
  local scope="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local f; f="$(secret_file "$scope")"
  if [ ! -f "$f" ]; then "$@"; return; fi
  local script; script="$(cred_precedence_prelude "$scope")exec $(shell_quote "$@")"
  case "$SECRET_BACKEND" in
    sops)  SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops exec-env "$f" "$script" ;;
    op)    op run --env-file="$f" -- sh -c "$script" ;;
    plain) ( set -a; . "$f"; set +a; exec sh -c "$script" ) ;;
    *)     die "unknown SECRET_BACKEND '$SECRET_BACKEND' (sops|op|plain)" ;;
  esac
}

# --- credential / billing mode -----------------------------------------------------------------
# How the worker/planner Claude is powered, without ever printing a secret value:
#   subscription : secret.worker file holds CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`)
#   api          : secret.worker file holds ANTHROPIC_API_KEY (metered)
#   host         : no scope file, but the operator's own `claude` login exists on this host —
#                  spawn.sh copies it into the per-worker CLAUDE_CONFIG_DIR (v3 host-mode
#                  convenience; doctor notes the concealment tradeoff)
#   none         : nothing available — workers cannot run Claude
_AUTH_MODE_CACHE=""
auth_mode() {
  if [ -n "$_AUTH_MODE_CACHE" ]; then echo "$_AUTH_MODE_CACHE"; return 0; fi
  local probe='if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo subscription; elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then echo api; else echo none; fi'
  local mode=none
  if secret_present worker; then
    # One decrypt per process (cached); the probe echoes a MODE, never a value.
    if mode="$(secret_exec worker -- sh -c "$probe" 2>/dev/null)"; then :; else mode=none; fi
    case "$mode" in subscription|api) ;; *) mode=none ;; esac
  fi
  if [ "$mode" = none ]; then
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then mode=subscription   # exported by the operator (CI etc.)
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then mode=api
    elif [ -f "$HOME/.claude/.credentials.json" ]; then mode=host
    fi
  fi
  _AUTH_MODE_CACHE="$mode"; echo "$mode"
}
have_credential() { [ "$(auth_mode)" != none ]; }

# --- herdr (fleet display, agent-state detection, notifications) --------------------------------
# herdr is the v3 replacement for tmux: every worker Claude runs in a herdr pane whose agent
# state (idle/working/blocked) herdr detects natively. ALL calls are best-effort behind
# herdr_ok — the loop's guarantees (SessionStart/Stop hooks + ref-watching) never depend on it.
herdr_ok() { command -v herdr >/dev/null 2>&1 && herdr status server >/dev/null 2>&1; }
# Always returns 0 (empty output when unknown): callers assign `ws="$(herdr_workspace)"` under
# set -e, and a bare failing substitution would kill the whole script (the D1 class of bug).
herdr_workspace() { cat "$STATE_DIR/herdr-workspace" 2>/dev/null || true; }

# Agent state for a worker: idle|working|blocked|done|unknown|none (none = no server/agent).
# Parses `herdr agent get` output defensively (grep for a state token) — the exact format is
# not contract; worker names (w1..wN) cannot collide with the tokens.
agent_state() {
  local t="$1" out st
  herdr_ok || { echo none; return 0; }
  if ! out="$(herdr agent get "$t" 2>/dev/null)"; then echo none; return 0; fi
  st="$(printf '%s\n' "$out" | tr '[:upper:]' '[:lower:]' \
        | grep -oE '\b(idle|working|blocked|done|unknown)\b' | head -1)"
  echo "${st:-unknown}"
}

# The pane id hosting a worker's agent (for send-keys/close). Empty + rc 1 when absent.
agent_pane() {
  local t="$1" out p
  herdr_ok || return 1
  out="$(herdr agent get "$t" 2>/dev/null)" || return 1
  p="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]+:p[A-Za-z0-9_-]+' | head -1)"
  [ -n "$p" ] || return 1
  echo "$p"
}

# Best-effort nudge into a worker's Claude UI. Text and the submitting Enter go as SEPARATE
# calls with a pause between them — a combined send races the TUI and can leave the nudge
# typed-but-unsubmitted (the same bug the tmux send-keys path had). Delivery is still
# GUARANTEED by the SessionStart/stop-gate hooks, not by this.
agent_send() {
  local t="$1"; shift
  herdr_ok || return 1
  herdr agent send "$t" "$*" 2>/dev/null || return 1
  sleep 1
  local p
  if p="$(agent_pane "$t")"; then herdr pane send-keys "$p" Enter 2>/dev/null || true; fi
  return 0
}

# --- loop helpers (shared by loop.sh / watch.sh / plan.sh / sync.sh) ---

# All known worker task ids (from state/*.env), one per line.
worker_tasks() {
  shopt -s nullglob
  local f t
  for f in "$STATE_DIR"/*.env; do
    t="$(basename "$f" .env)"; echo "$t"
  done
}

# UTC timestamp (no Math.random/Date restrictions here — this is bash).
now_utc() { date -u +%FT%TZ 2>/dev/null || echo "unknown"; }

# Liveness watchdog decision (PURE — unit-tested; loop.sh feeds it real times). Given how many
# seconds a BUSY worker has shown no progress and whether it was already warned once, decide the
# action. Echoes exactly one of: none | warn | act.
#   worker_watchdog_action <idle_secs> <already_warned:0|1>
# Off (echoes none) when WORKER_TIMEOUT_SECS is 0/unset. First it waits WORKER_TIMEOUT_SECS then
# says 'warn'; after the warning it waits WORKER_HANG_GRACE more then says 'act' (respawn/escalate).
worker_watchdog_action() {
  local idle="${1:-0}" warned="${2:-0}" limit
  [ "${WORKER_TIMEOUT_SECS:-0}" -gt 0 ] || { echo none; return 0; }
  if [ "$warned" = 1 ]; then limit="${WORKER_HANG_GRACE:-300}"; else limit="${WORKER_TIMEOUT_SECS}"; fi
  if [ "$idle" -ge "$limit" ]; then
    if [ "$warned" = 1 ]; then echo act; else echo warn; fi
  else
    echo none
  fi
}

# Crash reconciliation for the backlog (PURE — unit-tested). loop.sh marks a goal it is working
# as "- [~]"; if the loop then crashes, next_goal (which only matches "- [ ]") would skip that
# goal forever and it would be silently lost. On (re)start, flip every "- [~]" back to "- [ ]"
# so the goal is re-picked. Idempotent. Echoes the number of goals reset.
#   backlog_reset_inprogress <backlog.md>
backlog_reset_inprogress() {
  local f="${1:?}" n
  [ -f "$f" ] || { echo 0; return 0; }
  n="$(grep -cE '^- \[~\] ' "$f" 2>/dev/null || true)"; n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    local tmp; tmp="$(mktemp)"
    sed -E 's/^- \[~\] /- [ ] /' "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  echo "$n"
}

# sync.sh decision when herdr can't report a worker's state (PURE — unit-tested). Given how many
# seconds the worktree has been quiet (no new commit), echo "defer" (too recent — a live worker
# may be editing) or "ok" (quiet long enough to rebase safely). SYNC_IDLE_SECS=0 -> always "ok".
#   sync_unknown_decision <quiet_secs>
sync_unknown_decision() {
  local quiet="${1:-0}"
  [ "${SYNC_IDLE_SECS:-0}" -gt 0 ] || { echo ok; return 0; }
  if [ "$quiet" -lt "${SYNC_IDLE_SECS}" ]; then echo defer; else echo ok; fi
}

# --- heartbeat exclusivity -------------------------------------------------------------------
# loop.sh (full-auto) and watch.sh (semi-auto, incl. `loop supervise`) both drive the gate, so
# running them together double-gates every commit. Each heartbeat claims state/<name>.pid; the
# other refuses to start while that pid is alive. All helpers are rc-0-always EXCEPT
# heartbeat_pid_alive, which callers must wrap in `if` (lib.sh runs under set -e — D1 class).
heartbeat_pid_alive() {  # <name> — rc 0 and prints the pid iff that heartbeat still runs
  local pid
  pid="$(cat "$STATE_DIR/$1.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  echo "$pid"
}
heartbeat_claim()   { mkdir -p "$STATE_DIR"; echo $$ > "$STATE_DIR/$1.pid"; }
heartbeat_release() { rm -f "$STATE_DIR/$1.pid" 2>/dev/null || true; }

# Current tip of a worker's branch in canonical (worktrees share refs, so a worker's commit is
# instantly visible here — this replaces the v2 exchange push-event marker). "none" if no branch.
worker_head() {
  git -C "$CANONICAL" rev-parse --verify -q "refs/heads/$(branch_for "$1")" 2>/dev/null || echo none
}

# Compact one-line stats for a worker's branch vs the base it forked from — per-slice telemetry
# for PROGRESS after a land/escalate (workers, unlike the planner, have no token/usage capture,
# so this "how big was the work" signal is all the operator gets to reconstruct a run). Reads
# git only; never fails the caller. Call BEFORE land.sh merges (afterwards the merge-base moves).
#   slice_stats <task>  ->  e.g. "commits=3 +120 -14 files=5"
slice_stats() {
  local t="$1" br mb commits sums
  br="$(branch_for "$t")"
  git -C "$CANONICAL" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1 || { echo "commits=0"; return 0; }
  mb="$(git -C "$CANONICAL" merge-base "$BASE_BRANCH" "$br" 2>/dev/null || true)"
  [ -n "$mb" ] || { echo "commits=?"; return 0; }
  commits="$(git -C "$CANONICAL" rev-list --count "$mb..$br" 2>/dev/null || echo 0)"
  sums="$(git -C "$CANONICAL" diff --numstat "$mb" "$br" 2>/dev/null \
          | awk '{i+=($1=="-"?0:$1); d+=($2=="-"?0:$2); f++} END{printf "+%d -%d files=%d", i+0, d+0, f+0}')"
  echo "commits=${commits:-0} ${sums:-+0 -0 files=0}"
}

# Append one event to memory/PROGRESS.md (the loop's external memory). Tab-separated.
#   progress_log <EVENT> <task/slice> <branch@sha-or-->  <free text note>
progress_log() {
  local ev="${1:-?}" who="${2:--}" ref="${3:--}" note="${4:-}"
  mkdir -p "$MEMORY_DIR"
  [ -f "$MEMORY_DIR/PROGRESS.md" ] || printf '# PROGRESS\n\n## Log\n' > "$MEMORY_DIR/PROGRESS.md"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_utc)" "$ev" "$who" "$ref" "$note" >> "$MEMORY_DIR/PROGRESS.md"
  progress_compact
}

# Keep PROGRESS.md a bounded, planner-friendly context: the planner reads the WHOLE file every
# cycle, so unbounded append-only growth silently burns tokens and buries fresh signal in stale
# noise. Past PROGRESS_MAX_LINES, fold events older than the last PROGRESS_KEEP_LINES into one
# `# [compacted ...]` count line — except ESCALATED / LAND_FAIL events, which stay verbatim
# (they are unresolved work a future plan must see). Header/summary lines are always preserved.
progress_compact() {
  local f="$MEMORY_DIR/PROGRESS.md"
  [ -f "$f" ] || return 0
  local total; total="$(wc -l < "$f")"
  [ "$total" -gt "${PROGRESS_MAX_LINES:-400}" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v keep="${PROGRESS_KEEP_LINES:-200}" -v now="$(now_utc)" '
    # An "event" is a TSV line starting with a UTC timestamp; everything else is header.
    # No {n} interval regex here — mawk (a common /usr/bin/awk) may not support it.
    { line[NR]=$0; isev[NR] = ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z\t/) ? 1 : 0; ev_total += isev[NR] }
    END {
      cutoff = ev_total - keep                 # events beyond this index (1-based) stay verbatim
      seen = 0
      # First: header lines + the summary of folded events, in original order.
      for (i = 1; i <= NR; i++) if (!isev[i]) print line[i]
      # Count folded events (skipping the always-kept kinds).
      for (i = 1; i <= NR; i++) {
        if (!isev[i]) continue
        seen++
        if (seen > cutoff) break
        split(line[i], f_, "\t")
        if (f_[2] == "ESCALATED" || f_[2] == "LAND_FAIL") { keepline[i] = 1; continue }
        cnt[f_[2]]++; folded++
      }
      if (folded > 0) {
        s = "# [compacted " now "] " folded " older events folded:"
        for (k in cnt) s = s " " k "=" cnt[k]
        print s
      }
      # Then: preserved ESCALATED/LAND_FAIL from the folded range + the recent tail, in order.
      seen = 0
      for (i = 1; i <= NR; i++) {
        if (!isev[i]) continue
        seen++
        if (seen <= cutoff) { if (keepline[i]) print line[i]; continue }
        print line[i]
      }
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Deterministically validate a planner slices.json BEFORE any worker burns tokens on it.
# The prompt asks for disjoint, protected-free paths (advisory, L1); this is the structural
# check (L3) that catches a planner that ignored it — a bad plan otherwise surfaces later as
# merge conflicts (gate exit 3) or land denial (exit 4), each costing a full feedback round.
# Checks: (a) schema — name/brief strings, non-empty paths[], optional tests[];
#         (b) no slice path under/over a PROTECTED_PATHS prefix;
#         (c) paths disjoint ACROSS slices (prefix-overlap in either direction).
# Prints each violation to stderr; returns non-zero on any.
validate_slices() {
  local f="$1"
  jq -e 'type=="array" and length>=1' "$f" >/dev/null 2>&1 \
    || { echo "slices: not a non-empty JSON array" >&2; return 1; }
  jq -e 'all(.[];
        (.name  | type=="string" and length>0)
    and (.brief | type=="string" and length>0)
    and (.paths | type=="array" and length>0 and all(.[]; type=="string" and length>0))
    and ((.tests // []) | type=="array" and all(.[]; type=="string")))' "$f" >/dev/null 2>&1 \
    || { echo "slices: schema violation — every slice needs name, brief, non-empty paths[] (tests[] optional array)" >&2; return 1; }
  jq -r 'to_entries[] | .key as $i | .value.paths[] | "\($i)\t\(.)"' "$f" \
    | awk -F'\t' -v prot="${PROTECTED_PATHS:-}" '
      { idx[NR]=$1; p=$2; sub(/^\.\//, "", p); path[NR]=p }
      END {
        bad = 0
        n = split(prot, pr, /[[:space:]]+/)
        for (i = 1; i <= NR; i++) {
          for (k = 1; k <= n; k++) {
            if (pr[k] != "" && (index(path[i], pr[k]) == 1 || index(pr[k], path[i]) == 1)) {
              printf "slices: slice %s claims protected path: %s (protected: %s)\n", idx[i], path[i], pr[k] > "/dev/stderr"; bad = 1
            }
          }
          for (j = i + 1; j <= NR; j++) {
            if (idx[i] != idx[j] && (index(path[i], path[j]) == 1 || index(path[j], path[i]) == 1)) {
              printf "slices: paths overlap across slices %s and %s: %s vs %s\n", idx[i], idx[j], path[i], path[j] > "/dev/stderr"; bad = 1
            }
          }
        }
        exit bad
      }'
}

# Regenerate memory/REPO_MAP.md from canonical — a deterministic structural map (no Claude, no
# tokens). Called after every land and at setup, so the planner reads a CURRENT map instead of
# exploring the repo from scratch each cycle (and instead of trusting a hand-written, rotting one).
repo_map_refresh() {
  [ -d "$CANONICAL/.git" ] || return 0
  mkdir -p "$MEMORY_DIR"
  {
    echo "# REPO_MAP — auto-generated structural map. Do not edit (regenerated on every land)."
    echo
    echo "Base: $BASE_BRANCH @ $(git -C "$CANONICAL" rev-parse --short HEAD 2>/dev/null || echo '?')  ($(now_utc))"
    echo
    echo "## Directories (tracked-file counts, depth <= 3)"
    echo '```'
    git -C "$CANONICAL" ls-files 2>/dev/null \
      | awk -F/ '{
          if (NF == 1) c["(root)"]++
          else { p = ""; for (i = 1; i < NF && i <= 3; i++) { p = p $i "/"; c[p]++ } }
        } END { for (k in c) printf "%6d  %s\n", c[k], k }' \
      | sort -k2
    echo '```'
  } > "$MEMORY_DIR/REPO_MAP.md"
}

# One-line token-usage note from a `claude -p --output-format json` result file. Field paths
# verified empirically against Claude Code 2.1.x. Prints nothing (and still returns 0) if the
# file is missing or unparsable (e.g. the planner timed out mid-write) — never fails the caller.
plan_usage_note() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  jq -r 'select(type=="object" and .usage != null)
         | "in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0)"
         + " cache_read=\(.usage.cache_read_input_tokens // 0)"
         + " cache_write=\(.usage.cache_creation_input_tokens // 0)"
         + " turns=\(.num_turns // 0) cost_usd=\(.total_cost_usd // 0)"' \
    "$f" 2>/dev/null || true
}

# Deterministically (re)generate wiki/index.md in canonical from each page's frontmatter —
# zero tokens, zero merge conflicts. This is the scoped "LLM wiki" pattern: workers keep their
# slice's wiki/modules/<name>.md fresh as part of DONE (the moment they still hold the full
# implementation context — the cheap moment to write it down), the planner reads index +
# relevant pages instead of re-exploring the codebase, and the index — the one file everyone
# would fight over — is owned by this script instead of any LLM.
wiki_index_refresh() {
  [ "${WIKI_ENABLED:-1}" = 1 ] || return 0
  local wdir="$CANONICAL/wiki"
  [ -d "$wdir" ] || return 0
  local tmp; tmp="$(mktemp)"
  {
    echo "# Wiki Index"
    echo
    echo "> AUTO-GENERATED from page frontmatter on every land — edits here are overwritten."
    echo "> Read this index first, then open ONLY the pages you need. Never bulk-load the wiki."
    local sec t hdr f rel fm typ title sources printed
    for sec in module:Modules concept:Concepts entity:Entities summary:Summaries other:Other; do
      t="${sec%%:*}"; hdr="${sec#*:}"; printed=0
      while IFS= read -r f; do
        rel="${f#"$wdir"/}"
        fm="$(awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$f")"
        typ="$(sed -n 's/^type:[[:space:]]*//p' <<<"$fm" | head -1 | awk '{print $1}')"
        case "$t" in
          other) case "$typ" in module|concept|entity|summary) continue ;; esac ;;
          *)     [ "$typ" = "$t" ] || continue ;;
        esac
        title="$(sed -n 's/^title:[[:space:]]*//p' <<<"$fm" | head -1)"
        [ -n "$title" ] || title="$(basename "$f" .md)"
        sources="$(awk '/^sources:/{s=1; next} s && /^[^ ]/{s=0} s && /^[[:space:]]*- /{sub(/^[[:space:]]*- /, ""); printf "%s%s", (n++ ? ", " : ""), $0}' <<<"$fm")"
        [ "$printed" = 1 ] || { echo; echo "## $hdr"; printed=1; }
        printf -- '- [%s](%s)%s\n' "$title" "$rel" "${sources:+ — sources: $sources}"
      done < <(find "$wdir" -name '*.md' ! -name 'index.md' | sort)
    done
  } > "$tmp" && mv "$tmp" "$wdir/index.md"
}

# --- AIF event ontology (memory/ontology/) ------------------------------------------------------
# Append-only argument graph derived from LOOP EVENTS ONLY (never hand-written, never
# LLM-written): I-nodes are the repo's wiki/modules pages (worker-maintained, existing
# contract); this file holds the S-nodes — CA (conflict: gate FAIL, codex concerns) and PA
# (preference: land, handoff approval) — in AIF terms (upper ontology fixed here; project
# forms vocabulary may extend `scheme` values, documented in memory/ontology/README.md).
# One JSON object per line: {"ts","node":"I|RA|CA|PA","scheme","premise","target","note"}.
# Contract: ALWAYS rc 0 (best-effort, herdr-style) — an ontology write may never fail a caller.
ontology_event() { # <node:I|RA|CA|PA> <scheme> <premise> <target> <note>
  [ "${ONTOLOGY_ENABLED:-1}" = 1 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local node="${1:-}" scheme="${2:-}" premise="${3:-}" target="${4:-}" note="${5:-}"
  case "$node" in I|RA|CA|PA) ;; *) return 0 ;; esac
  mkdir -p "$MEMORY_DIR/ontology" 2>/dev/null || return 0
  jq -cn --arg ts "$(now_utc)" --arg node "$node" --arg scheme "$scheme" \
         --arg premise "$premise" --arg target "$target" --arg note "$note" \
         '{ts:$ts, node:$node, scheme:$scheme, premise:$premise, target:$target, note:$note}' \
    >> "$MEMORY_DIR/ontology/graph.jsonl" 2>/dev/null || true
  return 0
}

# Deterministically summarize the event graph into a small planner-readable digest (same move
# as wiki_index_refresh / repo_map_refresh: zero tokens, regenerated — never hand-edited).
# Unresolved CA nodes (conflicts newer than the last PA on the same target) are the signal a
# planner must see; resolved history is folded into counts.
ontology_digest_refresh() {
  [ "${ONTOLOGY_ENABLED:-1}" = 1 ] || return 0
  local g="$MEMORY_DIR/ontology/graph.jsonl"
  [ -s "$g" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp; tmp="$(mktemp)"
  {
    echo "# Ontology digest — auto-generated from memory/ontology/graph.jsonl on every land."
    echo "# CA = recorded conflict (gate FAIL / codex concern), PA = recorded acceptance."
    echo
    echo "## Open conflicts (CA newer than the target's last PA — treat as unresolved signal)"
    jq -rs '
      (map(select(.node=="PA")) | group_by(.target) | map({(. [0].target): (max_by(.ts).ts)}) | add // {}) as $pa
      | map(select(.node=="CA") | select(.ts > ($pa[.target] // "")))
      | sort_by(.ts) | .[-20:] | .[]
      | "- \(.ts) [\(.scheme)] \(.target): \(.note) (premise: \(.premise))"' "$g" 2>/dev/null \
      || echo "- (digest unavailable)"
    echo
    echo "## Totals"
    jq -rs 'group_by(.node) | map("- \(.[0].node): \(length)") | .[]' "$g" 2>/dev/null || true
  } > "$tmp" 2>/dev/null && mv "$tmp" "$MEMORY_DIR/ontology/digest.md" 2>/dev/null || rm -f "$tmp"
  return 0
}

# --- verifier co-evolution seam ------------------------------------------------------------------
# When a slice ESCALATES (all feedback rounds burned), the failure is not always the worker's:
# research on autonomous loops says the VERIFIER is a proxy for intent and must be revised as
# often as the code ("verification must co-evolve with the generator"). Write a review packet
# for the human/supervisor that frames BOTH hypotheses — bad implementation vs bad gate/contract
# tests — instead of silently implying the worker failed. Best-effort: never fails the caller.
escalation_report() { # <task> <slice> <rounds>
  local t="${1:-?}" slice="${2:--}" rounds="${3:-?}" d="$STATE_DIR/escalations" ts f
  mkdir -p "$d" 2>/dev/null || return 0
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)"
  f="$d/$t-$ts.md"
  {
    echo "# Escalation review packet — $t (slice: $slice)"
    echo
    echo "Burned $rounds feedback rounds without passing the gate. Before re-queueing, review"
    echo "BOTH hypotheses — repeated escalation is as often a verifier defect as a worker defect:"
    echo
    echo "1. Implementation is wrong  -> read the last feedback below, re-slice or re-brief."
    echo "2. The GATE is wrong        -> review tests/ contract tests, harness/check.sh and"
    echo "   CHECK_CMD for over-strictness, flakiness, or a spec the goal never asked for."
    echo "   Fixing the verifier here counts as progress — verifiers are revision targets too."
    echo
    echo "## Last feedback routed to the worker"
    echo '```'
    cat "$(harness_dir "$t")/feedback.md" 2>/dev/null || echo "(no feedback.md on file)"
    echo '```'
  } > "$f" 2>/dev/null || return 0
  echo "$f"
  return 0
}

# --- codex second-opinion policy (gate side) ----------------------------------------------------
# Applies the SECOND_OPINION policy to a gate-time verdict file written by second-opinion.sh.
#   codex_gate_policy <verdict.json> <task>
# rc 0 = pass (no concerns, advisory-only concerns, or budget exhausted; logged to PROGRESS).
# rc 7 = route a feedback round: stdout carries the feedback body for the caller to deliver.
# The per-task round counter (state/<task>.codex-rounds) bounds advise-mode rounds at
# CODEX_GATE_MAX_ROUNDS; every routed round ALSO counts toward MAX_FEEDBACK_ROUNDS in loop.sh,
# so a disagreeing codex can never spin the loop forever. Reset the counter on land.
codex_gate_policy() {
  local v="$1" t="$2" mode
  mode="${SECOND_OPINION_GATE:-${SECOND_OPINION:-advise}}"
  [ "$mode" = off ] && return 0
  [ -f "$v" ] || return 0
  jq -e '.verdict=="concerns"' "$v" >/dev/null 2>&1 || return 0
  local high
  high="$(jq -r '[.issues[]? | select(.severity=="high")] | length' "$v" 2>/dev/null)" || high=0
  if [ "${high:-0}" -eq 0 ]; then
    progress_log CODEX_ADVISE "$t" "-" "$(jq -c '[.issues[]? | .severity] | group_by(.) | map({(.[0]): length}) | add' "$v" 2>/dev/null || echo '-') low/medium only — pass"
    return 0
  fi
  local cfile="$STATE_DIR/$t.codex-rounds" n
  n="$(cat "$cfile" 2>/dev/null || echo 0)"
  if [ "$mode" = advise ] && [ "${n:-0}" -ge "${CODEX_GATE_MAX_ROUNDS:-1}" ]; then
    progress_log CODEX_ADVISE "$t" "-" "high concerns remain but codex round budget ($n) spent — passing"
    return 0
  fi
  echo $((n + 1)) > "$cfile"
  {
    echo "## Independent second-opinion review (codex)"
    echo "The deterministic checks PASSED, but an independent reviewer flagged issues below."
    echo "Address the high-severity ones (or explain in code why they do not apply), then commit."
    echo
    jq -r '.issues[]? | "- [\(.severity)] \(.note)"' "$v" 2>/dev/null
  }
  progress_log CODEX_CONCERNS "$t" "-" "high=$high routed as feedback round $((n + 1))"
  ontology_event CA codex-concerns "codex:$t" "task:$t" "high=$high routed as feedback round $((n + 1))"
  return 7
}
codex_rounds_reset() { rm -f "$STATE_DIR/$1.codex-rounds" 2>/dev/null || true; }

# Best-effort, non-blocking notification. Never fails the caller.
notify() {
  local msg="$*"
  [ "${NOTIFY:-1}" = "1" ] || return 0
  herdr_ok && herdr notification show "loop: $PROJECT_NAME" --body "$msg" >/dev/null 2>&1 || true
  printf '\a' 2>/dev/null || true
  command -v wsl-notify-send.exe >/dev/null 2>&1 && wsl-notify-send.exe "$msg" >/dev/null 2>&1 || true
  command -v wsl-notify-send    >/dev/null 2>&1 && wsl-notify-send    "$msg" >/dev/null 2>&1 || true
  return 0
}
