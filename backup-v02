#!/usr/bin/env bash
set -euo pipefail

# SCRIPT DESENVOLVIDO PELA INTELIGERNCIA ORGANICA DE FRANCO COM AJUDA DA INTELIGENCIA ARTIFICIAL DO DUCK.AI
#
# Esse script foi desenvolvido para fazer backup dos dados de um mundo de um servidor de minecraft rodando em docker
# A proposta é que esse script siga a lógica de um container, ele funciona baseado no local onde ele está, que precisa
# ser o mesmo diretório do arquivo docker-compose.yaml.
# O script também espera que a pasta onde estão os dados esteja também no mesmo local e se chame /data
# O destino do backup é um diretório que se não existe, é criado e se chama /autobackup, fica no mesmo diretório do script.
# Para o script funcionar de forma automática, depende de um cronjob, é so colocar o script no lugar correto e apontar o caminho no crontab.

# Configurações
RCON_STOP_TIMEOUT=30      # Timeout para parada graceful do servidor (segundos)
BACKUP_RETENTION_DAYS=14  # Manter backups dos últimos 14 dias
MIN_DISK_SPACE_MB=1000    # Espaço mínimo em disco antes de fazer backup (MB)

# Roda tudo baseado no local que esse script tá
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCK_FILE="$SCRIPT_DIR/.backup.lock"
LOG_FILE="$SCRIPT_DIR/autobkp.log"
LAST_BACKUP_MARKER="$SCRIPT_DIR/.backup-last-time"

# Função para cleanup em caso de erro
cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

log() {
  local msg="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $msg" | tee -a "$LOG_FILE"
}

COMPOSE_FILE=""
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
else
  echo "Error: docker-compose.yml or docker-compose.yaml not found in: $SCRIPT_DIR"
  exit 1
fi

# Define pra onde vai o backup, baseado também no local do script
BKP_ROOT="$SCRIPT_DIR/autobkp"

# Paths relativos ao local do script
DATA_DIR="$SCRIPT_DIR/data"
WORLD_SRC="$DATA_DIR/world"
SERVER_PROPERTIES_FILE="$DATA_DIR/server.properties"

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

# Verifica qual o nome do container lendo o arquivo .yaml
CONTAINER_NAME="$(
  sed -nE 's/^[[:space:]]*container_name:[[:space:]]*([^#]+).*/\1/p' "$COMPOSE_FILE" \
  | head -n 1 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//; s/["'"'"']$//'
)"

if [[ -z "${CONTAINER_NAME:-}" ]]; then
  echo "Error: could not find a 'container_name:' line in $COMPOSE_FILE"
  exit 1
fi

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "Error: required file not found: $f"
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

# Pega a senha e porta do rcon do ./data/server.properties
RCON_PASSWORD="$(get_prop "rcon.password" "$SERVER_PROPERTIES_FILE")"
RCON_PORT="$(get_prop "rcon.port" "$SERVER_PROPERTIES_FILE")"

if [[ -z "${RCON_PASSWORD:-}" ]]; then
  echo "Error: rcon.password missing/empty in: $SERVER_PROPERTIES_FILE"
  exit 1
fi
if [[ -z "${RCON_PORT:-}" ]]; then
  echo "Error: rcon.port missing/empty in: $SERVER_PROPERTIES_FILE"
  exit 1
fi

if [[ ! -d "$WORLD_SRC" ]]; then
  echo "Error: world dir does not exist: $WORLD_SRC"
  exit 1
fi

# Verificação de lock para evitar backups simultâneos
check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE")"
    if kill -0 "$lock_pid" 2>/dev/null; then
      log "ERROR: Backup já está rodando (PID: $lock_pid)"
      exit 1
    else
      rm -f "$LOCK_FILE"
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

# Verifica se container existe e está rodando
check_container() {
  if ! docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR: Container não encontrado ou não está rodando: $CONTAINER_NAME"
    exit 1
  fi
}

rcon() {
  local args=("$@")
  docker exec -i "$CONTAINER_NAME" rcon-cli \
    --host 127.0.0.1 \
    --port "$RCON_PORT" \
    --password "$RCON_PASSWORD" \
    "${args[@]}"
}

