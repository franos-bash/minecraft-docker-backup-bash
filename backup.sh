#!/usr/bin/env bash
set -euo pipefail

# SCRIPT DESENVOLVIDO PELA INTELIGÊNCIA ORGÂNICA DE FRANCO COM AJUDA DA INTELIGÊNCIA ARTIFICIAL DO DUCK.AI
#
# Este script foi desenvolvido para fazer backup dos dados de um mundo de um servidor Minecraft rodando em Docker
# A proposta é que este script siga a lógica de um container, ele funciona baseado no local onde está,
# que precisa ser o mesmo diretório do arquivo docker-compose.yaml.
# O script também espera que a pasta contendo os dados esteja mapeada no docker-compose.yaml
# O destino do backup é um diretório que, se não existir, é criado e se chama /autobackup,
# fica no mesmo diretório do script.
# Para o script funcionar de forma automática, depende de um cronjob,
# basta colocar o script no local correto e apontar o caminho no crontab.

# ====== CONFIGURAÇÕES ======
RCON_STOP_TIMEOUT=30      # Tempo limite para parada graciosa do servidor (segundos)
MAX_BACKUP_COPIES=10      # Manter no máximo 10 cópias de backup (manter as mais recentes)
MIN_DISK_SPACE_MB=1000    # Espaço mínimo em disco antes de fazer backup (MB)
LOG_SIZE_LIMIT=10485760   # 10MB - rotacionar log quando atingir este tamanho
CONTAINER_CHECK_RETRIES=3 # Número de tentativas para iniciar o container

# ====== CAMINHOS ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCK_FILE="$SCRIPT_DIR/.backup.lock"
LOG_FILE="$SCRIPT_DIR/autobkp.log"
LAST_BACKUP_MARKER="$SCRIPT_DIR/.backup-last-time"

# ====== CONFIGURAÇÃO ======
# Função para limpeza em caso de erro
cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Rotaciona log se ficar muito grande
rotate_log_if_needed() {
  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( log_size > LOG_SIZE_LIMIT )); then
      mv "$LOG_FILE" "${LOG_FILE}.$(date +%s)"
      log "Log rotacionado (tamanho anterior: ${log_size} bytes)"
    fi
  fi
}

log() {
  local msg="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $msg" | tee -a "$LOG_FILE"
}

# ====== ARQUIVO DOCKER COMPOSE ======
COMPOSE_FILE=""
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
  COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
else
  log "ERRO: docker-compose.yml ou docker-compose.yaml não encontrado em: $SCRIPT_DIR"
  exit 1
fi

# Valida a configuração do docker-compose
validate_compose_config() {
  if command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose config >/dev/null 2>&1; then
      log "ERRO: Configuração do docker-compose inválida"
      exit 1
    fi
  elif command -v docker >/dev/null 2>&1; then
    if ! docker compose config >/dev/null 2>&1; then
      log "ERRO: Configuração do docker compose inválida"
      exit 1
    fi
  else
    log "ERRO: docker ou docker-compose não encontrado"
    exit 1
  fi
}

