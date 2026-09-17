#!/usr/bin/env python3
"""wt-stack v0.6.0 — rewrite a `docker compose config --no-interpolate` dump
into a COMPLETE standalone compose.worktree.yml that cannot touch the main
stack. Run: gen-compose.py <project> <tag> <outfile>  (YAML dump on stdin).

Closes every production-contamination vector (2026-09-16/17 incidents):
  - service keys re-keyed <project>-<svc>      (Docker aliases EVERY service
                                                by its key on EVERY joined
                                                network — INCLUDING the shared
                                                traefik_proxy. A worktree
                                                keyed `postgres:` claimed the
                                                alias `postgres` on
                                                traefik_proxy and collided
                                                with the MAIN stack's
                                                postgres: main backend
                                                resolved 2 IPs and
                                                round-robined into the
                                                worktree DB — UndefinedTable
                                                outage 2026-09-17. Key ==
                                                container name now, so no
                                                short-name alias ever joins
                                                traefik_proxy)
  - internal refs remapped to the new keys:    depends_on, links, network
                                                aliases, healthcheck targets,
                                                env values (bare hostname,
                                                userinfo@host, scheme://host)
  - container_name <project>-<svc>             (never the main's names)
  - image re-tag when build: present           (wt --build never overwrites a
                                                shared prod tag, e.g. wallet-gateway:prod)
  - traefik.* labels stripped and re-emitted  routers/services/middlewares
    re-keyed <x>-<tag>                        (no "defined multiple times"
                                                collision on traefik_proxy)
  - ports stripped                            (Traefik-only ingress)
  - volumes: explicit-name -> <project>_<orig> (prod data never mounted);
    external volumes kept with warning
  - networks: owned -> <project>_<net>        (each worktree gets its own);
    external: traefik_proxy kept silently, others warned. Service joins are
    preserved (traefik_proxy: null stays — routing needs the join); explicit
    aliases matching an old service key/container name are remapped to the
    unique key
  - ${VAR} interpolation stays verbatim (--no-interpolate input), so secrets
    remain in .env only. Log lines to stderr with the "wt-stack:" prefix.
"""
import re
import shlex
import sys

import yaml


def wt_host(host: str, tag: str) -> str:
    if "." in host:
        lbl, rest = host.split(".", 1)
        return f"{lbl}-{tag}.{rest}"
    return f"{host}-{tag}"


def parse_labels(lab):
    """Base labels -> {key: value} (list of 'k=v' or dict).

    Guarantees: values are stripped of surrounding quotes; never leak
    trailing single or double quotes into emitted labels.
    """
    out = {}
    if isinstance(lab, dict):
        out = {str(k): str(v).strip().strip('"').strip("'") for k, v in lab.items()}
    elif isinstance(lab, list):
        for item in lab:
            if isinstance(item, str) and "=" in item:
                k, _, v = item.partition("=")
                out[k] = v.strip().strip('"').strip("'")
    return out


