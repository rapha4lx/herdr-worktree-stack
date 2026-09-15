#!/usr/bin/env bash
# worktree-stack teardown — kill the docker stack of a worktree without compose files.
#
# Why label-based: herdr fires this on `worktree.removed`, AFTER git removed the
# checkout, so compose.yml / compose.worktree.yml / .env are gone. The compose
# labels survive on the containers/networks, so we resolve the project FROM THE
# LIVE CONTAINERS instead of guessing a name from the worktree path.
#
# Resolution (source of truth = running containers):
#   1. worktree path from HERDR_PLUGIN_EVENT_JSON / HERDR_PLUGIN_CONTEXT_JSON.
#   2. find containers whose label `com.docker.compose.project.working_dir`
#      == that path. Every container `docker compose up`'d inside the worktree
#      carries it, regardless of the `name:` used in compose.worktree.yml
#      (huginn-wor, huginn-extract-9ca9, wallet-gateway-prod, ...) — so the
#      naming contract never has to match a convention. No match = no-op.
#   3. for each project found: `docker rm -f` every container with that
#      project label, PLUS any container attached to the project's networks
#      (orchestrator-spawned selenium/browser nodes use `docker run`, they have
#      NO compose labels but join the project networks) — then remove the
#      project networks.
#   4. fallback (legacy): if no working_dir label matched, retry with the old
#      basename candidates (basename + `3chars-rest` swap) so very old stacks
#      still get cleaned.
#
# Safety: containers + networks always removed ("remove worktree").
# VOLUMES (data) kept by default; set WT_PURGE=1 to also remove volumes.
set -euo pipefail

json="${HERDR_PLUGIN_EVENT_JSON:-${HERDR_PLUGIN_CONTEXT_JSON:-}}"

path="$(python3 - "$json" <<'PY'
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

# herdr v0.9: EVENT_JSON = {"event":"worktree.removed","data":{"worktree":{"path":...}}}
#             CONTEXT_JSON = {"worktree":{"checkout_path":...},"workspace_cwd":...}
wt = dig(["data", "worktree"]) or dig(["worktree"]) or {}
p = (wt.get("path") or wt.get("checkout_path") or dig(["workspace_cwd"]) or "").strip()
print(p)
PY
)"
if [ -z "$path" ]; then
  echo "worktree-stack: no worktree path in event/context json"
  exit 1
fi
base="$(basename "$(echo "$path" | sed 's#/$##')")"
echo "worktree-stack: worktree path='$path' basename='$base'"

# --- 1) resolve projects from live containers (source of truth) -------------
projects="$(
  for id in $(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$path" 2>/dev/null || true); do
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null
  done | sort -u
)"

# --- fallback: old basename conventions (legacy stacks without the label) ---
if [ -z "$projects" ]; then
  echo "worktree-stack: no container matched working_dir='$path' — trying legacy basename candidates"
  legacy="$(
    python3 - "$base" <<'PY'
import sys
base = sys.argv[1].lower()
out = {base}
if "-" in base:
    first, _, rest = base.partition("-")
    if len(first) == 3 and rest:
        out.add(f"{rest}-{first}")
print(" ".join(sorted(out)))
PY
  )"
  for cand in $legacy; do
    hit="$(docker ps -aq --filter "label=com.docker.compose.project=$cand" 2>/dev/null | head -1)"
    [ -n "$hit" ] && projects="$projects $cand"
  done
  projects="$(printf '%s\n' $projects | sed '/^$/d' | sort -u)"
fi

if [ -z "$projects" ]; then
  echo "worktree-stack: no docker resources matched (safe no-op)"
  exit 0
fi

echo "worktree-stack: projects=$projects"

for project in $projects; do
  echo "worktree-stack: tearing down project=$project"

  # containers with the project label
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  # project networks (also carry the project label) — by NAME: `network ls -q`
  # returns short IDs, which `docker ps --filter network=` does not accept
  nets="$(docker network ls --format '{{.Name}}' --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"

  # docker-run stragglers: attached to this project's networks, no compose labels
  stragglers=""
  for net in $nets; do
    for sid in $(docker ps -aq --filter "network=$net" 2>/dev/null || true); do
      case " $ids " in
        *" $sid "*) : ;;
        *) stragglers="$stragglers $sid" ;;
      esac
    done
  done
  stragglers="$(printf '%s\n' $stragglers | sed '/^$/d' | sort -u)"

  if [ -n "$ids" ] || [ -n "$stragglers" ]; then
    docker rm -f $ids $stragglers >/dev/null 2>&1
    echo "worktree-stack:   containers removed ($(printf '%s\n' $ids $stragglers | sed '/^$/d' | wc -l))"
  fi

  vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
  if [ "${WT_PURGE:-0}" = "1" ] && [ -n "$vols" ]; then
    docker volume rm -f $vols >/dev/null 2>&1 || true
    echo "worktree-stack:   volumes removed (WT_PURGE=1)"
  elif [ -n "$vols" ]; then
    echo "worktree-stack:   volumes KEPT (data safe; WT_PURGE=1 removes): $vols"
  fi

  if [ -n "$nets" ]; then
    docker network rm $nets >/dev/null 2>&1 || true
    echo "worktree-stack:   network(s) removed"
  fi
done
echo "worktree-stack: done"
