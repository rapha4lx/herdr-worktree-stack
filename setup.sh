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
#   5. Generate compose.worktree.yml if missing: `name: <project>` +
#      `container_name: <project>-<svc>` per service (services from
#      `docker compose config --services`; fallback top-level key grep).
#      Networks inherited from the base compose are declared `external: true`
#      (worktree joins the SHARED networks — incl. traefik_proxy — without
#      trying to own them; kills the "exists but was not created for project"
#      warning / non-zero exit).
#   6. Prefix APP_HOST in .env with `<tag>-` if present and not prefixed.
#      Fallback (no APP_HOST): derive a worktree host from the base compose
#      Traefik labels — `Host(`foo.domain`)` -> `foo-<tag>.domain` (needs
#      wildcard DNS, e.g. `*.rafaelferro.dev`) — and inject a per-service
#      overriding label into compose.worktree.yml (compose merges labels
#      append-only; the later duplicate rule key wins in Traefik). URL =
#      `https://foo-<tag>.domain`, printed as `wt-stack: URL=...`.
#   7. `docker compose -f compose.yml -f compose.worktree.yml up -d [--build]`.
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
#   APP_HOST   = `<tag>-<orig>`     -> e.g. `9ca9-app.example.com`
# Teardown NEVER guesses the name: it resolves the project from the live
# container label `com.docker.compose.project.working_dir` == worktree path
# (teardown.sh in this same plugin dir). Naming is for humans/URLs only.

set -euo pipefail

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
# existing worktree .env. The APP_HOST prefix step below then applies the
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

# --- parse base compose (agnostic helper) ------------------------------------
# One python3 pass extracts everything the override needs, project-agnostic:
#   services, top-level networks, per-service Traefik routers (attrs), and
#   published ports. No hardcoded project knowledge.
COMPOSE_META="$(python3 - "$DIR/$COMPOSE_BASE" <<'PY' 2>/dev/null || true
import json, sys, re
fn = sys.argv[1]
txt = open(fn, encoding="utf-8", errors="replace").read()
lines = txt.split("\n")
services, networks, external_nets, routes, ports = [], [], [], {}, {}
containers, envs = {}, {}
svc = section = None
svc_re = re.compile(r"^  ([\w-]+):\s*$")
sec_re = re.compile(r"^    ([\w-]+):\s*$")
port_re = re.compile(r'^\s{6}-\s*"?(\d+):([\d]+(?:/[a-z]+)?)"?\s*$')
lab_re = re.compile(r'traefik\.http\.routers\.([\w.-]+)\.([\w.-]+)=(.+)')
for line in lines:
    m = svc_re.match(line)
    if m:
        svc = m.group(1); section = None
        if svc not in routes: routes[svc] = {}
        if svc not in ports: ports[svc] = []
        services.append(svc)
        continue
    m = sec_re.match(line)
    if m:
        section = m.group(1)
        continue
    # `container_name: X` is a service-level KEY with a VALUE (not a section —
    # sec_re above requires `key:` + EOL), so it never matches sec_re; capture
    # it directly.
    m = re.match(r"^    container_name:\s*(\S+)\s*$", line)
    if m and svc is not None:
        containers[svc] = m.group(1)
        continue
    if svc is None or section is None:
        continue
    if section == "ports":
        m = port_re.match(line)
        if m: ports[svc].append(f"{m.group(1)}:{m.group(2)}")
    elif section == "labels":
        m = lab_re.search(line)
        if m:
            rtr, attr, val = m.group(1), m.group(2), m.group(3).rstrip('"').strip()
            routes[svc].setdefault(rtr, {})[attr] = val
    elif section == "environment":
        # `      KEY: value` items under `environment:` (mapping form).
        m = re.match(r'^\s{6}([^#][^:]*):\s*(.*)$', line)
        if m:
            envs.setdefault(svc, {})[m.group(1).strip()] = m.group(2).strip()
# top-level networks (2-space keys under `networks:`; note the per-network
# `external: <bool>` flag — external networks are SHARED infra (traefik_proxy
# etc) and must stay external; owned networks are isolated per worktree).
in_net = False
for i, line in enumerate(lines):
    t = line
    if re.match(r"^networks:\s*$", t):
        in_net = True; continue
    if in_net:
        m = re.match(r"^  ([\w-]+):\s*$", t)
        if m:
            nt = m.group(1)
            networks.append(nt)
            # scan the network's block (4-space indented) for `external: true`
            ext = False
            for j in range(i + 1, len(lines)):
                l = lines[j]
                if l.startswith("    ") and re.search(r"external\s*:\s*true", l):
                    ext = True; break
                if l.strip() and not l.startswith("    "):
                    break
            if ext: external_nets.append(nt)
            continue
        if t.strip() and not t.startswith(" "):
            in_net = False