# Testa conexão RCON antes de começar
test_rcon() {
  set +e
  rcon list >/dev/null 2>&1
  local rc=$?
  set -e
  return $rc
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

timestamp_hour() {
  date '+%Y%m%d-%H'
}

# Verifica se houve atividade desde o último backup
has_activity_since_last_backup() {
  # Se é o primeiro backup, sempre faz
  if [[ ! -f "$LAST_BACKUP_MARKER" ]]; then
    log "Primeiro backup ou marcador não encontrado, realizando backup"
    return 0
  fi

  # Procura por arquivos modificados após o marcador do último backup
  # Ignora alguns diretórios que mudam frequentemente
  local recent_files
  recent_files=$(find "$WORLD_SRC" \
    -newer "$LAST_BACKUP_MARKER" \
    -not -path "*/session.lock" \
    -not -path "*/.DS_Store" \
    2>/dev/null | head -n 1)

  if [[ -n "$recent_files" ]]; then
    log "Atividade detectada desde o último backup"
    return 0
  else
    log "Nenhuma atividade detectada desde o último backup - pulando backup"
    return 1
  fi
}

# Verifica espaço em disco
check_disk_space() {
  local available_mb
  available_mb="$(df "$BKP_ROOT" 2>/dev/null | tail -n 1 | awk '{print $4}')"
  
  if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
    log "WARN: Não conseguiu verificar espaço em disco"
    return 0
  fi

  if (( available_mb < MIN_DISK_SPACE_MB )); then
    log "ERROR: Espaço em disco insuficiente. Disponível: ${available_mb}MB, Necessário: ${MIN_DISK_SPACE_MB}MB"
    exit 1
  fi
  
  log "Espaço em disco OK: ${available_mb}MB disponível"
}

# Limpa backups antigos
cleanup_old_backups() {
  log "Limpando backups com mais de ${BACKUP_RETENTION_DAYS} dias..."
  find "$BKP_ROOT" -maxdepth 1 -type d -name "*world*" -mtime "+${BACKUP_RETENTION_DAYS}" | while read -r old_backup; do
    log "Removendo: $old_backup"
    rm -rf "$old_backup"
  done
}

backup_world() {
  local ts dest
  ts="$(timestamp_hour)"
  dest="${BKP_ROOT}/${CONTAINER_NAME}-world-${ts}"

  mkdir -p "$BKP_ROOT"
  rm -rf "$dest"
  mkdir -p "$dest"

  rsync -a --delete-delay "${WORLD_SRC}/" "${dest}/"
  log "Backup concluído: ${dest}"
  
  # Marca quando o backup foi concluído com sucesso
  touch "$LAST_BACKUP_MARKER"
}

countdown_30s() {
  local s
  for s in {30..1}; do
    broadcast_if_players "AVISO: Servidor reiniciando em ${s}s"
    sleep 1
  done
}

kick_everyone() {
  rcon kickall >/dev/null 2>&1 || true
}

# Aguarda servidor parar gracefully (polling)
wait_server_stop() {
  local elapsed=0
  local max_wait=$1
  
  while (( elapsed < max_wait )); do
    if ! rcon ping >/dev/null 2>&1; then
      log "Servidor parou após ${elapsed}s"
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  
  log "WARN: Servidor ainda respondendo após ${max_wait}s, forçando parada com docker stop"
  return 1
}

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
    echo "---- command output (last 50 lines) ----"
    tail -n 50 "$log_file" || true
    rm -f "$log_file"
    exit "$rc"
  fi
}

# ====== INICIO DO SCRIPT ======

log "=========================================="
log "Iniciando backup do container: ${CONTAINER_NAME}"
log "=========================================="

check_lock
check_container

if ! test_rcon; then
  log "ERROR: Falha ao conectar ao RCON"
  exit 1
fi

# Verifica se houve atividade desde o último backup
if ! has_activity_since_last_backup; then
  log "Reiniciando servidor sem fazer backup"
  echo ""
  echo "Nenhuma atividade detectada - pulando backup"
  
  # Ainda assim reinicia o servidor de forma graciosa
  broadcast_if_players "AVISO: Servidor reiniciando em 5 minutos"
  run_step "Avisando players - Reiniciando em 5 minutos" sleep 240

  broadcast_if_players "AVISO: Servidor reiniciando em 1 minuto"
  run_step "Avisando players - Reiniciando em 1 minuto" sleep 30

  run_step "Avisando players - Contagem final de 30s" countdown_30s

  run_step "Kickando todos os players" kick_everyone

  run_step "Salvando o mundo" rcon save-all

  run_step "Parando servidor gracefully" rcon stop

  if wait_server_stop "$RCON_STOP_TIMEOUT"; then
    log "Servidor parou gracefully"
  else
    log "Timeout aguardando parada do servidor, forçando..."
  fi

  run_step "Parando o Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

  run_step "Iniciando Container" compose_up_d
  
  log "Reinicialização sem backup concluída com sucesso"
  exit 0
fi

# Se houve atividade, procede com o backup
check_disk_space

echo "Container: ${CONTAINER_NAME}"
echo "Backing up: ${WORLD_SRC} -> ${BKP_ROOT} (timestamped by date+hour)"

broadcast_if_players "AVISO: Servidor reiniciando em 5 minutos - Backup automatico"
run_step "Avisando players - Reiniciando em 5 minutos" sleep 240
