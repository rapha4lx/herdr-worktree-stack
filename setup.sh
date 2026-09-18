#!/usr/bin/env bash
# worktree-stack setup — auto-mount isolated docker stack for a git worktree.
#
# Self-contained herdr plugin (no dependency on any checkout/repo). Hook for
# `worktree.created` (TUI right-click -> "new worktree") or action `wt-stack.up`.
# Resolves the worktree dir from HERDR_PLUGIN_EVENT_JSON /
# HERDR_PLUGIN_CONTEXT_JSON (same dig as teardown.sh) or --cwd (open-code
# plugin). Idempotent; never destructive; safe no-op for main checkouts / repos
# without a compose file.
#
# What it does:
#   1. Resolve worktree dir (--cwd, herdr JSON, or current dir).
#   2. Skip unless cwd is a LINKED worktree (not the main checkout) of a git repo.
#   3. Copy `.env` from the main checkout when the worktree has none (gitignored
#      files don't ship with a fresh checkout). NEVER overwrites an existing
#      worktree `.env`.
#   4. Skip (safe no-op, exit 0) if the worktree has no base compose file.
#   5. Generate a COMPLETE standalone compose.worktree.yml (v0.5) from
#      `docker compose config --no-interpolate` (canonical merged doc) via
#      gen-compose.py (PyYAML hard requirement). Regenerated EVERY run — never
#      an overlay, so the base compose's traefik.* labels can never merge
#      append-only back into the stack. Per service: unique container_name
#      <project>-<svc>, image re-tagged <project>-<svc>:latest when the base
#      has `build:` (wt --build never overwrites shared prod tags), ALL base
#      traefik.* labels stripped and re-emitted with router/service/middleware
#      names re-keyed <x>-<tag> (http AND tcp; unrouted services get
#      traefik.enable=false), published ports stripped, env values rewritten
#      URL-safe (hostname after last '@' only). Top-level: volumes re-scoped
#      <project>_<key> (dump resolves implicit names — leaving them would MOUNT
#      the main stack's volumes), owned networks re-scoped <project>_<net> (no
#      DNS-alias collision), external networks kept (traefik_proxy).
#   6. Rewrite APP_HOST in .env via wt_host (append): `foo.domain` ->
#      `foo-<tag>.domain` if present and not already suffixed.
#      Fallback (no APP_HOST): derive worktree host from ANY Traefik
#      Host() rule in the compose (prefers display_svc, falls back to first
#      http route). If neither APP_HOST nor any route found -> hard error.
#      URL = `https://foo-<tag>.domain`, printed as `wt-stack: URL=...`.
#   7. Safety warnings (docker.sock/host-device/absolute binds), gentle orphan
#      pre-clean (exited/dead containers + zero-attached networks of THIS
#      project), then SINGLE-FILE up:
#      `docker compose --project-name "$project" -f compose.worktree.yml up -d
#      [--build]` — base compose NEVER part of the command. Generated file is
#      validated via `docker compose config` BEFORE up.
#      WT_DRY_RUN=1 prints instead of touching docker (validation mode).
#      Exit code: containers are ground truth — compose rc != 0 but project
#      containers running still exits 0 (warnings, e.g. shared networks).
#
# Build policy — WT_STACK_BUILD=auto|always|never (default auto):
#   auto:   --build on the FIRST mount (override just generated / no container
#           for project yet), then regular `up -d` on re-runs. Ensures fresh
#           images catch new code on first boot without slowing every re-run.
#   always: --build every run.
#   never:  never --build.
#
# NAMING CONTRACT v2 (skill compose-traefik §"Worktree docker stacks"): ONE
# tag per worktree, used for BOTH the docker project and APP_HOST:
#   tag = trailing <hex> token of the worktree DIR basename
#         (herdr style `worktree-calm-meadow-9ca9` -> tag `9ca9`, unique per WT)
#         else first 3 alnum chars of the dir basename (`wt-a3f` -> `a3f`)
#         (herdr-v1 dir `<3chars>-<repo>`, `a3f-bayhub` -> tag `a3f`)
#   project/id = `<repo_lc>-<tag>`  -> containers `huginn-extract-9ca9-backend`
#   APP_HOST   = `<orig>-<tag>`     -> e.g. `app-9ca9.example.com` (wt_host append)
# Teardown NEVER guesses the name: it resolves the project from the live
# container label `com.docker.compose.project.working_dir` == worktree path
# (teardown.sh in this same plugin dir). Naming is for humans/URLs only.

set -euo pipefail

# PyYAML hard requirement (validator#1) — fail loudly if missing
python3 -c "import yaml" || { echo 'wt-stack: PyYAML required (pip install pyyaml / apt python3-yaml)'; exit 1; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo ".")"

DRY="${WT_DRY_RUN:-0}"
BUILD="${WT_STACK_BUILD:-auto}"
DIR=""
FROM_PANE="${WT_FROM_PANE:-0}"

# --- input resolution -------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) DIR="$2"; shift 2 ;;
    --from-pane) FROM_PANE=1; shift ;;
    *) shift ;;
  esac
done

