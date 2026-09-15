# herdr worktree-stack

Auto-setup + teardown of git-worktree docker stacks.

When a worktree is created (`worktree.created`), `setup.sh` mounts an ISOLATED
compose stack for it: project/containers named `<repo>-<tag>` (one tag per
worktree, trailing hex of the dir name), networks from the base compose joined
as `external: true` (shared incl. traefik_proxy), and Traefik label isolation —
router names suffixed `-<tag>` with a worktree host `hostname-<tag>.<domain>`
(needs wildcard DNS), so worktree and main stacks never collide. `.env` is
copied from the main checkout when missing; APP_HOST gets `<tag>-` prefixed;
a whitelist env-rewrite adapts CORS/URL/domain vars to the worktree host
(identity-derived, nothing hardcoded); env changes force `--build` (inline of
NEXT_PUBLIC/VITE vars). Published ports warn + `WT_PORT_SHIFT=<n>` remaps.

When the worktree is removed (`worktree.removed`), `teardown.sh` kills the
stack by compose project label (`com.docker.compose.project.working_dir` ==
the removed worktree path) — works after git removed the checkout, no compose
files needed.

Install: `herdr plugin install rapha4lx/herdr-worktree-stack`
Actions: `wt-stack.up` / `wt-stack.down` / `wt-stack.info`.