out = {"services": services, "networks": networks, "external_networks": external_nets,
       "containers": containers, "envs": envs,
       "routes": None, "ports": {s: p for s, p in ports.items() if p}}
def host_of(rule):
    m = re.match(r"Host\(`([^`]+)`\)", rule or "")
    return m.group(1) if m else ""
out["routes"] = {s: [{"router": r, "host": host_of(a.get("rule", "")), "attrs": a}
                     for r, a in rs.items() if "rule" in a]
                 for s, rs in routes.items()}
json.dump(out, sys.stdout)
PY
)"
if [ -z "$COMPOSE_META" ]; then
  echo "wt-stack: could not parse $COMPOSE_BASE (skip override)"
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

# port conflict handling: warn always; shift only when WT_PORT_SHIFT=<n> set
if [ -n "$port_rows" ]; then
  if [ -n "${WT_PORT_SHIFT:-}" ]; then
    echo "wt-stack: published ports found — shifting host ports by +$WT_PORT_SHIFT (WT_PORT_SHIFT)"
  else
    first_ports="$(printf '%s\n' "$port_rows" | head -1)"
    echo "wt-stack: WARN published ports ($first_ports ...) — worktree will CONFLICT with main on host ports; set WT_PORT_SHIFT=<n> to remap"
  fi
fi

# --- generate override (always — keeps in sync with base compose) ----------
{
  printf 'name: %s\nservices:\n' "$project"
  while IFS= read -r s; do
    printf '  %s:\n    container_name: %s-%s\n' "$s" "$project" "$s"
    # Traefik isolation: router NAME suffixed with the worktree tag so main
    # and worktree routers NEVER collide (the "HTTP router defined multiple
    # times" failure seen 2026-09-15). All base router attrs are MIRRORED
    # (rule host rewritten to the worktree host) — agnostic to entrypoints/
    # certresolver/middlewares/tls/priority/...; service pinned if absent.
    if [ -n "${wt_route[$s]+x}" ]; then
      IFS='|' read -r rtr host attrs <<< "${wt_route[$s]}"
      wt_rtr="${rtr}-${tag}"
      wt_host_val="$(wt_host "$host" "$tag")"
      {
        printf '    labels:\n'
        printf '      - "traefik.http.routers.%s.rule=Host(`%s`)"\n' "$wt_rtr" "$wt_host_val"
        has_svc=0
        if [ -n "$attrs" ]; then
          while IFS= read -r av; do
            [ -n "$av" ] || continue
            a="${av%%=*}"; v="${av#*=}"
            [ "$a" = "rule" ] && continue
            [ "$a" = "service" ] && has_svc=1
            printf '      - "traefik.http.routers.%s.%s=%s"\n' "$wt_rtr" "$a" "$v"
          done <<< "${attrs//;/$'\n'}"
        fi
        [ "$has_svc" = "0" ] && printf '      - "traefik.http.routers.%s.service=%s"\n' "$wt_rtr" "$rtr"
      }
    fi
    # published ports: remap host port when WT_PORT_SHIFT set
    if [ -n "${WT_PORT_SHIFT:-}" ] && [ -n "$port_rows" ]; then
      while IFS=$'\t' read -r ps ph; do
        [ "$ps" = "$s" ] || continue
        hp="${ph%%:*}"; cp="${ph#*:}"
        nh=$((hp + WT_PORT_SHIFT))
        printf '    ports:\n      - "%s:%s"\n' "$nh" "$cp"
      done <<< "$port_rows"
    fi
    # env host rewrite: point *_HOST/_URL/_ENDPOINT-style values at THIS
    # worktree's own containers (`<project>-<svc>`, globally unique) instead
    # of the main stack's `huginn-*` / bare service names. With isolated
    # networks (below) the main containers are unreachable from the worktree
    # networks, and unique container names also dodge DNS alias collisions on
    # the shared traefik_proxy. Base `environment:` mapping values are
    # re-emitted here only for keys whose value actually changed.
    if [ -n "$ENV_REWRITE_TSV" ]; then
      wt_env="$(printf '%s\n' "$ENV_REWRITE_TSV" | awk -F'\t' -v svc="$s" '$1==svc{printf "      %s: %s\n", $2, $3}')"
      if [ -n "$wt_env" ]; then
        printf '    environment:\n%s\n' "$wt_env"
      fi
    fi
  done <<< "$services"
  # OWNED (non-external) networks are ISOLATED per worktree (`name:
  # <project>_<net>`) so worktree containers never share a DNS namespace with
  # the main stack (fixes the `postgres`/`redis`/`minio` alias collision —
  # db-bootstrap migrated the WRONG postgres 2026-09-16). EXTERNAL networks
  # (traefik_proxy, ...) stay shared so Traefik can route to the services.
  if [ -n "$networks_list" ]; then
    printf 'networks:\n'
    while IFS= read -r nt; do
      if printf '%s\n' "$external_networks" | grep -qx "$nt"; then
        printf '  %s:\n    external: true\n' "$nt"
      else
        printf '  %s:\n    name: %s_%s\n' "$nt" "$project" "$nt"
      fi
    done <<< "$networks_list"
  fi
} > "$OVERRIDE"
echo "wt-stack: generated $OVERRIDE"
# ensure compose.worktree.yml is never accidentally committed (generated per worktree)
if [ -f "$DIR/.gitignore" ] && ! grep -qxF 'compose.worktree.yml' "$DIR/.gitignore"; then
  printf '\n# worktree docker override (auto-generated by wt-stack)\ncompose.worktree.yml\n' >> "$DIR/.gitignore"
  echo "wt-stack: added compose.worktree.yml to .gitignore"