json="${HERDR_PLUGIN_EVENT_JSON:-${HERDR_PLUGIN_CONTEXT_JSON:-}}"
if [ -z "$DIR" ] && [ -n "$json" ]; then
  DIR="$(python3 - "$json" <<'PY' 2>/dev/null || true
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
# herdr v0.9 envelope: HERDR_PLUGIN_EVENT_JSON is
#   {"event":"worktree.created","data":{"workspace":{...,"worktree":{"checkout_path":...}},"worktree":{"path":...}}}
# HERDR_PLUGIN_CONTEXT_JSON is
#   {"workspace_id":...,"workspace_cwd":"/path","worktree":{"checkout_path":"/path"},...}
for paths in (["data","worktree","path"],
              ["data","workspace","worktree","checkout_path"],
              ["worktree","checkout_path"],
              ["workspace_cwd"]):
    v = dig(paths)
    if isinstance(v, str) and v.strip():
        print(v.strip()); break
PY
)"
  DIR="${DIR:-$PWD}"
elif [ -z "$DIR" ]; then
  DIR="$PWD"
fi
DIR="$(cd "$DIR" 2>/dev/null && pwd || echo "$DIR")"

[ -d "$DIR" ] || { echo "wt-stack: dir missing: $DIR"; exit 1; }

# --- worktree detection -----------------------------------------------------
WT_LIST="$(git -C "$DIR" worktree list --porcelain 2>/dev/null || true)"
[ -n "$WT_LIST" ] || { echo "wt-stack: no git repo at $DIR (skip)"; exit 0; }

main_path="$(printf '%s\n' "$WT_LIST" | awk '/^worktree /{p=substr($0,10); if(!m) m=p} END{print m}')"
in_list="$(printf '%s\n' "$WT_LIST" | awk -v d="$DIR" '$0=="worktree "d{found=1} END{print found+0}')"
[ "$in_list" = "1" ] || { echo "wt-stack: $DIR not a registered worktree (skip)"; exit 0; }
[ "$main_path" = "$DIR" ] && { echo "wt-stack: main checkout at $DIR (skip, no isolation needed)"; exit 0; }

# --- delegate to the worktree's own pane (herdr event only) ------------------
# When herdr fires `worktree.created`, THIS script runs in herdr's background
# (output lands in `herdr plugin log`, the worktree console stays blank — the
# user sees nothing). Instead: find the worktree's root pane in the herdr TUI
# and run this script THERE via `herdr pane run`. The worktree console then
# shows the whole setup live (build, networks, compose up, URLs) and stays
# busy until the script returns. `--from-pane` marks the second invocation so
# we don't re-delegate in a loop. Fallbacks: no herdr CLI → run in background
# as before; already in the pane → run normally.
if [ "$FROM_PANE" = "0" ] && [ -n "${HERDR_PLUGIN_EVENT_JSON:-}" ] && command -v herdr >/dev/null 2>&1; then
  ws_id="$(python3 - "$json" <<'PY' 2>/dev/null || true
import json, sys
raw = sys.argv[1]
try: d = json.loads(raw)
except Exception: sys.exit()
def dig(paths):
    cur = d
    for p in paths:
        if not isinstance(cur, dict) or p not in cur: return None
        cur = cur[p]
    return cur
for paths in (["data","workspace","workspace_id"], ["data","workspace","id"], ["workspace_id"]):
    v = dig(paths)
    if isinstance(v, str) and v.strip():
        print(v.strip()); break
PY
)"
  target=""
  if [ -n "$ws_id" ]; then
    target="$(herdr pane list --workspace "$ws_id" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    panes = d.get("result", {}).get("panes", [])
    for p in panes:
        if p.get("agent_status") in (None, "unknown", "idle"):
            print(p.get("pane_id", "")); break
    if not panes: print("")
except Exception: pass' || true)"
  fi
  if [ -n "$target" ]; then
    echo "wt-stack: delegating to worktree pane $target (wt-stack live in console)"
    SCRIPT_ABS="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    env WT_FROM_PANE=1 WT_STACK_BUILD="$BUILD" herdr pane run "$target" "bash '$SCRIPT_ABS' --cwd '$DIR' --from-pane" >/dev/null 2>&1 || true
    echo "wt-stack: delegated (console pane $target is running the setup)"
    exit 0
  else
    echo "wt-stack: no visible pane found (ws=$ws_id) — running in background"
  fi
fi

base="$(basename "$DIR")"
base_lc="${base,,}"
repo="$(basename "$main_path" 2>/dev/null || true)"
[ -n "$repo" ] || { repo="$(git -C "$DIR" remote get-url origin 2>/dev/null | sed -E 's#.*/##; s#\.git$##' || true)"; }
[ -n "$repo" ] || repo="${base}"
repo_lc="${repo,,}"

# NAMING CONTRACT v2 — one tag per worktree (project + APP_HOST), deterministic
# and collision-free: trailing <hex> token of the dir basename (herdr style,
# e.g. `worktree-calm-meadow-9ca9` -> `9ca9`); else first 3 alnum chars
# (`wt-a3f` -> `a3f`; herdr-v1 `a3f-bayhub` -> `a3f`). See header + skill.
base_tag="${base_lc##*-}"                       # last dash token
if printf '%s' "$base_tag" | grep -qE '^[0-9a-f]{3,}$'; then
  tag="$base_tag"                               # herdr `...-<hex>` (9ca9, fa27)
elif printf '%s' "$base_lc" | grep -qE '^[a-z0-9]{3}-'; then
  tag="${base_lc:0:3}"                          # herdr-v1 `a3f-bayhub` -> a3f
else
  tag="$(printf '%s' "$base_lc" | tr -cd 'a-z0-9' | cut -c1-3)"
