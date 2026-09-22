#!/usr/bin/env bash
# worktree-stack seed — seed dev data (postgres/redis/minio) from origin stack.
#
# Called automatically by setup.sh on mount when WT_SEED!=0 and data is empty,
# or manually via action wt-stack.seed (--force).
#
# Seeding decision is per-volume marker-based (.wt-seed-done), race-proof and
# independent of bootstrap table migrations or initial cache writes.
#
# Arguments:
#   --cwd <dir>        Worktree checkout directory (required)
#   --project <name>   Docker compose project name for worktree (required)
#   --main <path>      Main checkout directory (origin stack) (required)
#   --force            Force re-seed even if destination has data (optional)
#
# Environment variables:
#   WT_SEED            0 to disable (respected unless --force given)
#   WT_SEED_TARGETS    Whitespace list of services to seed (default: "postgres redis minio")
#   WT_SEED_TIMEOUT    Per-service timeout in seconds (default: 300)
#   WT_DRY_RUN         1 to print actions without running them

# shellcheck disable=SC2015,SC2329
LOG_FILE="${LOG_FILE:-/tmp/wt-stack.log}"
wt_note()  { printf 'wt-stack: %s\n' "$*"; [ -n "$LOG_FILE" ] && printf '%s [info] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
wt_step()  { local n=$1 t=$2; shift 2; printf '  ▪ %s/%s %s\n' "$n" "$t" "$*"; [ -n "$LOG_FILE" ] && printf '%s [step] %s/%s %s\n' "$(date '+%F %T')" "$n" "$t" "$*" >> "$LOG_FILE"; }
wt_ok()    { printf '      → %s\n' "$*"; [ -n "$LOG_FILE" ] && printf '%s [ok] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
wt_fail()  { printf '      → FAIL: %s\n' "$*"; [ -n "$LOG_FILE" ] && printf '%s [fail] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
wt_trace() { [ -n "$LOG_FILE" ] && printf '%s [trace] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
wt_run()   {
  local label="$1"; shift
  wt_trace "[run] $label: $*"
  "$@" >> "$LOG_FILE" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] && wt_trace "[run-ok] $label" || wt_trace "[run-fail rc=$rc] $label"
  return "$rc"
}

# --- argument parsing ---
CWD_DIR=""
PROJECT=""
MAIN_PATH=""
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD_DIR="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --main) MAIN_PATH="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "wt-stack seed: unknown argument $1" >&2; exit 1 ;;
  esac
done

if [ -z "$CWD_DIR" ] || [ -z "$PROJECT" ] || [ -z "$MAIN_PATH" ]; then
  echo "wt-stack seed: missing required arguments (--cwd, --project, --main)" >&2
  exit 1
fi

CWD_DIR="$(cd "$CWD_DIR" 2>/dev/null && pwd || echo "$CWD_DIR")"
MAIN_PATH="$(cd "$MAIN_PATH" 2>/dev/null && pwd || echo "$MAIN_PATH")"

# Configure LOG_FILE based on project tag if not customized
tag="$(printf '%s\n' "$PROJECT" | awk -F'-' '{print $NF}')"
[ -n "$tag" ] && LOG_FILE="/tmp/wt-stack-$tag.log"

DRY="${WT_DRY_RUN:-0}"
WT_SEED="${WT_SEED:-1}"
TIMEOUT_SEC="${WT_SEED_TIMEOUT:-300}"

# Respect WT_SEED=0 unless --force is given
if [ "$FORCE" -eq 0 ] && [ "$WT_SEED" = "0" ]; then
  wt_note "seed disabled (WT_SEED=0)"
  exit 0
fi

# Whitelist validation for WT_SEED_TARGETS
RAW_TARGETS="${WT_SEED_TARGETS:-postgres redis minio}"
VALID_TARGETS=()
HAS_PARSE_ERROR=0
for t in $RAW_TARGETS; do
  case "$t" in
    postgres|redis|minio)
      VALID_TARGETS+=("$t")
      ;;
    *)
      wt_fail "invalid seed target '$t' in WT_SEED_TARGETS (allowed: postgres redis minio)"
      HAS_PARSE_ERROR=1
      ;;
  esac
done

if [ "$HAS_PARSE_ERROR" -eq 1 ] && [ ${#VALID_TARGETS[@]} -eq 0 ]; then
  wt_note "no valid seed targets after validation failure; skipping seed"
  exit 0
fi

# Check if worktree compose file exists
WT_COMPOSE="$CWD_DIR/compose.worktree.yml"
if [ ! -f "$WT_COMPOSE" ]; then
  wt_note "no compose.worktree.yml found at $CWD_DIR (skip seed)"
  exit 0
fi

# Discover services declared in the worktree compose
WT_SERVICES="$(docker compose -f "$WT_COMPOSE" config --services 2>/dev/null || true)"
if [ -z "$WT_SERVICES" ]; then
  wt_note "unable to query services from $WT_COMPOSE or no services declared (skip seed)"
  exit 0
fi

# Check which target services are declared in the worktree compose
# Notice gen-compose.py keys services as <project>-<svc> or <svc>
find_wt_service() {
  local svc="$1"
  local matched=""
  for s in $WT_SERVICES; do
    if [ "$s" = "$PROJECT-$svc" ] || [ "$s" = "$svc" ]; then
      matched="$s"
      break
    fi
  done
  printf '%s' "$matched"
}

# Source container discovery by label working_dir and service
find_src_container() {
  local svc="$1"
  docker ps -q \
    --filter "label=com.docker.compose.project.working_dir=$MAIN_PATH" \
    --filter "label=com.docker.compose.service=$svc" 2>/dev/null | head -n 1
}

# --- Service: Postgres ---
seed_postgres() {
  local src_cid="$1"
  local dst_name="$2"

  wt_note "seeding postgres: source=$src_cid -> dest=$dst_name"

  # Discover credentials from source container
  local src_user src_db dst_user dst_db
  src_user="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src_cid" 2>/dev/null | awk -F= '$1=="POSTGRES_USER"{print $2; exit}' || true)"
  src_db="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src_cid" 2>/dev/null | awk -F= '$1=="POSTGRES_DB"{print $2; exit}' || true)"

  src_user="${src_user:-postgres}"
  src_db="${src_db:-${src_user}}"

  if [ "$DRY" = "1" ]; then
    dst_user="${dst_user:-$src_user}"
    dst_db="${dst_db:-$src_db}"
    wt_note "WT_DRY_RUN=1 — would check marker \$PGDATA/.wt-seed-done on $dst_name"
    wt_note "WT_DRY_RUN=1 — would dump $src_cid (db=$src_db, user=$src_user), restore into $dst_name (db=$dst_db, user=$dst_user), and touch \$PGDATA/.wt-seed-done"
    return 0
  fi

  # In live run, inspect destination container
  dst_user="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dst_name" 2>/dev/null | awk -F= '$1=="POSTGRES_USER"{print $2; exit}' || true)"
  dst_db="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dst_name" 2>/dev/null | awk -F= '$1=="POSTGRES_DB"{print $2; exit}' || true)"
  dst_user="${dst_user:-$src_user}"
  dst_db="${dst_db:-$src_db}"

  # Readiness probe destination (poll 30s)
  local ready=0
  for _ in $(seq 1 30); do
    if docker exec "$dst_name" pg_isready -h localhost -U "$dst_user" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    wt_fail "destination postgres ($dst_name) not ready after 30s"
    return 1
  fi

  # Marker-based empty check (unless force)
  # Fresh volume = no .wt-seed-done. Present = already seeded.
  local pgdata
  pgdata="$(docker exec "$dst_name" printenv PGDATA 2>/dev/null || true)"
  pgdata="${pgdata:-/var/lib/postgresql/data}"

  if [ "$FORCE" -eq 0 ]; then
    if docker exec "$dst_name" sh -c "test -f '$pgdata/.wt-seed-done'" >/dev/null 2>&1; then
      wt_note "postgres seed skipped (já semeado, marker $pgdata/.wt-seed-done presente)"
      return 0
    fi
  fi

  # Ensure destination database exists
  docker exec "$dst_name" psql -U "$dst_user" -tc "SELECT 1 FROM pg_database WHERE datname = '$dst_db'" 2>/dev/null | grep -q 1 || \
    docker exec "$dst_name" psql -U "$dst_user" -c "CREATE DATABASE \"$dst_db\";" >> "$LOG_FILE" 2>&1 || true

  # Dump piped to restore (host pipes stdin/stdout; secrets remain in containers)
  # Run under per-service timeout
  # shellcheck disable=SC2016
  timeout "$TIMEOUT_SEC" bash -c \
    'docker exec "$1" pg_dump -Fc -U "$2" -d "$3" | docker exec -i "$4" pg_restore -U "$5" -d "$6" --clean --if-exists --no-owner --role="$5"' \
    _ "$src_cid" "$src_user" "$src_db" "$dst_name" "$dst_user" "$dst_db" >> "$LOG_FILE" 2>&1

  local rc=$?
  # pg_restore returns 0 on success, or 1 on non-fatal warnings (e.g. relation already exists, role not found)
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    docker exec "$dst_name" sh -c "touch '$pgdata/.wt-seed-done'" >> "$LOG_FILE" 2>&1 || true
    wt_ok "postgres seeded successfully (db=$dst_db)"
    return 0
  else
    wt_fail "postgres seed failed with exit code $rc"
    return "$rc"
  fi
}

