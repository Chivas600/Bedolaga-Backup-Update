#!/bin/bash
set -e

# ===== ЦВЕТОВЫЕ ФУНКЦИИ =====
error()   { echo -e "\033[31m❌ ОШИБКА: $1\033[0m"; }
success() { echo -e "\033[32m✅ $1\033[0m"; }
info()    { echo -e "\033[33mℹ️  $1\033[0m"; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m\n"; }

# ===== ПУТЬ К ФАЙЛУ НАСТРОЕК =====
CONFIG_FILE="/root/.bedolaga-config"

# ===== ФУНКЦИЯ: Авто-детект путей к компонентам =====
detect_paths() {
  info "🔍 Авто-поиск путей к компонентам..."
  
  local SEARCH_DIRS=("/opt" "/root" "/home" "/var/www" "/srv" "/usr/local")
  local FOUND_BOT=""
  local FOUND_CABINET=""
  local FOUND_CADDY=""
  
  # Ищем бота (ищем .env + docker-compose.yml + папка с bot в имени)
  for dir in "${SEARCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      while IFS= read -r -d '' found_dir; do
        if [ -f "$found_dir/.env" ] && [ -f "$found_dir/docker-compose.yml" ]; then
          if [[ "$found_dir" =~ bot|telegram|remnawave|bedolaga ]]; then
            FOUND_BOT="$found_dir"
            break 2
          fi
        fi
      done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
    fi
  done
  
  # Ищем кабинет (ищем package.json + src/ или cabinet в имени)
  for dir in "${SEARCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      while IFS= read -r -d '' found_dir; do
        if [ -f "$found_dir/package.json" ] || [ -d "$found_dir/src" ]; then
          if [[ "$found_dir" =~ cabinet|panel|admin|frontend|bedolaga ]]; then
            FOUND_CABINET="$found_dir"
            break 2
          fi
        fi
      done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
    fi
  done
  
  # Ищем Caddy (ищем Caddyfile)
  for dir in "${SEARCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      while IFS= read -r -d '' found_dir; do
        if [ -f "$found_dir/Caddyfile" ]; then
          FOUND_CADDY="$found_dir"
          break 2
        fi
      done < <(find "$dir" -maxdepth 3 -type d -print0 2>/dev/null)
    fi
  done
  
  # Показываем найденное и спрашиваем
  echo ""
  
  # Бот
  if [ -n "$FOUND_BOT" ]; then
    info "Найден бот: $FOUND_BOT"
    read -p "✅ Использовать этот путь? [Y/n]: " CONFIRM_BOT
    if [[ ! "$CONFIRM_BOT" =~ ^[Nn]$ ]]; then
      BOT_DIR="$FOUND_BOT"
      success "Бот: $BOT_DIR"
    else
      read -p " Введите путь к боту: " BOT_DIR
    fi
  else
    read -p "📁 Не найдено. Введите путь к боту: " BOT_DIR
  fi
  
  # Кабинет
  if [ -n "$FOUND_CABINET" ]; then
    info "Найден кабинет: $FOUND_CABINET"
    read -p "✅ Использовать этот путь? [Y/n]: " CONFIRM_CABINET
    if [[ ! "$CONFIRM_CABINET" =~ ^[Nn]$ ]]; then
      CABINET_DIR="$FOUND_CABINET"
      success "Кабинет: $CABINET_DIR"
    else
      read -p "📁 Введите путь к кабинету: " CABINET_DIR
    fi
  else
    read -p "📁 Не найдено. Введите путь к кабинету: " CABINET_DIR
  fi
  
  # Caddy
  if [ -n "$FOUND_CADDY" ]; then
    info "Найден Caddy: $FOUND_CADDY"
    read -p "✅ Использовать этот путь? [Y/n]: " CONFIRM_CADDY
    if [[ ! "$CONFIRM_CADDY" =~ ^[Nn]$ ]]; then
      CADDY_DIR="$FOUND_CADDY"
      success "Caddy: $CADDY_DIR"
    else
      read -p "📁 Введите путь к Caddy (или Enter если нет): " CADDY_DIR
    fi
  else
    read -p "📁 Не найдено. Введите путь к Caddy (или Enter если нет): " CADDY_DIR
  fi
  
  # Проверяем, что пути существуют
  echo ""
  info "Проверка путей..."
  [ -d "$BOT_DIR" ] && success "Бот: $BOT_DIR ✅" || { error "Бот: папка не существует ❌"; return 1; }
  [ -d "$CABINET_DIR" ] && success "Кабинет: $CABINET_DIR ✅" || { error "Кабинет: папка не существует ❌"; return 1; }
  [ -z "$CADDY_DIR" ] || [ -d "$CADDY_DIR" ] && success "Caddy: ${CADDY_DIR:-не используется} ✅" || { error "Caddy: папка не существует ❌"; return 1; }
  
  # Сохраняем пути в конфиг
  echo ""
  read -p "💾 Сохранить пути в конфиг? [y/N]: " SAVE_PATHS
  if [[ "$SAVE_PATHS" =~ ^[Yy]$ ]]; then
    cat >> "$CONFIG_FILE" << PATHS
BOT_DIR="$BOT_DIR"
CABINET_DIR="$CABINET_DIR"
CADDY_DIR="$CADDY_DIR"
PATHS
    success "Пути сохранены в $CONFIG_FILE"
  fi
  
  return 0
}

# ===== ФУНКЦИЯ: Авто-детект доменов из конфигов =====
detect_domains() {
  info "🔍 Авто-детект доменов из конфигов..."
  
  local DETECTED_DOMAINS=()
  
  # Ищем в Caddyfile
  if [ -n "$CADDY_DIR" ] && [ -f "$CADDY_DIR/Caddyfile" ]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]]; then
        local domain="${BASH_REMATCH[1]}"
        if [[ ! "$domain" =~ localhost|127\.0\.0\.1 ]] && [[ ! " ${DETECTED_DOMAINS[@]} " =~ " ${domain} " ]]; then
          DETECTED_DOMAINS+=("$domain")
        fi
      fi
    done < <(grep -E "^https?://" "$CADDY_DIR/Caddyfile" 2>/dev/null || true)
  fi
  
  # Ищем в .env бота
  if [ -f "$BOT_DIR/.env" ]; then
    while IFS= read -r line; do
      if [[ "$line" =~ =(https?://)?([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]]; then
        local domain="${BASH_REMATCH[2]}"
        if [[ ! "$domain" =~ localhost|127\.0\.0\.1 ]] && [[ ! " ${DETECTED_DOMAINS[@]} " =~ " ${domain} " ]]; then
          DETECTED_DOMAINS+=("$domain")
        fi
      fi
    done < <(grep -E "^(WEBHOOK|API|APP|BOT)_URL|DOMAIN|HOST=" "$BOT_DIR/.env" 2>/dev/null || true)
  fi
  
  # Если нашли домены — показываем и даём выбрать
  if [ ${#DETECTED_DOMAINS[@]} -gt 0 ]; then
    echo ""
    info "Найдены домены в конфигах:"
    for i in "${!DETECTED_DOMAINS[@]}"; do
      echo "  $((i+1))) ${DETECTED_DOMAINS[$i]}"
    done
    echo ""
    
    read -p "📌 Введите номер домена для ПРОВЕРКИ КАБИНЕТА [1]: " CABINET_NUM
    CABINET_NUM=${CABINET_NUM:-1}
    PRIMARY_DOMAIN="${DETECTED_DOMAINS[$((CABINET_NUM-1))]}"
    success "Кабинет: $PRIMARY_DOMAIN"
    
    if [ ${#DETECTED_DOMAINS[@]} -gt 1 ]; then
      echo ""
      read -p "📌 Введите номер домена для ПРОВЕРКИ API [$((CABINET_NUM % ${#DETECTED_DOMAINS[@]} + 1))]: " API_NUM
      if [ -z "$API_NUM" ]; then
        API_NUM=$((CABINET_NUM % ${#DETECTED_DOMAINS[@]} + 1))
      fi
      HOOKS_DOMAIN="${DETECTED_DOMAINS[$((API_NUM-1))]}"
      success "API: $HOOKS_DOMAIN"
    else
      HOOKS_DOMAIN="$PRIMARY_DOMAIN"
      info "API: используем тот же домен ($HOOKS_DOMAIN)"
    fi
  else
    echo ""
    info "Не удалось авто-определить домены."
    read -p "🌐 Введите домен кабинета: " PRIMARY_DOMAIN
    if [ -z "$PRIMARY_DOMAIN" ]; then
      error "Домен кабинета обязателен!"
      return 1
    fi
    read -p "🌐 Введите домен API (или Enter для того же): " HOOKS_DOMAIN
    HOOKS_DOMAIN=${HOOKS_DOMAIN:-$PRIMARY_DOMAIN}
    success "Кабинет: $PRIMARY_DOMAIN, API: $HOOKS_DOMAIN"
  fi
  
  return 0
}

# ===== ЗАГРУЗКА ИЛИ СОЗДАНИЕ КОНФИГА =====
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  info "Загружены настройки из $CONFIG_FILE"
  
  # Проверяем, есть ли пути в конфиге
  if [ -z "$BOT_DIR" ] || [ -z "$CABINET_DIR" ]; then
    info "Пути не найдены в конфиге — запускаем авто-поиск..."
    detect_paths || exit 1
  fi
  if [ -z "$PRIMARY_DOMAIN" ]; then
    info "Домены не найдены в конфиге — запускаем авто-детект..."
    detect_domains || exit 1
  fi
else
  header "⚙️ ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА"
  echo "Введите данные для резервного сервера (бэкапы):"
  echo ""
  
  while [ -z "$BACKUP_SERVER" ]; do
    read -p "🌐 IP адрес резервного сервера: " BACKUP_SERVER
    [ -z "$BACKUP_SERVER" ] && error "IP адрес обязателен!"
  done
  
  read -p "👤 Пользователь на сервере [root]: " BACKUP_USER_INPUT
  BACKUP_USER=${BACKUP_USER_INPUT:-root}
  [ -z "$BACKUP_USER_INPUT" ] && success "Используем: root"
  
  read -p "📁 Путь для бэкапов на сервере [/root/bedolaga-backups]: " BACKUP_REMOTE_DIR_INPUT
  BACKUP_REMOTE_DIR=${BACKUP_REMOTE_DIR_INPUT:-/root/bedolaga-backups}
  [ -z "$BACKUP_REMOTE_DIR_INPUT" ] && success "Используем: /root/bedolaga-backups"
  
  read -p "📦 Количество хранимых бэкапов [7]: " BACKUP_RETENTION_INPUT
  BACKUP_RETENTION=${BACKUP_RETENTION_INPUT:-7}
  [ -z "$BACKUP_RETENTION_INPUT" ] && success "Храним: 7"
  
  echo ""
  echo "Проверка настроек:"
  echo "  🌐 Сервер: $BACKUP_SERVER"
  echo "  👤 Пользователь: $BACKUP_USER"
  echo "  📁 Путь: $BACKUP_REMOTE_DIR"
  echo "  📦 Бэкапов: $BACKUP_RETENTION"
  echo ""
  
  read -p "💾 Сохранить настройки? [y/N]: " SAVE_CONFIG
  if [[ "$SAVE_CONFIG" =~ ^[Yy]$ ]]; then
    cat > "$CONFIG_FILE" << CONF
BACKUP_SERVER="$BACKUP_SERVER"
BACKUP_USER="$BACKUP_USER"
BACKUP_REMOTE_DIR="$BACKUP_REMOTE_DIR"
BACKUP_RETENTION="$BACKUP_RETENTION"
CONF
    chmod 600 "$CONFIG_FILE"
    success "Настройки сохранены в $CONFIG_FILE"
  fi
  echo ""
  
  # Авто-поиск путей
  detect_paths || exit 1
  echo ""
  # Авто-детект доменов
  detect_domains || exit 1
fi

# ===== ЛОГИРОВАНИЕ =====
REPORT_FILE="/root/bedolaga-report-$(date +%Y%m%d-%H%M).txt"
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$REPORT_FILE"; }

# ===== ФУНКЦИЯ ПРОВЕРКИ ФАЙЛА БЭКАПА =====
check_backup_file() {
  local FILE="$1"
  local NAME="$2"
  if [ -f "$FILE" ]; then
    local SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 0 ]; then
      success "$NAME: $(ls -lh "$FILE" | awk '{print $5}') ✅"
      return 0
    else
      error "$NAME: файл пустой (0 байт) ❌"
      return 1
    fi
  else
    error "$NAME: файл не найден ❌"
    return 1
  fi
}

# ===== ФУНКЦИЯ РОТАЦИИ БЭКАПОВ =====
rotate_backups() {
  header "🗑️ РОТАЦИЯ БЭКАПОВ"
  local LOCAL_BACKUP_DIR="/root/bedolaga-local-backups"
  info "Храним последние $BACKUP_RETENTION бэкапов..."
  
  local BACKUP_COUNT=$(ls -1d "$LOCAL_BACKUP_DIR"/bedolaga-full-backup-* 2>/dev/null | wc -l)
  
  if [ "$BACKUP_COUNT" -gt "$BACKUP_RETENTION" ]; then
    local TO_DELETE=$((BACKUP_COUNT - BACKUP_RETENTION))
    info "Найдено $BACKUP_COUNT бэкапов. Удаляем $TO_DELETE старых..."
    
    ls -1d "$LOCAL_BACKUP_DIR"/bedolaga-full-backup-* 2>/dev/null | head -n "$TO_DELETE" | while read OLD_BACKUP; do
      local BACKUP_DATE=$(basename "$OLD_BACKUP" | sed 's/bedolaga-full-backup-//')
      local BACKUP_SIZE=$(du -sh "$OLD_BACKUP" 2>/dev/null | awk '{print $1}')
      info "Удаляем бэкап от $BACKUP_DATE ($BACKUP_SIZE)..."
      rm -rf "$OLD_BACKUP" && success "Бэкап от $BACKUP_DATE удалён ✅" || error "Не удалось удалить ❌"
      log "Удалён старый бэкап: $BACKUP_DATE ($BACKUP_SIZE)"
    done
  else
    info "Бэкапов: $BACKUP_COUNT из $BACKUP_RETENTION. Удаление не требуется ✅"
  fi
}

# ===== ЗАГОЛОВОК =====
clear
echo -e "\033[1;36m"
echo "╔════════════════════════════════════╗"
echo "║  🤖 Bedolaga: Обновление системы  ║"
echo "╚════════════════════════════════════╝"
echo -e "\033[0m"
log "🚀 Запуск скрипта обновления"
info "Резервный сервер: $BACKUP_USER@$BACKUP_SERVER:$BACKUP_REMOTE_DIR"
info "Бот: $BOT_DIR"
info "Кабинет: $CABINET_DIR"
info "Caddy: ${CADDY_DIR:-не используется}"
echo ""

# ===== МЕНЮ =====
echo "Выберите действие:"
echo "1) 🔒 Только бэкап"
echo "2) 🔄 Только обновление"
echo "3) ⚡ Бэкап + Обновление (рекомендуется)"
echo "4) ⚙️ Изменить настройки сервера"
read -p "Ваш выбор [1-4]: " ACTION

if [[ ! "$ACTION" =~ ^[1-4]$ ]]; then
  error "Неверный выбор"
  exit 1
fi

if [ "$ACTION" = "4" ]; then
  header "⚙️ ИЗМЕНЕНИЕ НАСТРОЕК"
  rm -f "$CONFIG_FILE"
  info "Настройки сброшены. Перезапустите скрипт."
  exit 0
fi

# ===== ФУНКЦИЯ БЭКАПА =====
do_backup() {
  header "📦 СОЗДАНИЕ БЭКАПА"
  local BACKUP_DIR="/root/bedolaga-local-backups/bedolaga-full-backup-$(date +%Y%m%d-%H%M)"
  mkdir -p "$BACKUP_DIR/bot" "$BACKUP_DIR/cabinet" "$BACKUP_DIR/caddy"
  log "Создана папка: $BACKUP_DIR"

  info "Бэкап конфигов бота..."
  cd "$BOT_DIR" || { error "Папка бота не найдена"; return 1; }
  cp .env docker-compose.yml "$BACKUP_DIR/bot/"
  check_backup_file "$BACKUP_DIR/bot/.env" "Конфиг .env"
  check_backup_file "$BACKUP_DIR/bot/docker-compose.yml" "Конфиг docker-compose.yml"

  info "Бэкап базы данных..."
  local POSTGRES_VOLUME=$(docker volume ls | grep postgres_data | awk '{print $2}')
  if [ -n "$POSTGRES_VOLUME" ]; then
    docker run --rm -v "$POSTGRES_VOLUME":/source -v "$BACKUP_DIR/bot":/backup alpine tar -czf /backup/postgres_data.tar.gz -C /source .
    check_backup_file "$BACKUP_DIR/bot/postgres_data.tar.gz" "Бэкап БД" || { error "Бэкап БД не создан!"; return 1; }
  else
    error "Том БД не найден"
  fi

  info "Бэкап Redis..."
  local REDIS_VOLUME=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$REDIS_VOLUME" ]; then
    docker run --rm -v "$REDIS_VOLUME":/source -v "$BACKUP_DIR/bot":/backup alpine tar -czf /backup/redis_data.tar.gz -C /source .
    check_backup_file "$BACKUP_DIR/bot/redis_data.tar.gz" "Бэкап Redis"
  fi

  info "Бэкап кабинета..."
  cd "$CABINET_DIR" 2>/dev/null && { cp .env package*.json "$BACKUP_DIR/cabinet/" 2>/dev/null || true; cp -r src/ "$BACKUP_DIR/cabinet/" 2>/dev/null || true; }
  [ -f "$BACKUP_DIR/cabinet/.env" ] && success "Конфиг кабинета ✅" || info "Конфиг кабинета не найден"
  [ -d "$BACKUP_DIR/cabinet/src" ] && success "Исходный код кабинета ✅" || info "Исходный код не найден"

  [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ] && { cp "$CADDY_DIR/Caddyfile" "$BACKUP_DIR/caddy/" 2>/dev/null || true; success "Caddy ✅"; }

  info "Копирование на резервный сервер..."
  read -s -p "🔐 Пароль для $BACKUP_USER@$BACKUP_SERVER: " BACKUP_PASS
  echo
  echo "$BACKUP_PASS" | scp -r -o StrictHostKeyChecking=no "$BACKUP_DIR" "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/" && \
    success "Бэкап скопирован ✅" || error "Не удалось скопировать ❌"
  
  log "Бэкап завершён: $BACKUP_DIR"
  rotate_backups
  return 0
}

# ===== ФУНКЦИЯ ОБНОВЛЕНИЯ =====
do_update() {
  header "🔄 ОБНОВЛЕНИЕ"
  info "Запускаю обновление..."

  info "Обновление бота..."
  cd "$BOT_DIR" || { error "Папка бота не найдена"; return 1; }
  git pull origin main && \
  docker compose down && \
  docker compose up -d --build bot && \
  sleep 10 && \
  (docker compose ps | grep -q "remnawave_bot.*healthy" && success "Бот: healthy ✅" || error "Бот: не healthy ⚠️") || error "Ошибка обновления бота ❌"

  info "Обновление кабинета..."
  cd "$CABINET_DIR" || { error "Папка кабинета не найдена"; return 1; }
  git pull origin main && \
  npm install && \
  npm run build && \
  docker compose up -d --build cabinet-frontend && \
  sleep 15 && \
  (docker exec cabinet_frontend wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ 2>&1 | grep -q "200\|exists" && success "Кабинет: healthy ✅" || error "Кабинет: healthcheck failed ⚠️") || error "Ошибка обновления кабинета ❌"

  info "Перезапуск Caddy..."
  if [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose down && docker compose up -d --build && success "Caddy ✅"
  else
    docker restart remnawave_caddy 2>/dev/null && success "Caddy (restart) ✅" || info "Caddy не используется"
  fi
  
  log "Обновление завершено"
  return 0
}

# ===== ФУНКЦИЯ ПРОВЕРКИ =====
do_check() {
  header "✅ ПРОВЕРКА"
  local STATUS=0

  info "Статус контейнеров:"
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "remnawave|cabinet" | tee -a "$REPORT_FILE"
  if docker ps --format "{{.Status}}" | grep -E "remnawave|cabinet" | grep -qv "healthy"; then
    error "⚠️ Есть контейнеры не в healthy"
    STATUS=1
  else
    success "Все контейнеры: healthy 🟢"
  fi

  if [ -n "$PRIMARY_DOMAIN" ]; then
    info "Проверка кабинета: $PRIMARY_DOMAIN..."
    if curl -s -o /dev/null -w "%{http_code}" "https://$PRIMARY_DOMAIN" | grep -q "200"; then
      success "Кабинет ($PRIMARY_DOMAIN): HTTP 200 🟢"
    else
      error "Кабинет ($PRIMARY_DOMAIN): не отвечает ❌"
      STATUS=1
    fi
  fi

  if [ -n "$HOOKS_DOMAIN" ]; then
    info "Проверка API: $HOOKS_DOMAIN..."
    API_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 "https://$HOOKS_DOMAIN" 2>/dev/null || echo "000")
    if [[ "$API_CODE" =~ ^(200|404|405|401|403)$ ]]; then
      success "API ($HOOKS_DOMAIN): код $API_CODE 🟢"
    else
      error "API ($HOOKS_DOMAIN): не отвечает ❌"
      STATUS=1
    fi
  fi

  return $STATUS
}

# ===== ФУНКЦИЯ ОТЧЁТА =====
show_report() {
  header "📊 ОТЧЁТ"
  echo "Время: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Отчёт: $REPORT_FILE"
  echo ""
  cat "$REPORT_FILE"
  echo ""
  [ $? -eq 0 ] && success "🎉 Все операции завершены успешно!" || error "⚠️ Завершено с предупреждениями"
}

# ===== ОСНОВНОЙ ЦИКЛ =====
case $ACTION in
  1) do_backup ;;
  2) do_update ;;
  3)
    do_backup
    BACKUP_RESULT=$?
    if [ $BACKUP_RESULT -eq 0 ]; then
      echo ""
      read -p "✅ Бэкап готов. Запустить обновление? [y/N]: " CONFIRM
      if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Запускаю обновление..."
        do_update
      else
        info "Обновление отменено"
      fi
    else
      error "Бэкап с ошибкой — обновление отменено"
    fi
    ;;
esac

do_check
CHECK_RESULT=$?
show_report
exit $CHECK_RESULT