fi
[ -n "$tag" ] || tag="wt"
project="${repo_lc}-${tag}"

echo "wt-stack: worktree=$DIR project=$project tag=$tag main=$main_path"

# --- copy .env from main checkout if missing --------------------------------
# New worktrees don't ship `.env` (gitignored), so a fresh checkout has none.
# Seed it from the main checkout when the main has one — NEVER overwrite an
# existing worktree .env. The APP_HOST rewrite step below then applies the
# worktree tag to the copied file. Values may still need worktree-specific
# edits (the copied main .env carries production secrets).
ENV_FILE="$DIR/.env"
MAIN_ENV="$main_path/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$MAIN_ENV" ]; then
  cp "$MAIN_ENV" "$ENV_FILE"
  echo "wt-stack: copied .env from main checkout ($MAIN_ENV) — check/adjust worktree-specific values"
elif [ -f "$ENV_FILE" ]; then
  echo "wt-stack: .env exists in worktree (no copy)"
else
  echo "wt-stack: no .env in main or worktree (skip)"
fi

# --- copy common gitignored runtime files from main checkout ----------------
# Fresh worktrees ship TRACKED files only. Gitignored runtime files (`.env*`,
# `certs/*.crt|*.key`, ...) must come from the main checkout or services crash
# at mount (e.g. a cert host-path bound as directory vs file — incident
# 2026-09-15, worktree-brave-meadow-0568). Copies a conservative allowlist:
# root `.env*` files + secrets-y top-level dirs. NEVER overwrites existing
# worktree files; NEVER touches node_modules/.venv/dist/target etc.
# NOTE: pre-filter with ONE grep — repos can have 30k+ ignored files
# (node_modules etc.); a per-line printf|grep loop would take minutes.
SECRET_DIRS='certs|ssl|keys|secrets|\.secrets|aws|\.aws'
copied_gitignored=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$main_path/$rel" ] || continue
  [ -e "$DIR/$rel" ] && continue   # never overwrite existing worktree files
  mkdir -p "$DIR/${rel%/*}"
  cp "$main_path/$rel" "$DIR/$rel"
  copied_gitignored=$((copied_gitignored+1))
done < <(git -C "$main_path" ls-files --others --ignored --exclude-standard 2>/dev/null \
        | grep -E "(^|/)\.env([^/]*)?$|^($SECRET_DIRS)/" || true)
[ "$copied_gitignored" -gt 0 ] && echo "wt-stack: copied $copied_gitignored gitignored file(s) from main checkout"

# --- compose base -----------------------------------------------------------
COMPOSE_BASE=""
# prefer the generic names first, then the common explicit variants
# (prod/local/devnet overrides — e.g. solana repo ships only
# docker-compose.prod.yml / docker-compose.local.yml / docker-compose.devnet.yml)
for f in compose.yml docker-compose.yml compose.prod.yml docker-compose.prod.yml \
         compose.local.yml docker-compose.local.yml compose.devnet.yml docker-compose.devnet.yml; do
  [ -f "$DIR/$f" ] && { COMPOSE_BASE="$f"; break; }
done
if [ -z "$COMPOSE_BASE" ]; then
  echo "wt-stack: no compose file in worktree (safe no-op)"
  exit 0
fi
echo "wt-stack: base compose=$COMPOSE_BASE"

OVERRIDE="$DIR/compose.worktree.yml"

# --- render base compose -> canonical merged YAML (single source of truth) ---
# `docker compose config --no-interpolate` resolves override files, extends,
# !reset/merge keys, multi-file -f a -f b. ${VAR} stays VERBATIM so secrets
# never land in compose.worktree.yml (they stay in .env). This canonical doc
# is BOTH the meta source and the rewrite input for the complete-compose dump.
COMPOSE_DUMP="$( (cd "$DIR" && docker compose -f "$COMPOSE_BASE" config --no-interpolate 2>/dev/null) || true )"
if [ -z "$COMPOSE_DUMP" ]; then
  echo "wt-stack: could not render $COMPOSE_BASE via docker compose config (skip)"
  exit 0
fi

# Extract the same meta schema the old regex parser produced (services,
# top-level networks, per-service Traefik routers, published ports, container
# names, env maps) — now from the merged canonical doc. Equal TSV/JSON shape so
# the downstream sections (env rewrite, routes, ports, hosts) stay untouched.
COMPOSE_META="$(python3 - "$project" "$COMPOSE_DUMP" <<'PY' 2>/dev/null || true
import json, sys, re
import yaml
project, dump = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(dump) or {}
svcs = doc.get("services") or {}
services, networks, external_nets = [], [], []
containers, envs, routes, ports = {}, {}, {}, {}
for s, d in svcs.items():
    services.append(s)
    cn = d.get("container_name")
    if cn: containers[s] = cn
    env = d.get("environment")
    if isinstance(env, dict):
        envs[s] = {str(k): str(v) for k, v in env.items() if v is not None}
    elif isinstance(env, list):
        for item in env:
            if isinstance(item, str) and "=" in item:
                k, _, v = item.partition("=")
                envs.setdefault(s, {})[k] = v
    lab = d.get("labels")
    labdict = {}
    if isinstance(lab, dict):
        labdict = {str(k): str(v) for k, v in lab.items()}
    elif isinstance(lab, list):
        for item in lab:
            if isinstance(item, str) and "=" in item:
                k, _, v = item.partition("=")
                labdict[k] = v
    for k, v in labdict.items():
        # NOTE: regex expects the FULL `key=value` — k alone (post-partition)
        # never matches the `=(.*)$` tail, so routes were always empty. Rebuild
        # the full string; val keeps the label value (quotes already stripped
        # by yaml/dump), stripped of any remaining surrounding quotes.
        m = re.match(r"traefik\.http\.routers\.([\w.-]+)\.([\w.-]+)=(.*)$", f"{k}={v}")
        if m:
            rtr, attr, val = m.group(1), m.group(2), m.group(3).strip().strip('"')
            routes.setdefault(s, {}).setdefault(rtr, {})[attr] = val
    plist = d.get("ports") or []
    for p in plist:
        if isinstance(p, dict) and p.get("published") is not None:
            tgt = p.get("target", "")
            ports.setdefault(s, []).append(f"{p['published']}:{tgt}")
        elif isinstance(p, str):
            ports.setdefault(s, []).append(p)
