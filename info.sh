#!/usr/bin/env bash
# wt-stack info — show docker resources for a worktree project (candidates).
set -euo pipefail
json="${HERDR_PLUGIN_CONTEXT_JSON:-}"
candidates="$(python3 - "$json" <<'PY'
import json, os, sys
raw = sys.argv[1]
if not raw.strip():
    sys.exit()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)
path = (d.get("workspace") or {}).get("cwd") or ""
if not path:
    sys.exit(2)
base = os.path.basename(path.rstrip("/")).lower()
out = {base}
if "-" in base:
    first, _, rest = base.partition("-")
    if len(first) == 3 and rest:
        out.add(f"{rest}-{first}")
for p in sorted(out):
    print(p)
PY
)" || { echo "wt-stack: no workspace cwd in context json"; exit 1; }

echo "wt-stack: candidates=$candidates"
for project in $candidates; do
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  [ -z "$ids" ] && continue
  echo "-- project=$project containers --"
  docker ps -a --filter "label=com.docker.compose.project=$project" --format 'table {{.Names}}\t{{.Status}}' || true
done