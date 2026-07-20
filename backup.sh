#!/usr/bin/env bash
set -euo pipefail

# SCRIPT DEVELOPED BY FRANCO'S ORGANIC INTELLIGENCE WITH HELP FROM DUCK.AI ARTIFICIAL INTELLIGENCE
#
# This script was developed to backup data from a Minecraft server world running in Docker
# The proposal is that this script follows the logic of a container, it works based on the location where it is,
# which needs to be the same directory as the docker-compose.yaml file.
# The script also expects that the folder containing the data is mapped in the docker-compose.yaml
# The backup destination is a directory that, if it doesn't exist, is created and is called /autobackup,
# it stays in the same directory as the script.
# For the script to work automatically, it depends on a cronjob,
# just place the script in the correct location and point the path in the crontab.

# ====== CONFIGURATIONS ======
RCON_STOP_TIMEOUT=30      # Timeout for graceful server shutdown (seconds)
MAX_BACKUP_COPIES=10      # Keep a maximum of 10 backup copies (keep the most recent)
MIN_DISK_SPACE_MB=1000    # Minimum disk space before backup (MB)
LOG_SIZE_LIMIT=10485760   # 10MB - rotate log when reaching this size
CONTAINER_CHECK_RETRIES=3 # Number of attempts to start container

# ====== PATHS ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCK_FILE="$SCRIPT_DIR/.backup.lock"
LOG_FILE="$SCRIPT_DIR/autobkp.log"
LAST_BACKUP_MARKER="$SCRIPT_DIR/.backup-last-time"

# ====== SETUP ======
# Function for cleanup in case of error
cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Rotates log if it gets too large
rotate_log_if_needed() {
  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( log_size > LOG_SIZE_LIMIT )); then
      mv "$LOG_FILE" "${LOG_FILE}.$(date +%s)"
      log "Log rotated (previous size: ${log_size} bytes)"
    fi
  fi
}

log() {
  local msg="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $msg" | tee -a "$LOG_FILE"
}

# ====== DOCKER COMPOSE FILE ======
COMPOSE_FILE=""
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
else
  log "ERROR: docker-compose.yml or docker-compose.yaml not found in: $SCRIPT_DIR"
  exit 1
fi

# Validates docker-compose config
validate_compose_config() {
  if command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose config >/dev/null 2>&1; then
      log "ERROR: Invalid docker-compose configuration"
      exit 1
    fi
  elif command -v docker >/dev/null 2>&1; then
    if ! docker compose config >/dev/null 2>&1; then
      log "ERROR: Invalid docker compose configuration"
      exit 1
    fi
  else
    log "ERROR: docker or docker-compose not found"
    exit 1
  fi
}

# ====== EXTRACT DATA DIR FROM DOCKER-COMPOSE ======
# Extracts the DATA_DIR path from docker-compose.yaml
# Searches for volumes mapped to /data in the container
get_data_dir_from_compose() {
  local data_dir=""
  
  # Tries to find volumes that map to /data or /minecraft/data in the container
  # Syntax: - ./path:/data or - /absolute/path:/data
  data_dir=$(
    grep -E '^\s*-\s+.*:(/data|/minecraft/data)' "$COMPOSE_FILE" \
    | head -n 1 \
    | sed -E 's/^\s*-\s+([^:]+):.*/\1/' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  )
  
  if [[ -z "$data_dir" ]]; then
    log "ERROR: Volume for /data not found in: $COMPOSE_FILE"
    log "Make sure your docker-compose.yaml contains a volume mapped to /data"
    exit 1
  fi
  
  # If the path is relative (starts with .), resolve it relative to SCRIPT_DIR
  if [[ "$data_dir" == ./* ]] || [[ "$data_dir" == .\\* ]]; then
    data_dir="${SCRIPT_DIR}/${data_dir#./}"
  fi
  
  echo "$data_dir"
}

# ====== DATA PATHS ======
BKP_ROOT="$SCRIPT_DIR/autobkp"
DATA_DIR="$(get_data_dir_from_compose)"
WORLD_SRC="$DATA_DIR/world"
SERVER_PROPERTIES_FILE="$DATA_DIR/server.properties"

# ====== DOCKER COMPOSE HELPERS ======
compose_up_down() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo docker-compose
  else
    echo docker
  fi
}

compose_up_d() {
  if [[ "$(compose_up_down)" == "docker-compose" ]]; then
    docker-compose up -d
  else
    docker compose up -d
  fi
}

# ====== CONTAINER NAME ======
CONTAINER_NAME="$(
  sed -nE 's/^[[:space:]]*container_name:[[:space:]]*([^#]+).*/\1/p' "$COMPOSE_FILE" \
  | head -n 1 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'']//; s/["'"']$//'
)"

if [[ -z "${CONTAINER_NAME:-}" ]]; then
  log "ERROR: 'container_name:' not found in: $COMPOSE_FILE"
  exit 1
fi

# ====== FILE HELPERS ======
require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    log "ERROR: required file not found: $f"
    exit 1
  fi
}

get_prop() {
  local key="$1"
  local file="$2"
  require_file "$file"

  local v
  v="$(
    grep -v '^[[:space:]]*#' "$file" \
    | grep -F "${key}=" \
    | tail -n 1 \
    | cut -d= -f2- \
    | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  )"
  echo "$v"
}