for nt, nd in (doc.get("networks") or {}).items():
    networks.append(nt)
    if isinstance(nd, dict) and nd.get("external"):
        external_nets.append(nt)
out = {"services": services, "networks": networks, "external_networks": external_nets,
       "containers": containers, "envs": envs,
       "routes": None, "ports": {s: p for s, p in ports.items() if p}}
def host_of(rule):
    m = re.match(r"Host\(\`([^\`]+)\`\)", rule or "")
    return m.group(1) if m else ""
out["routes"] = {s: [{"router": r, "host": host_of(a.get("rule", "")), "attrs": a}
                     for r, a in rs.items() if "rule" in a]
                 for s, rs in routes.items()}
json.dump(out, sys.stdout)
PY
)"
if [ -z "$COMPOSE_META" ]; then
  echo "wt-stack: could not extract meta from $COMPOSE_BASE (skip)"
  exit 0
fi

# services: prefer `docker compose config --services` (merges override files
# like docker-compose.override.yml); fall back to the python parser's list.
services="$( (cd "$DIR" && docker compose -f "$COMPOSE_BASE" config --services 2>/dev/null) || true )"
if [ -z "$services" ]; then
  services="$(printf '%s' "$COMPOSE_META" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).get("services",[])))')"
fi
networks_list="$(printf '%s' "$COMPOSE_META" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).get("networks",[])))')"
external_networks="$(printf '%s' "$COMPOSE_META" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).get("external_networks",[])))')"
if [ -z "$services" ]; then
  echo "wt-stack: could not list services of $COMPOSE_BASE (skip override)"
  exit 0
fi

# --- env host rewrite for isolated worktree networks -------------------------
# Owned (non-external) networks are re-created PER WORKTREE joined only by this
# worktree's containers (isolation: no shared DNS namespace with main). So
# environment values that reference the MAIN stack's container names (e.g.
# `MINIO_ENDPOINT: huginn-minio:9000` -> this worktree's `huginn-extract-9ca9-minio:9000`)
# MUST be rewritten, or they point at containers unreachable from the worktree
# networks. Rewrite any occurrence of a main container_name in env values to
# the worktree container_name. Emits TSV: svc<TAB>KEY<TAB>rewritten-value.
ENV_REWRITE_TSV="$(python3 - "$project" "$COMPOSE_META" <<'PY'
import json, re, sys
project, meta = sys.argv[1], sys.argv[2]
d = json.loads(meta)
# map: main container_name -> worktree container_name (generated below as
# <project>-<svc>); include the bare service name too (same DNS name).
rew = {}
for svc in d.get("services", []):
    cn = (d.get("containers") or {}).get(svc) or svc
    rew[cn] = f"{project}-{svc}"
    rew[svc] = f"{project}-{svc}"
# longest-first so `huginn-minio` wins over `minio` inside `huginn-minio:9000`
order = sorted(rew, key=len, reverse=True)
out = []
for svc, env in (d.get("envs") or {}).items():
    if not env:
        continue
    changed = {}
    for k, v in env.items():
        if not isinstance(v, str) or not v:
            continue
        nv = v
        for name in order:
            # whole-word-ish replace, BARE hostnames only: reject a following
            # `.` (public FQDN — `minio.rafaelferro.dev` stays untouched; the
            # label-host rewrite handles those), allow `:`/EOL/`/` after it.
            nv = re.sub(r'(?<![A-Za-z0-9_.-])' + re.escape(name) + r'(?![A-Za-z0-9_.-])',
                        rew[name], nv)
        if nv != v:
            changed[k] = nv
    for k, nv in changed.items():
        out.append(f"{svc}\t{k}\t{nv}")
print("\n".join(out))
PY
)"

# routes per service, TSV: svc<TAB>router<TAB>host<TAB>attr=val;attr=val...
route_rows="$(printf '%s' "$COMPOSE_META" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for svc, rs in d.get("routes", {}).items():
    for r in rs:
        host = r["host"].strip()
        attrs = ";".join(f"{k}={v}" for k, v in r["attrs"].items())
        print(f"{svc}\t{r["router"]}\t{host}\t{attrs}")
')"
# published ports, TSV: svc<TAB>H:C
port_rows="$(printf '%s' "$COMPOSE_META" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for svc, ps in d.get("ports", {}).items():
    for p in ps:
        print(f"{svc}\t{p}")
')"

