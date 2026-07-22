#!/usr/bin/env bash
# Deterministic validator for the AIF-style event ontology (memory/ontology/graph.jsonl).
# Zero LLM, zero network — the same class of tool as validate_slices: catch a malformed graph
# BEFORE anything consumes it (the planner reads the digest derived from this file).
#
# Upper-ontology constraints enforced (AIF: I-nodes = information, S-nodes = RA/CA/PA schemes;
# edges run I -> S -> I, S-nodes need both sides, I-nodes carry content not edges):
#   - every line is a JSON object with ts / node / scheme
#   - node is one of I | RA | CA | PA
#   - S-nodes (RA/CA/PA) MUST have non-empty premise AND target (their incoming/outgoing edges)
#   - I-nodes MUST have a non-empty note (their content) and MUST NOT carry premise/target
#     (an I->I edge is exactly what AIF forbids)
# The forms layer (which `scheme` values exist) is project vocabulary and NOT validated here —
# document new schemes in memory/ontology/README.md instead.
#
#   ./control/ontology-check.sh [graph.jsonl]     (default: $MEMORY_DIR/ontology/graph.jsonl)
# Exit 0 = valid (or file absent — an empty ontology is fine), 1 = violations (listed on stderr).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GRAPH="${1:-$MEMORY_DIR/ontology/graph.jsonl}"
[ -f "$GRAPH" ] || { echo "ontology-check: no graph at $GRAPH (nothing to validate)."; exit 0; }
command -v jq >/dev/null 2>&1 || die "ontology-check: jq is required"

bad=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  [ -n "$line" ] || continue
  if ! err="$(printf '%s' "$line" | jq -r '
        if type != "object" then "not a JSON object"
        elif (.ts // "") == "" then "missing ts"
        elif ((.node // "") | IN("I","RA","CA","PA") | not) then "node must be I|RA|CA|PA (got \(.node // "null"))"
        elif (.scheme // "") == "" then "missing scheme"
        elif (.node != "I") and (((.premise // "") == "") or ((.target // "") == ""))
          then "S-node (\(.node)) needs non-empty premise and target"
        elif (.node == "I") and ((.note // "") == "") then "I-node needs a non-empty note"
        elif (.node == "I") and (((.premise // "") != "") or ((.target // "") != ""))
          then "I-node must not carry premise/target (I->I edges are forbidden)"
        else empty end' 2>/dev/null)"; then
    err="unparseable JSON"
  fi
  if [ -n "$err" ]; then
    echo "ontology-check: line $lineno: $err" >&2
    bad=1
  fi
done < "$GRAPH"

if [ "$bad" -ne 0 ]; then
  echo "ontology-check: FAIL — $GRAPH violates the upper ontology (see above)." >&2
  exit 1
fi
echo "ontology-check: OK ($lineno line(s), $GRAPH)"
