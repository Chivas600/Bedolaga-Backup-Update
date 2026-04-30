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
[[ "${1:-}" == "--cron" ]] && CRON_MODE=true
SSH_KEY="/root/.ssh/id_backup"
HEALTH_WARN=0

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
  prompt_path "бот" "$FOUND_BOT" "bot" && BOT_DIR="$PROMPT_PATH_RESULT"
  prompt_path "кабинет" "$FOUND_CABINET" "cabinet" && CABINET_DIR="$PROMPT_PATH_RESULT"

  echo "" >&2
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

  echo "" >&2; info "Проверка путей..." >&2
  [ -d "$BOT_DIR" ] && success "Бот: $BOT_DIR ✅" >&2 || { error "Бот: папка не существует ❌" >&2; return 1; }
  [ -d "$CABINET_DIR" ] && success "Кабинет: $CABINET_DIR ✅" >&2 || { error "Кабинет: папка не существует ❌" >&2; return 1; }
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
BOT_DIR="$BOT_DIR"
CABINET_DIR="$CABINET_DIR"
CADDY_DIR="$CADDY_DIR"
PRIMARY_DOMAIN="$PRIMARY_DOMAIN"
HOOKS_DOMAIN="$HOOKS_DOMAIN"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
TG_THREAD_ID="$TG_THREAD_ID"
CONF
  chmod 600 "$CONFIG_FILE"
  success "Все настройки сохранены ✅" >&2
}

# ===== ПРОВЕРКА КРИТИЧНЫХ НАСТРОЕК =====
check_critical_config() {
  local MISSING=()
  [ -z "$BACKUP_SERVER" ] && MISSING+=("BACKUP_SERVER")
  [ -z "$BOT_DIR" ] && MISSING+=("BOT_DIR")
  [ -z "$CABINET_DIR" ] && MISSING+=("CABINET_DIR")
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
      info "Удаляем: $DT ($SZ)..." >&2; rm -rf "$OLD" && success "Удалён ✅" >&2 || error "Ошибка ❌" >&2
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
  local SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no ${BACKUP_USER}@${BACKUP_SERVER}"

  local ALL=$($SSH "ls -1d ${BACKUP_REMOTE_DIR}/bedolaga-full-backup-* 2>/dev/null | sort" || true)
  [ -z "$ALL" ] && { info "На удалённом сервере нет бэкапов ✅" >&2; return 0; }

  local CNT=$(echo "$ALL" | wc -l)
  info "Найдено бэкапов: $CNT (лимит: $RET)" >&2

  if [ "$CNT" -gt "$RET" ]; then
    local DEL=$((CNT - RET))
    info "Удаляем $DEL старых..." >&2
    local DEL_LIST=$(echo "$ALL" | head -n "$DEL" | tr '\n' ' ')
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

# ===== ЗАГРУЗКА ИЛИ СОЗДАНИЕ КОНФИГА =====
NEED_FULL_SETUP=false

if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  info "Настройки загружены из $CONFIG_FILE" >&2
  BACKUP_USER="${BACKUP_USER:-root}"
  BACKUP_REMOTE_DIR="${BACKUP_REMOTE_DIR:-/root/bedolaga-backups}"
  BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
  [[ ! "$BACKUP_RETENTION" =~ ^[0-9]+$ ]] && BACKUP_RETENTION=7
  if ! check_critical_config; then
    warn "Конфиг неполный — запускаю полную настройку..." >&2
    NEED_FULL_SETUP=true
  fi
else
  NEED_FULL_SETUP=true
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
  read -p "👤 Пользователь [root]: " U >&2; BACKUP_USER="${U:-root}"; [ -z "$U" ] && success "root" >&2
  read -p "📁 Путь бэкапов [/root/bedolaga-backups]: " P >&2; BACKUP_REMOTE_DIR="${P:-/root/bedolaga-backups}"; [ -z "$P" ] && success "по умолчанию" >&2
  read -p "📦 Хранить бэкапов [7]: " R >&2; BACKUP_RETENTION="${R:-7}"; [ -z "$R" ] && success "7" >&2
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
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$REPORT_FILE" >&2; }

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
  read -p "Выбор [1-6]: " SACT >&2
  [[ ! "$SACT" =~ ^[1-6]$ ]] && { error "Неверный выбор" >&2; return 1; }

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
      save_all_config
      ;;
    5)
      echo "" >&2
      info "Текущий cron:" >&2
      crontab -l 2>/dev/null | grep bedolaga >&2 || info "Cron не настроен" >&2
      echo "" >&2
      read -p "⏰ Час запуска [0-23]: " CH >&2
      read -p "⏰ Минута запуска [0-59]: " CM >&2
      if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 0 ] && [ "$CH" -le 23 ] && \
         [[ "$CM" =~ ^[0-9]+$ ]] && [ "$CM" -ge 0 ] && [ "$CM" -le 59 ]; then
        local SCRIPT_PATH; SCRIPT_PATH="$(realpath "$0")"
        local TMPFILE; TMPFILE=$(mktemp)
        crontab -l 2>/dev/null | grep -v bedolaga > "$TMPFILE"
        echo "$CM $CH * * * $SCRIPT_PATH --cron >> /root/bedolaga-cron.log 2>&1" >> "$TMPFILE"
        crontab "$TMPFILE"; rm -f "$TMPFILE"
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
  esac
}