# worktree host from a main host: `foo.domain` + tag c852 -> `foo-c852.domain`
wt_host() { # $1 host  $2 tag
  local h="$1" t="$2" rest
  if [[ "$h" == *.* ]]; then
    rest="${h#*.}"
    printf '%s-%s.%s' "${h%%.*}" "$t" "$rest"
  else
    printf '%s-%s' "$h" "$t"
  fi
}

# route map for override: svc -> "router|host|attrPairs" (label hosts only —
# `$`-interpolated rules are handled via the APP_HOST env path instead)
declare -A wt_route
wt_svc_order=()
while IFS=$'\t' read -r s rtr host attrs; do
  [ -n "$s" ] || continue
  case "$host" in *\$*) continue ;; esac
  wt_route["$s"]="${rtr}|${host}|${attrs}"
  wt_svc_order+=("$s")
done <<< "$route_rows"

# frontend-ish service for the DISPLAY url (fallback: first routed service)
wt_display_svc=""
for s in "${wt_svc_order[@]}"; do
  case "$s" in
    *frontend*|*front*|*web*|*ui*|*app*) [ -z "$wt_display_svc" ] && wt_display_svc="$s" ;;
  esac
done
[ -z "$wt_display_svc" ] && [ "${#wt_svc_order[@]}" -gt 0 ] && wt_display_svc="${wt_svc_order[0]}"

# port conflict handling: v0.5 always STRIPS published ports (Traefik-only
# ingress); gen-compose.py logs each removed port below.
if [ -n "$port_rows" ]; then
  first_ports="$(printf '%s\n' "$port_rows" | head -1)"
  echo "wt-stack: WARN published ports ($first_ports ...) — stripped from compose.worktree.yml (Traefik-only ingress)"
fi

# --- generate COMPLETE compose.worktree.yml (v0.5: standalone, not overlay) -
# `docker compose config --no-interpolate` dump (COMPOSE_DUMP) is rewritten by
# gen-compose.py into a full standalone compose. The base compose is NEVER
# part of `up` again — merging it back would re-add its traefik.* labels
# append-only and re-collide with the main stack. gen-compose.py closes every
# contamination vector (see its header): container_name, image re-tag for
# local builds, traefik labels stripped + re-keyed (http AND tcp), ports
# removed, explicit volumes/networks renamed.
GEN_PY="$SELF_DIR/gen-compose.py"
python3 "$GEN_PY" "$project" "$tag" "$OVERRIDE" <<PY 2>&1 | sed 's/^/wt-stack: /' >&2
$COMPOSE_DUMP
PY
if [ ! -s "$OVERRIDE" ]; then
  echo "wt-stack: gen-compose.py produced empty $OVERRIDE (abort)"
  exit 1
fi
# ensure compose.worktree.yml is never accidentally committed (generated per worktree)
if [ -f "$DIR/.gitignore" ] && ! grep -qxF 'compose.worktree.yml' "$DIR/.gitignore"; then
  printf '\n# worktree docker override (auto-generated by wt-stack)\ncompose.worktree.yml\n' >> "$DIR/.gitignore"
  echo "wt-stack: added compose.worktree.yml to .gitignore"
elif [ ! -f "$DIR/.gitignore" ]; then
  printf '# worktree docker override (auto-generated by wt-stack)\ncompose.worktree.yml\n' > "$DIR/.gitignore"
  echo "wt-stack: created .gitignore with compose.worktree.yml"
fi
# validate BEFORE up — abort with clear error on malformed output
if ! ( cd "$DIR" && docker compose -f compose.worktree.yml config >/dev/null 2>&1 ); then
  echo "wt-stack: FAIL generated compose.worktree.yml does not parse — abort (check base compose for unsupported constructs)"
  exit 1
fi

# --- APP_HOST rewrite in .env (wt_host — append: host-<tag>.domain) ----------
FINAL_HOST=""
ENV_HOST_ORIG=""
if [ -f "$ENV_FILE" ] && grep -q '^APP_HOST=' "$ENV_FILE"; then
  cur="$(sed -n 's/^APP_HOST=//p' "$ENV_FILE" | head -1)"
  # Idempotency: detect trailing -<tag> suffix (wt_host appends)
  case "$cur" in
    *"-${tag}".*|*"-${tag}")
      # Already suffixed — strip the -<tag> (or -<tag>.domain) to recover orig
      ENV_HOST_ORIG="$(printf '%s' "$cur" | sed -E "s/-${tag}(\\.|$)/\\1/")"
      echo "wt-stack: APP_HOST already suffixed ($cur)"
      FINAL_HOST="$cur" ;;
    "")
      echo "wt-stack: APP_HOST empty in .env (leave as-is)" ;;
    *)
      ENV_HOST_ORIG="$cur"
      new_host="$(wt_host "$cur" "$tag")"
      sed -i.bak "s/^APP_HOST=.*/APP_HOST=${new_host}/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
      echo "wt-stack: APP_HOST rewritten -> ${new_host}"
      FINAL_HOST="${new_host}" ;;
  esac
fi

# labels fallback: no APP_HOST -> derive `hostname-<tag>.<domain>` from ANY
# Traefik Host() rule. Prefer display_svc (frontend-ish), else first routed svc.
if [ -z "$FINAL_HOST" ]; then
  # Try display_svc first, then iterate all routed services
  _fallback_order=()
  [ -n "$wt_display_svc" ] && _fallback_order+=("$wt_display_svc")
  for _s in "${wt_svc_order[@]}"; do
    [ "$_s" = "$wt_display_svc" ] && continue
    _fallback_order+=("$_s")
  done
  for _s in "${_fallback_order[@]}"; do
    [ -n "${wt_route[$_s]+x}" ] || continue
    IFS='|' read -r _r _h _a <<< "${wt_route[$_s]}"
    [ -n "$_h" ] || continue
    FINAL_HOST="$(wt_host "$_h" "$tag")"
    echo "wt-stack: Traefik host derived from svc=$_s (no APP_HOST) -> $FINAL_HOST"
    break
  done
