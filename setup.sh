#!/usr/bin/env bash
# wt-stack setup — auto-mount isolated worktree docker stack.
#
# Hook for `worktree.created` (or action `wt-stack.up`) — delegates to the
# shared core script <repo>/scripts/wt-stack-setup.sh, resolving the worktree
# path from HERDR_PLUGIN_EVENT_JSON / HERDR_PLUGIN_CONTEXT_JSON (same dig as
# teardown.sh). Safe no-op when the worktree has no compose file.
set -euo pipefail

json="${HERDR_PLUGIN_EVENT_JSON:-${HERDR_PLUGIN_CONTEXT_JSON:-}}"
dir=""
if [ -n "$json" ]; then
  dir="$(python3 - "$json" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    sys.exit()
def dig(paths):
    cur = d
    for p in paths:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur
for paths in (["worktree","path"], ["params","worktree"], ["result","worktree"], ["workspace","cwd"]):
    v = dig(paths)
    if isinstance(v, str) and v.strip():
        print(v.strip()); break
PY
)" || true
fi
dir="${dir:-$PWD}"

core="$(cd "$(dirname "$0")/../.." && pwd)/scripts/wt-stack-setup.sh"
if [ ! -f "$core" ]; then
  echo "wt-stack: shared core not found at $core (link plugin from repo checkout)"
  exit 1
fi
exec bash "$core" --cwd "$dir"