elif [ ! -f "$DIR/.gitignore" ]; then
  printf '# worktree docker override (auto-generated by wt-stack)\ncompose.worktree.yml\n' > "$DIR/.gitignore"
  echo "wt-stack: created .gitignore with compose.worktree.yml"
fi

# --- APP_HOST prefix in .env ------------------------------------------------
FINAL_HOST=""
ENV_HOST_ORIG=""
if [ -f "$ENV_FILE" ] && grep -q '^APP_HOST=' "$ENV_FILE"; then
  cur="$(sed -n 's/^APP_HOST=//p' "$ENV_FILE" | head -1)"
  ENV_HOST_ORIG="$(printf '%s' "$cur" | sed -E "s/^${tag}-//")"
  case "$cur" in
    "${tag}-"*) echo "wt-stack: APP_HOST already prefixed ($cur)"; FINAL_HOST="$cur" ;;
    "")
      echo "wt-stack: APP_HOST empty in .env (leave as-is)" ;;
    *)
      sed -i.bak "s/^APP_HOST=.*/APP_HOST=${tag}-${cur}/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
      echo "wt-stack: APP_HOST prefixed -> ${tag}-${cur}"
      FINAL_HOST="${tag}-${cur}" ;;
  esac
fi

# labels fallback: no APP_HOST -> derive `hostname-<tag>.<domain>` from the
# Traefik labels and surface it as the worktree URL (injected into the
# override by the generation step above).
if [ -z "$FINAL_HOST" ] && [ -n "$wt_display_svc" ] && [ -n "${wt_route[$wt_display_svc]+x}" ]; then
  IFS='|' read -r _r _h _a <<< "${wt_route[$wt_display_svc]}"
  FINAL_HOST="$(wt_host "$_h" "$tag")"
  echo "wt-stack: Traefik host derived (no APP_HOST) -> $FINAL_HOST"
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
ENV_HASH="$(sha256sum "$ENV_FILE" 2>/dev/null | cut -d' ' -f1)"
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

# --- bring up ---------------------------------------------------------------
# Isolation guarantee: `--project-name "$project"` (CLI flag, highest
# precedence) + override `name:` + `container_name:` per service — worktree
# containers ALWAYS get unique names (project-<svc>), never collide with /
# tear down the main checkout's containers. Verified via docker compose config
# merge: override wins over base file for both name and container_name.
up_cmd=(docker compose --project-name "$project" -f "$COMPOSE_BASE" -f compose.worktree.yml up -d)
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
  exit 0
else
  echo "wt-stack: warning — no running container matched project=$project"
  exit "$rc"
fi