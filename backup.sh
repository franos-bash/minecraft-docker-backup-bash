#!/usr/bin/env bash
set -euo pipefail

# SCRIPT DESENVOLVIDO PELA INTELIGENCIA ORGANICA DO FRANCO COM AJUDA DA INTELIGENCIA ARTIFICIAL DUCK.AI
# Este script faz backup dos dados de um mundo de servidor Minecraft executando em Docker.
# Ele deve ficar no mesmo diretorio do docker-compose.yml

# ====== CONFIGURACOES ======
RCON_STOP_TIMEOUT=30       # Tempo limite para desligamento gracioso do servidor (segundos)
MAX_BACKUP_COPIES=10       # Mantem no maximo 10 copias de backup (mais recentes)
MIN_DISK_SPACE_MB=1000     # Espaco minimo em disco antes do backup (MB)
LOG_SIZE_LIMIT=10485760    # 10MB - rotaciona o log ao atingir este tamanho
CONTAINER_CHECK_RETRIES=3  # Numero de tentativas para iniciar o container

# ====== CAMINHOS ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCK_FILE="$SCRIPT_DIR/.backup.lock"
LOG_FILE="$SCRIPT_DIR/autobkp.log"
LAST_BACKUP_MARKER="$SCRIPT_DIR/.backup-last-time"

# ====== PREPARACAO ======
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

log() {
    local msg="${1:-}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] $msg" | tee -a "$LOG_FILE"
}

rotate_log_if_needed() {
    if [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size="$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
        if (( log_size > LOG_SIZE_LIMIT )); then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%s)"
            log "Log rotacionado (tamanho anterior: ${log_size} bytes)"
        fi
    fi
}

# ====== ARQUIVO DO DOCKER COMPOSE ======
COMPOSE_FILE=""
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
    COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
else
    log "ERRO: docker-compose.yml ou docker-compose.yaml nao encontrado em: $SCRIPT_DIR"
    exit 1
fi

compose_kind() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo ""
    fi
}

validate_compose_config() {
    case "$(compose_kind)" in
        "docker-compose")
            if ! docker-compose -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
                log "ERRO: Configuracao invalida do docker-compose"
                exit 1
            fi
            ;;
        "docker compose")
            if ! docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
                log "ERRO: Configuracao invalida do docker compose"
                exit 1
            fi
            ;;
        *)
            log "ERRO: docker ou docker-compose nao encontrado"
            exit 1
            ;;
    esac
}

compose_up_d() {
    case "$(compose_kind)" in
        "docker-compose") docker-compose -f "$COMPOSE_FILE" up -d ;;
        "docker compose") docker compose -f "$COMPOSE_FILE" up -d ;;
        *) log "ERRO: docker ou docker-compose nao encontrado"; return 1 ;;
    esac
}

# ====== EXTRAIR DIRETORIO DE DADOS DO DOCKER-COMPOSE ======
get_data_dir_from_compose() {
    local data_dir=""

    # Procura volumes mapeados para /data ou /minecraft/data.
    # Exemplos:
    #   - ./data:/data
    #   - /opt/minecraft/data:/data
    #   - "./data:/data"
    data_dir="$(
        awk '
            /^[[:space:]]*-/ && $0 ~ /:(\/data|\/minecraft\/data)(:|[[:space:]]|$)/ {
                line=$0
                sub(/^[[:space:]]*-[[:space:]]*/, "", line)
                gsub(/^"|"$/, "", line)
                split(line, a, ":")
                print a[1]
                exit
            }
        ' "$COMPOSE_FILE"
    )"

    if [[ -z "$data_dir" ]]; then
        log "ERRO: Volume para /data nao encontrado em: $COMPOSE_FILE"
        log "Verifique se o docker-compose.yaml contem um volume mapeado para /data"
        exit 1
    fi

    if [[ "$data_dir" == ./* ]]; then
        data_dir="$SCRIPT_DIR/${data_dir#./}"
    elif [[ "$data_dir" != /* ]]; then
        data_dir="$SCRIPT_DIR/$data_dir"
    fi

    echo "$data_dir"
}

# ====== CAMINHOS DOS DADOS ======
BKP_ROOT="$SCRIPT_DIR/autobkp"
DATA_DIR="$(get_data_dir_from_compose)"
WORLD_SRC="$DATA_DIR/world"
SERVER_PROPERTIES_FILE="$DATA_DIR/server.properties"

# ====== NOME DO CONTAINER ======
CONTAINER_NAME="$(
    awk -F: '/^[[:space:]]*container_name[[:space:]]*:/ {
        name=$2
        sub(/^[[:space:]]*/, "", name)
        sub(/[[:space:]]*#.*/, "", name)
        gsub(/^"|"$/, "", name)
        print name
        exit
    }' "$COMPOSE_FILE"
)"