# ====== RCON CONFIGURATION ======
RCON_PASSWORD="$(get_prop "rcon.password" "$SERVER_PROPERTIES_FILE")"
RCON_PORT="$(get_prop "rcon.port" "$SERVER_PROPERTIES_FILE")"

if [[ -z "${RCON_PASSWORD:-}" ]]; then
  log "ERROR: rcon.password not found or empty in: $SERVER_PROPERTIES_FILE"
  exit 1
fi
if [[ -z "${RCON_PORT:-}" ]]; then
  log "ERROR: rcon.port not found or empty in: $SERVER_PROPERTIES_FILE"
  exit 1
fi

if [[ ! -d "$WORLD_SRC" ]]; then
  log "ERROR: world directory does not exist: $WORLD_SRC"
  exit 1
fi

# ====== LOCK MANAGEMENT ======
check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE")"
    if kill -0 "$lock_pid" 2>/dev/null; then
      log "ERROR: Backup is already running (PID: $lock_pid)"
      exit 1
    else
      rm -f "$LOCK_FILE"
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

# ====== CONTAINER CHECKS ======
check_container() {
  if ! docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR: Container not found or not running: $CONTAINER_NAME"
    return 1
  fi
  return 0
}

# Waits for container to start successfully (with retries)
wait_container_ready() {
  local retries=$1
  local attempt=0

  while (( attempt < retries )); do
    sleep 2
    if check_container; then
      log "Container started successfully"
      return 0
    fi
    ((attempt++))
    log "Attempt $((attempt)) of $retries waiting for container to start..."
  done

  log "ERROR: Container failed to start after $retries attempts"
  return 1
}

# ====== RCON HELPERS ======
rcon() {
  local args=("$@")
  docker exec -i "$CONTAINER_NAME" rcon-cli \
    --host 127.0.0.1 \
    --port "$RCON_PORT" \
    --password "$RCON_PASSWORD" \
    "${args[@]}"
}

# Tests RCON connection before starting
test_rcon() {
  set +e
  rcon list >/dev/null 2>&1
  local rc=$?
  set -e
  return $rc
}