# --- Service: Redis ---
seed_redis() {
  local src_cid="$1"
  local dst_name="$2"

  wt_note "seeding redis: source=$src_cid -> dest=$dst_name"

  if [ "$DRY" = "1" ]; then
    wt_note "WT_DRY_RUN=1 — would check marker /data/.wt-seed-done on destination volume"
    wt_note "WT_DRY_RUN=1 — would BGSAVE on $src_cid, stop $dst_name, copy dump.rdb to destination volume, start $dst_name, and touch marker /data/.wt-seed-done"
    return 0
  fi

  # Verify destination has a volume declared
  local dst_vol dst_mount
  dst_vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}' "$dst_name" 2>/dev/null || true)"
  dst_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Destination}}{{end}}{{end}}' "$dst_name" 2>/dev/null || true)"
  dst_mount="${dst_mount:-/data}"

  if [ -z "$dst_vol" ]; then
    wt_note "destination redis ($dst_name) has no volume declared (skip seed)"
    return 0
  fi

  # Marker-based empty check (unless force)
  if [ "$FORCE" -eq 0 ]; then
    if docker exec "$dst_name" sh -c "test -f '$dst_mount/.wt-seed-done'" >/dev/null 2>&1; then
      wt_note "redis seed skipped (já semeado, marker $dst_mount/.wt-seed-done presente)"
      return 0
    fi
  fi

  # Extract password if present
  local src_pass dst_pass
  src_pass="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src_cid" 2>/dev/null | awk -F= '$1=="REDIS_PASSWORD"{print $2; exit}' || true)"
  dst_pass="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dst_name" 2>/dev/null | awk -F= '$1=="REDIS_PASSWORD"{print $2; exit}' || true)"

  local src_cli=(docker exec "$src_cid" redis-cli)
  [ -n "$src_pass" ] && src_cli+=(-a "$src_pass")
  local dst_cli=(docker exec "$dst_name" redis-cli)
  [ -n "$dst_pass" ] && dst_cli+=(-a "$dst_pass")

  # Readiness probe destination (poll 30s)
  local ready=0
  for _ in $(seq 1 30); do
    if "${dst_cli[@]}" ping 2>/dev/null | grep -q "PONG"; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    wt_fail "destination redis ($dst_name) not ready after 30s"
    return 1
  fi

  # BGSAVE on source and poll LASTSAVE until changed
  local baseline_save
  baseline_save="$("${src_cli[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || true)"
  "${src_cli[@]}" BGSAVE >> "$LOG_FILE" 2>&1 || true

  local save_ok=0
  for _ in $(seq 1 30); do
    local cur_save
    cur_save="$("${src_cli[@]}" LASTSAVE 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$cur_save" ] && [ -n "$baseline_save" ] && [ "$cur_save" -gt "$baseline_save" ] 2>/dev/null; then
      save_ok=1
      break
    fi
    sleep 1
  done

  if [ "$save_ok" -ne 1 ]; then
    wt_note "redis BGSAVE did not update LASTSAVE within 30s; proceeding with current dump.rdb"
  fi

  # Read source dump.rdb directly from container
  # Redis destination MUST be stopped before replacing dump.rdb
  wt_note "stopping destination $dst_name for RDB restore"
  docker stop "$dst_name" >> "$LOG_FILE" 2>&1 || true

  # Stream dump.rdb from source container into destination volume using alpine helper
  local copy_rc=0
  docker exec "$src_cid" cat /data/dump.rdb 2>/dev/null | \
    docker run --rm -i -v "$dst_vol:/data" alpine:3 sh -c 'cat > /data/dump.rdb && touch /data/.wt-seed-done' >> "$LOG_FILE" 2>&1 || copy_rc=$?

  wt_note "restarting destination $dst_name"
  docker start "$dst_name" >> "$LOG_FILE" 2>&1 || true

  if [ "$copy_rc" -eq 0 ]; then
    wt_ok "redis seeded successfully (RDB copied to volume $dst_vol)"
    return 0
  else
    wt_fail "redis seed copy failed with exit code $copy_rc"
    return "$copy_rc"
  fi
}