# ===== ЗАГОЛОВОК И МЕНЮ =====
if [ "$CRON_MODE" = true ]; then
  log "🚀 Запуск (cron)"
  ACT=1
else
  clear; echo -e "\033[1;36m"
  echo "╔════════════════════════════════════╗"
  echo "║  🤖 Bedolaga: Обновление системы  ║"
  echo "╚════════════════════════════════════╝"
  echo -e "\033[0m"
  log "🚀 Запуск"; info "Сервер: ${BACKUP_USER:-?}@${BACKUP_SERVER:-НЕ УКАЗАН}" >&2; info "Бот: $BOT_DIR" >&2; info "Кабинет: $CABINET_DIR" >&2; info "Caddy: ${CADDY_DIR:-нет}" >&2

  echo "" >&2; echo "Действие:" >&2; echo "1) 🔒 Только бэкап" >&2; echo "2) 🔄 Только обновление" >&2; echo "3) ⚡ Бэкап + Обновление" >&2; echo "4) ⚙️ Настройки" >&2; echo "5) 🔁 Восстановление из бэкапа" >&2
  read -p "Выбор [1-5]: " ACT >&2
  [[ ! "$ACT" =~ ^[1-5]$ ]] && { error "Неверно" >&2; exit 1; }
  [ "$ACT" = "4" ] && { do_settings; exit 0; }
fi