def rewrite_traefik(labels, tag, routed_svc):
    """Split base traefik labels by category and re-key for the wt stack.

    Returns a new labels list. Router/service/middleware names are suffixed
    <x>-<tag> for BOTH http and tcp routers (tcp SNI routers like
    `wallet-gateway-postgres` collided with production otherwise). Router rule
    hosts are rewritten to the wt host UNLESS they contain '$' (interpolated —
    leave verbatim, resolved from the wt .env at up time).

    Complete emission: EVERY router gets rule/entrypoints/tls/tls.certresolver/
    service/middlewares re-emitted.  traefik.enable + traefik.docker.network
    are emitted when ANY router exists across any proto.
    """
    groups = {}   # "http"|"tcp" -> {"routers"|"services"|"middlewares": {name: {attr: val}}}
    misc = {}
    for k, v in labels.items():
        if not k.startswith("traefik."):
            continue
        rest = k[len("traefik."):]
        if rest.startswith("http.") or rest.startswith("tcp."):
            proto, _, sub = rest.partition(".")
            if sub.startswith("routers."):
                name, _, attr = sub[len("routers."):].partition(".")
                groups.setdefault(proto, {}).setdefault("routers", {}).setdefault(name, {})[attr] = v
            elif sub.startswith("services."):
                name, _, attr = sub[len("services."):].partition(".")
                groups.setdefault(proto, {}).setdefault("services", {}).setdefault(name, {})[attr] = v
            elif sub.startswith("middlewares."):
                name, _, attr = sub[len("middlewares."):].partition(".")
                groups.setdefault(proto, {}).setdefault("middlewares", {}).setdefault(name, {})[attr] = v
            else:
                misc[k] = v
        else:
            misc[k] = v  # enable, docker.network, etc.

    new = []
    has_router = False
    for proto, cats in groups.items():
        # Emit middlewares first (re-keyed)
        for name, attrs in cats.get("middlewares", {}).items():
            for attr, val in attrs.items():
                new.append(f"traefik.{proto}.middlewares.{name}-{tag}.{attr}={val}")
        # Emit routers with COMPLETE attribute set
        for name, attrs in cats.get("routers", {}).items():
            has_router = True
            new_name = f"{name}-{tag}"
            svc_name = attrs.get("service", name)
            for attr, val in attrs.items():
                if attr == "service":
                    # Emit re-keyed service def separately below
                    continue
                if attr == "rule" and "$" not in val:
                    # Rewrite host tokens URL-safe; leave $-interpolated rules verbatim
                    val = re.sub(r"Host\(`([^`]+)`\)", lambda m: f"Host(`{wt_host(m.group(1), tag)}`)", val)
                    val = re.sub(r"HostSNI\(`([^`]+)`\)",
                                 lambda m: f"HostSNI(`{wt_host(m.group(1), tag)}`)", val)
                elif attr == "entries":
                    # rewire entrypoint references to tagged names
                    val = re.sub(r"EntryPoint\(\`([^`]+)`\)",
                                 lambda m: f"EntryPoint(`{wt_host(m.group(1), tag)}`)", val)
                elif attr == "middlewares":
                    val = re.sub(r"([\w.-]+)(?=[,@]|$)",
                                 lambda m: f"{m.group(1)}-{tag}", val)
                # NEW: tls attr — emit tls.certresolver if present
                if attr == "tls":
                    # ensure tls.certresolver is emitted if it was set on the router
                    if "tls.certresolver" not in attrs:
                        # check if a default resolver might be referenced elsewhere; keep verbatim
                        pass
                    # emit the full tls block with its sub-attrs
                    # rebuild tls section: we need to emit tls.certresolver separately
                    # since it was stored as a sub-attr of tls
                    pass
                new.append(f"traefik.{proto}.routers.{new_name}.{attr}={val}")
            # Emit re-keyed service definition for this router
            new.append(f"traefik.{proto}.routers.{new_name}.service={svc_name}-{tag}")
            # Emit service definition labels re-keyed
            for attr, val in cats.get("services", {}).get(svc_name, {}).items():
                new.append(f"traefik.{proto}.services.{svc_name}-{tag}.{attr}={val}")
        # leftover service defs whose router never referenced them
        for name, attrs in cats.get("services", {}).items():
            if name.endswith("-" + tag) or any(name == r.get("service", name)
                                               for r in cats.get("routers", {}).values()):
                continue
            for attr, val in attrs.items():
                new.append(f"traefik.{proto}.services.{name}-{tag}.{attr}={val}")

    # Emit traefik.enable and traefik.docker.network when ANY router exists
    # across ALL protos — check if any router was emitted in any proto
    overall_has_router = False
    for proto, cats in groups.items():
        if cats.get("routers", {}):
            overall_has_router = True
            break
    if overall_has_router:
        new.append("traefik.enable=true")
        new.append("traefik.docker.network=traefik_proxy")
    else:
        new.append("traefik.enable=false")

    # Emit misc non-traefik labels (already stripped of quotes by parse_labels)
    for k, v in misc.items():
        # Skip traefik.enable/traefik.docker.network — already emitted above
        if k.endswith("traefik.enable") or k.endswith("traefik.docker.network"):
            continue
        new.append(f"{k}={v}")

    return new


def remap_depends_on(d, svc_map):
    """depends_on keys ARE compose service keys — rename them with the
    service, or `docker compose config` fails on undefined services."""
    dep = d.get("depends_on")
    if isinstance(dep, dict):
        d["depends_on"] = {svc_map.get(k, k): v for k, v in dep.items()}
    elif isinstance(dep, list):
        d["depends_on"] = [svc_map.get(x, x) for x in dep]


def remap_links(d, host_map):
    """links target a service key or container name (`svc` | `svc:alias`) —
    the target token before ':' is the service ref, the alias part stays."""
    lnk = d.get("links")
    if not isinstance(lnk, list):
        return
    out = []
    for item in lnk:
        if not isinstance(item, str):
            out.append(item)
        elif ":" in item:
            tgt, _, alias = item.partition(":")
            out.append(f"{host_map.get(tgt, tgt)}:{alias}")
        else:
            out.append(host_map.get(item, item))
    d["links"] = out


def remap_network_aliases(d, host_map):
    """Explicit per-network aliases equal to an old service key/container
    name must become the unique key — Compose keeps the alias verbatim, so a
    short name on traefik_proxy would re-collide with the main stack."""
    nw = d.get("networks")
    if not isinstance(nw, dict):
        return
    for nc in nw.values():
        if isinstance(nc, dict) and isinstance(nc.get("aliases"), list):
            nc["aliases"] = [host_map.get(a, a) for a in nc["aliases"]]


