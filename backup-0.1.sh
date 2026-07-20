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

# Roda tudo baseado no local que esse script tá
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
  # Pega key 
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

rcon() {
  # Roda o rcon-cli dentro do container, pra poder avisar os users no chat so server e kickar geral
  local args=("$@")
  docker exec -i "$CONTAINER_NAME" rcon-cli \
    --host 127.0.0.1 \
    --port "$RCON_PORT" \
    --password "$RCON_PASSWORD" \
    "${args[@]}"
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

backup_world() {
  local ts dest
  ts="$(timestamp_hour)"
  dest="${BKP_ROOT}/${CONTAINER_NAME}-world-${ts}"

  mkdir -p "$BKP_ROOT"
  rm -rf "$dest"
  mkdir -p "$dest"

  rsync -a --delete-delay "${WORLD_SRC}/" "${dest}/"
  echo "Backup completed: ${dest}"
}

countdown_30s() {
  local s
  for s in {30..1}; do
    broadcast_if_players "AVISO: Servidor reiniciando em ${s}"
    sleep 1
  done
}

kick_everyone() {
  rcon kickall >/dev/null 2>&1 || true
}

spinner_run() {
  # Usage: spinner_run <pid> <message>
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
  # Usage: run_step "Message" command [args...]
  local msg="$1"; shift

  local log
  log="$(mktemp)"
  local cmd_pid
  local spin_pid
  local rc=0

  set +e
  "$@" >"$log" 2>&1 &
  cmd_pid=$!

  spinner_run "$cmd_pid" "$msg" &
  spin_pid=$!

  wait "$cmd_pid"
  rc=$?

  # stop spinner
  kill "$spin_pid" >/dev/null 2>&1 || true
  wait "$spin_pid" >/dev/null 2>&1 || true

  if [[ $rc -eq 0 ]]; then
    printf "\r✓ %s\n" "$msg"
    rm -f "$log"
    set -e
  else
    printf "\r✗ %s\n" "$msg"
    echo "---- command output (last 50 lines) ----"
    tail -n 50 "$log" || true
    rm -f "$log"
    exit "$rc"
  fi
}

echo "Container: ${CONTAINER_NAME}"
echo "Backing up: ${WORLD_SRC} -> ${BKP_ROOT} (timestamped by date+hour)"

broadcast_if_players "AVISO: Servidor reiniciando em 5 minutos - Backup automatico"
run_step "Avisando players - Reiniciando em 5 minutos" sleep 240

broadcast_if_players "AVISO: Servidor reiniciando em 1 minuto - Backup automatico"
run_step "Avisando players - Reiniciando em 1 minuto" sleep 30

run_step "Avisando players - Contagem final de 30s" countdown_30s

run_step "Kickando todos os players" kick_everyone

run_step "Parando o Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

run_step "Copiando dados do diretorio world" backup_world

run_step "Iniciando Container" compose_up_d

echo "Backup bem sucedido, inicializando container"