if [[ -z "$CONTAINER_NAME" ]]; then
    log "ERRO: 'container_name:' nao encontrado em: $COMPOSE_FILE"
    exit 1
fi

# ====== FUNCOES AUXILIARES DE ARQUIVO ======
require_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log "ERRO: arquivo obrigatorio nao encontrado: $f"
        exit 1
    fi
}

get_prop() {
    local key="$1"
    local file="$2"
    local v

    require_file "$file"
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

# ====== CONFIGURACAO DO RCON ======
RCON_PASSWORD="$(get_prop "rcon.password" "$SERVER_PROPERTIES_FILE")"
RCON_PORT="$(get_prop "rcon.port" "$SERVER_PROPERTIES_FILE")"

if [[ -z "$RCON_PASSWORD" ]]; then
    log "ERRO: rcon.password nao encontrado ou vazio em: $SERVER_PROPERTIES_FILE"
    exit 1
fi

if [[ -z "$RCON_PORT" ]]; then
    log "ERRO: rcon.port nao encontrado ou vazio em: $SERVER_PROPERTIES_FILE"
    exit 1
fi

if [[ ! -d "$WORLD_SRC" ]]; then
    log "ERRO: diretorio do mundo nao existe: $WORLD_SRC"
    exit 1
fi

# ====== GERENCIAMENTO DE LOCK ======
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid="$(cat "$LOCK_FILE")"
        if kill -0 "$lock_pid" 2>/dev/null; then
            log "ERRO: O backup ja esta em execucao (PID: $lock_pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
}

# ====== VERIFICACOES DO CONTAINER ======
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        log "ERRO: Container nao encontrado ou nao esta em execucao: $CONTAINER_NAME"
        return 1
    fi

    return 0
}

wait_container_ready() {
    local retries="$1"
    local attempt=0

    while (( attempt < retries )); do
        sleep 2
        if check_container; then
            log "Container iniciado com sucesso"
            return 0
        fi

        ((attempt++))
        log "Tentativa $attempt de $retries aguardando o container iniciar..."
    done

    log "ERRO: O container falhou ao iniciar apos $retries tentativas"
    return 1
}

# ====== FUNCOES AUXILIARES DO RCON ======
rcon() {
    local args=("$@")
    docker exec -i "$CONTAINER_NAME" rcon-cli \
        --host 127.0.0.1 \
        --port "$RCON_PORT" \
        --password "$RCON_PASSWORD" \
        "${args[@]}"
}

test_rcon() {
    local rc=0
    rcon list >/dev/null 2>&1 || rc=$?
    return "$rc"
}

