#!/usr/bin/env python3
"""wt-stack v0.5.1 — rewrite a `docker compose config --no-interpolate` dump
into a COMPLETE standalone compose.worktree.yml that cannot touch the main
stack. Run: gen-compose.py <project> <tag> <outfile>  (YAML dump on stdin).

Closes every production-contamination vector (2026-09-16 incidents):
  - container_name <project>-<svc>            (never the main's names)
  - image re-tag when build: present          (wt --build never overwrites a
                                                shared prod tag, e.g. wallet-gateway:prod)
  - traefik.* labels stripped and re-emitted  routers/services/middlewares
    re-keyed <x>-<tag>                        (no "defined multiple times"
                                                collision on traefik_proxy)
  - ports stripped                            (Traefik-only ingress)
  - volumes: explicit-name -> <project>_<orig> (prod data never mounted);
    external volumes kept with warning
  - networks: owned -> <project>_<net>        (no DNS-alias collision);
    external: traefik_proxy kept silently, others warned
  - ${VAR} interpolation stays verbatim (--no-interpolate input), so secrets
 remain in .env only. Log lines to stderr with the "wt-stack:" prefix.
"""
import re
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


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: gen-compose.py <project> <tag> <outfile>\n")
        sys.exit(2)
    project, tag, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = sys.stdin.read()
    doc = yaml.safe_load(raw) or {}
    doc["name"] = project
    svcs = doc.get("services") or {}

    # hostname rewrite map: service key AND base container_name -> the wt
    # container's DNS name (<project>-<svc>). Only exact bare-hostname tokens
    # are rewritten (URL-safe: hostname after last '@', bounded by :/?); URL
    # userinfo/password and values containing '$' (interpolation) are left
    # untouched — ${VAR} stays verbatim and resolves from the wt .env at up.
    host_map = {}
    for s, d in svcs.items():
        host_map[s] = f"{project}-{s}"
        cn = (d.get("container_name") or "").strip()
        if cn:
            host_map[cn] = f"{project}-{s}"

    def rewrite_env_value(v):
        if not isinstance(v, str) or not v or "$" in v:
            return v
        out = v
        for name in sorted(host_map, key=len, reverse=True):
            repl = host_map[name]
            if "@" in out:
                head, _, tail = out.rpartition("@")
                m = re.match(r"^([^/?:]*)([/?:].*)?$", tail)
                hostpart = m.group(1) if m else tail
                if hostpart == name:
                    out = head + "@" + repl + tail[len(hostpart):]
            else:
                m = re.match(r"^([^/?:]*)([/?:].*)?$", out)
                hostpart = m.group(1) if m else out
                if hostpart == name:
                    out = repl + (m.group(2) if m and m.group(2) else "")
        return out

    removed_ports = []
    for s, d in svcs.items():
        d["container_name"] = f"{project}-{s}"
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
        # URL-safe: hostname token only after the last '@', bounded by :/? —
        # NEVER touches URL userinfo/password.
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