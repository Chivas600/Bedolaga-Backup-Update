#!/bin/bash
set -e

# ===== ЦВЕТОВЫЕ ФУНКЦИИ (все сообщения в stderr) =====
error()   { echo -e "\033[31m❌ ОШИБКА: $1\033[0m" >&2; }
success() { echo -e "\033[32m✅ $1\033[0m" >&2; }
info()    { echo -e "\033[33mℹ️  $1\033[0m" >&2; }
warn()    { echo -e "\033[33m⚠️  $1\033[0m" >&2; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m\n" >&2; }

# ===== ПУТЬ К ФАЙЛУ НАСТРОЕК =====
CONFIG_FILE="/root/.bedolaga-config"

# ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====
clean_domain() {
  local d="$1"
  d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"
  echo "$d" | xargs
}

is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]
}

# ===== ВЫБОР ДОМЕНА (возвращает значение в stdout, сообщения в stderr) =====
select_domain() {
  local NAME="$1"; shift
  local DOMAINS=("$@")
  
  if [ ${#DOMAINS[@]} -gt 0 ]; then
    info "Доступные домены для $NAME:" >&2
    for i in "${!DOMAINS[@]}"; do echo "  $((i+1))) ${DOMAINS[$i]}" >&2; done
    echo "  m) Ввести вручную" >&2; echo "" >&2
    
    while true; do
      read -p "📌 Ваш выбор [1-${#DOMAINS[@]}/m]: " INPUT >&2
      INPUT="$(echo "$INPUT" | xargs)"
      
      if [[ "$INPUT" == "m" ]] || [[ "$INPUT" == "M" ]]; then
        echo "Требования: домен без http/https, например app.example.com" >&2
        read -p "🌐 Введите домен для $NAME: " MANUAL >&2
        MANUAL="$(clean_domain "$MANUAL")"
        if [[ -n "$MANUAL" ]] && is_valid_domain "$MANUAL"; then
          echo "$MANUAL"; return 0
        fi
        error "Некорректный формат домена" >&2
      elif [[ "$INPUT" =~ ^[0-9]+$ ]] && [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#DOMAINS[@]}" ]; then
        echo "${DOMAINS[$((INPUT-1))]}"; return 0
      else
        error "Неверный выбор. Введите 1-${#DOMAINS[@]} или 'm'" >&2
      fi
    done
  else
    warn "Домены не найдены автоматически" >&2
    echo "Требования: домен без http/https" >&2
    while true; do
      read -p "🌐 Введите домен для $NAME (или 'skip'): " MANUAL >&2
      MANUAL="$(echo "$MANUAL" | xargs)"
      if [[ "$MANUAL" == "skip" ]]; then echo ""; return 0; fi
      MANUAL="$(clean_domain "$MANUAL")"
      if [[ -n "$MANUAL" ]] && is_valid_domain "$MANUAL"; then echo "$MANUAL"; return 0; fi
      error "Некорректный формат" >&2
    done
  fi
}

# ===== ВВОД ПУТИ (возвращает путь в stdout, сообщения в stderr) =====
prompt_path() {
  local LABEL="$1"; local FOUND="$2"
  
  if [ -n "$FOUND" ]; then
    info "Найден путь к $LABEL: $FOUND" >&2
    read -p "✅ Использовать этот путь? [y/N]: " CONFIRM >&2
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "$FOUND"; return 0
    fi
    info "Другой путь не найден — введите вручную" >&2
  fi
  
  echo "Требования: абсолютный путь, папка должна существовать" >&2
  echo "Пример: /opt/my-project" >&2
  
  while true; do
    read -p "📁 Введите путь к $LABEL: " INPUT_PATH >&2
    INPUT_PATH="${INPUT_PATH//\"/}"; INPUT_PATH="${INPUT_PATH//\'/}"
    INPUT_PATH="$(echo "$INPUT_PATH" | xargs)"
    
    if [ -z "$INPUT_PATH" ]; then error "Путь не может быть пустым" >&2; continue; fi
    if [ ! -d "$INPUT_PATH" ]; then error "Папка '$INPUT_PATH' не найдена" >&2; continue; fi
    echo "$INPUT_PATH"; return 0
  done
}

# ===== АВТО-ДЕТЕКТ ПУТЕЙ =====
detect_paths() {
  info "🔍 Авто-поиск путей к компонентам..." >&2
  
  local SEARCH_DIRS=("/opt" "/root" "/home" "/var/www" "/srv" "/usr/local")
  local FOUND_BOT="" FOUND_CABINET="" FOUND_CADDY=""
  
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' found_dir; do
      if [ -f "$found_dir/.env" ] && [ -f "$found_dir/docker-compose.yml" ]; then
        if [[ "$found_dir" =~ bot|telegram|remnawave|bedolaga ]]; then FOUND_BOT="$found_dir"; break 2; fi
      fi
    done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
  done
  
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' found_dir; do
      if [ -f "$found_dir/package.json" ] || [ -d "$found_dir/src" ]; then
        if [[ "$found_dir" =~ cabinet|panel|admin|frontend|bedolaga ]]; then FOUND_CABINET="$found_dir"; break 2; fi
      fi
    done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
  done
  
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' found_dir; do
      if [ -f "$found_dir/Caddyfile" ]; then FOUND_CADDY="$found_dir"; break 2; fi
    done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
  done
  
  echo "" >&2
  BOT_DIR="$(prompt_path "бот" "$FOUND_BOT")"
  CABINET_DIR="$(prompt_path "кабинет" "$FOUND_CABINET")"
  
  echo "" >&2
  if [ -n "$FOUND_CADDY" ]; then
    info "Найден путь к Caddy: $FOUND_CADDY" >&2
    read -p "✅ Использовать этот путь? [y/N]: " CONFIRM_CADDY >&2
    if [[ "$CONFIRM_CADDY" =~ ^[Yy]$ ]]; then
      CADDY_DIR="$FOUND_CADDY"
      success "Caddy: $CADDY_DIR" >&2
    else
      info "Введите путь вручную или Enter для пропуска" >&2
      read -p "📁 Путь к Caddy: " CADDY_DIR >&2
      CADDY_DIR="$(echo "${CADDY_DIR//\"/}" | xargs)"
      [ -n "$CADDY_DIR" ] && [ ! -d "$CADDY_DIR" ] && { warn "Папка не найдена — Caddy пропущен" >&2; CADDY_DIR=""; }
    fi
  else
    info "Caddy не найден. Введите путь или Enter для пропуска" >&2
    read -p "📁 Путь к Caddy: " CADDY_DIR >&2
    CADDY_DIR="$(echo "${CADDY_DIR//\"/}" | xargs)"
    [ -n "$CADDY_DIR" ] && [ ! -d "$CADDY_DIR" ] && { warn "Папка не найдена — Caddy пропущен" >&2; CADDY_DIR=""; }
  fi
  [ -z "$CADDY_DIR" ] && info "Caddy: не используется" >&2
  
  echo "" >&2; info "Проверка путей..." >&2
  [ -d "$BOT_DIR" ] && success "Бот: $BOT_DIR ✅" >&2 || { error "Бот: папка не существует ❌" >&2; return 1; }
  [ -d "$CABINET_DIR" ] && success "Кабинет: $CABINET_DIR ✅" >&2 || { error "Кабинет: папка не существует ❌" >&2; return 1; }
  [ -z "$CADDY_DIR" ] || [ -d "$CADDY_DIR" ] && success "Caddy: ${CADDY_DIR:-не используется} ✅" >&2 || { error "Caddy: папка не существует ❌" >&2; return 1; }
  
  echo "" >&2
  read -p "💾 Сохранить пути в конфиг? [y/N]: " SAVE_PATHS >&2
  if [[ "$SAVE_PATHS" =~ ^[Yy]$ ]]; then
    [ -f "$CONFIG_FILE" ] && grep -vE "^BOT_DIR=|^CABINET_DIR=|^CADDY_DIR=" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    { echo "BOT_DIR=\"$BOT_DIR\""; echo "CABINET_DIR=\"$CABINET_DIR\""; echo "CADDY_DIR=\"$CADDY_DIR\""; } >> "$CONFIG_FILE"
    success "Пути сохранены в $CONFIG_FILE" >&2
  fi
  return 0
}

# ===== АВТО-ДЕТЕКТ ДОМЕНОВ =====
detect_domains() {
  info "🔍 Авто-детект доменов из конфигов..." >&2
  local DETECTED=()
  
  if [ -n "$CADDY_DIR" ] && [ -f "$CADDY_DIR/Caddyfile" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]] || continue
      local d="${BASH_REMATCH[1]}"
      [[ "$d" =~ localhost|127\.0\.0\.1 ]] && continue
      [[ " ${DETECTED[*]} " =~ " ${d} " ]] && continue
      DETECTED+=("$d")
    done < <(grep -E "^https?://" "$CADDY_DIR/Caddyfile" 2>/dev/null || true)
  fi
  
  if [ -f "$BOT_DIR/.env" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ =(https?://)?([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]] || continue
      local d="${BASH_REMATCH[2]}"
      [[ "$d" =~ localhost|127\.0\.0\.1 ]] && continue
      [[ " ${DETECTED[*]} " =~ " ${d} " ]] && continue
      [[ "$d" =~ ^[A-Z_]+$ ]] && continue
      DETECTED+=("$d")
    done < <(grep -E "^(WEBHOOK|API|APP|BOT)_URL|DOMAIN|HOST=" "$BOT_DIR/.env" 2>/dev/null || true)
  fi
  
  local UNIQUE=()
  for d in "${DETECTED[@]}"; do [[ " ${UNIQUE[*]} " =~ " ${d} " ]] || UNIQUE+=("$d"); done
  
  PRIMARY_DOMAIN="$(select_domain "кабинета" "${UNIQUE[@]}")"
  [ -z "$PRIMARY_DOMAIN" ] && { HOOKS_DOMAIN=""; return 0; }
  
  if [ ${#UNIQUE[@]} -gt 1 ]; then
    HOOKS_DOMAIN="$(select_domain "API" "${UNIQUE[@]}")"
  else
    HOOKS_DOMAIN="$PRIMARY_DOMAIN"
    info "API: используем тот же домен ($HOOKS_DOMAIN)" >&2
  fi
  return 0
}

# ===== ЗАГРУЗКА КОНФИГА =====
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  info "Настройки загружены из $CONFIG_FILE" >&2
  [ -z "$BOT_DIR" ] || [ -z "$CABINET_DIR" ] && { info "Пути не найдены — авто-поиск..." >&2; detect_paths || exit 1; }
  [ -z "$PRIMARY_DOMAIN" ] && [ -z "$HOOKS_DOMAIN" ] && { info "Домены не найдены — авто-детект..." >&2; detect_domains || exit 1; }
else
  header "⚙️ ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА" >&2
  while [ -z "$BACKUP_SERVER" ]; do read -p "🌐 IP сервера: " BACKUP_SERVER >&2; [ -z "$BACKUP_SERVER" ] && error "Обязательно!" >&2; done
  read -p "👤 Пользователь [root]: " U >&2; BACKUP_USER="${U:-root}"; [ -z "$U" ] && success "root" >&2
  read -p "📁 Путь бэкапов [/root/bedolaga-backups]: " P >&2; BACKUP_REMOTE_DIR="${P:-/root/bedolaga-backups}"; [ -z "$P" ] && success "по умолчанию" >&2
  read -p "📦 Хранить бэкапов [7]: " R >&2; BACKUP_RETENTION="${R:-7}"; [ -z "$R" ] && success "7" >&2
  echo "" >&2; echo "Проверка:" >&2; echo "  🌐 $BACKUP_SERVER 👤 $BACKUP_USER 📁 $BACKUP_REMOTE_DIR 📦 $BACKUP_RETENTION" >&2; echo "" >&2
  read -p "💾 Сохранить? [y/N]: " S >&2
  if [[ "$S" =~ ^[Yy]$ ]]; then
    cat > "$CONFIG_FILE" << CONF
BACKUP_SERVER="$BACKUP_SERVER"
BACKUP_USER="$BACKUP_USER"
BACKUP_REMOTE_DIR="$BACKUP_REMOTE_DIR"
BACKUP_RETENTION="$BACKUP_RETENTION"
CONF
    chmod 600 "$CONFIG_FILE"; success "Сохранено" >&2
  fi
  detect_paths || exit 1; echo "" >&2; detect_domains || exit 1
fi

# ===== ЛОГИРОВАНИЕ =====
REPORT_FILE="/root/bedolaga-report-$(date +%Y%m%d-%H%M).txt"
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$REPORT_FILE" >&2; }

# ===== ПРОВЕРКА ФАЙЛА =====
check_backup_file() {
  local F="$1" N="$2"
  if [ -f "$F" ]; then
    local SZ=$(stat -c%s "$F" 2>/dev/null || echo 0)
    [ "$SZ" -gt 0 ] && { success "$N: $(ls -lh "$F"|awk '{print $5}') ✅" >&2; return 0; }
    error "$N: пустой файл ❌" >&2; return 1
  fi
  error "$N: не найден ❌" >&2; return 1
}

# ===== РОТАЦИЯ =====
rotate_backups() {
  header "🗑️ РОТАЦИЯ" >&2
  local DIR="/root/bedolaga-local-backups"
  info "Храним: $BACKUP_RETENTION" >&2
  local CNT=$(ls -1d "$DIR"/bedolaga-full-backup-* 2>/dev/null | wc -l)
  if [ "$CNT" -gt "$BACKUP_RETENTION" ]; then
    local DEL=$((CNT - BACKUP_RETENTION))
    info "Удаляем $DEL старых..." >&2
    ls -1d "$DIR"/bedolaga-full-backup-* 2>/dev/null | head -n "$DEL" | while read OLD; do
      local DT=$(basename "$OLD"|sed 's/bedolaga-full-backup-//')
      local SZ=$(du -sh "$OLD"|awk '{print $1}')
      info "Удаляем: $DT ($SZ)..." >&2
      rm -rf "$OLD" && success "Удалён ✅" >&2 || error "Ошибка ❌" >&2
      log "Удалён: $DT ($SZ)"
    done
  else
    info "Бэкапов: $CNT/$BACKUP_RETENTION ✅" >&2
  fi
}

# ===== ПРОВЕРКА ДИСКА =====
check_disk_space() {
  local MIN=1024 AVAIL=$(df -m "${1:-/root}" | awk 'NR==2{print $4}')
  [ "$AVAIL" -lt "$MIN" ] && { error "Мало места: ${AVAIL}МБ < ${MIN}МБ" >&2; return 1; }
  success "Место: ${AVAIL}МБ ✅" >&2; return 0
}

# ===== ЗАГОЛОВОК =====
clear; echo -e "\033[1;36m"
echo "╔════════════════════════════════════╗"
echo "║  🤖 Bedolaga: Обновление системы  ║"
echo "╚════════════════════════════════════╝"
echo -e "\033[0m"
log "🚀 Запуск"; info "Сервер: $BACKUP_USER@$BACKUP_SERVER" >&2; info "Бот: $BOT_DIR" >&2; info "Кабинет: $CABINET_DIR" >&2; info "Caddy: ${CADDY_DIR:-нет}" >&2

# ===== МЕНЮ =====
echo "" >&2; echo "Действие:" >&2; echo "1) 🔒 Только бэкап" >&2; echo "2) 🔄 Только обновление" >&2; echo "3) ⚡ Бэкап + Обновление" >&2; echo "4) ⚙️ Настройки" >&2
read -p "Выбор [1-4]: " ACT >&2
[[ ! "$ACT" =~ ^[1-4]$ ]] && { error "Неверно" >&2; exit 1; }
[ "$ACT" = "4" ] && { header "⚙️ СБРОС" >&2; rm -f "$CONFIG_FILE"; info "Перезапустите скрипт" >&2; exit 0; }

# ===== БЭКАП =====
do_backup() {
  header "📦 БЭКАП" >&2
  check_disk_space "/root" || return 1
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
  [ -n "$RV" ] && docker run --rm -v "$RV":/source -v "$BD/bot":/backup alpine tar -czf /backup/redis_data.tar.gz -C /source . && check_backup_file "$BD/bot/redis_data.tar.gz" "Redis"
  
  info "Кабинет..." >&2
  if [ -d "$CABINET_DIR" ]; then
    cd "$CABINET_DIR" 2>/dev/null && { cp .env package*.json "$BD/cabinet/" 2>/dev/null||true; cp -r src/ "$BD/cabinet/" 2>/dev/null||true; }
    [ -f "$BD/cabinet/.env" ] && success "Конфиг ✅" >&2||info "Конфиг не найден" >&2
    [ -d "$BD/cabinet/src" ] && success "Код ✅" >&2||info "Код не найден" >&2
  fi
  
  [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ] && cp "$CADDY_DIR/Caddyfile" "$BD/caddy/" 2>/dev/null && success "Caddy ✅" >&2
  
  info "Копирование на сервер..." >&2
  read -s -p "🔐 Пароль: " PASS >&2; echo >&2
  echo "$PASS" | scp -r -o StrictHostKeyChecking=no "$BD" "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/" && success "Скопировано ✅" >&2 || { error "Ошибка копирования ❌" >&2; log "❌ scp failed"; }
  log "Бэкап: $BD"; rotate_backups; return 0
}

# ===== ОБНОВЛЕНИЕ =====
do_update() {
  header "🔄 ОБНОВЛЕНИЕ" >&2; info "Запуск..." >&2
  
  # Бот: тихая синхронизация с удалённым репозиторием
  info "Бот..." >&2
  cd "$BOT_DIR" || { error "Папка бота не найдена" >&2; return 1; }
  if git fetch origin && git reset --hard origin/main; then
    docker compose down
    docker compose up -d --build bot
    sleep 10
    docker compose ps | grep -q "remnawave_bot.*healthy" && success "Бот: healthy ✅" >&2 || { warn "Бот: проверка ⚠️" >&2; docker compose logs --tail=20 bot||true; }
  else error "Ошибка синхронизации бота ❌" >&2; return 1; fi
  
  # Кабинет: тихая синхронизация
  info "Кабинет..." >&2
  cd "$CABINET_DIR" || { error "Папка кабинета не найдена" >&2; return 1; }
  if git fetch origin && git reset --hard origin/main; then
    npm install --silent
    npm run build --silent
    docker compose up -d --build cabinet-frontend
    sleep 15
    docker exec cabinet_frontend wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ 2>&1 | grep -qE "200|exists|connected" && success "Кабинет: healthy ✅" >&2 || { warn "Кабинет: проверка ⚠️" >&2; docker compose logs --tail=30 cabinet-frontend||true; }
  else error "Ошибка синхронизации кабинета ❌" >&2; return 1; fi
  
  # Caddy
  info "Caddy..." >&2
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose down && docker compose up -d --build && success "Caddy ✅" >&2
  else docker restart remnawave_caddy 2>/dev/null && success "Caddy ✅" >&2 || info "Caddy: нет" >&2; fi
  log "Обновление завершено"; return 0
}

# ===== ПРОВЕРКА =====
do_check() {
  header "✅ ПРОВЕРКА" >&2; local ST=0
  info "Контейнеры:" >&2; docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "remnawave|cabinet" | tee -a "$REPORT_FILE" >&2
  docker ps --format "{{.Status}}" | grep -E "remnawave|cabinet" | grep -qv "healthy" && { warn "⚠️ Не все healthy" >&2; ST=1; } || success "Все healthy 🟢" >&2
  
  [ -n "$PRIMARY_DOMAIN" ] && { info "Кабинет: $PRIMARY_DOMAIN..." >&2; curl -s -o /dev/null -w "%{http_code}" "https://$PRIMARY_DOMAIN" | grep -q "200" && success "Кабинет: 200 🟢" >&2 || { error "Кабинет: не отвечает ❌" >&2; ST=1; }; }
  
  [ -n "$HOOKS_DOMAIN" ] && { info "API: $HOOKS_DOMAIN..." >&2; local AC=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 "https://$HOOKS_DOMAIN" 2>/dev/null||echo "000"); [[ "$AC" =~ ^(200|404|405|401|403)$ ]] && success "API: $AC 🟢" >&2 || { error "API: код $AC ❌" >&2; ST=1; }; }
  return $ST
}

# ===== ОТЧЁТ =====
show_report() {
  header "📊 ОТЧЁТ" >&2
  echo "Время: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Файл: $REPORT_FILE"
  echo ""
  cat "$REPORT_FILE"
  echo ""
  [ $? -eq 0 ] && success "🎉 Успех!" >&2 || warn "⚠️ С предупреждениями" >&2
}

# ===== ЦИКЛ =====
case $ACT in
  1) do_backup;;
  2) do_update;;
  3) do_backup && { echo "" >&2; read -p "✅ Бэкап готов. Обновить? [y/N]: " C >&2; [[ "$C" =~ ^[Yy]$ ]] && do_update||info "Отменено" >&2; } || error "Бэкап с ошибкой — обновление отменено" >&2;;
esac

do_check; CR=$?; show_report; exit $CR