# healthcheck rewrite: flag-aware so only HOST positions are touched. A bare
# `postgres` after -h/--host/--hostname (or as an URL host) is the service DNS
# name and must follow the rename; a value after -U/-d/-p (username, dbname,
# password) is a credential and is NEVER rewritten.
_HOST_FLAGS = {"-h", "--host", "--hostname"}
_NONHOST_FLAGS = {
    "-a", "-A", "-c", "-d", "-n", "-p", "-P", "-u", "-U", "-v", "-w", "-W",
    "--command", "--dbname", "--no-password", "--password", "--prompt-password",
    "--user", "--username",
}


def _hc_token(tok, host_map, host_next):
    """Rewrite one healthcheck token; host_next=True means the previous token
    was a host flag, so THIS bare token is hostname position. Returns
    (new_tok, new_host_next)."""
    if tok in _HOST_FLAGS:
        return tok, True
    if tok in _NONHOST_FLAGS:
        return tok, False
    if tok.startswith("--host="):
        v = tok[len("--host="):]
        return "--host=" + host_map.get(v, v), False
    if tok.startswith("-h") and len(tok) > 2 and tok[2] != "-" and not tok[2].isdigit():
        v = tok[2:]
        return "-h" + host_map.get(v, v), False
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*://)([^/?:@]*)(.*)$", tok)
    if m and m.group(2) in host_map:
        return m.group(1) + host_map[m.group(2)] + m.group(3), False
    if host_next:
        return host_map.get(tok, tok), False
    return tok, False


def _shell_has_host_flag(cmd):
    try:
        toks = shlex.split(cmd)
    except ValueError:
        return False
    return any(t in _HOST_FLAGS or t.startswith("--host=")
               or (t.startswith("-h") and len(t) > 2 and t[2] != "-" and not t[2].isdigit())
               for t in toks)


def _rewrite_shell_cmd(cmd, host_map):
    """CMD-SHELL form: one command string. Only touched when a host flag is
    plainly present (never mangles `-U postgres` / `-d db` values on their
    own); whitespace-tokenized with flag awareness, then rejoined."""
    try:
        toks = shlex.split(cmd)
    except ValueError:
        return cmd
    out = []
    host_next = False
    for t in toks:
        nv, host_next = _hc_token(t, host_map, host_next)
        out.append(nv)
    return " ".join(out)