fi

# Hard error: neither APP_HOST nor any Host() rule found
if [ -z "$FINAL_HOST" ]; then
  echo "wt-stack: ERROR no APP_HOST in .env and no Host() rule found — set APP_HOST=<your-domain> in .env (or add a Traefik Host() label)"
  exit 1
fi

# --- env rewrite: adapt CORS/URL/domain vars to the worktree (whitelist) ----
# Project-agnostic: nothing is hardcoded. "Identity" = the project's own hosts
# (APP_HOST + every label rule host); each maps 1:1 to its worktree form
# (hostname-<tag>.<domain>). Whitelisted KEYS whose VALUE contains an identity
# host get that substring replaced; domain/cookie keys are forced to the exact
# worktree host (session isolation, no shared cookies between wt and main).
# External hosts (e.g. AGENT_BASE_URL -> omnirouter...) are never touched.
# Extend the whitelist with WT_ENV_KEYS_EXTRA="KEY1,KEY2..." (globs ok).
ENV_REWRITE_MODE="${WT_ENV_REWRITE:-1}"
ENV_WL='^(NEXT_PUBLIC_|VITE_|REACT_APP_|PUBLIC_)|(_URL|_URI|_ORIGIN|_WS_URL|_ENDPOINT|_CALLBACK|_REDIRECT)$|^CORS|_DOMAIN$'
if [ -n "${WT_ENV_KEYS_EXTRA:-}" ]; then
  ENV_WL="${ENV_WL}|$(printf '%s' "$WT_ENV_KEYS_EXTRA" | tr ',' '|' | sed 's/\./\\./g; s/[*]/.*/g')"
fi
ID_HOSTS="$(
  printf '%s' "$COMPOSE_META" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for rs in d.get("routes", {}).values():
    for r in rs:
        h = r.get("host", "").strip()
        if h and "$" not in h:
            print(h)
'
  if [ -n "${ENV_HOST_ORIG:-}" ]; then printf '%s\n' "$ENV_HOST_ORIG"; fi
)"
ID_HOSTS="$(printf '%s\n' "$ID_HOSTS" | awk 'NF && !seen[$0]++')"

if [ "$ENV_REWRITE_MODE" = "1" ] && [ -f "$ENV_FILE" ] && [ -n "$FINAL_HOST" ] && [ -n "$ID_HOSTS" ]; then
  id_list="$(printf '%s\n' "$ID_HOSTS" | paste -sd, -)"
  rewrite_out="$(python3 - "$ENV_FILE" "$tag" "$FINAL_HOST" "$ENV_WL" "$id_list" <<'PY' || true
import sys, re
path, tag, wt_host, wl, id_csv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
wl_re = re.compile(wl)
ids = [h for h in id_csv.split(",") if h]
def wf(h):  # worktree form of an identity host
    if "." in h:
        lbl, rest = h.split(".", 1)
        return f"{lbl}-{tag}.{rest}"
    return f"{h}-{tag}"
wf_map = {h: wf(h) for h in ids}
apexes = {h.split(".", 1)[1] for h in ids if "." in h}
changed = []
out = []
for raw in open(path, encoding="utf-8", errors="replace"):
    line = raw.rstrip("\n")
    if "=" not in line or line.lstrip().startswith("#"):
        out.append(raw); continue
    key, val = line.split("=", 1)
    key, val = key.strip(), val.strip()
    if not wl_re.search(key):
        out.append(raw); continue
    orig = val
    if key.endswith("_DOMAIN") or key in ("COOKIE_DOMAIN", "SESSION_DOMAIN"):
        # force exact worktree host: full isolation (no shared cookies)
        base = val[1:] if val.startswith(".") else val
        if base in wf_map or any(base == a or base.endswith("." + a) for a in apexes) or base in ids:
            val = wt_host
    else:
        for h in sorted(wf_map, key=len, reverse=True):
            if h in val:
                val = val.replace(h, wf_map[h])
    if val != orig:
        changed.append((key, orig, val))
    out.append(f"{key}={val}\n")
if changed:
    open(path, "w", encoding="utf-8").writelines(out)
for key, o, n in changed:
    sys.stderr.write(f"wt-stack: env rewrite {key}: {o} -> {n}\n")
PY
)"
  [ -n "$rewrite_out" ] && printf '%s\n' "$rewrite_out"
fi

# --- env change detection -> rebuild -----------------------------------------
# Build-time-inlined vars (NEXT_PUBLIC_*, VITE_*, REACT_APP_*) only land in
# the bundle at build time; after a rewrite the image must be rebuilt for the
# worktree URLs to take effect — even on a re-run.
ENV_HASH_FILE="$DIR/.wt-stack.env-hash"
ENV_HASH="$(sha256sum "$ENV_FILE" 2>/dev/null | cut -d' ' -f1 || true)"
ENV_CHANGED=""
if [ -n "$ENV_HASH" ]; then
  if [ ! -f "$ENV_HASH_FILE" ]; then
    ENV_CHANGED=1   # first run under env-hash tracking — rebuild so the
                    # (possibly rewritten) .env lands in the images
  elif [ "$(cat "$ENV_HASH_FILE")" != "$ENV_HASH" ]; then
    ENV_CHANGED=1
  fi
