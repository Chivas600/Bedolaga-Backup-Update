#!/bin/bash
set -e

# ===== ЦВЕТОВЫЕ ФУНКЦИИ =====
error()   { echo -e "\033[31m❌ ОШИБКА: $1\033[0m" >&2; }
success() { echo -e "\033[32m✅ $1\033[0m" >&2; }
info()    { echo -e "\033[33mℹ️  $1\033[0m" >&2; }
warn()    { echo -e "\033[33m⚠️  $1\033[0m" >&2; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m\n" >&2; }

CONFIG_FILE="/root/.bedolaga-config"
CRON_MODE=false
DRY_RUN=false
ONLY=""          # --only bot|cabinet|all: выбор компонентов на этот запуск
VERIFY_RESTORE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --cron)    CRON_MODE=true ;;
    --dry-run) DRY_RUN=true ;;
    --only)    shift; ONLY="${1:-}" ;;
    --only=*)  ONLY="${1#--only=}" ;;
    --verify-restore) VERIFY_RESTORE=true ;;
  esac
  shift
done
SSH_KEY="/root/.ssh/id_backup"
HEALTH_WARN=0
VERSION="3.0.2"

# ===== DRY-RUN =====
# guard <команда...>: в режиме --dry-run печатает намерение и НЕ выполняет команду.
# Используется для потенциально опасных/исходящих операций (scp, ssh rm, rm -rf, docker и т.п.).
guard() {
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] пропущено: $*" >&2
    return 0
  fi
  "$@"
}

# ===== ВЫБОР КОМПОНЕНТОВ (бот / кабинет / всё) =====
# ROLE  — что физически есть на этом хосте (all|bot|cabinet); для разнесённых инстансов.
# SCOPE — что бэкапим/восстанавливаем на этот запуск (all|bot|cabinet).
# component_available: доступен ли компонент на хосте (по ROLE)
component_available() {
  case "${ROLE:-all}" in
    all)     return 0 ;;
    bot)     [[ "$1" == "bot" || "$1" == "caddy" ]] ;;
    cabinet) [[ "$1" == "cabinet" ]] ;;
    *)       return 0 ;;
  esac
}
# want_component: нужно ли трогать компонент на этот запуск (ROLE ∩ SCOPE)
want_component() {
  component_available "$1" || return 1
  case "$1" in
    bot|caddy) [[ "${SCOPE:-all}" == "all" || "${SCOPE:-all}" == "bot" ]] ;;
    cabinet)   [[ "${SCOPE:-all}" == "all" || "${SCOPE:-all}" == "cabinet" ]] ;;
    *)         return 1 ;;
  esac
}
valid_scope() { [[ "$1" =~ ^(all|bot|cabinet)$ ]]; }

clean_domain() { local d="$1"; d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; echo "$d" | xargs; }
is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; }