players_online_list() {
    local out
    out="$(rcon list 2>/dev/null || echo "")"

    if [[ "$out" =~ online:[[:space:]]*(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    echo ""
}

players_online_count() {
    local out
    out="$(rcon list 2>/dev/null || echo "")"

    if [[ "$out" =~ There[[:space:]]are[[:space:]]([0-9]+)[[:space:]]of ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$out" =~ ([0-9]+)[[:space:]]+of[[:space:]]+[0-9]+ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    echo 0
}

broadcast_if_players() {
    local msg="$1"
    local n
    n="$(players_online_count || echo 0)"

    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        rcon say "$msg" >/dev/null 2>&1 || true
    fi
}

# ====== FUNCOES AUXILIARES DE TEMPO ======
timestamp_hour() {
    date '+%Y%m%d-%H'
}

# ====== VERIFICACAO DE ATIVIDADE ======
has_activity_since_last_backup() {
    if [[ ! -f "$LAST_BACKUP_MARKER" ]]; then
        log "Primeiro backup ou marcador nao encontrado, executando backup"
        return 0
    fi

    local playerdata_dir recent_files
    playerdata_dir="$WORLD_SRC/playerdata"

    if [[ -d "$playerdata_dir" ]]; then
        recent_files="$(find "$playerdata_dir" -type f -newer "$LAST_BACKUP_MARKER" -not -name "*.tmp" 2>/dev/null | wc -l)"
        if (( recent_files > 0 )); then
            log "Atividade de jogador detectada: $recent_files arquivos modificados em playerdata"
            return 0
        else
            log "Nenhuma alteracao em playerdata desde o ultimo backup"
            return 1
        fi
    fi

    recent_files="$(
        find "$WORLD_SRC" \
            -type f \
            -newer "$LAST_BACKUP_MARKER" \
            -not -name "session.lock" \
            -not -name ".DS_Store" \
            -not -name "*.tmp" \
            2>/dev/null | wc -l
    )"

    if (( recent_files > 0 )); then
        log "Atividade detectada (verificacao alternativa no mundo): $recent_files arquivos modificados"
        return 0
    else
        log "Nenhuma atividade detectada desde o ultimo backup"
        return 1
    fi
}

# ====== VERIFICACAO DE ESPACO EM DISCO ======
check_disk_space() {
    mkdir -p "$BKP_ROOT"

    local available_mb
    available_mb="$(df -Pm "$BKP_ROOT" 2>/dev/null | tail -n 1 | awk '{print $4}')"

    if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
        log "AVISO: Nao foi possivel verificar o espaco em disco"
        return 0
    fi

    if (( available_mb < MIN_DISK_SPACE_MB )); then
        log "ERRO: Espaco em disco insuficiente. Disponivel: ${available_mb}MB, Necessario: ${MIN_DISK_SPACE_MB}MB"
        exit 1
    fi

    log "Espaco em disco OK: ${available_mb}MB disponiveis"
}

# ====== LIMPEZA DE BACKUPS ======
cleanup_old_backups() {
    log "Verificando limite de copias de backup (maximo: $MAX_BACKUP_COPIES)..."

    local backup_count
    backup_count="$(find "$BKP_ROOT" -maxdepth 1 -type d -name '*-world' 2>/dev/null | wc -l)"

    if (( backup_count <= MAX_BACKUP_COPIES )); then
        log "Total de backups: $backup_count (dentro do limite)"
        return 0
    fi

    local to_remove=$(( backup_count - MAX_BACKUP_COPIES ))
    log "Total de backups: $backup_count (excedeu o limite em $to_remove). Removendo os mais antigos..."

    find "$BKP_ROOT" -maxdepth 1 -type d -name '*-world' -printf '%T+ %p\n' 2>/dev/null \
        | sort \
        | head -n "$to_remove" \
        | cut -d' ' -f2- \
        | while read -r old_backup; do
            log "Removendo backup antigo: $old_backup"
            rm -rf "$old_backup"
        done
}

# ====== EXECUCAO DO BACKUP ======
backup_world() {
    local ts dest backup_size
    ts="$(timestamp_hour)"
    dest="$BKP_ROOT/${ts}-world"

    mkdir -p "$BKP_ROOT"
    rm -rf "$dest"
    mkdir -p "$dest"

    rsync -a --delete-delay "$WORLD_SRC/" "$dest/"
    log "Backup concluido: $dest"

    backup_size="$(du -sh "$dest" 2>/dev/null | awk '{print $1}' || echo 'unknown')"
    log "Tamanho do backup: $backup_size"

    touch "$LAST_BACKUP_MARKER"
}

# ====== SEQUENCIA DE DESLIGAMENTO DO SERVIDOR ======
countdown_30s() {
    local s
    for s in {30..1}; do
        broadcast_if_players "AVISO: O servidor sera reiniciado em $s segundos"
        sleep 1
    done
}

kick_everyone() {
    rcon kickall >/dev/null 2>&1 || true
}

wait_server_stop() {
    local elapsed=0
    local max_wait="$1"

    while (( elapsed < max_wait )); do
        if ! rcon list >/dev/null 2>&1; then
            log "Servidor parou apos ${elapsed}s"
            return 0
        fi

        sleep 1
        ((elapsed++))
    done

    log "AVISO: O servidor ainda responde apos ${max_wait}s, forcando parada com docker stop"
    return 1
}

# ====== FUNCOES AUXILIARES DE INTERFACE ======
spinner_run() {
    local pid="$1"
    local msg="$2"
    local i=0
    local chars='/-\\|'

    while kill -0 "$pid" >/dev/null 2>&1; do
        local c="${chars:$((i % 4)):1}"
        printf "\r%s %s" "$msg" "$c"
        i=$((i + 1))
        sleep 0.1
    done
}

run_step() {
    local msg="$1"
    shift

    local log_file cmd_pid spin_pid rc
    log_file="$(mktemp)"
    rc=0

    "$@" >"$log_file" 2>&1 &
    cmd_pid=$!

    spinner_run "$cmd_pid" "$msg" &
    spin_pid=$!

    wait "$cmd_pid" || rc=$?

    kill "$spin_pid" >/dev/null 2>&1 || true
    wait "$spin_pid" >/dev/null 2>&1 || true

    if [[ "$rc" -eq 0 ]]; then
        printf "\rOK - %s\n" "$msg"
        rm -f "$log_file"
    else
        printf "\rERRO - %s\n" "$msg"
        log "---- saida do comando (ultimas 50 linhas) ----"
        tail -n 50 "$log_file" >> "$LOG_FILE" || true
        rm -f "$log_file"
        exit "$rc"
    fi
}

log_player_status_and_countdown() {
    local player_count player_list
    player_count="$(players_online_count || echo 0)"

    if [[ "$player_count" =~ ^[0-9]+$ ]] && (( player_count > 0 )); then
        player_list="$(players_online_list || echo "")"
        log "Jogadores online: $player_count - $player_list"
        run_step "Contagem regressiva antes do reinicio" countdown_30s
    else
        log "Nenhum jogador online - pulando contagem regressiva"
    fi
}

# ====== REINICIANDO SEM BACKUP ======
restart_without_backup() {
    log "Reiniciando servidor sem executar backup"
    echo ""
    echo "Nenhuma atividade detectada - pulando backup"

    log_player_status_and_countdown

    run_step "Expulsando todos os jogadores" kick_everyone
    run_step "Salvando o mundo" rcon save-all
    run_step "Parando servidor de forma graciosa" rcon stop

    if wait_server_stop "$RCON_STOP_TIMEOUT"; then
        log "Servidor parado de forma graciosa"
    else
        log "Tempo limite aguardando parada do servidor, forcando..."
    fi

    run_step "Parando o container" docker stop -t 60 "$CONTAINER_NAME"
    run_step "Iniciando o container" compose_up_d

    if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
        log "Reinicio sem backup concluido com sucesso"
    else
        log "ERRO: Falha ao reiniciar o container"
        exit 1
    fi
}

# ====== REINICIANDO COM BACKUP ======
backup_with_restart() {
    echo "Container: $CONTAINER_NAME"
    echo "Dados: $WORLD_SRC"
    echo "Backup: $WORLD_SRC -> $BKP_ROOT (identificado por data+hora)"

    log_player_status_and_countdown

    run_step "Expulsando todos os jogadores" kick_everyone
    run_step "Salvando o mundo" rcon save-all
    run_step "Parando servidor de forma graciosa" rcon stop

    if wait_server_stop "$RCON_STOP_TIMEOUT"; then
        log "Servidor parado de forma graciosa"
    else
        log "Tempo limite aguardando parada do servidor, forcando..."
    fi

    run_step "Parando o container" docker stop -t 60 "$CONTAINER_NAME"
    run_step "Copiando dados do diretorio do mundo" backup_world
    run_step "Iniciando o container" compose_up_d

    if wait_container_ready "$CONTAINER_CHECK_RETRIES"; then
        cleanup_old_backups
        log "Backup concluido com sucesso, container inicializado"
    else
        log "ERRO: Falha ao reiniciar o container after backup"
        exit 1
    fi
}

# ====== SCRIPT PRINCIPAL ======
rotate_log_if_needed

log "=========================================="
log "Iniciando backup do container: $CONTAINER_NAME"
log "=========================================="
log "Dados carregados de: $DATA_DIR"

validate_compose_config
check_lock
check_container || exit 1

if ! test_rcon; then
    log "ERRO: Falha ao conectar ao RCON em 127.0.0.1:$RCON_PORT"
    exit 1
fi

if ! has_activity_since_last_backup; then
    restart_without_backup
    exit 0
fi

check_disk_space
backup_with_restart

log "=========================================="
log "Script concluido com sucesso"
log "=========================================="