# ====== EXTRAIR DIRETÓRIO DE DADOS DO DOCKER-COMPOSE ======
# Extrai o caminho DATA_DIR do docker-compose.yaml
# Procura por volumes mapeados para /data no container
get_data_dir_from_compose() {
  local data_dir=""
  
  # Tenta encontrar volumes que mapeiam para /data ou /minecraft/data no container
  # Sintaxe: - ./caminho:/data ou - /caminho/absoluto:/data
  data_dir=$(
    grep -E '^\s*-\s+.*:(/data|/minecraft/data)' "$COMPOSE_FILE" \
    | head -n 1 \
    | sed -E 's/^\s*-\s+([^:]+):.*/\1/' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  )
  
  if [[ -z "$data_dir" ]]; then
    log "ERRO: Volume para /data não encontrado em: $COMPOSE_FILE"
    log "Certifique-se de que seu docker-compose.yaml contém um volume mapeado para /data"
    exit 1
  fi
  
  # Se o caminho for relativo (começa com .), resolve-o em relação a SCRIPT_DIR
  if [[ "$data_dir" == ./* ]] || [[ "$data_dir" == .\\* ]]; then
    data_dir="${SCRIPT_DIR}/${data_dir#./}"
  fi
  
  echo "$data_dir"
}

# ====== CAMINHOS DE DADOS ======
BKP_ROOT="$SCRIPT_DIR/autobkp"
DATA_DIR="$(get_data_dir_from_compose)"
WORLD_SRC="$DATA_DIR/world"
SERVER_PROPERTIES_FILE="$DATA_DIR/server.properties"

# ====== AUXILIARES DO DOCKER COMPOSE ======
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

# ====== NOME DO CONTAINER ======
CONTAINER_NAME="$(
  sed -nE 's/^[[:space:]]*container_name:[[:space:]]*([^#]+).*/\1/p' "$COMPOSE_FILE" \
  | head -n 1 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//; s/["'"'"']$//'
)"

if [[ -z "${CONTAINER_NAME:-}" ]]; then
  log "ERRO: 'container_name:' não encontrado em: $COMPOSE_FILE"
  exit 1
fi

# ====== AUXILIARES DE ARQUIVO ======
require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    log "ERRO: arquivo obrigatório não encontrado: $f"
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

# ====== CONFIGURAÇÃO RCON ======
RCON_PASSWORD="$(get_prop "rcon.password" "$SERVER_PROPERTIES_FILE")"
RCON_PORT="$(get_prop "rcon.port" "$SERVER_PROPERTIES_FILE")"

if [[ -z "${RCON_PASSWORD:-}" ]]; then
  log "ERRO: rcon.password não encontrado ou vazio em: $SERVER_PROPERTIES_FILE"
  exit 1
fi
if [[ -z "${RCON_PORT:-}" ]]; then
  log "ERRO: rcon.port não encontrado ou vazio em: $SERVER_PROPERTIES_FILE"
  exit 1
fi

if [[ ! -d "$WORLD_SRC" ]]; then
  log "ERRO: diretório world não existe: $WORLD_SRC"
  exit 1
fi

# ====== GERENCIAMENTO DE BLOQUEIO ======
check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE")"
    if kill -0 "$lock_pid" 2>/dev/null; then
      log "ERRO: Backup já está rodando (PID: $lock_pid)"
      exit 1
    else
      rm -f "$LOCK_FILE"
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

# ====== VERIFICAÇÕES DE CONTAINER ======
check_container() {
  if ! docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "ERRO: Container não encontrado ou não está rodando: $CONTAINER_NAME"
    return 1
  fi
  return 0
}

# Aguarda o container iniciar com sucesso (com tentativas)
wait_container_ready() {
  local retries=$1
  local attempt=0

  while (( attempt < retries )); do
    sleep 2
    if check_container; then
      log "Container iniciado com sucesso"
      return 0
    fi
    ((attempt++))
    log "Tentativa $((attempt)) de $retries aguardando o container iniciar..."
  done

  log "ERRO: Container falhou ao iniciar após $retries tentativas"
  return 1
}

# ====== AUXILIARES RCON ======
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

players_online_list() {
  local out
  set +e
  out="$(rcon list 2>/dev/null)"
  set -e

  # Tenta extrair lista de jogadores da resposta RCON
  # Formato típico: "There are X of Y players online: player1, player2, ..."
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

# ====== AUXILIARES DE TEMPO ======
timestamp_hour() {
  date '+%Y%m%d-%H'
}

# ====== VERIFICAÇÃO DE ATIVIDADE ======
has_activity_since_last_backup() {
  if [[ ! -f "$LAST_BACKUP_MARKER" ]]; then
    log "Primeiro backup ou marcador não encontrado, realizando backup"
    return 0
  fi

  local playerdata_dir recent_files
  playerdata_dir="${WORLD_SRC}/playerdata"

  # Preferir verificar playerdata: geralmente só muda quando um jogador real entra
  if [[ -d "$playerdata_dir" ]]; then
    recent_files=$(find "$playerdata_dir" -type f -newer "$LAST_BACKUP_MARKER" -not -name "*.tmp" 2>/dev/null | wc -l)
    if (( recent_files > 0 )); then
      log "Atividade de jogadores detectada: $recent_files arquivos modificados em playerdata"
      return 0
    else
      log "Nenhuma alteração em playerdata desde o último backup"
      return 1
    fi
  fi

  # Fallback: se playerdata não existir, usar a varredura do world original
  recent_files=$(find "$WORLD_SRC" \
    -type f \
    -newer "$LAST_BACKUP_MARKER" \
    -not -name "session.lock" \
    -not -name ".DS_Store" \
    -not -name "*.tmp" \
    2>/dev/null | wc -l)

  if (( recent_files > 0 )); then
    log "Atividade detectada (fallback world): $recent_files arquivos modificados"
    return 0
  else
    log "Nenhuma atividade detectada desde o último backup"
    return 1
  fi
}

# ====== VERIFICAÇÃO DE ESPAÇO EM DISCO ======
check_disk_space() {
  local available_mb
  available_mb="$(df "$BKP_ROOT" 2>/dev/null | tail -n 1 | awk '{print $4}')"
  
  if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
    log "AVISO: Não foi possível verificar espaço em disco"
    return 0
  fi

  if (( available_mb < MIN_DISK_SPACE_MB )); then
    log "ERRO: Espaço em disco insuficiente. Disponível: ${available_mb}MB, Necessário: ${MIN_DISK_SPACE_MB}MB"
    exit 1
  fi
  
  log "Espaço em disco OK: ${available_mb}MB disponível"
}

# ====== LIMPEZA DE BACKUP ======
cleanup_old_backups() {
  log "Verificando limite de cópias de backup (máximo: ${MAX_BACKUP_COPIES})..."
  
  local backup_count
  backup_count=$(find "$BKP_ROOT" -maxdepth 1 -type d -name "*world*" 2>/dev/null | wc -l)
  
  if (( backup_count <= MAX_BACKUP_COPIES )); then
    log "Total de backups: $backup_count (dentro do limite)"
    return 0
  fi
  
  local to_remove=$(( backup_count - MAX_BACKUP_COPIES ))
  log "Total de backups: $backup_count (excedeu limite em $to_remove). Removendo os mais antigos..."
  
  # Encontra e remove os backups mais antigos
  find "$BKP_ROOT" -maxdepth 1 -type d -name "*world*" -printf '%T+ %p\n' 2>/dev/null \
    | sort \
    | head -n "$to_remove" \
    | awk '{print $2}' \
    | while read -r old_backup; do
      log "Removendo backup antigo: $old_backup"
      rm -rf "$old_backup"
    done
}

# ====== EXECUÇÃO DE BACKUP ======
backup_world() {
  local ts dest
  ts="$(timestamp_hour)"
  dest="${BKP_ROOT}/${CONTAINER_NAME}-world-${ts}"

  mkdir -p "$BKP_ROOT"
  rm -rf "$dest"
  mkdir -p "$dest"

  rsync -a --delete-delay "${WORLD_SRC}/" "${dest}/"
  log "Backup concluído: ${dest}"
  
  # Calcula tamanho do backup
  local backup_size
  backup_size="$(du -sh "$dest" 2>/dev/null | awk '{print $1}' || echo 'desconhecido')"
  log "Tamanho do backup: $backup_size"
  
  touch "$LAST_BACKUP_MARKER"
}

# ====== SEQUÊNCIA DE DESLIGAMENTO DO SERVIDOR ======
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

# Aguarda o servidor parar graciosamente (polling)
# Usa 'list' em vez de 'ping' pois é mais confiável
wait_server_stop() {
  local elapsed=0
  local max_wait=$1
  
  while (( elapsed < max_wait )); do
    if ! rcon list >/dev/null 2>&1; then
      log "Servidor parou após ${elapsed}s"
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  
  log "AVISO: Servidor ainda respondendo após ${max_wait}s, forçando parada com docker stop"
  return 1
}

# ====== AUXILIARES DE INTERFACE ======
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
    log "---- saída do comando (últimas 50 linhas) ----"
    tail -n 50 "$log_file" >> "$LOG_FILE" || true
    rm -f "$log_file"
    exit "$rc"
  fi
}

# ====== REINICIAR SEM BACKUP ======
restart_without_backup() {
  log "Reiniciando servidor sem fazer backup"
  echo ""
  echo "Nenhuma atividade detectada - pulando backup"
  
  local player_count
  player_count="$(players_online_count || true)"
  
  if [[ "$player_count" =~ ^[0-9]+$ ]] && (( player_count > 0 )); then
    local player_list
    player_list="$(players_online_list || true)"
    log "Jogadores online: $player_count - $player_list"
    
    broadcast_if_players "AVISO: Servidor reiniciando em 5 minutos"
    run_step "Avisando jogadores - Reiniciando em 5 minutos" sleep 240

    broadcast_if_players "AVISO: Servidor reiniciando em 1 minuto"
    run_step "Avisando jogadores - Reiniciando em 1 minuto" sleep 30

    run_step "Avisando jogadores - Contagem final de 30s" countdown_30s
  else
    log "Nenhum jogador online - pulando contagem regressiva, iniciando backup imediatamente"
  fi

  run_step "Expulsando todos os jogadores" kick_everyone

  run_step "Salvando o mundo" rcon save-all

  run_step "Parando servidor graciosamente" rcon stop

  if wait_server_stop "$RCON_STOP_TIMEOUT"; then
    log "Servidor parou graciosamente"
  else
    log "Tempo limite aguardando parada do servidor, forçando..."
  fi

  run_step "Parando o Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

  run_step "Iniciando Container" compose_up_d
  
  if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
    log "Reinicialização sem backup concluída com sucesso"
  else
    log "ERRO: Falha ao reiniciar container"
    exit 1
  fi
}

# ====== BACKUP COM REINICIALIZAÇÃO ======
backup_with_restart() {
  echo "Container: ${CONTAINER_NAME}"
  echo "Dados: ${DATA_DIR}"
  echo "Backup: ${WORLD_SRC} -> ${BKP_ROOT} (marcado por hora+data)"

  local player_count
  player_count="$(players_online_count || true)"
  
  if [[ "$player_count" =~ ^[0-9]+$ ]] && (( player_count > 0 )); then
    local player_list
    player_list="$(players_online_list || true)"
    log "Jogadores online: $player_count - $player_list"
    
    broadcast_if_players "AVISO: Servidor reiniciando em 5 minutos - Backup automático"
    run_step "Avisando jogadores - Reiniciando em 5 minutos" sleep 240

    broadcast_if_players "AVISO: Servidor reiniciando em 1 minuto - Backup automático"
    run_step "Avisando jogadores - Reiniciando em 1 minuto" sleep 30

    run_step "Avisando jogadores - Contagem final de 30s" countdown_30s
  else
    log "Nenhum jogador online - pulando contagem regressiva, iniciando backup imediatamente"
  fi

  run_step "Expulsando todos os jogadores" kick_everyone

  run_step "Salvando o mundo" rcon save-all

  run_step "Parando servidor graciosamente" rcon stop

  if wait_server_stop "$RCON_STOP_TIMEOUT"; then
    log "Servidor parou graciosamente"
  else
    log "Tempo limite aguardando parada do servidor, forçando..."
  fi

  run_step "Parando o Container" docker stop -t 60 "$CONTAINER_NAME" >/dev/null

  run_step "Copiando dados do diretório world" backup_world

  run_step "Iniciando Container" compose_up_d

  if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
    cleanup_old_backups
    log "Backup bem-sucedido, container inicializado"
  else
    log "ERRO: Falha ao reiniciar container após backup"
    exit 1
  fi
}

# ====== SCRIPT PRINCIPAL ======

rotate_log_if_needed

log "=========================================="
log "Iniciando backup do container: ${CONTAINER_NAME}"
log "Dados carregados de: ${DATA_DIR}"
log "=========================================="

validate_compose_config
check_lock
check_container || exit 1

if ! test_rcon; then
  log "ERRO: Falha ao conectar ao RCON em ${CONTAINER_NAME}:${RCON_PORT}"
  exit 1
fi

# Verifica se houve atividade desde o último backup
if ! has_activity_since_last_backup; then
  restart_without_backup
  exit 0
fi

# Se houve atividade, procede com o backup
check_disk_space
backup_with_restart

log "=========================================="
log "Script finalizado com sucesso"
log "=========================================="