fi

# --- build policy -----------------------------------------------------------
build_args=()
case "$BUILD" in
  always) build_args=(--build) ;;
  never)  build_args=() ;;
  auto|"")
    # --build on first mount (fresh code + rewritten env lands in images) and
    # whenever .env changed since last successful up; plain up otherwise.
    if ! docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null | grep -q .; then
      build_args=(--build)
      echo "wt-stack: first mount — building images (--build)"
    elif [ -n "$ENV_CHANGED" ]; then
      build_args=(--build)
      echo "wt-stack: env changed — rebuilding images (--build)"
    else
      echo "wt-stack: re-run — images already up (no --build)"
    fi
    ;;
  *)
    echo "wt-stack: WARN unknown WT_STACK_BUILD='$BUILD' (auto|always|never) — using auto"
    build_args=(--build)
    ;;
esac

# --- safety warnings (non-blocking) ------------------------------------------
# Log-only guards for vectors that can't be auto-isolated: host-wide sockets,
# host devices, absolute binds outside the worktree.
python3 - "$DIR" "$COMPOSE_DUMP" <<'PY' 2>/dev/null || true
import sys, yaml
wt, dump = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(dump) or {}
for s, d in (doc.get("services") or {}).items():
    vols = d.get("volumes") or []
    for v in vols:
        src = ""
        if isinstance(v, str): src = v.split(":", 1)[0]
        elif isinstance(v, dict): src = str(v.get("source") or "")
        if src in ("/var/run/docker.sock", "/dev", "/sys"):
            sys.stderr.write(f"wt-stack: WARN {s} mounts host-wide: {src}\n")
        elif src.startswith("/") and not src.startswith(wt):
            sys.stderr.write(f"wt-stack: WARN {s} absolute bind outside worktree: {src}\n")
PY

# --- orphan pre-clean (this project only, gentle) -----------------------------
# Stale exited/dead containers + networks with zero attached containers from
# interrupted runs — NEVER a running container or an in-use network.
for id in $(docker ps -aq --filter "status=exited" --filter "status=dead" --filter "label=com.docker.compose.project=$project" 2>/dev/null || true); do
  docker rm "$id" >/dev/null 2>&1 || true
  echo "wt-stack: removed stale container $id"
done
for net in $(docker network ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true); do
  if [ -z "$(docker ps -aq --filter "network=$net" 2>/dev/null || true)" ]; then
    docker network rm "$net" >/dev/null 2>&1 || true
    echo "wt-stack: removed stale network $net"
  fi
done

# --- bring up ---------------------------------------------------------------
# v0.5: SINGLE-FILE up. The base compose is NEVER part of the command — merging
# it back re-adds its traefik.* labels append-only and re-collides with the
# main stack. compose.worktree.yml is complete (name + all services).
up_cmd=(docker compose --project-name "$project" -f compose.worktree.yml up -d)
[ "${#build_args[@]}" -gt 0 ] && up_cmd+=("${build_args[@]}")

if [ "$DRY" = "1" ]; then
  echo "wt-stack: WT_DRY_RUN=1 — would run:"
  echo "  cd $DIR && ${up_cmd[*]}"
  [ -n "$FINAL_HOST" ] && echo "wt-stack: URL=https://$FINAL_HOST"
  exit 0
fi

# Containers are ground truth: compose may exit non-zero on WARNINGS (e.g.
# shared networks) while the stack is actually up — exit 0 then. Only a
# genuinely dead stack (0 containers) propagates the compose rc.
rc=0
if ( cd "$DIR" && "${up_cmd[@]}" ); then
  rc=0
else
  rc=$?
fi

n="$(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null | wc -l)"
if [ "$n" -gt 0 ]; then
  echo "wt-stack: up ok — $n container(s) project=$project (compose rc=$rc)"
  [ -n "$FINAL_HOST" ] && echo "wt-stack: URL=https://$FINAL_HOST"
  [ -n "$ENV_HASH" ] && printf '%s' "$ENV_HASH" > "$ENV_HASH_FILE"

  # --- worktree orchestrator: tag-scoped isolation override + up --------------
  # Some app repos ship their own orchestrator compose (`docker-compose.orchestrator.yml`
  # + an overlay). Those overlays historically use GLOBAL FIXED names
  # (project/container/networks/volumes `*-wor-orchestrator*`), so a SECOND
  # worktree collides on the same names and never gets an orchestrator. Generate
  # a tag-scoped override that renames every owned resource to
  # `<project>-orchestrator` / `<project>_orchestrator_*` and rewires the
  # internal refs to THIS worktree's hub/redis/networks (and `.env`'s
  # BACKEND_WS_URL / ORCHESTRATOR_CONNECT_TOKEN), validate, then up it INSIDE
  # the worktree dir — teardown.sh's label resolution (working_dir) picks it up
  # automatically. Escape hatch: WT_NO_ORCHESTRATOR=1 skips entirely.
  ORCH_BASE="$DIR/docker-compose.orchestrator.yml"
  ORCH_OVERLAY="$DIR/compose.worktree.orchestrator.yml"
  ORCH_ISOLATE="$DIR/compose.worktree.orchestrator.$tag.yml"
  if [ -f "$ORCH_BASE" ] && [ -f "$ORCH_OVERLAY" ] && [ -z "${WT_NO_ORCHESTRATOR:-}" ]; then
    if python3 - "$project" "$ORCH_BASE" "$ORCH_OVERLAY" "$ORCH_ISOLATE" <<'PY'