# ===== ВЫБОР ДОМЕНА =====
select_domain() {
  local NAME="$1"; shift; local DOMAINS=("$@")
  if [ ${#DOMAINS[@]} -gt 0 ]; then
    info "Доступные домены для $NAME:" >&2
    for i in "${!DOMAINS[@]}"; do echo "  $((i+1))) ${DOMAINS[$i]}" >&2; done
    echo "  m) Ввести вручную" >&2; echo "" >&2
    while true; do
      read -p "📌 Выбор [1-${#DOMAINS[@]}/m]: " INPUT >&2; INPUT="$(echo "$INPUT" | xargs)"
      if [[ "$INPUT" == "m" || "$INPUT" == "M" ]]; then
        echo "Требования: домен без http/https" >&2
        read -p "🌐 Домен для $NAME: " MANUAL >&2; MANUAL="$(clean_domain "$MANUAL")"
        if [[ -n "$MANUAL" ]] && is_valid_domain "$MANUAL"; then echo "$MANUAL"; return 0; fi
        error "Некорректный формат" >&2
      elif [[ "$INPUT" =~ ^[0-9]+$ ]] && [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#DOMAINS[@]}" ]; then
        echo "${DOMAINS[$((INPUT-1))]}"; return 0
      else error "Введите 1-${#DOMAINS[@]} или 'm'" >&2; fi
    done
  else
    warn "Домены не найдены автоматически" >&2
    echo "Требования: домен без http/https" >&2
    while true; do
      read -p "🌐 Домен для $NAME (или 'skip'): " MANUAL >&2; MANUAL="$(echo "$MANUAL" | xargs)"
      [[ "$MANUAL" == "skip" ]] && { echo ""; return 0; }
      MANUAL="$(clean_domain "$MANUAL")"
      if [[ -n "$MANUAL" ]] && is_valid_domain "$MANUAL"; then echo "$MANUAL"; return 0; fi
      error "Некорректный формат" >&2
    done
  fi
}

# ===== ВВОД ПУТИ =====
PROMPT_PATH_RESULT=""
prompt_path() {
  local LABEL="$1" FOUND="$2" TYPE="${3:-}"
  local SEARCH_DIRS=("/opt" "/root" "/home" "/srv")
  PROMPT_PATH_RESULT=""

  if [ -n "$FOUND" ]; then
    info "Найден путь к $LABEL: $FOUND" >&2
    read -p "✅ Использовать? [y/N]: " CONFIRM >&2
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then PROMPT_PATH_RESULT="$FOUND"; return 0; fi
  fi

  local CANDIDATES=()
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      [ "$f" = "$FOUND" ] && continue
      [[ "$f" =~ backup ]] && continue
      local IS_MATCH=false
      case "$TYPE" in
        bot)
          [ -f "$f/.env" ] && [ -f "$f/docker-compose.yml" ] && \
            grep -qE 'bot|remnawave|telegram' "$f/docker-compose.yml" 2>/dev/null && IS_MATCH=true
          ;;
        cabinet)
          [ -f "$f/.env" ] && [ -f "$f/package.json" ] && \
            grep -qE 'cabinet|bedolaga|vite|react' "$f/package.json" 2>/dev/null && IS_MATCH=true
          ;;
        caddy)
          [ -f "$f/Caddyfile" ] && IS_MATCH=true
          ;;
      esac
      $IS_MATCH || continue
      local ALREADY=false
      for c in "${CANDIDATES[@]}"; do [[ "$c" == "$f" ]] && ALREADY=true && break; done
      $ALREADY || CANDIDATES+=("$f")
    done < <(find "$dir" -maxdepth 2 -type d -print0 2>/dev/null)
  done

  if [ ${#CANDIDATES[@]} -gt 0 ]; then
    info "Доступные варианты для $LABEL:" >&2
    for i in "${!CANDIDATES[@]}"; do echo "  $((i+1))) ${CANDIDATES[$i]}" >&2; done
    echo "  m) Ввести вручную" >&2; echo "" >&2
    while true; do
      read -p "📌 Выбор [1-${#CANDIDATES[@]}/m]: " SEL >&2
      SEL="$(echo "$SEL" | xargs)"
      if [[ "$SEL" == "m" || "$SEL" == "M" ]]; then
        break
      elif [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#CANDIDATES[@]}" ]; then
        PROMPT_PATH_RESULT="${CANDIDATES[$((SEL-1))]}"; return 0
      else
        error "Введите 1-${#CANDIDATES[@]} или 'm'" >&2
      fi
    done
  fi

  echo "Требования: абсолютный путь, папка должна существовать" >&2
  echo "Пример: /opt/my-project" >&2
  while true; do
    read -p "📁 Путь к $LABEL: " IP >&2
    IP="${IP//\"/}"; IP="${IP//\'/}"; IP="$(echo "$IP" | xargs)"
    [ -z "$IP" ] && { error "Путь не может быть пустым" >&2; continue; }
    [ ! -d "$IP" ] && { error "Папка '$IP' не найдена" >&2; continue; }
    PROMPT_PATH_RESULT="$IP"; return 0
  done
}

# ===== АВТО-ДЕТЕКТ ПУТЕЙ =====
detect_paths() {
  info "🔍 Авто-поиск путей..." >&2
  local SEARCH_DIRS=("/opt" "/root" "/home" "/srv")
  local FOUND_BOT="" FOUND_CABINET="" FOUND_CADDY=""

  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      [[ "$f" =~ backup ]] && continue
      [ -f "$f/.env" ] && [ -f "$f/docker-compose.yml" ] && \
        grep -qE 'bot|remnawave|telegram' "$f/docker-compose.yml" 2>/dev/null && \
        FOUND_BOT="$f" && break 2
    done < <(find "$dir" -maxdepth 2 -type d -print0 2>/dev/null)
  done
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      [[ "$f" =~ backup ]] && continue
      [ -f "$f/.env" ] && [ -f "$f/package.json" ] && \
        grep -qE 'cabinet|bedolaga|vite|react' "$f/package.json" 2>/dev/null && \
        FOUND_CABINET="$f" && break 2
    done < <(find "$dir" -maxdepth 2 -type d -print0 2>/dev/null)
  done
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      [[ "$f" =~ backup ]] && continue
      [ -f "$f/Caddyfile" ] && FOUND_CADDY="$f" && break 2
    done < <(find "$dir" -maxdepth 2 -type d -print0 2>/dev/null)
  done

  echo "" >&2
  if component_available bot; then
    prompt_path "бот" "$FOUND_BOT" "bot" && BOT_DIR="$PROMPT_PATH_RESULT"
  else
    BOT_DIR=""; info "Роль=$ROLE — бот на этом хосте не используется, пропуск" >&2
  fi
  if component_available cabinet; then
    prompt_path "кабинет" "$FOUND_CABINET" "cabinet" && CABINET_DIR="$PROMPT_PATH_RESULT"
  else
    CABINET_DIR=""; info "Роль=$ROLE — кабинет на этом хосте не используется, пропуск" >&2
  fi

  echo "" >&2
  if component_available caddy; then
    if [ -n "$FOUND_CADDY" ]; then
      info "Найден путь к Caddy: $FOUND_CADDY" >&2
      read -p "✅ Использовать? [y/N]: " CC >&2
      [[ "$CC" =~ ^[Yy]$ ]] && CADDY_DIR="$FOUND_CADDY" || { info "Введите путь или Enter для пропуска" >&2; read -p "📁 Путь к Caddy: " CADDY_DIR >&2; }
    else
      info "Caddy не найден. Введите путь или Enter для пропуска" >&2
      read -p "📁 Путь к Caddy: " CADDY_DIR >&2
    fi
    CADDY_DIR="$(echo "${CADDY_DIR//\"/}" | xargs)"
    [ -n "$CADDY_DIR" ] && [ ! -d "$CADDY_DIR" ] && { warn "Папка не найдена — Caddy пропущен" >&2; CADDY_DIR=""; }
    [ -z "$CADDY_DIR" ] && info "Caddy: не используется" >&2
  else
    CADDY_DIR=""
  fi

  echo "" >&2; info "Проверка путей..." >&2
  if component_available bot; then
    [ -d "$BOT_DIR" ] && success "Бот: $BOT_DIR ✅" >&2 || { error "Бот: папка не существует ❌" >&2; return 1; }
  fi
  if component_available cabinet; then
    [ -d "$CABINET_DIR" ] && success "Кабинет: $CABINET_DIR ✅" >&2 || { error "Кабинет: папка не существует ❌" >&2; return 1; }
  fi
  [ -z "$CADDY_DIR" ] || [ -d "$CADDY_DIR" ] && success "Caddy: ${CADDY_DIR:-нет} ✅" >&2 || { error "Caddy: папка не существует ❌" >&2; return 1; }
  return 0
}

# ===== АВТО-ДЕТЕКТ ДОМЕНОВ =====
detect_domains() {
  info "🔍 Авто-детект доменов..." >&2; local DETECTED=()
  [ -n "$CADDY_DIR" ] && [ -f "$CADDY_DIR/Caddyfile" ] && while IFS= read -r line; do
    [[ "$line" =~ ^https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]] || continue
    local d="${BASH_REMATCH[1]}"; [[ "$d" =~ localhost|127\.0\.0\.1 ]] && continue
    [[ " ${DETECTED[*]} " =~ " ${d} " ]] || DETECTED+=("$d")
  done < <(grep -E "^https?://" "$CADDY_DIR/Caddyfile" 2>/dev/null || true)

  [ -f "$BOT_DIR/.env" ] && while IFS= read -r line; do
    [[ "$line" =~ =(https?://)?([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]] || continue
    local d="${BASH_REMATCH[2]}"; [[ "$d" =~ localhost|127\.0\.0\.1 || "$d" =~ ^[A-Z_]+$ ]] && continue
    [[ " ${DETECTED[*]} " =~ " ${d} " ]] || DETECTED+=("$d")
  done < <(grep -E "^(WEBHOOK|API|APP|BOT)_URL|DOMAIN|HOST=" "$BOT_DIR/.env" 2>/dev/null || true)

  local UNIQUE=(); for d in "${DETECTED[@]}"; do [[ " ${UNIQUE[*]} " =~ " ${d} " ]] || UNIQUE+=("$d"); done
  PRIMARY_DOMAIN="$(select_domain "кабинета" "${UNIQUE[@]}")"
  [ -z "$PRIMARY_DOMAIN" ] && { HOOKS_DOMAIN=""; return 0; }
  [ ${#UNIQUE[@]} -gt 1 ] && HOOKS_DOMAIN="$(select_domain "API" "${UNIQUE[@]}")" || HOOKS_DOMAIN="$PRIMARY_DOMAIN"
  info "API: используем $HOOKS_DOMAIN" >&2; return 0
}

# ===== СОХРАНЕНИЕ ВСЕХ НАСТРОЕК =====
save_all_config() {
  info "💾 Сохранение всех настроек в $CONFIG_FILE..." >&2
  cat > "$CONFIG_FILE" << CONF
# Bedolaga Config - $(date '+%Y-%m-%d %H:%M')
BACKUP_SERVER="$BACKUP_SERVER"
BACKUP_USER="$BACKUP_USER"
BACKUP_REMOTE_DIR="$BACKUP_REMOTE_DIR"
BACKUP_RETENTION="$BACKUP_RETENTION"
BACKUP_SSH_PORT="$BACKUP_SSH_PORT"
ROLE="$ROLE"
BOT_DIR="$BOT_DIR"
CABINET_DIR="$CABINET_DIR"
CADDY_DIR="$CADDY_DIR"
PRIMARY_DOMAIN="$PRIMARY_DOMAIN"
HOOKS_DOMAIN="$HOOKS_DOMAIN"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
TG_THREAD_ID="$TG_THREAD_ID"
DEST_LOCAL="$DEST_LOCAL"
DEST_SSH="$DEST_SSH"
DEST_S3="$DEST_S3"
DEST_TELEGRAM="$DEST_TELEGRAM"
RCLONE_REMOTE="$RCLONE_REMOTE"
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
ENCRYPT="$ENCRYPT"
AGE_RECIPIENT="$AGE_RECIPIENT"
AGE_KEY_FILE="$AGE_KEY_FILE"
CONF
  chmod 600 "$CONFIG_FILE"
  success "Все настройки сохранены ✅" >&2
}

# ===== ПРОВЕРКА КРИТИЧНЫХ НАСТРОЕК =====
check_critical_config() {
  local MISSING=()
  [ -z "$BACKUP_SERVER" ] && MISSING+=("BACKUP_SERVER")
  component_available bot     && [ -z "$BOT_DIR" ]     && MISSING+=("BOT_DIR")
  component_available cabinet && [ -z "$CABINET_DIR" ] && MISSING+=("CABINET_DIR")
  if [ ${#MISSING[@]} -gt 0 ]; then
    warn "В конфиге не хватает: ${MISSING[*]}" >&2
    return 1
  fi
  return 0
}

# ===== РОТАЦИЯ ЛОКАЛЬНЫХ БЭКАПОВ =====
rotate_local_backups() {
  header "🗑️ РОТАЦИЯ ЛОКАЛЬНЫХ БЭКАПОВ" >&2; local DIR="/root/bedolaga-local-backups"
  info "Храним: $BACKUP_RETENTION" >&2
  local CNT=$(ls -1d "$DIR"/bedolaga-full-backup-* 2>/dev/null | wc -l)
  if [ "$CNT" -gt "$BACKUP_RETENTION" ]; then
    local DEL=$((CNT - BACKUP_RETENTION)); info "Удаляем $DEL старых..." >&2
    ls -1d "$DIR"/bedolaga-full-backup-* 2>/dev/null | head -n "$DEL" | while read OLD; do
      local DT=$(basename "$OLD"|sed 's/bedolaga-full-backup-//'); local SZ=$(du -sh "$OLD"|awk '{print $1}')
      info "Удаляем: $DT ($SZ)..." >&2; guard rm -rf "$OLD" && success "Удалён ✅" >&2 || error "Ошибка ❌" >&2
      log "Локальный удалён: $DT ($SZ)"
    done
  else info "Бэкапов: $CNT/$BACKUP_RETENTION ✅" >&2; fi
}

# ===== РОТАЦИЯ УДАЛЁННЫХ БЭКАПОВ =====
rotate_remote_backups() {
  header "🗑️ РОТАЦИЯ УДАЛЁННЫХ БЭКАПОВ" >&2
  [ -z "$BACKUP_SERVER" ] && { warn "Сервер не указан — пропущено" >&2; return 0; }
  info "Подключение к серверу для ротации..." >&2

  local RET=${BACKUP_RETENTION:-7}
  local SSH="ssh -i $SSH_KEY -p $BACKUP_SSH_PORT -o StrictHostKeyChecking=no ${BACKUP_USER}@${BACKUP_SERVER}"

  local ALL=$($SSH "ls -1d ${BACKUP_REMOTE_DIR}/bedolaga-full-backup-* 2>/dev/null | sort" || true)
  [ -z "$ALL" ] && { info "На удалённом сервере нет бэкапов ✅" >&2; return 0; }

  local CNT=$(echo "$ALL" | wc -l)
  info "Найдено бэкапов: $CNT (лимит: $RET)" >&2

  if [ "$CNT" -gt "$RET" ]; then
    local DEL=$((CNT - RET))
    info "Удаляем $DEL старых..." >&2
    local DEL_LIST=$(echo "$ALL" | head -n "$DEL" | tr '\n' ' ')
    if [ "$DRY_RUN" = true ]; then
      info "[dry-run] ssh rm -rf $DEL_LIST (пропущено)" >&2
      return 0
    fi
    if $SSH "rm -rf $DEL_LIST" 2>&1; then
      success "Удалено $DEL бэкапов с сервера ✅" >&2
      echo "$ALL" | head -n "$DEL" | while read BP; do
        local BN=$(basename "$BP"); local BD=$(echo "$BN" | sed 's/bedolaga-full-backup-//')
        log "Удалён удалённый: $BD"
      done
    else
      error "Не удалось удалить бэкапы ❌" >&2
      log "❌ Ошибка удаления на сервере"
    fi
  else
    info "Удаление не требуется ✅" >&2
  fi
}

# ===== TELEGRAM =====
send_telegram() {
  local MSG="$1"
  if [ "$DRY_RUN" = true ]; then info "[dry-run] Telegram-сообщение не отправляется" >&2; return 0; fi
  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then return 0; fi
  local THREAD_ARGS=()
  [ -n "$TG_THREAD_ID" ] && THREAD_ARGS=(-d "message_thread_id=${TG_THREAD_ID}")
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=HTML" \
    "${THREAD_ARGS[@]}" \
    --data-urlencode "text=$MSG" \
    -o /dev/null 2>&1 || true
}

# ===== МАСКИРОВКА СЕКРЕТА =====
# Показывает начало и конец, середину скрывает звёздочками (для верификации без раскрытия).
mask_secret() {
  local s="$1" n=${#1}
  if [ "$n" -le 28 ]; then echo "****"; return; fi
  echo "${s:0:20}************${s: -8}"
}

# ===== ОТПРАВКА В TELEGRAM С САМОУНИЧТОЖЕНИЕМ =====
# Отправляет сообщение и планирует его удаление через TTL секунд.
# (Bot API не умеет «после прочтения», поэтому таймер идёт от момента отправки.)
tg_send_selfdestruct() {
  local MSG="$1" TTL="${2:-180}"
  if [ "$DRY_RUN" = true ]; then info "[dry-run] Telegram self-destruct не отправляется" >&2; return 0; fi
  { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; } && return 1
  local THREAD_ARGS=()
  [ -n "$TG_THREAD_ID" ] && THREAD_ARGS=(-d "message_thread_id=${TG_THREAD_ID}")
  local RESP MID
  RESP=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" "${THREAD_ARGS[@]}" \
    --data-urlencode "text=$MSG" 2>/dev/null)
  MID=$(printf '%s' "$RESP" | jq -r '.result.message_id // empty' 2>/dev/null)
  [ -z "$MID" ] && return 1
  # Фоновая отложенная зачистка: закрываем fd блокировки (иначе лок держался бы весь TTL),
  # игнорируем SIGHUP, чтобы процесс пережил завершение скрипта.
  ( exec 9>&- 2>/dev/null; trap '' HUP
    sleep "$TTL"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
      -d "chat_id=${TG_CHAT_ID}" -d "message_id=${MID}" -o /dev/null 2>&1
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# ===== ОТПРАВКА ФАЙЛА В TELEGRAM =====
# Лимит Bot API на sendDocument — 50 МБ; берём безопасные 45 МБ, крупнее — режем split'ом.
TG_DOC_LIMIT=$((45 * 1024 * 1024))
tg_send_document() {
  local FILE="$1" CAPTION="$2"
  local ARGS=(-F "chat_id=${TG_CHAT_ID}")
  [ -n "$TG_THREAD_ID" ] && ARGS+=(-F "message_thread_id=${TG_THREAD_ID}")
  [ -n "$CAPTION" ] && ARGS+=(-F "caption=${CAPTION}")
  local CODE
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -F "document=@${FILE}" "${ARGS[@]}" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" 2>/dev/null || echo 000)
  [ "$CODE" = "200" ]
}

# ===== НАЗНАЧЕНИЕ: SSH (scp) =====
dest_ssh() {
  local BD="$1"
  [ -z "$BACKUP_SERVER" ] && { warn "SSH: сервер не указан — пропуск" >&2; return 1; }
  if [ "$DRY_RUN" = true ]; then info "[dry-run] scp $BD → ${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/" >&2; return 0; fi
  if scp -i "$SSH_KEY" -P "$BACKUP_SSH_PORT" -r -o StrictHostKeyChecking=no "$BD" "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/"; then
    success "SSH: скопировано ✅" >&2; return 0
  else
    error "SSH: ошибка копирования ❌" >&2; log "❌ scp failed"; return 1
  fi
}

# ===== НАЗНАЧЕНИЕ: S3 (rclone) =====
dest_s3() {
  local BD="$1"
  [ -z "$RCLONE_REMOTE" ] || [ -z "$S3_BUCKET" ] && { warn "S3: не настроен (remote/bucket) — пропуск" >&2; return 1; }
  local TARGET="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/$(basename "$BD")"
  if [ "$DRY_RUN" = true ]; then info "[dry-run] rclone copy $BD → $TARGET" >&2; return 0; fi
  if rclone copy "$BD" "$TARGET" 2>/dev/null; then
    success "S3: загружено → $TARGET ✅" >&2; return 0
  else
    error "S3: ошибка rclone ❌" >&2; log "❌ rclone copy failed"; return 1
  fi
}

# ===== НАЗНАЧЕНИЕ: Telegram-файлы (sendDocument, со split для >45МБ) =====
dest_telegram_files() {
  local BD="$1" LABEL; LABEL="$(basename "$BD")"
  [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && { warn "Telegram: токен/chat_id не заданы — пропуск" >&2; return 1; }
  if [ "$DRY_RUN" = true ]; then info "[dry-run] Telegram sendDocument для файлов из $BD" >&2; return 0; fi
  local RC=0 F SZ
  for F in "$BD"/*.tar.zst "$BD"/*.tar.zst.age "$BD"/SHA256SUMS "$BD"/manifest.txt; do
    [ -e "$F" ] || continue
    SZ=$(stat -c%s "$F" 2>/dev/null || echo 0)
    if [ "$SZ" -le "$TG_DOC_LIMIT" ]; then
      tg_send_document "$F" "${LABEL}/$(basename "$F")" && success "TG: $(basename "$F") ✅" >&2 || { error "TG: $(basename "$F") ❌" >&2; RC=1; }
    else
      info "TG: $(basename "$F") > 45МБ — режем на части..." >&2
      local TMP; TMP=$(mktemp -d)
      split -b 45m -d "$F" "$TMP/$(basename "$F").part"
      local PARTS=("$TMP"/*) P I=1 N
      N=${#PARTS[@]}
      for P in "${PARTS[@]}"; do
        tg_send_document "$P" "${LABEL}/$(basename "$F") [часть ${I}/${N}] — собрать: cat *.part* > файл" \
          && success "TG: $(basename "$P") ($I/$N) ✅" >&2 || { error "TG: $(basename "$P") ❌" >&2; RC=1; }
        I=$((I+1))
      done
      rm -rf "$TMP"
    fi
  done
  return $RC
}

# ===== РОТАЦИЯ S3 =====
rotate_s3_backups() {
  [ "${DEST_S3:-false}" = "true" ] || return 0
  [ -z "$RCLONE_REMOTE" ] || [ -z "$S3_BUCKET" ] && return 0
  header "🗑️ РОТАЦИЯ S3" >&2
  local BASE="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}" RET=${BACKUP_RETENTION:-7}
  if [ "$DRY_RUN" = true ]; then info "[dry-run] ротация S3 в $BASE (лимит $RET)" >&2; return 0; fi
  local ALL; ALL=$(rclone lsf --dirs-only "$BASE" 2>/dev/null | sed 's#/$##' | grep '^bedolaga-full-backup-' | sort)
  [ -z "$ALL" ] && { info "S3: бэкапов нет ✅" >&2; return 0; }
  local CNT; CNT=$(echo "$ALL" | wc -l)
  info "S3: найдено $CNT (лимит $RET)" >&2
  if [ "$CNT" -gt "$RET" ]; then
    local DEL=$((CNT - RET))
    echo "$ALL" | head -n "$DEL" | while read -r D; do
      rclone purge "$BASE/$D" 2>/dev/null && { success "S3 удалён: $D ✅" >&2; log "S3 удалён: $D"; } || error "S3: не удалось удалить $D ❌" >&2
    done
  else
    info "S3: удаление не требуется ✅" >&2
  fi
}

# ===== ЕДИНАЯ ЗАГРУЗКА ВО ВСЕ ВКЛЮЧЁННЫЕ НАЗНАЧЕНИЯ =====
UPLOAD_SUMMARY=""
upload_all() {
  local BD="$1" OVERALL=0
  UPLOAD_SUMMARY=""
  header "📡 ОТПРАВКА В НАЗНАЧЕНИЯ" >&2
  if [ "${DEST_SSH:-true}" = "true" ] && [ -n "$BACKUP_SERVER" ]; then
    if dest_ssh "$BD"; then UPLOAD_SUMMARY+="  ✅ SSH (${BACKUP_USER}@${BACKUP_SERVER})"$'\n'; else UPLOAD_SUMMARY+="  ❌ SSH"$'\n'; OVERALL=1; fi
  fi
  if [ "${DEST_S3:-false}" = "true" ]; then
    if dest_s3 "$BD"; then UPLOAD_SUMMARY+="  ✅ S3 (${RCLONE_REMOTE}:${S3_BUCKET})"$'\n'; else UPLOAD_SUMMARY+="  ❌ S3"$'\n'; OVERALL=1; fi
  fi
  if [ "${DEST_TELEGRAM:-false}" = "true" ] && [ -n "$TG_TOKEN" ]; then
    if dest_telegram_files "$BD"; then UPLOAD_SUMMARY+="  ✅ Telegram (файлы)"$'\n'; else UPLOAD_SUMMARY+="  ⚠️ Telegram (файлы, частично)"$'\n'; fi
  fi
  [ -z "$UPLOAD_SUMMARY" ] && UPLOAD_SUMMARY="  ⚪ только локально"$'\n'
  return $OVERALL
}

# ===== НАСТРОЙКА НАЗНАЧЕНИЙ (интерактивно) =====
setup_s3() {
  header "☁️ НАСТРОЙКА S3" >&2
  info "Провайдер по умолчанию — Selectel. Для другого S3 укажите свой endpoint/region." >&2
  read -p "Имя rclone-remote [selectel]: " RN >&2; RCLONE_REMOTE="${RN:-selectel}"
  read -p "Access Key ID: " AK >&2
  read -p "Secret Access Key: " SK >&2
  read -p "Endpoint [https://s3.storage.selcloud.ru]: " EP >&2; EP="${EP:-https://s3.storage.selcloud.ru}"
  read -p "Region [ru-1]: " RG >&2; RG="${RG:-ru-1}"
  read -p "Bucket (контейнер): " S3_BUCKET >&2
  read -p "Префикс (папка) [bedolaga-backups]: " PF >&2; S3_PREFIX="${PF:-bedolaga-backups}"
  if rclone config create "$RCLONE_REMOTE" s3 provider Other access_key_id "$AK" secret_access_key "$SK" endpoint "$EP" region "$RG" >/dev/null 2>&1; then
    success "rclone remote '$RCLONE_REMOTE' создан ✅" >&2
  else
    error "Не удалось создать rclone remote ❌" >&2; DEST_S3=false; return 1
  fi
  info "Проверка доступа к бакету '$S3_BUCKET'..." >&2
  if rclone lsd "${RCLONE_REMOTE}:${S3_BUCKET}" >/dev/null 2>&1 || rclone mkdir "${RCLONE_REMOTE}:${S3_BUCKET}" >/dev/null 2>&1; then
    success "S3: доступ к бакету ОК ✅" >&2; DEST_S3=true
  else
    error "S3: нет доступа — проверьте ключи/endpoint/bucket ❌" >&2; DEST_S3=false; return 1
  fi
}
configure_destinations() {
  header "📡 НАЗНАЧЕНИЯ БЭКАПОВ" >&2
  echo "Текущие:" >&2
  echo "  SSH:            ${DEST_SSH:-true}  (${BACKUP_SERVER:-нет})" >&2
  echo "  S3:             ${DEST_S3:-false}  (${RCLONE_REMOTE:+${RCLONE_REMOTE}:${S3_BUCKET}})" >&2
  echo "  Telegram-файлы: ${DEST_TELEGRAM:-false}" >&2
  echo "" >&2
  echo "1) Переключить SSH" >&2
  echo "2) Настроить/включить S3 (Selectel и др.)" >&2
  echo "3) Переключить Telegram-файлы" >&2
  echo "4) Выключить S3" >&2
  read -p "Выбор [1-4]: " D >&2
  case "$D" in
    1) [ "${DEST_SSH:-true}" = "true" ] && DEST_SSH=false || DEST_SSH=true; success "SSH: $DEST_SSH" >&2 ;;
    2) setup_s3 ;;
    3) [ "${DEST_TELEGRAM:-false}" = "true" ] && DEST_TELEGRAM=false || DEST_TELEGRAM=true; success "Telegram-файлы: $DEST_TELEGRAM" >&2 ;;
    4) DEST_S3=false; success "S3 выключен" >&2 ;;
    *) info "Отмена" >&2; return 0 ;;
  esac
  save_all_config
}

# ===== ПОЛУЧЕНИЕ ПРИВАТНОГО AGE-КЛЮЧА ДЛЯ РАСШИФРОВКИ =====
AGE_KEY_TMP=""
obtain_age_key() {
  # Печатает путь к файлу с приватным ключом (или пусто при неудаче)
  if [ -n "$AGE_KEY_FILE" ] && [ -f "$AGE_KEY_FILE" ]; then
    echo "$AGE_KEY_FILE"; return 0
  fi
  warn "Нужен приватный age-ключ — на сервере он не хранится." >&2
  info "Вставьте строку ключа (AGE-SECRET-KEY-1...) и нажмите Enter:" >&2
  local K; read -r K >&2
  K="$(echo "$K" | xargs)"
  [ -z "$K" ] && { error "Ключ не введён" >&2; return 1; }
  AGE_KEY_TMP=$(mktemp); printf '%s\n' "$K" > "$AGE_KEY_TMP"; chmod 600 "$AGE_KEY_TMP"
  echo "$AGE_KEY_TMP"; return 0
}

# ===== ОНБОРДИНГ ШИФРОВАНИЯ (age): понятная генерация и сохранение ключа =====
setup_encryption() {
  header "🔐 ШИФРОВАНИЕ БЭКАПОВ (age)" >&2
  cat >&2 <<'TXT'
Бэкапы содержат .env с паролями БД, токенами бота и SMTP. Перед отправкой в
Telegram/S3 их обязательно шифровать. Используется age — простая пара ключей:
  • ПУБЛИЧНЫЙ ключ  — шифрует, хранится на сервере (не секрет).
  • ПРИВАТНЫЙ ключ  — расшифровывает, храните ТОЛЬКО ВЫ.
⚠️ Без приватного ключа зашифрованный бэкап восстановить НЕВОЗМОЖНО.
TXT
  echo "" >&2
  if [ -n "$AGE_RECIPIENT" ]; then
    warn "Уже настроен публичный ключ: $AGE_RECIPIENT" >&2
    read -p "Сгенерировать НОВЫЙ ключ? Старые зашифрованные бэкапы станут нечитаемы новым ключом [y/N]: " RG >&2
    [[ "$RG" =~ ^[Yy]$ ]] || { info "Оставляю текущий ключ" >&2; return 0; }
  fi
  read -p "Сгенерировать ключ и включить шифрование? [y/N]: " GO >&2
  [[ "$GO" =~ ^[Yy]$ ]] || { info "Отмена" >&2; return 0; }

  # Генерируем в stdout: age-keygen -o отказывается писать в уже существующий файл (mktemp его создаёт)
  local KGEN PUB PRIV
  KGEN=$(age-keygen 2>/dev/null)
  PUB=$(printf '%s\n' "$KGEN" | grep 'public key:' | sed 's/.*public key: //' | head -1 | xargs)
  PRIV=$(printf '%s\n' "$KGEN" | grep '^AGE-SECRET-KEY-' | head -1 | xargs)
  if [ -z "$PUB" ] || [ -z "$PRIV" ]; then error "Не удалось сгенерировать ключ ❌" >&2; return 1; fi

  echo "" >&2
  echo -e "\033[1;31m╔═══════════════════════════════════════════════════════════════╗\033[0m" >&2
  echo -e "\033[1;31m║  ⚠️  СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС               ║\033[0m" >&2
  echo -e "\033[1;31m║  Без него вы НЕ восстановите зашифрованные бэкапы.            ║\033[0m" >&2
  echo -e "\033[1;31m╚═══════════════════════════════════════════════════════════════╝\033[0m" >&2
  echo "" >&2
  echo "  🔑 ПРИВАТНЫЙ КЛЮЧ (секрет — в менеджер паролей):" >&2
  echo -e "\033[1;33m      $PRIV\033[0m" >&2
  echo "" >&2
  echo "  🔓 Публичный ключ (не секрет, идёт в конфиг):" >&2
  echo "      $PUB" >&2
  echo "" >&2
  echo "  Что сделать: 1) скопируйте приватный ключ  2) сохраните в надёжном месте" >&2
  echo "               3) при восстановлении вставите его обратно — и всё заработает" >&2
  echo "" >&2

  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    read -p "Прислать в Telegram уведомление (ключ будет ЗАМАСКИРОВАН)? [y/N]: " TS >&2
    if [[ "$TS" =~ ^[Yy]$ ]]; then
      local MASKED; MASKED=$(mask_secret "$PRIV")
      if tg_send_selfdestruct "🔐 <b>Bedolaga — age-ключ бэкапов создан</b>

⚠️ Полный приватный ключ показан в <b>ТЕРМИНАЛЕ</b> — сохраните его там (менеджер паролей).
Здесь он показан частично (в целях безопасности):
🔑 <code>${MASKED}</code>

🔓 Публичный ключ: <code>${PUB}</code>

<b>Восстановление:</b> bedolaga-update → «5) Восстановление» → вставьте ПОЛНЫЙ ключ.

🧨 Это сообщение самоуничтожится через 3 минуты." 180; then
        success "Отправлено в Telegram (ключ замаскирован, сообщение удалится через 3 минуты)." >&2
      else
        warn "Не удалось отправить/запланировать удаление в Telegram." >&2
      fi
    fi
  fi

  # Гейт подтверждения: пользователь вводит последние 8 символов ключа
  local TAIL="${PRIV: -8}" OK=false TRY CONF
  echo "" >&2
  for TRY in 1 2 3; do
    read -p "Подтвердите сохранение: введите ПОСЛЕДНИЕ 8 символов приватного ключа: " CONF >&2
    CONF="$(echo "$CONF" | xargs)"
    if [ "$CONF" = "$TAIL" ]; then OK=true; break; fi
    warn "Не совпало (попытка $TRY/3). Точно сохранили ключ?" >&2
  done
  if [ "$OK" != true ]; then
    error "Не подтверждено. Шифрование НЕ включено, ключ отброшен (сгенерируйте заново позже)." >&2
    return 1
  fi

  AGE_RECIPIENT="$PUB"; ENCRYPT=true

  echo "" >&2
  warn "Хранение приватного ключа на СЕРВЕРЕ упрощает восстановление, но при взломе" >&2
  warn "сервера злоумышленник сможет расшифровать бэкапы. Рекомендация: НЕ хранить." >&2
  read -p "Сохранить приватный ключ на сервере (для авто-восстановления здесь же)? [y/N]: " KEEP >&2
  if [[ "$KEEP" =~ ^[Yy]$ ]]; then
    AGE_KEY_FILE="/root/.bedolaga-age.key"; printf '%s\n' "$KGEN" > "$AGE_KEY_FILE"; chmod 600 "$AGE_KEY_FILE"
    warn "Ключ сохранён в $AGE_KEY_FILE (chmod 600). Всё равно держите копию у себя!" >&2
  else
    AGE_KEY_FILE=""; info "Приватный ключ на сервере не хранится — только у вас." >&2
  fi
  save_all_config
  success "Шифрование включено ✅ (offsite-копии будут .tar.zst.age)" >&2
}

# ===== ЗАГРУЗКА ИЛИ СОЗДАНИЕ КОНФИГА =====
NEED_FULL_SETUP=false

if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  info "Настройки загружены из $CONFIG_FILE" >&2
  BACKUP_USER="${BACKUP_USER:-root}"
  BACKUP_REMOTE_DIR="${BACKUP_REMOTE_DIR:-/root/bedolaga-backups}"
  BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
  BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-22}"
  [[ ! "$BACKUP_RETENTION" =~ ^[0-9]+$ ]] && BACKUP_RETENTION=7
  if ! check_critical_config; then
    warn "Конфиг неполный — запускаю полную настройку..." >&2
    NEED_FULL_SETUP=true
  fi
else
  NEED_FULL_SETUP=true
fi

ROLE="${ROLE:-all}"
valid_scope "$ROLE" || ROLE="all"

# Назначения бэкапов (по умолчанию: локально + SSH, если задан сервер)
DEST_LOCAL="${DEST_LOCAL:-true}"
DEST_SSH="${DEST_SSH:-true}"
DEST_S3="${DEST_S3:-false}"
DEST_TELEGRAM="${DEST_TELEGRAM:-false}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-bedolaga-backups}"

# Шифрование (age): при ENCRYPT=true все копии (локальные и offsite) шифруются
ENCRYPT="${ENCRYPT:-false}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
AGE_KEY_FILE="${AGE_KEY_FILE:-}"

# Валидация --only и предварительное разрешение SCOPE (для cron/неинтерактивного режима)
if [ -n "$ONLY" ]; then
  valid_scope "$ONLY" || { echo "ERROR: --only принимает bot|cabinet|all (получено: '$ONLY')" >&2; exit 1; }
  if ! component_available "$ONLY" && [ "$ONLY" != "all" ]; then
    echo "ERROR: компонент '$ONLY' недоступен на этом хосте (ROLE=$ROLE)" >&2; exit 1
  fi
  SCOPE="$ONLY"
else
  SCOPE="all"   # ограничивается доступностью по ROLE через want_component
fi

if [ "$CRON_MODE" = true ] && [ "$NEED_FULL_SETUP" = true ]; then
  echo "ERROR: Конфиг не найден ($CONFIG_FILE). Сначала запустите скрипт интерактивно." >&2
  exit 1
fi

if [ "$NEED_FULL_SETUP" = true ]; then
  header "⚙️ ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА" >&2
  while [ -z "$BACKUP_SERVER" ]; do
    read -p "🌐 IP резервного сервера: " BACKUP_SERVER >&2
    [ -z "$BACKUP_SERVER" ] && error "Обязательно!" >&2
  done
  read -p "🔌 SSH порт резервного сервера [22]: " SP >&2; BACKUP_SSH_PORT="${SP:-22}"; [ -z "$SP" ] && success "22" >&2
  read -p "👤 Пользователь [root]: " U >&2; BACKUP_USER="${U:-root}"; [ -z "$U" ] && success "root" >&2
  read -p "📁 Путь бэкапов [/root/bedolaga-backups]: " P >&2; BACKUP_REMOTE_DIR="${P:-/root/bedolaga-backups}"; [ -z "$P" ] && success "по умолчанию" >&2
  read -p "📦 Хранить бэкапов [7]: " R >&2; BACKUP_RETENTION="${R:-7}"; [ -z "$R" ] && success "7" >&2
  echo "" >&2
  info "Роль этого сервера (что на нём установлено):" >&2
  echo "  1) Всё вместе (бот + кабинет)" >&2
  echo "  2) Только бот" >&2
  echo "  3) Только кабинет" >&2
  read -p "Выбор [1-3, по умолчанию 1]: " RSEL >&2
  case "$RSEL" in 2) ROLE="bot";; 3) ROLE="cabinet";; *) ROLE="all";; esac
  success "Роль: $ROLE" >&2
  echo "" >&2
  detect_paths || exit 1
  echo "" >&2
  detect_domains || exit 1
  echo "" >&2
  read -p "🤖 Telegram Bot Token (Enter для пропуска): " TG_TOKEN >&2
  read -p "💬 Telegram Chat ID (Enter для пропуска): " TG_CHAT_ID >&2
  read -p "🧵 Telegram Topic ID (Enter для пропуска): " TG_THREAD_ID >&2
  echo "" >&2
  read -p "💾 Сохранить ВСЕ настройки? [y/N]: " SAVE_ALL >&2
  if [[ "$SAVE_ALL" =~ ^[Yy]$ ]]; then save_all_config; fi
fi

REPORT_FILE="/root/bedolaga-report-$(date +%Y%m%d-%H%M).txt"
CURRENT_STEP=""
log() { CURRENT_STEP="$1"; echo "[$(date '+%H:%M:%S')] $1" | tee -a "$REPORT_FILE" >&2; }

# ===== АВАРИЙНЫЙ АЛЕРТ (гарантированное уведомление при сбое) =====
FAILED_NOTIFIED=false
notify_failure() {
  local EC="$1" WHERE="$2"
  [ "$FAILED_NOTIFIED" = true ] && return 0
  FAILED_NOTIFIED=true
  local TAIL; TAIL=$(tail -n 8 "$REPORT_FILE" 2>/dev/null)
  send_telegram "❌ <b>Bedolaga: сбой операции</b> — $(date '+%Y-%m-%d %H:%M')
Код: ${EC}${WHERE:+, место: $WHERE}
Последний шаг: <code>${CURRENT_STEP:-?}</code>
<b>Хвост лога:</b>
<pre>${TAIL}</pre>"
}
on_error() { local ec=$?; notify_failure "$ec" "trap ERR"; }
trap on_error ERR

# ===== РОТАЦИЯ ФАЙЛОВ-ОТЧЁТОВ =====
rotate_reports() {
  local KEEP=30 F
  ls -1t /root/bedolaga-report-*.txt 2>/dev/null | tail -n +$((KEEP+1)) | while read -r F; do
    guard rm -f "$F"
  done
}

check_backup_file() {
  local F="$1" N="$2"
  if [ -f "$F" ]; then
    local SZ=$(stat -c%s "$F" 2>/dev/null || echo 0)
    [ "$SZ" -gt 0 ] && { success "$N: $(ls -lh "$F"|awk '{print $5}') ✅" >&2; return 0; }
    error "$N: пустой файл ❌" >&2; return 1
  fi; error "$N: не найден ❌" >&2; return 1
}

check_disk_space() {
  local MIN=1024 AVAIL=$(df -m "${1:-/root}" | awk 'NR==2{print $4}')
  [ "$AVAIL" -lt "$MIN" ] && { error "Мало места: ${AVAIL}МБ < ${MIN}МБ" >&2; return 1; }
  success "Место: ${AVAIL}МБ ✅" >&2; return 0
}

CUSTOM_FILES="/root/.bedolaga-custom-files"

# ===== НАСТРОЙКИ =====
do_settings() {
  header "⚙️ НАСТРОЙКИ" >&2
  echo "Что изменить?" >&2
  echo "1) Всё (полный сброс)" >&2
  echo "2) Telegram (токен, chat_id, thread_id)" >&2
  echo "3) Пути (бот, кабинет, caddy)" >&2
  echo "4) Резервный сервер (IP, пользователь, путь, retention)" >&2
  echo "5) Время автобэкапа (cron)" >&2
  echo "6) Кастомные файлы (защита при обновлении)" >&2
  echo "7) Назначения бэкапов (SSH, S3, Telegram-файлы)" >&2
  echo "8) Роль сервера (всё / только бот / только кабинет)" >&2
  echo "9) Шифрование age (генерация ключа, вкл/выкл)" >&2
  read -p "Выбор [1-9]: " SACT >&2
  [[ ! "$SACT" =~ ^[1-9]$ ]] && { error "Неверный выбор" >&2; return 1; }

  case "$SACT" in
    1)
      rm -f "$CONFIG_FILE"
      info "Конфиг удалён. Перезапустите скрипт для полной настройки." >&2
      ;;
    2)
      echo "" >&2
      read -p "🤖 Telegram Bot Token [${TG_TOKEN:+****}]: " NT >&2
      [ -n "$NT" ] && TG_TOKEN="$NT"
      read -p "💬 Telegram Chat ID [${TG_CHAT_ID:-пусто}]: " NC >&2
      [ -n "$NC" ] && TG_CHAT_ID="$NC"
      read -p "🧵 Telegram Topic ID [${TG_THREAD_ID:-пусто}]: " NTH >&2
      [ -n "$NTH" ] && TG_THREAD_ID="$NTH"
      save_all_config
      ;;
    3)
      echo "" >&2
      detect_paths || return 1
      save_all_config
      ;;
    4)
      echo "" >&2
      read -p "🌐 IP резервного сервера [${BACKUP_SERVER:-пусто}]: " NS >&2
      [ -n "$NS" ] && BACKUP_SERVER="$NS"
      read -p "👤 Пользователь [${BACKUP_USER:-root}]: " NU >&2
      [ -n "$NU" ] && BACKUP_USER="$NU"
      read -p "📁 Путь бэкапов [${BACKUP_REMOTE_DIR:-/root/bedolaga-backups}]: " NP >&2
      [ -n "$NP" ] && BACKUP_REMOTE_DIR="$NP"
      read -p "📦 Хранить бэкапов [${BACKUP_RETENTION:-7}]: " NR >&2
      [ -n "$NR" ] && BACKUP_RETENTION="$NR"
      read -p "🔌 SSH порт [${BACKUP_SSH_PORT:-22}]: " NSSP >&2
      [ -n "$NSSP" ] && BACKUP_SSH_PORT="$NSSP"
      save_all_config
      ;;
    5)
      echo "" >&2
      info "Текущий cron:" >&2
      local CRON_FILE="/etc/cron.d/bedolaga-backup"
      if [ -f "$CRON_FILE" ]; then
        cat "$CRON_FILE" >&2
      else
        info "Cron не настроен" >&2
      fi
      echo "" >&2
      read -p "⏰ Час запуска [0-23]: " CH >&2
      read -p "⏰ Минута запуска [0-59]: " CM >&2
      if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 0 ] && [ "$CH" -le 23 ] && \
         [[ "$CM" =~ ^[0-9]+$ ]] && [ "$CM" -ge 0 ] && [ "$CM" -le 59 ]; then
        local SCRIPT_PATH; SCRIPT_PATH="$(realpath "$0")"
        echo "$CM $CH * * * root $SCRIPT_PATH --cron >> /var/log/bedolaga-cron.log 2>&1" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        success "Cron обновлён: $CM $CH * * * $SCRIPT_PATH --cron" >&2
      else
        error "Некорректное время" >&2; return 1
      fi
      ;;
    6)
      echo "" >&2
      info "Текущий список кастомных файлов ($CUSTOM_FILES):" >&2
      if [ -f "$CUSTOM_FILES" ]; then
        cat "$CUSTOM_FILES" >&2
      else
        info "(файл не существует)" >&2
      fi
      echo "" >&2
      info "Открываю редактор..." >&2
      nano "$CUSTOM_FILES"
      ;;
    7)
      configure_destinations
      ;;
    8)
      echo "" >&2
      info "Текущая роль: ${ROLE:-all}" >&2
      echo "  1) Всё вместе (бот + кабинет)" >&2
      echo "  2) Только бот" >&2
      echo "  3) Только кабинет" >&2
      read -p "Выбор [1-3]: " RSEL >&2
      case "$RSEL" in 2) ROLE="bot";; 3) ROLE="cabinet";; 1) ROLE="all";; *) error "Отмена" >&2; return 1;; esac
      success "Роль: $ROLE" >&2; save_all_config
      ;;
    9)
      echo "" >&2
      info "Шифрование: ${ENCRYPT:-false}$( [ -n "$AGE_RECIPIENT" ] && echo " (ключ: $AGE_RECIPIENT)")" >&2
      echo "  1) Настроить/сгенерировать ключ (включить)" >&2
      echo "  2) Выключить шифрование" >&2
      read -p "Выбор [1-2]: " ES >&2
      case "$ES" in
        1) setup_encryption ;;
        2) ENCRYPT=false; save_all_config; success "Шифрование выключено (ключ в конфиге сохранён)" >&2 ;;
        *) info "Отмена" >&2 ;;
      esac
      ;;
  esac
}

# ===== ЗАГОЛОВОК И МЕНЮ =====
if [ "$VERIFY_RESTORE" = true ]; then
  log "🚀 Запуск (--verify-restore)"
  ACT=0
elif [ "$CRON_MODE" = true ]; then
  log "🚀 Запуск (cron)"
  ACT=1
else
  clear 2>/dev/null || true; echo -e "\033[1;36m"
  echo "╔════════════════════════════════════╗"
  echo "║  🤖 Bedolaga Backup & Update v${VERSION}  ║"
  echo "╚════════════════════════════════════╝"
  echo -e "\033[0m"
  log "🚀 Запуск"; info "Сервер: ${BACKUP_USER:-?}@${BACKUP_SERVER:-НЕ УКАЗАН}" >&2; info "Бот: $BOT_DIR" >&2; info "Кабинет: $CABINET_DIR" >&2; info "Caddy: ${CADDY_DIR:-нет}" >&2

  echo "" >&2; echo "Действие:" >&2; echo "1) 🔒 Только бэкап" >&2; echo "2) 🔄 Только обновление" >&2; echo "3) ⚡ Бэкап + Обновление" >&2; echo "4) ⚙️ Настройки" >&2; echo "5) 🔁 Восстановление из бэкапа" >&2
  read -p "Выбор [1-5]: " ACT >&2
  [[ ! "$ACT" =~ ^[1-5]$ ]] && { error "Неверно" >&2; exit 1; }
  [ "$ACT" = "4" ] && { do_settings; exit 0; }

  # Выбор компонентов для бэкапа (если не задан --only)
  if [[ "$ACT" == "1" || "$ACT" == "3" ]] && [ -z "$ONLY" ]; then
    if [ "$ROLE" = "all" ]; then
      echo "" >&2; echo "Что бэкапим?" >&2
      echo "  1) Всё (бот + кабинет + caddy)" >&2
      echo "  2) Только бот" >&2
      echo "  3) Только кабинет" >&2
      read -p "Выбор [1-3, по умолчанию 1]: " SCSEL >&2
      case "$SCSEL" in 2) SCOPE="bot";; 3) SCOPE="cabinet";; *) SCOPE="all";; esac
    else
      SCOPE="$ROLE"
    fi
    info "Компоненты этого бэкапа: $SCOPE" >&2
  fi
fi

# ===== ПРОВЕРКА ОБНОВЛЕНИЙ =====
CHECK_UPDATES_RESULT=""
check_updates() {
  local BOT_VER CABINET_VER BOT_LATEST CABINET_LATEST
  CHECK_UPDATES_RESULT=""

  BOT_VER=$(git -C "$BOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "")
  CABINET_VER=$(git -C "$CABINET_DIR" describe --tags --abbrev=0 2>/dev/null || echo "")

  BOT_LATEST=$(curl -s "https://api.github.com/repos/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot/releases/latest" \
    | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  CABINET_LATEST=$(curl -s "https://api.github.com/repos/BEDOLAGA-DEV/bedolaga-cabinet/releases/latest" \
    | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  local UPDATES="" ALL_OK=true
  if [ -n "$BOT_LATEST" ] && [ -n "$BOT_VER" ] && [ "$BOT_VER" != "$BOT_LATEST" ]; then
    UPDATES="${UPDATES}  Бот: ${BOT_VER} → ${BOT_LATEST}"$'\n'
    ALL_OK=false
  fi
  if [ -n "$CABINET_LATEST" ] && [ -n "$CABINET_VER" ] && [ "$CABINET_VER" != "$CABINET_LATEST" ]; then
    UPDATES="${UPDATES}  Кабинет: ${CABINET_VER} → ${CABINET_LATEST}"$'\n'
    ALL_OK=false
  fi

  if [ "$ALL_OK" = true ]; then
    CHECK_UPDATES_RESULT="✅ Версии актуальны: Бот ${BOT_LATEST:-${BOT_VER:-?}}, Кабинет ${CABINET_LATEST:-${CABINET_VER:-?}}"
  else
    CHECK_UPDATES_RESULT="⚠️ <b>Доступны обновления:</b>"$'\n'"${UPDATES}<b>Обновись: запусти bedolaga-update и выбери пункт 2 или 3</b>"
  fi
}

# ===== АВТО-ДЕТЕКТ POSTGRESQL =====
detect_pg_credentials() {
  PG_USER=$(grep -oE 'POSTGRES_USER=\S+' "$BOT_DIR/.env" 2>/dev/null | cut -d= -f2)
  PG_DB=$(grep -oE 'POSTGRES_DB=\S+'   "$BOT_DIR/.env" 2>/dev/null | cut -d= -f2)

  if [ -z "$PG_USER" ]; then
    PG_USER=$(grep 'POSTGRES_USER:-' "$BOT_DIR/docker-compose.yml" 2>/dev/null \
      | sed 's/.*POSTGRES_USER:-\([^}]*\).*/\1/' | head -1 | xargs)
  fi
  if [ -z "$PG_DB" ]; then
    PG_DB=$(grep 'POSTGRES_DB:-' "$BOT_DIR/docker-compose.yml" 2>/dev/null \
      | sed 's/.*POSTGRES_DB:-\([^}]*\).*/\1/' | head -1 | xargs)
  fi

  PG_USER="${PG_USER:-postgres}"
  PG_DB="${PG_DB:-postgres}"

  # Детект имён контейнеров (не хардкодим — поддержка нестандартных имён/инстансов)
  PG_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'bot_db|postgres|_db$' | head -1)
  PG_CONTAINER="${PG_CONTAINER:-remnawave_bot_db}"
  REDIS_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'redis' | head -1)
  REDIS_CONTAINER="${REDIS_CONTAINER:-remnawave_bot_redis}"

  info "БД: пользователь=$PG_USER база=$PG_DB контейнер=$PG_CONTAINER" >&2
}

# ===== БЭКАП =====
do_backup() {
  local BACKUP_START; BACKUP_START=$(date +%s)
  header "📦 БЭКАП" >&2; check_disk_space "/root" || return 1
  local TS; TS=$(date +%Y%m%d-%H%M)
  local BD="/root/bedolaga-local-backups/bedolaga-full-backup-$TS"
  local STAGE; STAGE=$(mktemp -d "/tmp/bedolaga-stage-$TS.XXXXXX")
  mkdir -p "$BD" "$STAGE/bot" "$STAGE/cabinet" "$STAGE/caddy"; log "Создано: $BD"

  if want_component bot; then
  info "Конфиги бота..." >&2; cd "$BOT_DIR" || { error "Папка бота не найдена" >&2; rm -rf "$STAGE"; return 1; }
  cp .env docker-compose.yml "$STAGE/bot/"; check_backup_file "$STAGE/bot/.env" ".env"; check_backup_file "$STAGE/bot/docker-compose.yml" "docker-compose.yml"

  info "БД..." >&2
  detect_pg_credentials
  # pg_dump с защитой от set -e: ошибку ловим сами, а не роняем скрипт
  if ! docker exec "$PG_CONTAINER" pg_dump -Fc -U "$PG_USER" "$PG_DB" > "$STAGE/bot/postgres.dump" 2>/dev/null; then
    error "pg_dump завершился с ошибкой ❌" >&2; log "❌ pg_dump failed"; rm -rf "$STAGE"; return 1
  fi
  check_backup_file "$STAGE/bot/postgres.dump" "PostgreSQL" || { error "Бэкап БД не создан!" >&2; rm -rf "$STAGE"; return 1; }
  # Верификация: структура дампа должна читаться pg_restore --list (битый/пустой дамп отсеиваем здесь)
  if docker exec -i "$PG_CONTAINER" pg_restore --list < "$STAGE/bot/postgres.dump" >/dev/null 2>&1; then
    success "PostgreSQL: дамп валиден (pg_restore --list) ✅" >&2
  else
    error "PostgreSQL: дамп НЕ проходит pg_restore --list — повреждён ❌" >&2; log "❌ pg dump invalid"; rm -rf "$STAGE"; return 1
  fi

  info "Redis..." >&2
  # BGSAVE для консистентного снапшота перед архивацией тома
  docker exec "$REDIS_CONTAINER" redis-cli BGSAVE >/dev/null 2>&1 && sleep 2 || true
  local RV; RV=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$RV" ]; then
    docker run --rm -v "$RV":/source -v "$STAGE/bot":/backup alpine tar -czf /backup/redis_data.tar.gz -C /source .
    check_backup_file "$STAGE/bot/redis_data.tar.gz" "Redis"
  fi
  else
    info "Бот: пропуск (scope=$SCOPE, role=$ROLE)" >&2
  fi

  if want_component cabinet; then
  info "Кабинет..." >&2
  if [ -d "$CABINET_DIR" ]; then
    cd "$CABINET_DIR" 2>/dev/null && { cp .env package*.json "$STAGE/cabinet/" 2>/dev/null||true; cp -r src/ "$STAGE/cabinet/" 2>/dev/null||true; }
    [ -f "$STAGE/cabinet/.env" ] && success "Конфиг ✅" >&2||info "Конфиг не найден" >&2
    [ -d "$STAGE/cabinet/src" ] && success "Код ✅" >&2||info "Код не найден" >&2
  fi
  else
    info "Кабинет: пропуск (scope=$SCOPE, role=$ROLE)" >&2
  fi

  if want_component caddy && [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cp "$CADDY_DIR/Caddyfile" "$STAGE/caddy/" 2>/dev/null && success "Caddy ✅" >&2
  fi

  # ---- Архивация компонентов в отдельные tar.zst ----
  header "🗜 АРХИВАЦИЯ КОМПОНЕНТОВ" >&2
  local COMP
  for COMP in bot cabinet caddy; do
    if [ -z "$(ls -A "$STAGE/$COMP" 2>/dev/null)" ]; then
      info "Компонент '$COMP' пуст — пропуск" >&2; continue
    fi
    local ARCHIVE="$BD/${COMP}-${TS}.tar.zst"
    if tar -C "$STAGE" -cf - "$COMP" | zstd -q -T0 -19 > "$ARCHIVE" && zstd -tq "$ARCHIVE" 2>/dev/null; then
      check_backup_file "$ARCHIVE" "${COMP}.tar.zst"
    else
      error "Архивация '$COMP' не удалась ❌" >&2; log "❌ archive $COMP failed"; rm -rf "$STAGE"; return 1
    fi
  done

  # ---- Шифрование (age) перед контрольными суммами и отправкой offsite ----
  local ENC_STATE="false"
  if [ "${ENCRYPT:-false}" = "true" ] && [ -n "$AGE_RECIPIENT" ]; then
    header "🔐 ШИФРОВАНИЕ (age)" >&2
    local Z
    for Z in "$BD"/*.tar.zst; do
      [ -e "$Z" ] || continue
      if guard age -r "$AGE_RECIPIENT" -o "$Z.age" "$Z"; then
        [ "$DRY_RUN" = true ] || rm -f "$Z"
        success "🔐 $(basename "$Z").age ✅" >&2
      else
        error "Шифрование $(basename "$Z") не удалось ❌" >&2; log "❌ age failed"; rm -rf "$STAGE"; return 1
      fi
    done
    ENC_STATE="true"
  elif [ "${ENCRYPT:-false}" = "true" ]; then
    warn "ENCRYPT=true, но AGE_RECIPIENT пуст — шифрование ПРОПУЩЕНО! Настройте ключ (Настройки → 9)." >&2
  fi

  # ---- Манифест + контрольные суммы (по итоговому набору файлов) ----
  ( cd "$BD" && sha256sum *.tar.zst* > SHA256SUMS 2>/dev/null ) || true
  {
    echo "bedolaga-backup-format: 3"
    echo "created: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "timestamp: $TS"
    echo "role: ${ROLE:-all}"
    echo "scope: ${SCOPE:-all}"
    echo "host: $(hostname)"
    echo "encrypted: $ENC_STATE"
    echo "pg_user: $PG_USER"
    echo "pg_db: $PG_DB"
    echo "components:$(cd "$BD" && for f in *.tar.zst *.tar.zst.age; do [ -e "$f" ] && printf ' %s' "$(basename "$f" | sed "s/-$TS\.tar\.zst\(\.age\)\?//")"; done)"
  } > "$BD/manifest.txt"
  success "Манифест и SHA256SUMS записаны ✅" >&2
  rm -rf "$STAGE"

  local SCP_STATUS=0
  upload_all "$BD" || SCP_STATUS=1

  log "Бэкап: $BD"
  rotate_local_backups
  rotate_remote_backups
  rotate_s3_backups

  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    local ELAPSED=$(( $(date +%s) - BACKUP_START ))
    local ELAPSED_FMT
    [ "$ELAPSED" -ge 60 ] && ELAPSED_FMT="$((ELAPSED/60))м $((ELAPSED%60))с" || ELAPSED_FMT="${ELAPSED}с"

    local FILES_INFO="" FSZ ARCH
    for ARCH in "$BD"/*.tar.zst*; do
      [ -e "$ARCH" ] || continue
      FSZ=$(ls -lh "$ARCH" | awk '{print $5}')
      FILES_INFO="${FILES_INFO}  ✅ $(basename "$ARCH") (${FSZ})"$'\n'
    done
    [ -z "$FILES_INFO" ] && FILES_INFO="  ❌ архивы не созданы"$'\n'
    [ "${ENCRYPT:-false}" = "true" ] && [ -n "$AGE_RECIPIENT" ] && FILES_INFO="${FILES_INFO}  🔐 зашифровано age"$'\n'

    local RAM_FREE; RAM_FREE=$(free -h | awk '/^Mem:/{print $7}')
    local DISK_FREE; DISK_FREE=$(df -h /root | awk 'NR==2{print $4}')
    local SRV_UPTIME; SRV_UPTIME=$(uptime -p 2>/dev/null || uptime)
    local DOCKER_STATUS; DOCKER_STATUS=$(docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null)
    local LOCAL_CNT; LOCAL_CNT=$(ls -1d /root/bedolaga-local-backups/bedolaga-full-backup-* 2>/dev/null | wc -l)

    check_updates
    check_smtp
    local TG_MSG
    TG_MSG="🤖 <b>Bedolaga Backup</b> — $(date '+%Y-%m-%d %H:%M')

📦 <b>Файлы:</b>
${FILES_INFO}
💾 <b>Система:</b>
  RAM (avail): ${RAM_FREE}
  Диск (free): ${DISK_FREE}
  Uptime: ${SRV_UPTIME}

🐳 <b>Контейнеры:</b>
${DOCKER_STATUS}

📡 <b>Назначения:</b>
${UPLOAD_SUMMARY}🗂 <b>Бэкапов хранится (локально):</b> ${LOCAL_CNT}
⏱ <b>Время выполнения:</b> ${ELAPSED_FMT}
📧 <b>SMTP:</b> ${SMTP_CHECK_RESULT}

${CHECK_UPDATES_RESULT}"

    send_telegram "$TG_MSG"
  fi

  return $SCP_STATUS
}


save_custom_files() {
  local PROJECT_DIR="$1" SUBDIR="$2"
  [ -f "$CUSTOM_FILES" ] || return 0
  local DEST="$CUSTOM_TMP/$SUBDIR"
  mkdir -p "$DEST"
  while IFS= read -r LINE; do
    LINE="$(echo "$LINE" | sed 's/#.*//' | xargs)"
    [ -z "$LINE" ] && continue
    local SRC
    if [[ "$LINE" = /* ]]; then
      SRC="$LINE"
    else
      SRC="$PROJECT_DIR/$LINE"
    fi
    if [ -e "$SRC" ]; then
      local REL_DEST="$DEST/$(dirname "$LINE")"
      mkdir -p "$REL_DEST"
      cp -a "$SRC" "$REL_DEST/"
      log "🔒 Защищён: $LINE"
    fi
  done < "$CUSTOM_FILES"
}

restore_custom_files() {
  local PROJECT_DIR="$1" SUBDIR="$2"
  [ -f "$CUSTOM_FILES" ] || return 0
  local SRC_BASE="$CUSTOM_TMP/$SUBDIR"
  [ -d "$SRC_BASE" ] || return 0
  while IFS= read -r LINE; do
    LINE="$(echo "$LINE" | sed 's/#.*//' | xargs)"
    [ -z "$LINE" ] && continue
    local SRC="$SRC_BASE/$LINE"
    if [ -e "$SRC" ]; then
      local DEST_DIR
      if [[ "$LINE" = /* ]]; then
        DEST_DIR="$(dirname "$LINE")"
      else
        DEST_DIR="$PROJECT_DIR/$(dirname "$LINE")"
      fi
      mkdir -p "$DEST_DIR"
      cp -a "$SRC" "$DEST_DIR/"
      log "✅ Восстановлен: $LINE"
    fi
  done < "$CUSTOM_FILES"
}

# ===== ОБНОВЛЕНИЕ =====
do_update() {
  header "🔄 ОБНОВЛЕНИЕ" >&2
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] Обновление пропущено: git reset --hard + docker compose пересборка бота/кабинета/caddy не выполняются" >&2
    return 0
  fi
  info "Запуск..." >&2
  CUSTOM_TMP="/tmp/bedolaga-custom-$(date +%s)"
  mkdir -p "$CUSTOM_TMP"

  if want_component bot; then
  info "Бот..." >&2; cd "$BOT_DIR" || { error "Папка бота не найдена" >&2; return 1; }
  save_custom_files "$BOT_DIR" "bot"
  _branch=$(git remote show origin | awk '/HEAD branch/{print $NF}')
  git fetch origin && git reset --hard "origin/$_branch"
  restore_custom_files "$BOT_DIR" "bot"
  docker compose down
  docker compose up -d --build bot
  sleep 10
  if docker compose ps | grep -q "remnawave_bot.*(healthy)"; then success "Бот: healthy ✅" >&2; else warn "Бот: проверка ⚠️" >&2; docker compose logs --tail=20 bot||true; fi
  else
    info "Бот: обновление пропущено (scope=$SCOPE, role=$ROLE)" >&2
  fi

  if want_component cabinet; then
  info "Кабинет..." >&2; cd "$CABINET_DIR" || { error "Папка кабинета не найдена" >&2; return 1; }
  save_custom_files "$CABINET_DIR" "cabinet"
  _branch=$(git remote show origin | awk '/HEAD branch/{print $NF}')
  git fetch origin && git reset --hard "origin/$_branch"
  restore_custom_files "$CABINET_DIR" "cabinet"
  npm install --silent
  npm run build --silent
  docker compose up -d --build cabinet-frontend
  sleep 15
  if docker exec cabinet_frontend wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ 2>&1 | grep -qE "200|exists|connected"; then success "Кабинет: healthy ✅" >&2; else warn "Кабинет: проверка ⚠️" >&2; docker compose logs --tail=30 cabinet-frontend||true; fi
  else
    info "Кабинет: обновление пропущено (scope=$SCOPE, role=$ROLE)" >&2
  fi

  info "Caddy..." >&2
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose down && docker compose up -d --build && success "Caddy ✅" >&2
  else
    docker restart remnawave_caddy 2>/dev/null && success "Caddy ✅" >&2 || info "Caddy: нет" >&2
  fi

  rm -rf "$CUSTOM_TMP"
  log "Обновление завершено"; return 0
}

# ===== ПРОВЕРКА SMTP =====
SMTP_CHECK_RESULT=""
check_smtp() {
  local ENV_FILE="$BOT_DIR/.env"
  [ -f "$ENV_FILE" ] || { SMTP_CHECK_RESULT="⚪ SMTP: .env не найден"; return 0; }

  local HOST SMTP_U PASS PORT TLS
  HOST=$(grep -E '^SMTP_HOST=' "$ENV_FILE" | cut -d= -f2 | xargs)
  SMTP_U=$(grep -E '^SMTP_USER=' "$ENV_FILE" | cut -d= -f2 | xargs)
  PASS=$(grep -E '^SMTP_PASSWORD=' "$ENV_FILE" | cut -d= -f2 | xargs)
  PORT=$(grep -E '^SMTP_PORT=' "$ENV_FILE" | cut -d= -f2 | xargs)
  TLS=$(grep -E '^SMTP_USE_TLS=' "$ENV_FILE" | cut -d= -f2 | xargs)
  PORT="${PORT:-587}"

  if [ -z "$HOST" ] || [ -z "$SMTP_U" ] || [ -z "$PASS" ]; then
    SMTP_CHECK_RESULT="⚪ SMTP: не настроен"
    return 0
  fi

  info "SMTP: проверка $SMTP_U@$HOST:$PORT..." >&2

  local RESULT
  RESULT=$(docker exec \
    -e SMTP_HOST="$HOST" \
    -e SMTP_PORT="$PORT" \
    -e SMTP_USER="$SMTP_U" \
    -e SMTP_PASSWORD="$PASS" \
    -e SMTP_USE_TLS="$TLS" \
    remnawave_bot python3 -c '
import smtplib, os
host = os.environ["SMTP_HOST"]
port = int(os.environ["SMTP_PORT"])
user = os.environ["SMTP_USER"]
password = os.environ["SMTP_PASSWORD"]
use_tls = os.environ["SMTP_USE_TLS"].lower() in ("true", "1", "yes")
try:
    if port == 465:
        s = smtplib.SMTP_SSL(host, port, timeout=15)
        s.ehlo()
    else:
        s = smtplib.SMTP(host, port, timeout=15)
        s.ehlo()
        if use_tls:
            s.starttls()
            s.ehlo()
    s.login(user, password)
    s.quit()
    print("OK")
except Exception as e:
    print(f"FAIL:{e}")
' 2>&1) || true

  if [ -z "$RESULT" ]; then
    SMTP_CHECK_RESULT="⚪ SMTP: контейнер недоступен"
    warn "SMTP: контейнер remnawave_bot недоступен ⚠️" >&2
  elif [ "$RESULT" = "OK" ]; then
    SMTP_CHECK_RESULT="✅ SMTP: $SMTP_U@$HOST:$PORT — OK 🟢"
    success "SMTP: авторизация успешна 🟢" >&2
  else
    local ERR="${RESULT#FAIL:}"
    SMTP_CHECK_RESULT="❌ SMTP: $SMTP_U@$HOST:$PORT — $ERR"
    error "SMTP: $ERR ❌" >&2
    HEALTH_WARN=1
  fi
}

# ===== ПРОВЕРКА =====
do_check() {
  header "✅ ПРОВЕРКА" >&2
  info "Контейнеры:" >&2
  local DOCKER_OUT=$(docker ps --format '{{.Names}}\t{{.Status}}' | grep -E "remnawave|cabinet" || true)
  echo "$DOCKER_OUT" | tee -a "$REPORT_FILE" >&2
  if echo "$DOCKER_OUT" | grep -q "(unhealthy)"; then
    if [ -n "$PRIMARY_DOMAIN" ] && curl -s -o /dev/null -w "%{http_code}" "https://$PRIMARY_DOMAIN" | grep -q "200"; then
      warn "Контейнер помечен (unhealthy), но сайт отвечает ✅ (проверьте healthcheck в docker-compose.yml)" >&2
    else
      warn "Есть контейнеры в статусе (unhealthy)" >&2
    fi
    HEALTH_WARN=1
  else
    success "Все контейнеры работают штатно 🟢" >&2
  fi
  [ -n "$PRIMARY_DOMAIN" ] && { info "Кабинет: $PRIMARY_DOMAIN..." >&2; curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$PRIMARY_DOMAIN" | grep -q "200" && success "Кабинет: 200 🟢" >&2 || { error "Кабинет: не отвечает ❌" >&2; }; }
  [ -n "$HOOKS_DOMAIN" ] && { info "API: $HOOKS_DOMAIN..." >&2; local AC; AC=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 --max-time 10 "https://$HOOKS_DOMAIN" 2>/dev/null); AC="${AC:-000}"; [[ "$AC" =~ ^(200|404|405|401|403)$ ]] && success "API: $AC 🟢" >&2 || { error "API: код $AC ❌" >&2; }; }
  check_smtp
  return 0
}

# ===== ОТЧЁТ =====
show_report() {
  local CODE="${1:-0}"
  header "📊 ОТЧЁТ" >&2; echo "Время: $(date '+%Y-%m-%d %H:%M:%S')"; echo "Файл: $REPORT_FILE"; echo ""; cat "$REPORT_FILE"; echo ""
  if [ "$CODE" -eq 0 ]; then
    success "🎉 Операции выполнены успешно!" >&2
    [ $HEALTH_WARN -eq 1 ] && warn "⚠️ Обратите внимание: есть контейнеры в статусе (unhealthy)" >&2
  else
    error "❌ Операция завершилась с ошибками" >&2
  fi
}

# ===== СКАЧИВАНИЕ БЭКАПА С УДАЛЁННОГО ИСТОЧНИКА (SSH/S3) =====
FETCHED_TMP=""
fetch_remote_backup() {
  local SRC="$1" NAMES=() NAME
  if [ "$SRC" = ssh ]; then
    [ -z "$BACKUP_SERVER" ] && { error "SSH-сервер не настроен" >&2; return 1; }
    local SSH="ssh -i $SSH_KEY -p $BACKUP_SSH_PORT -o StrictHostKeyChecking=no ${BACKUP_USER}@${BACKUP_SERVER}"
    mapfile -t NAMES < <($SSH "ls -1d ${BACKUP_REMOTE_DIR}/bedolaga-full-backup-* 2>/dev/null" 2>/dev/null | while read -r p; do basename "$p"; done | sort)
  else
    { [ -z "$RCLONE_REMOTE" ] || [ -z "$S3_BUCKET" ]; } && { error "S3 не настроен" >&2; return 1; }
    mapfile -t NAMES < <(rclone lsf --dirs-only "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}" 2>/dev/null | sed 's#/$##' | grep '^bedolaga-full-backup-' | sort)
  fi
  [ ${#NAMES[@]} -eq 0 ] && { error "На источнике ($SRC) бэкапов не найдено" >&2; return 1; }
  info "Доступные бэкапы на источнике ($SRC):" >&2
  local i; for i in "${!NAMES[@]}"; do echo "  $((i+1))) ${NAMES[$i]}" >&2; done
  local SEL; read -p "Выбор [1-${#NAMES[@]}]: " SEL >&2
  { [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le ${#NAMES[@]} ]; } || { error "Неверный выбор" >&2; return 1; }
  NAME="${NAMES[$((SEL-1))]}"
  FETCHED_TMP=$(mktemp -d "/tmp/bedolaga-fetch-XXXXXX")
  info "Скачивание $NAME..." >&2
  if [ "$SRC" = ssh ]; then
    scp -i "$SSH_KEY" -P "$BACKUP_SSH_PORT" -r -o StrictHostKeyChecking=no "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/${NAME}" "$FETCHED_TMP/" >&2 \
      || { error "scp: не удалось скачать" >&2; return 1; }
  else
    rclone copy "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/${NAME}" "$FETCHED_TMP/${NAME}" >&2 \
      || { error "rclone: не удалось скачать" >&2; return 1; }
  fi
  success "Скачано во временную папку ✅" >&2
  echo "$FETCHED_TMP/$NAME"
}

# ===== SELF-TEST ВОССТАНОВЛЕНИЯ (--verify-restore) =====
do_verify_restore() {
  header "🔎 ПРОВЕРКА ВОССТАНОВЛЕНИЯ (self-test, без стенда)" >&2
  local BASE="/root/bedolaga-local-backups" BD RC=0
  BD=$(find "$BASE" -maxdepth 1 -type d -name "bedolaga-full-backup-*" | sort | tail -1)
  [ -z "$BD" ] && { error "Нет локальных бэкапов для проверки" >&2; return 1; }
  info "Проверяем последний бэкап: $(basename "$BD")" >&2

  # --- Уровень 1: целостность файлов ---
  if [ -f "$BD/SHA256SUMS" ]; then
    ( cd "$BD" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && success "SHA256: ✅" >&2 || { error "SHA256: ❌" >&2; RC=1; }
  fi
  local ENCRYPTED=false; ls "$BD"/*.tar.zst.age >/dev/null 2>&1 && ENCRYPTED=true
  local KEYFILE=""
  if [ "$ENCRYPTED" = true ]; then
    KEYFILE=$(obtain_age_key) || { error "Нет ключа — проверка зашифрованного бэкапа невозможна" >&2; return 1; }
  fi
  local TMP; TMP=$(mktemp -d) A GOTDUMP=""
  for A in "$BD"/bot-*.tar.zst*; do
    [ -e "$A" ] || continue
    if [ "$ENCRYPTED" = true ]; then
      age -d -i "$KEYFILE" "$A" 2>/dev/null | zstd -dc 2>/dev/null | tar -x -C "$TMP" 2>/dev/null \
        && success "bot: расшифровка+распаковка ✅" >&2 || { error "bot: расшифровка/распаковка ❌" >&2; RC=1; }
    else
      zstd -tq "$A" 2>/dev/null && zstd -dc "$A" 2>/dev/null | tar -x -C "$TMP" 2>/dev/null \
        && success "bot: целостность+распаковка ✅" >&2 || { error "bot: распаковка ❌" >&2; RC=1; }
    fi
  done
  [ -f "$TMP/bot/postgres.dump" ] && GOTDUMP="$TMP/bot/postgres.dump"
  # обратная совместимость: v2 (россыпь) — дамп лежит прямо в бэкапе
  [ -z "$GOTDUMP" ] && [ -f "$BD/bot/postgres.dump" ] && { GOTDUMP="$BD/bot/postgres.dump"; info "Формат v2: дамп взят напрямую" >&2; }
  detect_pg_credentials
  if [ -n "$GOTDUMP" ]; then
    docker exec -i "$PG_CONTAINER" pg_restore --list < "$GOTDUMP" >/dev/null 2>&1 \
      && success "pg_restore --list: дамп валиден ✅" >&2 || { error "pg_restore --list: дамп повреждён ❌" >&2; RC=1; }
  else
    warn "Дамп бота не найден (возможно scope=cabinet) — уровень 2 пропущен" >&2
  fi

  # --- Уровень 2: восстановление в ОДНОРАЗОВЫЙ контейнер (боевую БД не трогаем) ---
  if [ -n "$GOTDUMP" ]; then
    info "Уровень 2: pg_restore в изолированный тест-контейнер..." >&2
    local CN="bedolaga_restoretest_$$"
    docker rm -f "$CN" >/dev/null 2>&1 || true
    if docker run -d --name "$CN" -e POSTGRES_PASSWORD=verifytest -e POSTGRES_USER="$PG_USER" -e POSTGRES_DB="$PG_DB" postgres:15-alpine >/dev/null 2>&1; then
      local i; for i in $(seq 1 30); do docker exec "$CN" pg_isready -U "$PG_USER" >/dev/null 2>&1 && break; sleep 1; done
      # pg_restore выдаёт варнинги (роли/расширения) и код !=0 даже при успехе —
      # критерий успеха: в public появились таблицы, а не exit-код.
      docker exec -i "$CN" pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists < "$GOTDUMP" >/dev/null 2>&1 || true
      local TBLS; TBLS=$(docker exec "$CN" psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs)
      if [ -n "$TBLS" ] && [ "$TBLS" -gt 0 ] 2>/dev/null; then
        success "Восстановление в тест-контейнер ✅ (таблиц public: $TBLS)" >&2
      else
        error "pg_restore в тест-контейнер: таблицы не создались ❌" >&2; RC=1
      fi
      docker rm -f "$CN" >/dev/null 2>&1 && success "Тест-контейнер удалён ✅" >&2 || true
    else
      warn "Не удалось поднять тест-контейнер — уровень 2 пропущен" >&2
    fi
  fi

  rm -rf "$TMP"; [ -n "$AGE_KEY_TMP" ] && rm -f "$AGE_KEY_TMP"
  if [ "$RC" -eq 0 ]; then success "✅ Проверка восстановления ПРОЙДЕНА" >&2; else error "❌ Проверка выявила проблемы" >&2; fi
  send_telegram "🔎 <b>Bedolaga verify-restore</b> — $(date '+%Y-%m-%d %H:%M')
Бэкап: $(basename "$BD")
Итог: $([ "$RC" -eq 0 ] && echo '✅ OK' || echo '❌ проблемы — см. лог')"
  return $RC
}

# ===== ВОССТАНОВЛЕНИЕ =====
do_restore() {
  header "🔁 ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА" >&2
  if [ "$DRY_RUN" = true ]; then
    warn "[dry-run] Восстановление недоступно в режиме --dry-run (это разрушающая операция). Запустите без --dry-run." >&2
    return 0
  fi

  # Выбор источника бэкапа: локально / SSH / S3
  echo "Откуда восстанавливаем?" >&2
  echo "  1) Локально (/root/bedolaga-local-backups)" >&2
  echo "  2) SSH-сервер (${BACKUP_USER:-?}@${BACKUP_SERVER:-не задан})" >&2
  echo "  3) S3 (${RCLONE_REMOTE:+${RCLONE_REMOTE}:${S3_BUCKET}})" >&2
  read -p "Выбор [1-3, по умолчанию 1]: " RSRC >&2

  local BD
  case "$RSRC" in
    2) BD=$(fetch_remote_backup ssh) || return 1 ;;
    3) BD=$(fetch_remote_backup s3)  || return 1 ;;
    *)
      local BACKUP_BASE="/root/bedolaga-local-backups"
      local BACKUPS=()
      while IFS= read -r d; do BACKUPS+=("$d"); done < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name "bedolaga-full-backup-*" | sort)
      if [ ${#BACKUPS[@]} -eq 0 ]; then
        error "Локальных бэкапов не найдено в $BACKUP_BASE" >&2; return 1
      fi
      info "Доступные бэкапы:" >&2
      for i in "${!BACKUPS[@]}"; do
        local SZ; SZ=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | awk '{print $1}')
        local DT; DT=$(basename "${BACKUPS[$i]}" | sed 's/bedolaga-full-backup-//')
        echo "  $((i+1))) $DT  ($SZ)" >&2
      done
      echo "" >&2
      read -p "📌 Выберите номер бэкапа [1-${#BACKUPS[@]}]: " SEL >&2
      if [[ ! "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "${#BACKUPS[@]}" ]; then
        error "Неверный выбор" >&2; return 1
      fi
      BD="${BACKUPS[$((SEL-1))]}"
      ;;
  esac
  info "Выбран: $(basename "$BD")" >&2

  echo "" >&2
  read -p "⚠️  Восстановление ПЕРЕЗАПИШЕТ текущие данные. Продолжить? [y/N]: " C1 >&2
  [[ "$C1" =~ ^[Yy]$ ]] || { info "Отменено" >&2; return 0; }

  read -p "⚠️  Папки бота и кабинета будут перезаписаны. Вы уверены? [y/N]: " C2 >&2
  [[ "$C2" =~ ^[Yy]$ ]] || { info "Отменено" >&2; return 0; }

  read -p "⚠️  ПОСЛЕДНИЙ ШАНС. Введите слово RESTORE для подтверждения: " C3 >&2
  [ "$C3" = "RESTORE" ] || { info "Отменено" >&2; return 0; }

  log "🔁 Начало восстановления из $(basename "$BD")"

  # Определяем источник файлов: новый формат (компонентные архивы v3, возможно .age) или старый (россыпь v2)
  local SRC SRC_TMP="" ENCRYPTED=false
  ls "$BD"/*.tar.zst.age >/dev/null 2>&1 && ENCRYPTED=true
  if ls "$BD"/*.tar.zst* >/dev/null 2>&1; then
    if [ "$ENCRYPTED" = true ]; then info "Формат бэкапа: компонентные архивы v3 🔐 (зашифровано age)" >&2
    else info "Формат бэкапа: компонентные архивы v3" >&2; fi
    if [ -f "$BD/SHA256SUMS" ]; then
      if ( cd "$BD" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
        success "SHA256: контрольные суммы совпали ✅" >&2
      else
        error "SHA256: контрольные суммы НЕ совпали — архив повреждён ❌" >&2
        read -p "Всё равно продолжить восстановление? [y/N]: " CX >&2
        [[ "$CX" =~ ^[Yy]$ ]] || { info "Отменено" >&2; return 1; }
      fi
    fi
    local KEYFILE=""
    if [ "$ENCRYPTED" = true ]; then
      KEYFILE=$(obtain_age_key) || { error "Без приватного age-ключа зашифрованный бэкап восстановить нельзя." >&2; return 1; }
    fi
    SRC_TMP=$(mktemp -d "/tmp/bedolaga-restore-XXXXXX"); SRC="$SRC_TMP"
    local A
    for A in "$BD"/*.tar.zst*; do
      [ -e "$A" ] || continue
      info "Распаковка $(basename "$A")..." >&2
      if [ "$ENCRYPTED" = true ]; then
        age -d -i "$KEYFILE" "$A" 2>/dev/null | zstd -dc | tar -x -C "$SRC" \
          || { error "Ошибка расшифровки/распаковки $(basename "$A") ❌ (неверный ключ?)" >&2; rm -rf "$SRC_TMP"; [ -n "$AGE_KEY_TMP" ] && rm -f "$AGE_KEY_TMP"; return 1; }
      else
        zstd -dc "$A" | tar -x -C "$SRC" \
          || { error "Ошибка распаковки $(basename "$A") ❌" >&2; rm -rf "$SRC_TMP"; return 1; }
      fi
    done
    success "Архивы распакованы ✅" >&2
  else
    info "Формат бэкапа: россыпь файлов (v2, обратная совместимость)" >&2
    SRC="$BD"
  fi

  info "Остановка контейнеров..." >&2
  cd "$BOT_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
  cd "$CABINET_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
  [ -n "$CADDY_DIR" ] && cd "$CADDY_DIR" 2>/dev/null && docker compose down 2>/dev/null || true

  info "Восстановление конфигов бота..." >&2
  cp "$SRC/bot/.env" "$BOT_DIR/.env" && success ".env бота ✅" >&2 || error ".env бота ❌" >&2
  cp "$SRC/bot/docker-compose.yml" "$BOT_DIR/docker-compose.yml" && success "docker-compose.yml ✅" >&2 || error "docker-compose.yml ❌" >&2

  info "Восстановление PostgreSQL..." >&2
  detect_pg_credentials
  if [ -f "$SRC/bot/postgres.dump" ]; then
    docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists < "$SRC/bot/postgres.dump" \
      && success "PostgreSQL ✅" >&2 || error "PostgreSQL ❌" >&2
  else warn "PostgreSQL: файл postgres.dump не найден, пропущено" >&2; fi

  info "Восстановление Redis..." >&2
  local RV; RV=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$RV" ] && [ -f "$SRC/bot/redis_data.tar.gz" ]; then
    docker run --rm -v "$RV":/target -v "$SRC/bot":/backup alpine sh -c "rm -rf /target/* && tar -xzf /backup/redis_data.tar.gz -C /target" \
      && success "Redis ✅" >&2 || error "Redis ❌" >&2
  else warn "Redis: том или архив не найден, пропущено" >&2; fi

  info "Восстановление кабинета..." >&2
  [ -f "$SRC/cabinet/.env" ] && cp "$SRC/cabinet/.env" "$CABINET_DIR/.env" && success "cabinet/.env ✅" >&2 || warn "cabinet/.env не найден" >&2
  [ -d "$SRC/cabinet/src" ] && cp -r "$SRC/cabinet/src" "$CABINET_DIR/" && success "cabinet/src ✅" >&2 || warn "cabinet/src не найден" >&2

  if [ -n "$CADDY_DIR" ] && [ -f "$SRC/caddy/Caddyfile" ]; then
    cp "$SRC/caddy/Caddyfile" "$CADDY_DIR/Caddyfile" && success "Caddyfile ✅" >&2 || error "Caddyfile ❌" >&2
  fi

  info "Запуск контейнеров..." >&2
  cd "$BOT_DIR" && docker compose up -d && success "Бот запущен ✅" >&2 || error "Бот не запустился ❌" >&2
  cd "$CABINET_DIR" && docker compose up -d && success "Кабинет запущен ✅" >&2 || error "Кабинет не запустился ❌" >&2
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose up -d && success "Caddy запущен ✅" >&2 || error "Caddy не запустился ❌" >&2
  fi

  sleep 5
  do_check

  local DT_LABEL; DT_LABEL=$(basename "$BD" | sed 's/bedolaga-full-backup-//')
  send_telegram "🔁 <b>Bedolaga Restore</b> — $(date '+%Y-%m-%d %H:%M')

Восстановление из бэкапа <b>${DT_LABEL}</b> выполнено.
Проверьте контейнеры и работоспособность сервисов."

  [ -n "$SRC_TMP" ] && rm -rf "$SRC_TMP"
  [ -n "$AGE_KEY_TMP" ] && rm -f "$AGE_KEY_TMP"
  [ -n "$FETCHED_TMP" ] && rm -rf "$FETCHED_TMP"
  log "✅ Восстановление завершено"
}

# ===== БЛОКИРОВКА (flock) — не даём двум запускам идти параллельно =====
LOCK_FILE="/var/lock/bedolaga-backup.lock"
exec 9>"$LOCK_FILE" 2>/dev/null || exec 9>"/tmp/bedolaga-backup.lock"
if ! flock -n 9; then
  warn "Другой экземпляр bedolaga-update уже выполняется — пропуск этого запуска." >&2
  log "⏭ Пропуск: параллельный запуск заблокирован flock" 2>/dev/null || true
  exit 0
fi

# ===== SELF-TEST (--verify-restore) — отдельный режим, минуя обычный цикл =====
if [ "$VERIFY_RESTORE" = true ]; then
  do_verify_restore; VR=$?
  show_report "$VR"
  exit $VR
fi

# ===== ЦИКЛ =====
[ "$DRY_RUN" = true ] && header "🧪 РЕЖИМ DRY-RUN — реальные изменения НЕ выполняются (scp/ssh/rm/docker/git/telegram)" >&2
GLOBAL_EXIT=0
case $ACT in
  1) do_backup || GLOBAL_EXIT=1 ;;
  2) do_update || GLOBAL_EXIT=1 ;;
  3) do_backup || GLOBAL_EXIT=1
     if [ $GLOBAL_EXIT -eq 0 ]; then
       echo "" >&2; read -p "✅ Бэкап готов. Обновить? [y/N]: " C >&2
       if [[ "$C" =~ ^[Yy]$ ]]; then do_update || GLOBAL_EXIT=1; else info "Обновление отменено" >&2; fi
     fi
     ;;
  5) do_restore || GLOBAL_EXIT=1 ;;
esac

# Гарантированное уведомление о сбое (закрывает «тихие» провалы бэкапа)
if [ "$GLOBAL_EXIT" -ne 0 ]; then notify_failure "$GLOBAL_EXIT" "действие $ACT"; fi

rotate_reports
do_check
show_report "$GLOBAL_EXIT"
exit $GLOBAL_EXIT