# --- Service: MinIO ---
seed_minio() {
  local src_cid="$1"
  local dst_name="$2"

  wt_note "seeding minio: source=$src_cid -> dest=$dst_name"

  # Find minio credentials and endpoints from source
  local src_user src_pass dst_user dst_pass
  src_user="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src_cid" 2>/dev/null | awk -F= '$1=="MINIO_ROOT_USER"{print $2; exit}' || true)"
  src_pass="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$src_cid" 2>/dev/null | awk -F= '$1=="MINIO_ROOT_PASSWORD"{print $2; exit}' || true)"
  src_user="${src_user:-minioadmin}"
  src_pass="${src_pass:-minioadmin}"

  # Prefer local minio/mc image if present, otherwise quay.io/minio/mc:latest
  local mc_image="minio/mc:latest"
  if ! docker image inspect "$mc_image" >/dev/null 2>&1; then
    mc_image="quay.io/minio/mc:latest"
  fi

  if [ "$DRY" = "1" ]; then
    wt_note "WT_DRY_RUN=1 — would check marker /data/.wt-seed-done on $dst_name"
    wt_note "WT_DRY_RUN=1 — would mirror minio from $src_cid to $dst_name via $mc_image and touch /data/.wt-seed-done"
    return 0
  fi

  # Destination data dir for marker check
  local dst_datadir
  dst_datadir="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Destination}}{{end}}{{end}}' "$dst_name" 2>/dev/null | head -n 1 || true)"
  dst_datadir="${dst_datadir:-/data}"

  # Marker-based empty check (unless force)
  if [ "$FORCE" -eq 0 ]; then
    if docker exec "$dst_name" sh -c "test -f '$dst_datadir/.wt-seed-done'" >/dev/null 2>&1; then
      wt_note "minio seed skipped (já semeado, marker $dst_datadir/.wt-seed-done presente)"
      return 0
    fi
  fi

  dst_user="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dst_name" 2>/dev/null | awk -F= '$1=="MINIO_ROOT_USER"{print $2; exit}' || true)"
  dst_pass="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dst_name" 2>/dev/null | awk -F= '$1=="MINIO_ROOT_PASSWORD"{print $2; exit}' || true)"
  dst_user="${dst_user:-$src_user}"
  dst_pass="${dst_pass:-$src_pass}"

  # Networks to join helper container
  local src_net dst_net
  src_net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$src_cid" 2>/dev/null | head -n 1 || true)"
  dst_net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$dst_name" 2>/dev/null | head -n 1 || true)"

  if [ -z "$src_net" ] || [ -z "$dst_net" ]; then
    wt_fail "unable to determine network for minio containers"
    return 1
  fi

  # Source IP/address and destination IP/address
  local src_ip dst_ip
  src_ip="$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{println}}{{end}}" "$src_cid" 2>/dev/null | grep -v '^$' | head -n 1 || true)"
  dst_ip="$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{println}}{{end}}" "$dst_name" 2>/dev/null | grep -v '^$' | head -n 1 || true)"

  if [ -z "$src_ip" ] || [ -z "$dst_ip" ]; then
    wt_fail "unable to determine IP address for minio containers"
    return 1
  fi

  local src_endpoint="http://${src_ip}:9000"
  local dst_endpoint="http://${dst_ip}:9000"

  # Readiness check on destination minio (up to 30s) using --entrypoint /bin/sh
  local ready=0
  for _ in $(seq 1 30); do
    if docker run --rm --network "$dst_net" --entrypoint /bin/sh "$mc_image" -c \
       "mc alias set dst '$dst_endpoint' '$dst_user' '$dst_pass' --no-color >/dev/null 2>&1 && mc admin info dst --no-color >/dev/null 2>&1"; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    wt_fail "destination minio ($dst_name) not ready after 30s"
    return 1
  fi

  # Transient mirror container across both networks
  local helper_id
  helper_id="$(docker create --rm --network "$src_net" --entrypoint /bin/sh "$mc_image" -c "
    mc alias set src '$src_endpoint' '$src_user' '$src_pass' --no-color >/dev/null 2>&1 && \
    mc alias set dst '$dst_endpoint' '$dst_user' '$dst_pass' --no-color >/dev/null 2>&1 && \
    mc mirror --overwrite --max-workers 4 src/ dst/
  ")"

  if [ -z "$helper_id" ]; then
    wt_fail "could not create minio helper container"
    return 1
  fi

  if [ "$src_net" != "$dst_net" ]; then
    docker network connect "$dst_net" "$helper_id" >> "$LOG_FILE" 2>&1 || true
  fi

  # Run mirror under timeout
  local rc=0
  timeout "$TIMEOUT_SEC" docker start -a "$helper_id" >> "$LOG_FILE" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    docker exec "$dst_name" sh -c "touch '$dst_datadir/.wt-seed-done'" >> "$LOG_FILE" 2>&1 || true
    wt_ok "minio seeded successfully (buckets mirrored)"
    return 0
  else
    wt_fail "minio seed mirror failed with exit code $rc"
    return "$rc"
  fi
}

# --- Main execution loop ---
for svc in "${VALID_TARGETS[@]}"; do
  # Check if worktree compose declared this service
  wt_svc="$(find_wt_service "$svc")"
  if [ -z "$wt_svc" ]; then
    wt_trace "service $svc not declared in worktree compose; skipping"
    continue
  fi

  # Check source container
  src_cid="$(find_src_container "$svc")"
  if [ -z "$src_cid" ]; then
    wt_fail "source container for service '$svc' not running on $MAIN_PATH (skip)"
    continue
  fi

  dst_name="$PROJECT-$svc"

  # Non-fatal wrapper for each service
  set +e
  case "$svc" in
    postgres)
      seed_postgres "$src_cid" "$dst_name"
      ;;
    redis)
      seed_redis "$src_cid" "$dst_name"
      ;;
    minio)
      seed_minio "$src_cid" "$dst_name"
      ;;
  esac
  set -e
done

wt_note "seed completed"
exit 0
