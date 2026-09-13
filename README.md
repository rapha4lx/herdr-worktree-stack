# herdr wt-stack

Kill a git-worktree's docker stack when herdr removes the worktree.

Removing a worktree (`herdr worktree remove` / `git worktree remove`) only
deletes the git checkout. Docker containers, volumes and networks built from
that worktree keep running forever — orphaned. `wt-stack` closes the loop:
when herdr emits `worktree.removed`, the plugin tears the worktree's compose
stack down.

## Why label-based teardown?

herdr fires `worktree.removed` **after** git removed the checkout, so
`compose.yml`, overrides and `.env` no longer exist. You cannot run
`docker compose -f ... down` anymore. Compose leaves project labels
(`com.docker.compose.project=<project>`) on containers, volumes and networks,
so `wt-stack` removes by label. No compose files needed.

## Install

Requires herdr ≥ 0.7.0 (Linux).

```bash
herdr plugin install rapha4lx/herdr-wt-stack
```

Or link a local checkout for development:

```bash
herdr plugin link /path/to/herdr-wt-stack
```

## What it does

- **Automatic**: on herdr event `worktree.removed`, removes the worktree's
  containers and network. **Volumes are kept** (your data is safe); set
  `WT_PURGE=1` to also remove volumes.
- **Manual action** `wt-stack.down` — tear down the current workspace's stack
  right now (workspace context).
- **Manual action** `wt-stack.info` — list containers/volumes/networks for the
  current workspace's stack.

```bash
herdr plugin action invoke wt-stack.down
herdr plugin action invoke wt-stack.info
```

## Project matching

The worktree directory name determines the docker project candidate(s):

1. **Default compose naming** — project = worktree dir basename
   (worktree dir `myapp` → project `myapp`).
2. **`<repo>-<3chars>` convention** — when the worktree dir looks like
   `<3chars>-<repo>` (first hyphen-separated segment is exactly 3 chars), the
   project `name:` override is also matched:
   worktree dir `a3f-bayhub` → project `bayhub-a3f`.

Both candidates are checked; any that exist are torn down; none = safe no-op.

## Safety

- Containers + network are always removed when the worktree is removed.
- Volumes (data) are kept by default. `WT_PURGE=1` removes them too.
- The script is idempotent and only touches resources carrying the matching
  `com.docker.compose.project` label.
- The branch is never touched — herdr `worktree.remove` never deletes branches.

## Development

```bash
herdr plugin action list --plugin wt-stack   # registered actions
herdr plugin log list                        # command logs
```

Manifest: [`herdr-plugin.toml`](./herdr-plugin.toml).

## License

Apache-2.0