#!/usr/bin/env bash
# wt-stack teardown — kill the docker stack of a worktree without compose files.
#
# Why label-based: herdr fires this on `worktree.removed`, AFTER git removed the
# checkout, so compose.yml / compose.worktree.yml / .env are gone. Compose labels
# (com.docker.compose.project=<project>) survive on containers/volumes/networks,
# so we remove by project label instead of `docker compose ... down -f`.
#
# Project matching (convention-agnostic, both supported):
#   1. default docker compose project = worktree dir basename (no name: override)
#   2. explicit `name: <repo>-<3chars>` where the worktree dir is `<3chars>-<repo>`
#      (worktree `a3f-bayhub` -> project `bayhub-a3f`)
# The script computes BOTH candidates from the worktree path and tears down any
# that actually exist (no match = safe no-op).
#
# Inputs (herdr injects):
#   event hook:  HERDR_PLUGIN_EVENT_JSON      (worktree.removed event payload)
#   action:      HERDR_PLUGIN_CONTEXT_JSON    (workspace context)
# Safety:
#   containers + network always removed (that is what "remove worktree" means).
#   VOLUMES (data) kept by default; set WT_PURGE=1 to also remove volumes.
set -euo pipefail

json="${HERDR_PLUGIN_EVENT_JSON:-${HERDR_PLUGIN_CONTEXT_JSON:-}}"

candidates="$(python3 - "$json" <<'PY'
import json, os, sys
raw = sys.argv[1]
if not raw.strip():
    sys.exit()
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

wt = dig(["worktree"]) or dig(["params", "worktree"]) or dig(["result", "worktree"]) or {}
path = (wt.get("path") or dig(["workspace", "cwd"]) or "").strip()
if not path:
    sys.exit(2)
base = os.path.basename(path.rstrip("/")).lower()
out = {base}
# convention <3chars>-<repo> -> project <repo>-<3chars>
if "-" in base:
    first, _, rest = base.partition("-")
    if len(first) == 3 and rest:
        out.add(f"{rest}-{first}")
for p in sorted(out):
    print(p)
PY
)" && [ -n "$candidates" ] || { echo "wt-stack: no worktree path in event/context json"; exit 1; }

echo "wt-stack: candidates=$candidates"

handled=0
for project in $candidates; do
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  nets="$(docker network ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  [ -z "$ids$vols$nets" ] && continue
  handled=1
  echo "wt-stack: tearing down project=$project"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ids
    echo "wt-stack:   containers removed"
  fi
  if [ "${WT_PURGE:-0}" = "1" ] && [ -n "$vols" ]; then
    # shellcheck disable=SC2086
    docker volume rm -f $vols
    echo "wt-stack:   volumes removed (WT_PURGE=1)"
  elif [ -n "$vols" ]; then
    echo "wt-stack:   volumes KEPT (data safe; WT_PURGE=1 removes)"
  fi
  if [ -n "$nets" ]; then
    # shellcheck disable=SC2086
    docker network rm $nets || true
    echo "wt-stack:   network removed"
  fi
done

if [ "$handled" = "0" ]; then
  echo "wt-stack: no docker resources matched candidates (safe no-op)"
fi
echo "wt-stack: done"