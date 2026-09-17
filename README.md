# herdr worktree-stack

Auto-setup + teardown of git-worktree docker stacks.

When a worktree is created (`worktree.created`), `setup.sh` mounts an ISOLATED
compose stack for it: a complete standalone `compose.worktree.yml` is generated
(v0.5) from `docker compose config --no-interpolate` via `gen-compose.py`
(PyYAML required). Every production-contamination vector is closed:

- **containers/networks**: project `<repo>-<tag>` (one tag per worktree,
  trailing hex of the dir name); owned networks re-scoped
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
env values referencing main
container names are rewritten URL-safe (hostname after last `@` only — never
userinfo/password); env changes force `--build` (inline of NEXT_PUBLIC/VITE
vars). Before up: generated-file `docker compose config` validation, safety
warnings (docker.sock/host-device/absolute binds), orphan pre-clean
(exited/dead containers + zero-attached networks of this project only).

When the worktree is removed (`worktree.removed`), `teardown.sh` kills the
stack by compose project label (`com.docker.compose.project.working_dir` ==
the removed worktree path) — works after git removed the checkout, no compose
files needed — and GCs the project's own images (`<project>-*`). Volumes only
with `WT_PURGE=1`; external volumes/networks are NEVER touched.

Install: `herdr plugin install rapha4lx/herdr-worktree-stack`
Actions: `wt-stack.up` / `wt-stack.down` / `wt-stack.info`.