def remap_healthcheck(d, host_map):
    """Healthchecks that probe a sibling service by its (now renamed) key
    would fail DNS once the key-derived alias is gone. Rewrite host positions
    only."""
    hc = d.get("healthcheck")
    if not isinstance(hc, dict):
        return
    test = hc.get("test")
    if not isinstance(test, list):
        return
    out = []
    host_next = False
    for item in test:
        if not isinstance(item, str):
            out.append(item)
            host_next = False
            continue
        if any(c in item for c in " \t"):
            # CMD-SHELL — rewrite only when a host flag is clearly present
            out.append(_rewrite_shell_cmd(item, host_map) if _shell_has_host_flag(item) else item)
            host_next = False
            continue
        nv, host_next = _hc_token(item, host_map, host_next)
        out.append(nv)
    hc["test"] = out


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: gen-compose.py <project> <tag> <outfile>\n")
        sys.exit(2)
    project, tag, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = sys.stdin.read()
    doc = yaml.safe_load(raw) or {}
    doc["name"] = project
    raw_svcs = doc.get("services") or {}

    # --- service key rename: `svc` -> `<project>-<svc>` ----------------------
    # Docker Compose auto-aliases EVERY service by its key on EVERY joined
    # network — INCLUDING the shared traefik_proxy. A worktree service keyed
    # `postgres` therefore claimed the alias `postgres` on traefik_proxy,
    # colliding with the MAIN stack's postgres (same alias): the main backend
    # (POSTGRES_HOST=postgres) got TWO DNS answers and round-robined into the
    # worktree DB (UndefinedTable outage 2026-09-17). Re-keying removes the
    # default alias entirely: key == container_name == one unique DNS name.
    svc_map = {}   # old key -> new key
    for s in raw_svcs:
        new_key = f"{project}-{s}"
        if s.startswith(project + "-"):
            new_key = s      # idempotency guard: never double-prefix
        svc_map[s] = new_key

    # hostname rewrite map: old service key, base container_name, AND the new
    # key all -> the new key (new == container_name == one DNS name). The
    # self-entries make the rewrite idempotent: already-rewritten values match
    # and stay put.
    host_map = {}
    for s, d in raw_svcs.items():
        new_key = svc_map[s]
        host_map[s] = new_key
        host_map[new_key] = new_key
        cn = (d.get("container_name") or "").strip()
        if cn:
            host_map[cn] = new_key

    doc["services"] = {svc_map[s]: raw_svcs[s] for s in raw_svcs}

    def rewrite_env_value(v):
        # Bare hostname tokens in env values -> the wt DNS name. Host
        # position: after the last '@' (URL userinfo), else after an optional
        # scheme://, else at the start; bounded by / : ? — NEVER touches URL
        # userinfo/password. Values containing '$' (interpolation) are left
        # verbatim — ${VAR} resolves from the wt .env at up.
        if not isinstance(v, str) or not v or "$" in v:
            return v
        out = v
        for name in sorted(host_map, key=len, reverse=True):
            repl = host_map[name]
            head = ""
            tail = out
            if "@" in tail:
                h, _, t = tail.rpartition("@")
                head, tail = h + "@", t
            scheme = ""
            m = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", tail)
            if m:
                scheme = m.group(0)
                tail = tail[m.end():]
            m = re.match(r"^([^/?:]*)([/?:].*)?$", tail)
            hostpart = m.group(1) if m else tail
            if hostpart == name:
                out = head + scheme + repl + (m.group(2) if m and m.group(2) else "")
        return out

    removed_ports = []
    for s, d in raw_svcs.items():
        # key == container_name: the wt container's only DNS name is the
        # unique <project>-<svc> — no short-name alias anywhere.
        d["container_name"] = svc_map[s]
        # internal references that point at a service by its (renamed) key
        remap_depends_on(d, svc_map)
        remap_links(d, host_map)
        remap_network_aliases(d, host_map)
        remap_healthcheck(d, host_map)
        # image re-tag: local builds only
        if "build" in d:
            old = d.get("image")
            d["image"] = f"{project}-{s}:latest"
            sys.stderr.write(f"wt-stack: image re-tag {s}: {old} -> {d['image']}\n")
        # ports stripped
        if d.get("ports"):
            removed_ports.append((s, list(d["ports"])))
            del d["ports"]
        # env host rewrite: bare service/container hostnames in plain env values
        # -> <project>-<svc> (isolated networks can't resolve the main's names).
        # URL-safe: hostname token only after the last '@' / optional scheme,
        # bounded by :/? — NEVER touches URL userinfo/password.
        env = d.get("environment")
        if isinstance(env, dict):
            for k, v in list(env.items()):
                nv = rewrite_env_value(str(v))
                if nv != v:
                    env[k] = nv
        elif isinstance(env, list):
            for i, item in enumerate(env):
                if isinstance(item, str) and "=" in item:
                    k, _, v = item.partition("=")
                    nv = rewrite_env_value(v)
                    if nv != v:
                        env[i] = f"{k}={nv}"

        # labels: strip base traefik.*, re-emit wt-scoped; keep non-traefik
        base = parse_labels(d.get("labels"))
        routed = any(k.startswith("traefik.http.routers.") for k in base)
        non_traefik = [(k, v) for k, v in base.items() if not k.startswith("traefik.")]
        wt_traefik = rewrite_traefik({k: v for k, v in base.items()
                                       if k.startswith("traefik.")}, tag, routed)
        d["labels"] = [f"{k}={v}" for k, v in non_traefik] + wt_traefik

    # top-level volumes: explicit-name -> <project>_<key>; external kept.
    # NOTE: the `docker compose config` dump ALREADY resolves implicit names
    # (e.g. pgdata -> name: wallet-gateway-prod_pgdata). If we left that name
    # in place the wt would mount the MAIN stack's volume — so EVERY volume
    # with a resolved `name:` is re-scoped to <project>_<key> (the clean name
    # compose would derive anyway). External volumes (shared infra) kept.
    for vname, vd in (doc.get("volumes") or {}).items():
        if isinstance(vd, dict) and vd.get("external"):
            sys.stderr.write(f"wt-stack: WARN external volume kept: {vname}\n")
            continue
        if isinstance(vd, dict):
            vd["name"] = f"{project}_{vname}"
            sys.stderr.write(f"wt-stack: volume rename {vname} -> {vd['name']}\n")

    # top-level networks: owned -> <project>_<net>; external kept
    for nname, nd in (doc.get("networks") or {}).items():
        if isinstance(nd, dict) and nd.get("external"):
            if nname != "traefik_proxy":
                sys.stderr.write(f"wt-stack: WARN external network kept: {nname}\n")
            continue
        if isinstance(nd, dict):
            nd["name"] = f"{project}_{nname}"

    with open(outfile, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
    sys.stderr.write(f"wt-stack: generated {outfile}\n")
    for s, ps in removed_ports:
        for p in ps:
            sys.stderr.write(f"wt-stack: port removed {s}: {p}\n")


if __name__ == "__main__":
    main()