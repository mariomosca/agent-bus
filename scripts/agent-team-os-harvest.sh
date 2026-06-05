#!/usr/bin/env bash
# agent-team-os-harvest.sh — harvest token usage + cost from Claude Code transcripts.
# Parses ~/.claude/projects/<cwd-slug>/*.jsonl and aggregates usage per model.
#
# Usage:
#   agent-team-os-harvest.sh [--cwd <path>] [--agent <id>] [--json] [--help]
#
# Options:
#   --cwd <path>    Working directory to resolve transcript slug (default: $PWD)
#   --agent <id>    Agent label in output JSON (default: empty)
#   --json          Output machine-readable JSON (default: human-readable summary)
#   --help          Show this help
#
# Output format (--json):
#   {
#     "cwd": "...", "agent": "...", "slug": "...",
#     "totalInputTokens": N, "totalOutputTokens": N,
#     "totalCacheRead": N, "totalCacheWrite": N,
#     "estimatedCostUsd": N,
#     "modelBreakdown": [{ "model": "...", "inputTokens": N, ... "costUsd": N }],
#     "filesScanned": N, "linesSkipped": N
#   }

set -uo pipefail

# ---------- defaults ----------
TARGET_CWD="$PWD"
AGENT_ID=""
OUTPUT_JSON=false

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)    TARGET_CWD="$2"; shift 2 ;;
    --agent)  AGENT_ID="$2";   shift 2 ;;
    --json)   OUTPUT_JSON=true; shift ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- resolve transcript dir ----------
# Claude Code slugifies cwd: strip leading /, replace / with -
# In practice all slugs start with - (stripped leading slash produces no leading dash,
# but the projects/ dir names have a leading dash). We check both forms.
slug_bare=$(echo "$TARGET_CWD" | sed 's|^/||; s|/|-|g')
slug_dash="-${slug_bare}"

PROJECTS_DIR="$HOME/.claude/projects"
TRANSCRIPT_DIR=""

if [[ -d "$PROJECTS_DIR/$slug_dash" ]]; then
  TRANSCRIPT_DIR="$PROJECTS_DIR/$slug_dash"
elif [[ -d "$PROJECTS_DIR/$slug_bare" ]]; then
  TRANSCRIPT_DIR="$PROJECTS_DIR/$slug_bare"
else
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    printf '{"error":"no transcript dir found","cwd":"%s","slug":"%s"}\n' \
      "$TARGET_CWD" "$slug_dash"
  else
    echo "No transcript directory found for: $TARGET_CWD" >&2
    echo "Expected: $PROJECTS_DIR/$slug_dash" >&2
  fi
  exit 0
fi

USED_SLUG="${TRANSCRIPT_DIR##*/}"

# ---------- cost table (per million tokens) ----------
# Pattern match: any model ID containing opus/sonnet/haiku (case-insensitive prefix)
cost_for_model() {
  local model="$1"
  local token_type="$2"   # input | output | cache_read | cache_write
  local rate

  case "${model,,}" in
    *opus*)
      case "$token_type" in
        input)       rate="15" ;;
        output)      rate="75" ;;
        cache_read)  rate="1.5" ;;
        cache_write) rate="18.75" ;;
        *)           rate="0" ;;
      esac
      ;;
    *haiku*)
      case "$token_type" in
        input)       rate="0.8" ;;
        output)      rate="4" ;;
        cache_read)  rate="0.08" ;;
        cache_write) rate="1.0" ;;
        *)           rate="0" ;;
      esac
      ;;
    *)
      # default: sonnet
      case "$token_type" in
        input)       rate="3" ;;
        output)      rate="15" ;;
        cache_read)  rate="0.30" ;;
        cache_write) rate="3.75" ;;
        *)           rate="0" ;;
      esac
      ;;
  esac
  echo "$rate"
}

# ---------- parse JSONL files ----------
FILES_SCANNED=0
LINES_SKIPPED=0

# Accumulators stored as files under /tmp to avoid subshell scope issues
TMPDIR_HARVEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HARVEST"' EXIT

MODEL_TOTALS="$TMPDIR_HARVEST/model_totals.json"
echo '{}' > "$MODEL_TOTALS"

