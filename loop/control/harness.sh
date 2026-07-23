#!/usr/bin/env bash
# `loop harness` — adopt methodology packs into the WORKSPACE's harness and gate at
# introduction time (interactively or non-interactively). A pack is nothing new conceptually:
# it is a bundle of parts for the seams that already exist on the escalation ladder —
#   L1 (advisory harness) : snippets appended to skills/RULES.md / skills/ARCHITECTURE.md and
#                           CLAUDE.worker.local.md (spawn.sh already merges the overlay)
#   L2 (client harness)   : executable guards copied into worker-harness.d/ (spawn.sh already
#                           composes them into every worker's PreToolUse)
#   L3 (gate)             : checks + their config copied into gate.d/ (gate.sh runs them on
#                           the merged tree, worker-unreachable)
# The engine ships packs under loop/packs/; nothing here edits the engine — every artifact
# lands in the WORKSPACE, exactly where hand-written harness/gate extensions already go.
#
# Every pack declares WHEN-TO-REMOVE metadata (pack.md frontmatter): a harness part encodes an
# assumption about what the model can't do alone — re-examine packs on every model generation
# and strip the ones no longer load-bearing. (Security-class guards are marked non-removable.)
#
#   loop harness                    interactive wizard (pick packs, confirm, adopt)
#   loop harness list               show available packs + what each would install
#   loop harness apply <pack>...    adopt pack(s) non-interactively
#   loop harness apply <dir>        adopt an EXTERNAL pack (pack spec v1) from a directory —
#                                   an argument containing '/' is a path, not a shipped pack
#   loop harness status             show what this workspace's harness/gate contains
#
# External packs (built elsewhere, e.g. authored by the loop-pack-author skill) must satisfy
# pack spec v1: pack.md frontmatter with enforces/when-to-remove (requires/origin recommended),
# and — because their guards were not fixed by this engine's tests-toolkit — a selftest/ case
# per L2 guard (stdin fixture named <guard>.<desc>.exit<0|2>.json, run with HARNESS_WORKTREE=/wt
# against pack-shipped config defaults). Selftests run BEFORE anything is installed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PACKS_DIR="$ENGINE_DIR/packs"

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

