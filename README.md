# herdr worktree-stack

Auto-setup + teardown of git-worktree docker stacks.

When a worktree is created (`worktree.created`), `setup.sh` mounts an ISOLATED
compose stack for it: a complete standalone `compose.worktree.yml` is generated
(v0.5) from `docker compose config --no-interpolate` via `gen-compose.py`
(PyYAML required). Every production-contamination vector is closed:

- **containers/networks**: project `<repo>-<tag>` (one tag per worktree,
  trailing hex of the dir name); **service keys AND container names are
  `<project>-<svc>`** (never the short name). Docker Compose auto-aliases
  every service by its service key on every joined network — so a worktree
  keyed `postgres:` claimed the alias `postgres` on the shared `traefik_proxy`
  and collided with the MAIN stack's postgres (main backend resolved 2 IPs and
  round-robined into the worktree DB, UndefinedTable outage 2026-09-17). With
  the unique key, no short-name alias ever joins `traefik_proxy` and DNS
  collision with main is impossible. Owned networks re-scoped
  `<project>_<net>` — worktree never shares a DNS namespace with main (kills
  the `postgres`/`redis`/`minio` alias collision that let db-bootstrap migrate
  the WRONG postgres 2026-09-16). External networks (traefik_proxy) kept.
- **Traefik**: ALL base `traefik.*` labels stripped and re-emitted with
  router/service/middleware names re-keyed `<x>-<tag>` (http AND tcp) and a
  worktree host `hostname-<tag>.<domain>` (needs wildcard DNS) — worktree and
  main stacks never collide ("router defined multiple times" seen 2026-09-15).
- **images**: local builds re-tagged `<project>-<svc>:latest` — a worktree
  `--build` can never overwrite a shared prod tag (the `wallet-gateway:prod`
  overwrite seen 2026-09-16).
- **volumes**: every volume the dump resolves is re-scoped `<project>_<key>`
  (leaving the resolved name would MOUNT the main stack's volume); external
  volumes kept with a warning.
- **ports**: published ports stripped (Traefik-only ingress) with a warning.

Base compose is NEVER part of `up` (single-file up), so its labels can never
merge append-only back into the stack. `.env` is copied from the main checkout
when missing; APP_HOST is rewritten via `wt_host` (append: `host-<tag>.domain`);
env values
referencing main container names or service keys are rewritten to the
worktree DNS name (bare hostname, `user@host` and `scheme://host` forms —
never userinfo/password); env changes force `--build` (inline of
NEXT_PUBLIC/VITE vars). Before up: generated-file `docker compose config` validation, safety
warnings (docker.sock/host-device/absolute binds), orphan pre-clean
(exited/dead containers + zero-attached networks of this project only).

When the worktree is removed (`worktree.removed`), `teardown.sh` kills the
stack by compose project label (`com.docker.compose.project.working_dir` ==
the removed worktree path) — works after git removed the checkout, no compose
files needed — and GCs the project's own images (`<project>-*`). Volumes only
with `WT_PURGE=1`; external volumes/networks are NEVER touched.

## Worktree orchestrator (app-repo-owned compose)

Some app repos ship their own orchestrator compose
(`docker-compose.orchestrator.yml` + a `compose.worktree.orchestrator.yml`
overlay). Those overlays historically use GLOBAL FIXED names
(project/container/networks/volumes `*-wor-orchestrator*`), so a SECOND
worktree collided on the same names and silently never got an orchestrator
(sessions needing a browser never provisioned). `setup.sh` now generates a
tag-scoped override `compose.worktree.orchestrator.<tag>.yml` (gitignored) and
ups it with project `<project>-orchestrator` **inside the worktree dir**:

- container/hostname `<project>-orchestrator`; networks
  `<project>_orchestrator_{vm,browser}_net` + `<project>_internal_net`
  (external: the app stack owns it); volumes
  `<project>_orchestrator_{iso_cache,conf}`.
- env rewired to THIS worktree: `HUB_URL`/`REDIS_HOST` -> `<project>-hub` /
  `<project>-redis`, `DOCKER_VM_NETWORK`/`DOCKER_BROWSER_NETWORK` ->
  `<project>_orchestrator_*_net`, `DOCKER_NETWORK`/`DOCKER_EGRESS_NETWORK` ->
  `<project>_internal_net` / `<project>_scraping_net`,
  `BACKEND_WS_URL`/`ORCHESTRATOR_CONNECT_TOKEN` from the worktree's `.env`.
- validated with `docker compose config` before `up`; WARNs (never blocks) on
  failure; prints the command under `WT_DRY_RUN=1`. Skip entirely with
  `WT_NO_ORCHESTRATOR=1`.

Teardown already catches the orchestrator: it resolves containers by the
`working_dir` label, and the orchestrator is up'd from inside the worktree
dir.

Install: `herdr plugin install rapha4lx/herdr-worktree-stack`
Actions: `wt-stack.up` / `wt-stack.down` / `wt-stack.info`.