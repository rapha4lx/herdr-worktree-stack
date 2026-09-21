#!/usr/bin/env bash
# wt-stack info — show docker resources for the worktree of this workspace.
# Same resolution as teardown.sh: find containers whose label
# com.docker.compose.project.working_dir == workspace cwd (the current
# worktree), then list every container of those projects.
set -euo pipefail
json="${HERDR_PLUGIN_CONTEXT_JSON:-}"
[ -n "$json" ] || { echo "wt-stack: no context json"; exit 1; }

path="$(python3 - "$json" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)
def dig(paths):
    cur = d
    for p in paths:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur
wt = dig(["worktree"]) or {}
p = (wt.get("checkout_path") or dig(["workspace_cwd"]) or "").strip()
print(p)
PY
)"
[ -n "$path" ] || { echo "wt-stack: no workspace cwd in context json"; exit 1; }

projects="$(for id in $(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$path" 2>/dev/null || true); do
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null
done | sort -u)"

if [ -z "$projects" ]; then
  echo "wt-stack: no containers matched working_dir='$path' (safe no-op)"
  exit 0
fi

echo "wt-stack: projects=$projects"
for project in $projects; do
  echo "-- project=$project containers --"
  docker ps -a --filter "label=com.docker.compose.project=$project" --format 'table {{.Names}}\t{{.Status}}' || true
done

echo ""
echo "Supported actions: wt-stack.up, wt-stack.down, wt-stack.info, wt-stack.seed"
echo "Supported environment variables:"
echo "  WT_SEED=0|1               Disable/enable automatic data seeding on first mount (default: 1)"
echo "  WT_SEED_TARGETS=\"...\"     Whitespace-separated targets (default: \"postgres redis minio\")"
echo "  WT_SEED_FORCE=1           Force re-seeding even if destination data exists"
echo "  WT_SEED_TIMEOUT=300       Timeout per service in seconds (default: 300)"