# ===== ПРОВЕРКА ОБНОВЛЕНИЙ =====
CHECK_UPDATES_RESULT=""
check_updates() {
  local BOT_VER CABINET_VER BOT_LATEST CABINET_LATEST
  CHECK_UPDATES_RESULT=""

  BOT_VER=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' "$BOT_DIR/.env" 2>/dev/null | head -1)
  [ -z "$BOT_VER" ] && BOT_VER=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' "$BOT_DIR/docker-compose.yml" 2>/dev/null | head -1)

  CABINET_VER=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' "$CABINET_DIR/.env" 2>/dev/null | head -1)
  [ -z "$CABINET_VER" ] && CABINET_VER=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' "$CABINET_DIR/docker-compose.yml" 2>/dev/null | head -1)

  BOT_LATEST=$(curl -s "https://api.github.com/repos/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot/releases/latest" \
    | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  CABINET_LATEST=$(curl -s "https://api.github.com/repos/BEDOLAGA-DEV/bedolaga-cabinet/releases/latest" \
    | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  local UPDATES="" ALL_OK=true
  if [ -n "$BOT_LATEST" ] && [ -n "$BOT_VER" ] && [ "$BOT_VER" != "$BOT_LATEST" ]; then
    UPDATES="${UPDATES}  Бот: ${BOT_VER} → ${BOT_LATEST}\n"
    ALL_OK=false
  fi
  if [ -n "$CABINET_LATEST" ] && [ -n "$CABINET_VER" ] && [ "$CABINET_VER" != "$CABINET_LATEST" ]; then
    UPDATES="${UPDATES}  Кабинет: ${CABINET_VER} → ${CABINET_LATEST}\n"
    ALL_OK=false
  fi

  if [ "$ALL_OK" = true ]; then
    CHECK_UPDATES_RESULT="✅ Версии актуальны: Бот ${BOT_LATEST:-${BOT_VER:-?}}, Кабинет ${CABINET_LATEST:-${CABINET_VER:-?}}"
  else
    CHECK_UPDATES_RESULT="🆕 Доступны обновления:\n${UPDATES}Обновись: запусти bedolaga-update и выбери пункт 2 или 3"
  fi
}

# ===== БЭКАП =====
do_backup() {
  local BACKUP_START; BACKUP_START=$(date +%s)
  header "📦 БЭКАП" >&2; check_disk_space "/root" || return 1
  local BD="/root/bedolaga-local-backups/bedolaga-full-backup-$(date +%Y%m%d-%H%M)"
  mkdir -p "$BD/bot" "$BD/cabinet" "$BD/caddy"; log "Создано: $BD"

  info "Конфиги бота..." >&2; cd "$BOT_DIR" || { error "Папка бота не найдена" >&2; return 1; }
  cp .env docker-compose.yml "$BD/bot/"; check_backup_file "$BD/bot/.env" ".env"; check_backup_file "$BD/bot/docker-compose.yml" "docker-compose.yml"

  info "БД..." >&2; local PV=$(docker volume ls | grep postgres_data | awk '{print $2}')
  if [ -n "$PV" ]; then
    docker run --rm -v "$PV":/source -v "$BD/bot":/backup alpine tar -czf /backup/postgres_data.tar.gz -C /source .
    check_backup_file "$BD/bot/postgres_data.tar.gz" "PostgreSQL" || { error "Бэкап БД не создан!" >&2; return 1; }
  else error "Том БД не найден" >&2; fi

  info "Redis..." >&2; local RV=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$RV" ]; then
    docker run --rm -v "$RV":/source -v "$BD/bot":/backup alpine tar -czf /backup/redis_data.tar.gz -C /source .
    check_backup_file "$BD/bot/redis_data.tar.gz" "Redis"
  fi

  info "Кабинет..." >&2
  if [ -d "$CABINET_DIR" ]; then
    cd "$CABINET_DIR" 2>/dev/null && { cp .env package*.json "$BD/cabinet/" 2>/dev/null||true; cp -r src/ "$BD/cabinet/" 2>/dev/null||true; }
    [ -f "$BD/cabinet/.env" ] && success "Конфиг ✅" >&2||info "Конфиг не найден" >&2
    [ -d "$BD/cabinet/src" ] && success "Код ✅" >&2||info "Код не найден" >&2
  fi
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cp "$CADDY_DIR/Caddyfile" "$BD/caddy/" 2>/dev/null && success "Caddy ✅" >&2
  fi

  info "Копирование на сервер..." >&2
  local SCP_STATUS=0
  if [ -z "$BACKUP_SERVER" ]; then
    warn "Резервный сервер не указан. Копирование пропущено." >&2
  else
    scp -i "$SSH_KEY" -r -o StrictHostKeyChecking=no "$BD" "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/" \
      && success "Скопировано ✅" >&2 \
      || { error "Ошибка копирования ❌" >&2; log "❌ scp failed"; SCP_STATUS=1; }
  fi

  log "Бэкап: $BD"
  rotate_local_backups
  rotate_remote_backups

  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    local ELAPSED=$(( $(date +%s) - BACKUP_START ))
    local ELAPSED_FMT
    [ "$ELAPSED" -ge 60 ] && ELAPSED_FMT="$((ELAPSED/60))м $((ELAPSED%60))с" || ELAPSED_FMT="${ELAPSED}с"

    local FILES_INFO="" FP FSZ FNAME
    for FNAME in ".env" "docker-compose.yml" "postgres_data.tar.gz" "redis_data.tar.gz"; do
      FP="$BD/bot/$FNAME"
      if [ -f "$FP" ]; then
        FSZ=$(ls -lh "$FP" | awk '{print $5}')
        FILES_INFO="${FILES_INFO}  ✅ ${FNAME} (${FSZ})"$'\n'
      else
        FILES_INFO="${FILES_INFO}  ❌ ${FNAME} (нет)"$'\n'
      fi
    done
    FP="$BD/cabinet/.env"
    if [ -f "$FP" ]; then
      FSZ=$(ls -lh "$FP" | awk '{print $5}')
      FILES_INFO="${FILES_INFO}  ✅ cabinet/.env (${FSZ})"$'\n'
    else
      FILES_INFO="${FILES_INFO}  ⚪ cabinet/.env"$'\n'
    fi
    FP="$BD/caddy/Caddyfile"
    if [ -f "$FP" ]; then
      FSZ=$(ls -lh "$FP" | awk '{print $5}')
      FILES_INFO="${FILES_INFO}  ✅ Caddyfile (${FSZ})"$'\n'
    else
      FILES_INFO="${FILES_INFO}  ⚪ Caddyfile"$'\n'
    fi

    local RAM_FREE; RAM_FREE=$(free -h | awk '/^Mem:/{print $7}')
    local DISK_FREE; DISK_FREE=$(df -h /root | awk 'NR==2{print $4}')
    local SRV_UPTIME; SRV_UPTIME=$(uptime -p 2>/dev/null || uptime)
    local DOCKER_STATUS; DOCKER_STATUS=$(docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null)
    local LOCAL_CNT; LOCAL_CNT=$(ls -1d /root/bedolaga-local-backups/bedolaga-full-backup-* 2>/dev/null | wc -l)
    local SCP_TEXT
    [ "$SCP_STATUS" -eq 0 ] && SCP_TEXT="✅ OK (${BACKUP_USER}@${BACKUP_SERVER})" || SCP_TEXT="❌ Ошибка"

    check_updates
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

📡 <b>Копия на сервер:</b> ${SCP_TEXT}
🗂 <b>Бэкапов хранится:</b> ${LOCAL_CNT}
⏱ <b>Время выполнения:</b> ${ELAPSED_FMT}

${CHECK_UPDATES_RESULT}"

    send_telegram "$TG_MSG"
  fi

  return $SCP_STATUS
}

# ===== КАСТОМНЫЕ ФАЙЛЫ =====
CUSTOM_FILES="/root/.bedolaga-custom-files"

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
  header "🔄 ОБНОВЛЕНИЕ" >&2; info "Запуск..." >&2
  CUSTOM_TMP="/tmp/bedolaga-custom-$(date +%s)"
  mkdir -p "$CUSTOM_TMP"

  info "Бот..." >&2; cd "$BOT_DIR" || { error "Папка бота не найдена" >&2; return 1; }
  save_custom_files "$BOT_DIR" "bot"
  git fetch origin && git reset --hard origin/main
  restore_custom_files "$BOT_DIR" "bot"
  docker compose down
  docker compose up -d --build bot
  sleep 10
  if docker compose ps | grep -q "remnawave_bot.*healthy"; then success "Бот: healthy ✅" >&2; else warn "Бот: проверка ⚠️" >&2; docker compose logs --tail=20 bot||true; fi

  info "Кабинет..." >&2; cd "$CABINET_DIR" || { error "Папка кабинета не найдена" >&2; return 1; }
  save_custom_files "$CABINET_DIR" "cabinet"
  git fetch origin && git reset --hard origin/main
  restore_custom_files "$CABINET_DIR" "cabinet"
  npm install --silent
  npm run build --silent
  docker compose up -d --build cabinet-frontend
  sleep 15
  if docker exec cabinet_frontend wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ 2>&1 | grep -qE "200|exists|connected"; then success "Кабинет: healthy ✅" >&2; else warn "Кабинет: проверка ⚠️" >&2; docker compose logs --tail=30 cabinet-frontend||true; fi

  info "Caddy..." >&2
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose down && docker compose up -d --build && success "Caddy ✅" >&2
  else
    docker restart remnawave_caddy 2>/dev/null && success "Caddy ✅" >&2 || info "Caddy: нет" >&2
  fi

  rm -rf "$CUSTOM_TMP"
  log "Обновление завершено"; return 0
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
  [ -n "$PRIMARY_DOMAIN" ] && { info "Кабинет: $PRIMARY_DOMAIN..." >&2; curl -s -o /dev/null -w "%{http_code}" "https://$PRIMARY_DOMAIN" | grep -q "200" && success "Кабинет: 200 🟢" >&2 || { error "Кабинет: не отвечает ❌" >&2; }; }
  [ -n "$HOOKS_DOMAIN" ] && { info "API: $HOOKS_DOMAIN..." >&2; local AC=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 "https://$HOOKS_DOMAIN" 2>/dev/null||echo "000"); [[ "$AC" =~ ^(200|404|405|401|403)$ ]] && success "API: $AC 🟢" >&2 || { error "API: код $AC ❌" >&2; }; }
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

# ===== ВОССТАНОВЛЕНИЕ =====
do_restore() {
  header "🔁 ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА" >&2

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
  local BD="${BACKUPS[$((SEL-1))]}"
  info "Выбран: $(basename "$BD")" >&2

  echo "" >&2
  read -p "⚠️  Восстановление ПЕРЕЗАПИШЕТ текущие данные. Продолжить? [y/N]: " C1 >&2
  [[ "$C1" =~ ^[Yy]$ ]] || { info "Отменено" >&2; return 0; }

  read -p "⚠️  Папки бота и кабинета будут перезаписаны. Вы уверены? [y/N]: " C2 >&2
  [[ "$C2" =~ ^[Yy]$ ]] || { info "Отменено" >&2; return 0; }

  read -p "⚠️  ПОСЛЕДНИЙ ШАНС. Введите слово RESTORE для подтверждения: " C3 >&2
  [ "$C3" = "RESTORE" ] || { info "Отменено" >&2; return 0; }

  log "🔁 Начало восстановления из $(basename "$BD")"

  info "Остановка контейнеров..." >&2
  cd "$BOT_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
  cd "$CABINET_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
  [ -n "$CADDY_DIR" ] && cd "$CADDY_DIR" 2>/dev/null && docker compose down 2>/dev/null || true

  info "Восстановление конфигов бота..." >&2
  cp "$BD/bot/.env" "$BOT_DIR/.env" && success ".env бота ✅" >&2 || error ".env бота ❌" >&2
  cp "$BD/bot/docker-compose.yml" "$BOT_DIR/docker-compose.yml" && success "docker-compose.yml ✅" >&2 || error "docker-compose.yml ❌" >&2

  info "Восстановление PostgreSQL..." >&2
  local PV; PV=$(docker volume ls | grep postgres_data | awk '{print $2}')
  if [ -n "$PV" ] && [ -f "$BD/bot/postgres_data.tar.gz" ]; then
    docker run --rm -v "$PV":/target -v "$BD/bot":/backup alpine sh -c "rm -rf /target/* && tar -xzf /backup/postgres_data.tar.gz -C /target" \
      && success "PostgreSQL ✅" >&2 || error "PostgreSQL ❌" >&2
  else warn "PostgreSQL: том или архив не найден, пропущено" >&2; fi

  info "Восстановление Redis..." >&2
  local RV; RV=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$RV" ] && [ -f "$BD/bot/redis_data.tar.gz" ]; then
    docker run --rm -v "$RV":/target -v "$BD/bot":/backup alpine sh -c "rm -rf /target/* && tar -xzf /backup/redis_data.tar.gz -C /target" \
      && success "Redis ✅" >&2 || error "Redis ❌" >&2
  else warn "Redis: том или архив не найден, пропущено" >&2; fi

  info "Восстановление кабинета..." >&2
  [ -f "$BD/cabinet/.env" ] && cp "$BD/cabinet/.env" "$CABINET_DIR/.env" && success "cabinet/.env ✅" >&2 || warn "cabinet/.env не найден" >&2
  [ -d "$BD/cabinet/src" ] && cp -r "$BD/cabinet/src" "$CABINET_DIR/" && success "cabinet/src ✅" >&2 || warn "cabinet/src не найден" >&2

  if [ -n "$CADDY_DIR" ] && [ -f "$BD/caddy/Caddyfile" ]; then
    cp "$BD/caddy/Caddyfile" "$CADDY_DIR/Caddyfile" && success "Caddyfile ✅" >&2 || error "Caddyfile ❌" >&2
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

  log "✅ Восстановление завершено"
}

# ===== ЦИКЛ =====
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

do_check
show_report "$GLOBAL_EXIT"
exit $GLOBAL_EXIT