import sys
import yaml
project, base, overlay, out = sys.argv[1:5]
base = yaml.safe_load(open(base)) or {}
doc = yaml.safe_load(open(overlay)) or {}
svcs = doc.setdefault("services", {})
if "orchestrator" in svcs and isinstance(svcs["orchestrator"], dict):
    svc = svcs["orchestrator"]
    svc["container_name"] = f"{project}-orchestrator"
    svc["hostname"] = f"{project}-orchestrator"
    env = svc.setdefault("environment", {})
    if isinstance(env, list):
        env = {str(x).partition("=")[0]: str(x).partition("=")[2]
               for x in env if "=" in str(x)}
        svc["environment"] = env
    env.update({
        "HUB_URL": f"http://{project}-hub:4444",
        "DOCKER_VM_NETWORK": f"{project}_orchestrator_vm_net",
        "DOCKER_BROWSER_NETWORK": f"{project}_orchestrator_browser_net",
        "DOCKER_NETWORK": f"{project}_internal_net",
        "DOCKER_EGRESS_NETWORK": f"{project}_scraping_net",
        "REDIS_HOST": f"{project}-redis",
        "BACKEND_WS_URL": "${BACKEND_WS_URL:-}",
        "ORCHESTRATOR_CONNECT_TOKEN": "${ORCHESTRATOR_CONNECT_TOKEN:-}",
    })
nets = doc.setdefault("networks", {})
for alias, key in (("orchestrator_net", f"{project}_orchestrator_vm_net"),
                   ("orchestrator_browser_net", f"{project}_orchestrator_browser_net"),
                   ("internal_net", f"{project}_internal_net")):
    if alias in nets and isinstance(nets[alias], dict):
        nets[alias]["name"] = key
        nets[alias]["external"] = True  # owned by the worktree stack project
vols = doc.setdefault("volumes", {})
for alias, key in (("orchestrator_iso_cache", f"{project}_orchestrator_iso_cache"),
                   ("orchestrator_conf", f"{project}_orchestrator_conf")):
    if alias in vols and isinstance(vols[alias], dict):
        vols[alias]["name"] = key
with open(out, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
print(f"wt-stack: orchestrator isolate override -> {out}")
PY
    then
      if [ "$DRY" = "1" ]; then
        echo "wt-stack: WT_DRY_RUN=1 — would run:"
        echo "  cd $DIR && docker compose -p $project-orchestrator -f $ORCH_BASE -f $ORCH_OVERLAY -f $ORCH_ISOLATE up -d"
      elif ( cd "$DIR" && docker compose -p "$project-orchestrator" \
             -f docker-compose.orchestrator.yml \
             -f compose.worktree.orchestrator.yml \
             -f "$ORCH_ISOLATE" config --quiet >/dev/null 2>&1 ); then
        if ( cd "$DIR" && docker compose -p "$project-orchestrator" \
             -f docker-compose.orchestrator.yml \
             -f compose.worktree.orchestrator.yml \
             -f "$ORCH_ISOLATE" up -d >/dev/null 2>&1 ); then
          echo "wt-stack: orchestrator up (project=$project-orchestrator)"
        else
          _orch_rc=$?
          echo "wt-stack: WARN orchestrator up failed (rc=$_orch_rc) — worktree sessions needing a browser will not provision"
        fi
      else
        echo "wt-stack: WARN orchestrator compose config invalid (skip up) — check $ORCH_OVERLAY vs $ORCH_BASE"
      fi
    else
      echo "wt-stack: WARN could not generate orchestrator isolate override (skip)"
    fi
  fi
  [ -n "$ORCH_ISOLATE" ] && [ -f "$DIR/.gitignore" ] && \
    grep -qxF "compose.worktree.orchestrator.$tag.yml" "$DIR/.gitignore" || \
    printf 'compose.worktree.orchestrator.%s.yml\n' "$tag" >> "$DIR/.gitignore"

  # --- TLS probe (non-blocking WARN) -----------------------------------------
  # Probe the worktree URL via HTTPS; LE issuance may still be in progress on
  # first deploy — retry up to 6 times (~30s total). Success -> OK; failure ->
  # WARN with host + curl exit code + hint. NEVER blocks the script (exit 0).
  if [ -n "$FINAL_HOST" ]; then
    _tls_ok=0
    for _attempt in 1 2 3 4 5 6; do
      if curl -fsI --max-time 5 "https://$FINAL_HOST" >/dev/null 2>&1; then
        _tls_ok=1
        break
      fi
      [ "$_attempt" -lt 6 ] && sleep 5
    done
    if [ "$_tls_ok" = "1" ]; then
      echo "wt-stack: OK TLS https://$FINAL_HOST valid"
    else
      _curl_rc=0
      curl -fsI --max-time 5 "https://$FINAL_HOST" >/dev/null 2>&1 || _curl_rc=$?
      echo "wt-stack: WARN TLS probe failed for https://$FINAL_HOST (curl exit=$_curl_rc) — Let's Encrypt issuance may still be in progress; retry in 30s"
    fi
  fi

  exit 0
else
  echo "wt-stack: warning — no running container matched project=$project"
  exit "$rc"
fi