packs_available() {
  [ -d "$PACKS_DIR" ] || return 0
  local p
  for p in $(find "$PACKS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort); do
    # internal packs are wired by dedicated flows, not adopted directly.
    grep -q '^internal: true' "$PACKS_DIR/$p/pack.md" 2>/dev/null || echo "$p"
  done
}

pack_summary() { # <pack> — first non-frontmatter, non-empty line of pack.md
  local f="$PACKS_DIR/$1/pack.md"
  [ -f "$f" ] || { echo "(no pack.md)"; return 0; }
  awk '/^---$/{fm++; next} fm!=1 && NF {sub(/^# */,""); print; exit}' "$f"
}

# frontmatter_field <pack.md> <field> — value of a frontmatter line, empty if absent.
frontmatter_field() {
  awk -v f="$2:" '/^---$/{fm++; next} fm==1 && index($0, f)==1 { sub("^" f "[ ]*", ""); print; exit }' "$1" 2>/dev/null || true
}

# Run a pack's selftest cases against a STAGED copy of its guards + shipped config defaults,
# before anything touches the workspace. Case files: selftest/<guard>.<desc>.exit<0|2>.json —
# the raw PreToolUse stdin JSON; fixtures reference paths under /wt and run with
# HARNESS_WORKTREE=/wt. Staging mirrors the installed layout (worker-harness.d/ + ../gate.d/)
# so guards resolve their config exactly as they will once adopted.
selftest_pack() { # <pack-src-dir> <pack-name> — dies on any failing case
  local d="$1" pack="$2" td c base g exp rc ran=0
  [ -d "$d/selftest" ] || return 0
  td="$(mktemp -d)"
  mkdir -p "$td/worker-harness.d" "$td/gate.d"
  if [ -d "$d/guards" ]; then cp -r "$d/guards/." "$td/worker-harness.d/" 2>/dev/null || true; fi
  if [ -d "$d/config" ]; then cp -r "$d/config/." "$td/gate.d/" 2>/dev/null || true; fi
  for c in "$d/selftest"/*.exit*.json; do
    [ -f "$c" ] || continue
    base="$(basename "$c")"
    g="${base%%.*}"
    exp="${base##*.exit}"; exp="${exp%.json}"
    if [ ! -f "$td/worker-harness.d/$g" ]; then
      rm -rf "$td"; die "harness: selftest case '$base' names no guard '$g' in $pack/guards/"
    fi
    if ( HARNESS_WORKTREE=/wt bash "$td/worker-harness.d/$g" < "$c" ) >/dev/null 2>&1; then rc=0; else rc=$?; fi
    if [ "$rc" != "$exp" ]; then
      rm -rf "$td"; die "harness: selftest FAILED for pack '$pack' — $base expected exit $exp, got $rc. Nothing was installed."
    fi
    ran=$((ran + 1))
  done
  rm -rf "$td"
  [ "$ran" -gt 0 ] && echo "harness:  selftest — $ran case(s) passed (guards conform to stdin-JSON -> exit 0/2)"
  return 0
}

# External packs (adopted from a path) were not fixed by the engine's tests-toolkit, so the
# spec is enforced at the door: frontmatter contract, and a selftest case per L2 guard.
validate_external_pack() { # <pack-src-dir> <pack-name>
  local d="$1" pack="$2" f g v
  f="$d/pack.md"
  [ -f "$f" ] || die "harness: external pack '$pack' has no pack.md"
  [ -n "$(frontmatter_field "$f" enforces)" ]       || die "harness: external pack '$pack' — pack.md frontmatter must declare 'enforces:'"
  [ -n "$(frontmatter_field "$f" when-to-remove)" ] || die "harness: external pack '$pack' — pack.md frontmatter must declare 'when-to-remove:' (capability-assist assumptions are re-examined every model generation)"
  for g in "$d/guards"/*; do
    [ -f "$g" ] || continue
    ls "$d/selftest/$(basename "$g")".*.exit*.json >/dev/null 2>&1 \
      || die "harness: external pack '$pack' — L2 guard '$(basename "$g")' has no selftest case (selftest/$(basename "$g").<desc>.exit<0|2>.json). Guards from outside the engine are not adopted unverified."
  done
  v="$(frontmatter_field "$f" origin)";   [ -n "$v" ] && echo "harness:  origin  : $v (update THERE, then re-apply to propagate)"
  v="$(frontmatter_field "$f" requires)"; [ -n "$v" ] && echo "harness:  requires: $v (gate checks must fail loud, never skip silently, when this is missing)"
  return 0
}

# Append a snippet to a target file exactly once (marker-idempotent — the marker id must be
# stable across runs). Creates the target from an optional seed when absent. Re-adopting a
# pack never duplicates advisory text.
append_once() { # <marker-id> <snippet-file> <target-file> [seed-file]
  local id="$1" snip="$2" target="$3" seed="${4:-}"
  [ -f "$snip" ] || return 0
  local marker="<!-- loop-pack: $id -->"
  if [ -f "$target" ] && grep -qF "$marker" "$target"; then
    echo "harness:  $target — already adopted (skip)"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  if [ ! -f "$target" ] && [ -n "$seed" ] && [ -f "$seed" ]; then cp "$seed" "$target"; fi
  { echo; echo "$marker"; cat "$snip"; } >> "$target"
  echo "harness:  $target <- $id"
}

apply_pack() { # <shipped-pack-name | path/to/external/pack>
  local arg="$1" pack d f
  if [[ "$arg" == */* ]]; then
    # External pack (pack spec v1): validated + selftested at the door, then adopted through
    # the exact same seams as a shipped pack. The pack id is its directory name.
    d="$(cd "$arg" 2>/dev/null && pwd)" || die "harness: no such pack directory '$arg'"
    pack="$(basename "$d")"
    echo "harness: adopting EXTERNAL pack '$pack' ($d) -> $CONFIG_DIR"
    validate_external_pack "$d" "$pack"
    selftest_pack "$d" "$pack"
  else
    pack="$arg"; d="$PACKS_DIR/$arg"
    [ -d "$d" ] || die "unknown pack '$pack' (loop harness list)"
    echo "harness: adopting pack '$pack' -> $CONFIG_DIR"
    selftest_pack "$d" "$pack"   # shipped packs may carry selftests too; run them if present
  fi
  # L1 advisory snippets.
  append_once "$pack/rules"  "$d/RULES.snippet.md"        "$CONFIG_DIR/skills/RULES.md"        "$ENGINE_DIR/skills/RULES.md"
  append_once "$pack/arch"   "$d/ARCHITECTURE.snippet.md" "$CONFIG_DIR/skills/ARCHITECTURE.md" "$ENGINE_DIR/skills/ARCHITECTURE.md"
  append_once "$pack/worker" "$d/CLAUDE.worker.local.snippet.md" "$CONFIG_DIR/CLAUDE.worker.local.md"
  # L2 guards -> worker-harness.d/ (pack-prefixed; overwrite so engine updates propagate on
  # re-adopt — these are engine-owned code, not workspace edits).
  if [ -d "$d/guards" ]; then
    mkdir -p "$CONFIG_DIR/worker-harness.d"
    for f in "$d/guards"/*; do
      [ -f "$f" ] || continue
      cp "$f" "$CONFIG_DIR/worker-harness.d/$pack-$(basename "$f")"
      chmod +x "$CONFIG_DIR/worker-harness.d/$pack-$(basename "$f")"
      echo "harness:  worker-harness.d/$pack-$(basename "$f") (L2 guard)"
    done
  fi
  # L3 checks -> gate.d/ (gate.sh runs them on the merged tree).
  if [ -d "$d/check.d" ]; then
    mkdir -p "$CONFIG_DIR/gate.d"
    for f in "$d/check.d"/*.sh; do
      [ -f "$f" ] || continue
      cp "$f" "$CONFIG_DIR/gate.d/$pack-$(basename "$f")"
      echo "harness:  gate.d/$pack-$(basename "$f") (L3 gate check)"
    done
  fi
  # Pack configuration templates -> gate.d/ (no-clobber: the workspace's tuned values win).
  # Both the L3 checks and the L2 guards read their rules from gate.d/ — one source of truth
  # for "what the project forbids", owned by the supervisor side.
  if [ -d "$d/config" ]; then
    mkdir -p "$CONFIG_DIR/gate.d"
    for f in "$d/config"/*; do
      [ -f "$f" ] || continue
      if [ -e "$CONFIG_DIR/gate.d/$(basename "$f")" ]; then
        echo "harness:  gate.d/$(basename "$f") — exists (kept; edit it to tune this pack)"
      else
        cp "$f" "$CONFIG_DIR/gate.d/$(basename "$f")"
        echo "harness:  gate.d/$(basename "$f") (EDIT THIS to activate the pack's enforcement)"
      fi
    done
  fi
  # Ontology scaffolding (README describing the fixed upper ontology + project forms seam).
  if [ -d "$d/ontology" ]; then
    mkdir -p "$MEMORY_DIR/ontology"
    for f in "$d/ontology"/*; do
      [ -f "$f" ] || continue
      [ -e "$MEMORY_DIR/ontology/$(basename "$f")" ] || cp "$f" "$MEMORY_DIR/ontology/$(basename "$f")"
    done
    echo "harness:  memory/ontology/ scaffold"
  fi
  progress_log HARNESS_PACK "-" "-" "adopted pack: $pack"
}

cmd_list() {
  local p
  echo "available packs ($PACKS_DIR):"
  for p in $(packs_available); do
    printf '  %-24s %s\n' "$p" "$(pack_summary "$p")"
  done
  [ -n "$(packs_available)" ] || echo "  (none)"
}

cmd_status() {
  echo "workspace: $CONFIG_DIR"
  local markers
  markers="$(grep -rhoE '<!-- loop-pack: [^>]+ -->' \
    "$CONFIG_DIR/skills" "$CONFIG_DIR/CLAUDE.worker.local.md" 2>/dev/null | sort -u || true)"
  echo "adopted pack markers (L1):"
  if [ -n "$markers" ]; then echo "$markers" | sed 's/^/  /'; else echo "  (none)"; fi
  echo "L2 guards (worker-harness.d/):"
  ls "$CONFIG_DIR/worker-harness.d" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo "L3 gate checks + config (gate.d/):"
  ls "$CONFIG_DIR/gate.d" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  if [ -n "${DESIGN_SSOT_DIR:-}" ]; then
    echo "design SSOT (direct-read): $DESIGN_SSOT_DIR"
  else
    echo "design SSOT (direct-read): (unset — the planner auto-detects <repo>/atlas/ if present)"
  fi
}

cmd_wizard() {
  [ -t 0 ] || { usage; die "harness: no TTY for the wizard — use 'loop harness apply <pack>...'"; }
  echo "harness wizard — decide this project's methodology; the harness/gate then enforce it."
  local p ans chosen=()
  for p in $(packs_available); do
    echo
    echo "== $p — $(pack_summary "$p")"
    sed -n '/^---$/,/^---$/p' "$PACKS_DIR/$p/pack.md" 2>/dev/null | grep -E '^(when-to-remove|enforces):' | sed 's/^/   /' || true
    printf 'adopt? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes) chosen+=("$p");; esac
  done
  [ "${#chosen[@]}" -gt 0 ] || { echo "harness: nothing selected."; return 0; }
  for p in "${chosen[@]}"; do apply_pack "$p"; done
  echo
  echo "harness: done. Workers pick the L1/L2 artifacts up on their next spawn/respawn;"
  echo "the gate picks the L3 checks up immediately."
}

cmd="${1:-wizard}"; shift || true
case "$cmd" in
  list)            cmd_list ;;
  status)          cmd_status ;;
  apply)           [ $# -gt 0 ] || die "usage: loop harness apply <pack> [<pack>...]"
                   for p in "$@"; do apply_pack "$p"; done ;;
  wizard)          cmd_wizard ;;
  help|--help|-h)  usage ;;
  *)               usage; die "harness: unknown subcommand '$cmd'" ;;
esac