players_online_list() {
  local out
  set +e
  out="$(rcon list 2>/dev/null)"
  set -e

  # Tries to extract player list from RCON response
  # Typical format: "There are X of Y players online: player1, player2, ..."
  if [[ "$out" =~ :\ (.+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  echo ""
}

players_online_count() {
  local out
  set +e
  out="$(rcon list 2>/dev/null)"
  set -e

  if [[ "$out" =~ There\ are\ ([0-9]+)\ of ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$out" =~ ([0-9]+)[[:space:]]*of[[:space:]]*[0-9]+ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  echo 0
}

broadcast_if_players() {
  local msg="$1"
  local n
  n="$(players_online_count || true)"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
    rcon say "$msg" >/dev/null 2>&1 || true
  fi
}

# ====== TIME HELPERS ======
timestamp_hour() {
  date '+%Y%m%d-%H'
}

# ====== ACTIVITY CHECK ======
has_activity_since_last_backup() {
  if [[ ! -f "$LAST_BACKUP_MARKER" ]]; then
    log "First backup or marker not found, performing backup"
    return 0
  fi

  local playerdata_dir recent_files
  playerdata_dir="${WORLD_SRC}/playerdata"

  # Prefer checking playerdata: this usually only changes when a real player joins
  if [[ -d "$playerdata_dir" ]]; then
    recent_files=$(find "$playerdata_dir" -type f -newer "$LAST_BACKUP_MARKER" -not -name "*.tmp" 2>/dev/null | wc -l)
    if (( recent_files > 0 )); then
      log "Player activity detected: $recent_files files modified in playerdata"
      return 0
    else
      log "No changes in playerdata since last backup"
      return 1
    fi
  fi

  # Fallback: if playerdata doesn't exist, use the original world scan
  recent_files=$(find "$WORLD_SRC" \
    -type f \
    -newer "$LAST_BACKUP_MARKER" \
    -not -name "session.lock" \
    -not -name ".DS_Store" \
    -not -name "*.tmp" \
    2>/dev/null | wc -l)

  if (( recent_files > 0 )); then
    log "Activity detected (fallback world): $recent_files files modified"
    return 0
  else
    log "No activity detected since last backup"
    return 1
  fi
}

# ====== DISK SPACE CHECK ======
check_disk_space() {
  local available_mb
  available_mb="$(df "$BKP_ROOT" 2>/dev/null | tail -n 1 | awk '{print $4}')"
  
  if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
    log "WARN: Could not check disk space"
    return 0
  fi

  if (( available_mb < MIN_DISK_SPACE_MB )); then
    log "ERROR: Insufficient disk space. Available: ${available_mb}MB, Required: ${MIN_DISK_SPACE_MB}MB"
    exit 1
  fi
  
  log "Disk space OK: ${available_mb}MB available"
}

# ====== BACKUP CLEANUP ======
cleanup_old_backups() {
  log "Checking backup copy limit (maximum: ${MAX_BACKUP_COPIES})..."
  
  local backup_count
  backup_count=$(find "$BKP_ROOT" -maxdepth 1 -type d -name "*world*" 2>/dev/null | wc -l)
  
  if (( backup_count <= MAX_BACKUP_COPIES )); then
    log "Total backups: $backup_count (within limit)"
    return 0
  fi
  
  local to_remove=$(( backup_count - MAX_BACKUP_COPIES ))
  log "Total backups: $backup_count (exceeded limit by $to_remove). Removing oldest..."
  
  # Finds and removes the oldest backups
  find "$BKP_ROOT" -maxdepth 1 -type d -name "*world*" -printf '%T+ %p\n' 2>/dev/null \
    | sort \
    | head -n "$to_remove" \
    | awk '{print $2}' \
    | while read -r old_backup; do
      log "Removing old backup: $old_backup"
      rm -rf "$old_backup"
    done
}

# ====== BACKUP EXECUTION ======
backup_world() {
  local ts dest
  ts="$(timestamp_hour)"
  dest="${BKP_ROOT}/${CONTAINER_NAME}-world-${ts}"

  mkdir -p "$BKP_ROOT"
  rm -rf "$dest"
  mkdir -p "$dest"

  rsync -a --delete-delay "${WORLD_SRC}/" "${dest}/"
  log "Backup completed: ${dest}"
  
  # Calculates backup size
  local backup_size
  backup_size="$(du -sh "$dest" 2>/dev/null | awk '{print $1}' || echo 'unknown')"
  log "Backup size: $backup_size"
  
  touch "$LAST_BACKUP_MARKER"
}

# ====== SERVER SHUTDOWN SEQUENCE ======
countdown_30s() {
  local s
  for s in {30..1}; do
    broadcast_if_players "WARNING: Server restarting in ${s}s"
    sleep 1
  done
}

kick_everyone() {
  rcon kickall >/dev/null 2>&1 || true
}

# Waits for server to stop gracefully (polling)
# Uses 'list' instead of 'ping' as it's more reliable
wait_server_stop() {
  local elapsed=0
  local max_wait=$1
  
  while (( elapsed < max_wait )); do
    if ! rcon list >/dev/null 2>&1; then
      log "Server stopped after ${elapsed}s"
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  
  log "WARN: Server still responding after ${max_wait}s, forcing stop with docker stop"
  return 1
}

# ====== UI HELPERS ======
spinner_run() {
  local pid="$1"
  local msg="$2"
  local i=0
  local chars=$'|/-\\'

  while kill -0 "$pid" >/dev/null 2>&1; do
    local c="${chars:$((i%4)):1}"
    printf "\r%s %s" "$msg" "$c"
    i=$((i+1))
    sleep 0.1
  done
}

run_step() {
  local msg="$1"; shift

  local log_file
  log_file="$(mktemp)"
  local cmd_pid
  local spin_pid
  local rc=0

  set +e
  "$@" >"$log_file" 2>&1 &
  cmd_pid=$!

  spinner_run "$cmd_pid" "$msg" &
  spin_pid=$!

  wait "$cmd_pid"
  rc=$?

  kill "$spin_pid" >/dev/null 2>&1 || true
  wait "$spin_pid" >/dev/null 2>&1 || true

  if [[ $rc -eq 0 ]]; then
    printf "\r✓ %s\n" "$msg"
    rm -f "$log_file"
    set -e
  else
    printf "\r✗ %s\n" "$msg"
    log "---- command output (last 50 lines) ----"
    tail -n 50 "$log_file" >> "$LOG_FILE" || true
    rm -f "$log_file"
    exit "$rc"
  fi
}

# ====== RESTART WITHOUT BACKUP ======
restart_without_backup() {
  log "Restarting server without performing backup"
  echo ""
  echo "No activity detected - skipping backup"
  
  local player_count
  player_count="$(players_online_count || true)"
  
  if [[ "$player_count" =~ ^[0-9]+$ ]] && (( player_count > 0 )); then
    local player_list
    player_list="$(players_online_list || true)"
    log "Players online: $player_count - $player_list"
    
    broadcast_if_players "WARNING: Server restarting in 5 minutes"
    run_step "Notifying players - Restarting in 5 minutes" sleep 240

    broadcast_if_players "WARNING: Server restarting in 1 minute"
    run_step "Notifying players - Restarting in 1 minute" sleep 30

    run_step "Notifying players - Final 30s countdown" countdown_30s
  else
    log "No players online - skipping countdown, starting backup immediately"
  fi

  run_step "Kicking all players" kick_everyone

  run_step "Saving the world" rcon save-all

  run_step "Stopping server gracefully" rcon stop

  if wait_server_stop "$RCON_STOP_TIMEOUT"; then
    log "Server stopped gracefully"
  else
    log "Timeout waiting for server stop, forcing..."
  fi

  run_step "Stopping the Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

  run_step "Starting Container" compose_up_d
  
  if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
    log "Restart without backup completed successfully"
  else
    log "ERROR: Failed to restart container"
    exit 1
  fi
}

# ====== BACKUP WITH RESTART ======
backup_with_restart() {
  echo "Container: ${CONTAINER_NAME}"
  echo "Data: ${DATA_DIR}"
  echo "Backup: ${WORLD_SRC} -> ${BKP_ROOT} (timestamped by date+hour)"

  local player_count
  player_count="$(players_online_count || true)"
  
  if [[ "$player_count" =~ ^[0-9]+$ ]] && (( player_count > 0 )); then
    local player_list
    player_list="$(players_online_list || true)"
    log "Players online: $player_count - $player_list"
    
    broadcast_if_players "WARNING: Server restarting in 5 minutes - Automatic backup"
    run_step "Notifying players - Restarting in 5 minutes" sleep 240

    broadcast_if_players "WARNING: Server restarting in 1 minute - Automatic backup"
    run_step "Notifying players - Restarting in 1 minute" sleep 30

    run_step "Notifying players - Final 30s countdown" countdown_30s
  else
    log "No players online - skipping countdown, starting backup immediately"
  fi

  run_step "Kicking all players" kick_everyone

  run_step "Saving the world" rcon save-all

  run_step "Stopping server gracefully" rcon stop

  if wait_server_stop "$RCON_STOP_TIMEOUT"; then
    log "Server stopped gracefully"
  else
    log "Timeout waiting for server stop, forcing..."
  fi

  run_step "Stopping the Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

  run_step "Copying data from world directory" backup_world

  run_step "Starting Container" compose_up_d

  if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
    cleanup_old_backups
    log "Backup successful, container initialized"
  else
    log "ERROR: Failed to restart container after backup"
    exit 1
  fi
}

# ====== MAIN SCRIPT ======

rotate_log_if_needed

log "=========================================="
log "Starting backup of container: ${CONTAINER_NAME}"
log "Data loaded from: ${DATA_DIR}"
log "=========================================="

validate_compose_config
check_lock
check_container || exit 1

if ! test_rcon; then
  log "ERROR: Failed to connect to RCON at ${CONTAINER_NAME}:${RCON_PORT}"
  exit 1
fi

# Checks if there has been activity since the last backup
if ! has_activity_since_last_backup; then
  restart_without_backup
  exit 0
fi

# If there was activity, proceed with backup
check_disk_space
backup_with_restart

log "=========================================="
log "Script completed successfully"
log "=========================================="