while IFS= read -r jsonl_file; do
  [[ -f "$jsonl_file" ]] || continue
  FILES_SCANNED=$((FILES_SCANNED + 1))
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Filter type:assistant with usage
    row_type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null) || { LINES_SKIPPED=$((LINES_SKIPPED+1)); continue; }
    [[ "$row_type" != "assistant" ]] && continue
    has_usage=$(echo "$line" | jq 'has("message") and (.message | has("usage"))' 2>/dev/null) || { LINES_SKIPPED=$((LINES_SKIPPED+1)); continue; }
    [[ "$has_usage" != "true" ]] && continue

    model=$(echo "$line" | jq -r '.message.model // "claude-sonnet-4-6"' 2>/dev/null)
    [[ -z "$model" || "$model" == "null" ]] && model="claude-sonnet-4-6"

    input_tok=$(echo "$line"  | jq -r '.message.usage.input_tokens // 0' 2>/dev/null)
    output_tok=$(echo "$line" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null)
    cache_r=$(echo "$line"    | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null)
    cache_w=$(echo "$line"    | jq -r '.message.usage.cache_creation_input_tokens // 0' 2>/dev/null)

    # Accumulate in model_totals JSON (jq in-place update)
    tmp="$TMPDIR_HARVEST/mt.tmp"
    jq --arg model "$model" \
       --argjson it "$input_tok" --argjson ot "$output_tok" \
       --argjson cr "$cache_r"   --argjson cw "$cache_w" '
      .[$model] //= {"inputTokens":0,"outputTokens":0,"cacheRead":0,"cacheWrite":0}
      | .[$model].inputTokens  += $it
      | .[$model].outputTokens += $ot
      | .[$model].cacheRead    += $cr
      | .[$model].cacheWrite   += $cw
    ' "$MODEL_TOTALS" > "$tmp" && mv "$tmp" "$MODEL_TOTALS"
  done < "$jsonl_file"
done < <(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' -type f)

# ---------- compute costs + build output ----------
# Use python3 for float arithmetic (bc not always available with . decimal)
python3 - <<PYEOF
import json, sys, re

with open("$MODEL_TOTALS") as f:
    totals = json.load(f)

def cost_per_model(model, it, ot, cr, cw):
    m = model.lower()
    if "opus" in m:
        rates = (15, 75, 1.5, 18.75)
    elif "haiku" in m:
        rates = (0.8, 4, 0.08, 1.0)
    else:
        rates = (3, 15, 0.30, 3.75)
    return (it * rates[0] + ot * rates[1] + cr * rates[2] + cw * rates[3]) / 1_000_000

breakdown = []
total_in = total_out = total_cr = total_cw = 0.0
total_cost = 0.0

for model, t in totals.items():
    it = t.get("inputTokens", 0)
    ot = t.get("outputTokens", 0)
    cr = t.get("cacheRead", 0)
    cw = t.get("cacheWrite", 0)
    cost = cost_per_model(model, it, ot, cr, cw)
    breakdown.append({
        "model": model,
        "inputTokens": it,
        "outputTokens": ot,
        "cacheRead": cr,
        "cacheWrite": cw,
        "costUsd": round(cost, 6)
    })
    total_in  += it
    total_out += ot
    total_cr  += cr
    total_cw  += cw
    total_cost += cost

output = {
    "cwd":               "$TARGET_CWD",
    "agent":             "$AGENT_ID",
    "slug":              "$USED_SLUG",
    "totalInputTokens":  int(total_in),
    "totalOutputTokens": int(total_out),
    "totalCacheRead":    int(total_cr),
    "totalCacheWrite":   int(total_cw),
    "estimatedCostUsd":  round(total_cost, 6),
    "modelBreakdown":    sorted(breakdown, key=lambda x: -x["costUsd"]),
    "filesScanned":      $FILES_SCANNED,
    "linesSkipped":      $LINES_SKIPPED
}

json_out = json.dumps(output, indent=2)

if "$OUTPUT_JSON" == "true":
    print(json_out)
else:
    # Human-readable summary
    print(f"=== Agent Team OS — Harvest ===")
    print(f"cwd:    {output['cwd']}")
    if output['agent']:
        print(f"agent:  {output['agent']}")
    print(f"slug:   {output['slug']}")
    print(f"files:  {output['filesScanned']} scanned, {output['linesSkipped']} lines skipped")
    print(f"")
    print(f"{'Model':<30} {'Input':>10} {'Output':>10} {'CacheR':>10} {'CacheW':>10} {'Cost USD':>12}")
    print("-" * 86)
    for b in output['modelBreakdown']:
        print(f"{b['model']:<30} {b['inputTokens']:>10,} {b['outputTokens']:>10,} {b['cacheRead']:>10,} {b['cacheWrite']:>10,} {b['costUsd']:>12.4f}")
    print("-" * 86)
    print(f"{'TOTAL':<30} {output['totalInputTokens']:>10,} {output['totalOutputTokens']:>10,} {output['totalCacheRead']:>10,} {output['totalCacheWrite']:>10,} {output['estimatedCostUsd']:>12.4f}")
PYEOF
