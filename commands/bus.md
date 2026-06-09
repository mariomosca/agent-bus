---
description: Agent Team OS hub — show roster, status, capabilities, routing rules.
---

Print the current state of the bus: which agents are configured, who is active, and what routing rules apply.

Run via Bash:

```bash
LIB="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/agent-team-os-lib.sh"
   [[ -f "$LIB" ]] || LIB="$HOME/.claude/scripts/agent-team-os-lib.sh"
   source "$LIB"

echo "=== Agent Team OS Roster ==="
if [[ ! -f "$HOME/.agent-team-os/AGENT_MAP.json" ]]; then
  echo "AGENT_MAP.json not found. Run install.sh first."
  exit 0
fi

jq -r '
  "Agents (" + (.agents | length | tostring) + "):",
  (.agents | to_entries[] | "  - " + .key +
    (if .value.role then " — " + .value.role else "" end) +
    (if .value.capabilities then "  caps: " + (.value.capabilities | join(", ")) else "" end)
  ),
  "",
  "Routing:",
  (if (.cc_awareness.enabled // false)
   then "  full-mesh (graph) + cross-domain cc → " + (.cc_awareness.hub // "hub")
   else "  hub-and-spoke (deny-based)" end),
  ( [ .routing_rules // {} | to_entries[] | select((.value.deny // []) | length > 0) ] as $blocked
    | if ($blocked | length) > 0
      then ($blocked[] | "  " + .key + " ↛ " + ((.value.deny // []) | join(",")))
      else "  no deny-pairs (all agents can message all)" end
  )
' "$HOME/.agent-team-os/AGENT_MAP.json"

echo ""
echo "Active sessions (last 5min):"
for f in "$HOME"/.agent-team-os/registry/*.json; do
  [[ -f "$f" ]] || continue
  AGENT=$(jq -r '.name // (input_filename | split("/")[-1] | rtrimstr(".json"))' "$f" 2>/dev/null)
  LAST=$(jq -r '.last_seen // ""' "$f")
  ACTIVE=$(jq -r '.active // false' "$f")
  [[ "$ACTIVE" == "true" ]] && echo "  - $AGENT  (last: $LAST)"
done
```

Sub-commands like `/bus status` or `/bus history` are not implemented in v1. Use `/inbox`, `/read`, `/send`, `/reply`, `/thread` directly.
