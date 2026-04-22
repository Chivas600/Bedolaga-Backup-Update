#!/bin/bash
set -e

# ===== ЦВЕТОВЫЕ ФУНКЦИИ =====
error()   { echo -e "\033[31m❌ ОШИБКА: $1\033[0m"; }
success() { echo -e "\033[32m✅ $1\033[0m"; }
info()    { echo -e "\033[33mℹ️  $1\033[0m"; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m\n"; }

# ===== ПУТЬ К ФАЙЛУ НАСТРОЕК =====
CONFIG_FILE="/root/.bedolaga-config"

# ===== ФУНКЦИЯ: Авто-детект доменов из конфигов =====
detect_domains() {
  info "🔍 Авто-детект доменов из конфигов..."
  
  local BOT_ENV="/opt/remnawave-bedolaga-telegram-bot/.env"
  local CABINET_ENV="/opt/bedolaga-cabinet/.env"
  local CADDYFILE="/opt/caddy/Caddyfile"
  
  # Пытаемся найти домены в разных местах
  local DETECTED_DOMAINS=()
  
  # Ищем в .env бота (WEBHOOK_HOST, API_URL, etc.)
  if [ -f "$BOT_ENV" ]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[A-Z_]+=(https?://)?([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]]; then
        local domain="${BASH_REMATCH[2]}"
        if [[ ! " ${DETECTED_DOMAINS[@]} " =~ " ${domain} " ]] && [[ ! "$domain" =~ localhost|127\.0\.0\.1 ]]; then
          DETECTED_DOMAINS+=("$domain")
        fi
      fi
    done < <(grep -E "^(WEBHOOK|API|APP|BOT)_URL|DOMAIN|HOST=" "$BOT_ENV" 2>/dev/null || true)
  fi
  
  # Ищем в Caddyfile
  if [ -f "$CADDYFILE" ]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}) ]]; then
        local domain="${BASH_REMATCH[1]}"
        if [[ ! " ${DETECTED_DOMAINS[@]} " =~ " ${domain} " ]]; then
          DETECTED_DOMAINS+=("$domain")
        fi
      fi
    done < <(grep -E "^https?://" "$CADDYFILE" 2>/dev/null || true)
  fi
  
  # Если нашли — показываем и спрашиваем
  if [ ${#DETECTED_DOMAINS[@]} -gt 0 ]; then
    echo ""
    info "Найдены домены в конфигах:"
    for i in "${!DETECTED_DOMAINS[@]}"; do
      echo "  $((i+1))) ${DETECTED_DOMAINS[$i]}"
    done
    echo ""
    read -p "✅ Использовать найденные домены для проверок? [Y/n]: " CONFIRM_DOMAINS
    if [[ ! "$CONFIRM_DOMAINS" =~ ^[Nn]$ ]]; then
      # Используем первый домен для основных проверок
      PRIMARY_DOMAIN="${DETECTED_DOMAINS[0]}"
      success "Используем домен: $PRIMARY_DOMAIN"
      return 0
    fi
  fi
  
  # Если не нашли или пользователь отказался — спрашиваем вручную
  echo ""
  info "Не удалось авто-определить домены или вы отказались."
  read -p "🌐 Введите основной домен для проверок (например, app.yoursite.st): " PRIMARY_DOMAIN
  if [ -z "$PRIMARY_DOMAIN" ]; then
    error "Домен обязателен для проверок!"
    return 1
  fi
  success "Используем домен: $PRIMARY_DOMAIN"
}

# ===== ЗАГРУЗКА ИЛИ СОЗДАНИЕ КОНФИГА =====
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  info "Загружены настройки из $CONFIG_FILE"
else
  header "⚙️ ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА"
  echo "Введите данные для резервного сервера (бэкапы):"
  echo ""
  
  # IP сервера (обязательно)
  while [ -z "$BACKUP_SERVER" ]; do
    read -p "🌐 IP адрес резервного сервера: " BACKUP_SERVER
    if [ -z "$BACKUP_SERVER" ]; then
      error "IP адрес обязателен!"
    fi
  done
  
  # Пользователь (по умолчанию root)
  read -p "👤 Пользователь на сервере [root]: " BACKUP_USER_INPUT
  if [ -z "$BACKUP_USER_INPUT" ]; then
    BACKUP_USER="root"
    success "Используем пользователя по умолчанию: root"
  else
    BACKUP_USER="$BACKUP_USER_INPUT"
  fi
  
  # Путь для бэкапов (по умолчанию /root/bedolaga-backups)
  read -p "📁 Путь для бэкапов на сервере [/root/bedolaga-backups]: " BACKUP_REMOTE_DIR_INPUT
  if [ -z "$BACKUP_REMOTE_DIR_INPUT" ]; then
    BACKUP_REMOTE_DIR="/root/bedolaga-backups"
    success "Используем путь по умолчанию: /root/bedolaga-backups"
  else
    BACKUP_REMOTE_DIR="$BACKUP_REMOTE_DIR_INPUT"
  fi
  
  # Количество бэкапов (по умолчанию 7)
  read -p "📦 Количество хранимых бэкапов [7]: " BACKUP_RETENTION_INPUT
  if [ -z "$BACKUP_RETENTION_INPUT" ]; then
    BACKUP_RETENTION="7"
    success "Храним бэкапов: 7"
  else
    BACKUP_RETENTION="$BACKUP_RETENTION_INPUT"
  fi
  
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
    info "Для сброса: rm $CONFIG_FILE"
  else
    info "Настройки не сохранены — будут запрошены при следующем запуске"
  fi
  echo ""
fi

# ===== ПУТИ К КОМПОНЕНТАМ =====
BOT_DIR="/opt/remnawave-bedolaga-telegram-bot"
CABINET_DIR="/opt/bedolaga-cabinet"
CADDY_DIR="/opt/caddy"
LOCAL_BACKUP_DIR="/root/bedolaga-local-backups"
REPORT_FILE="/root/bedolaga-report-$(date +%Y%m%d-%H%M).txt"

# ===== ЛОГИРОВАНИЕ =====
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
  info "Храним последние $BACKUP_RETENTION бэкапов..."
  
  local BACKUP_COUNT=$(ls -1d "$LOCAL_BACKUP_DIR"/bedolaga-full-backup-* 2>/dev/null | wc -l)
  
  if [ "$BACKUP_COUNT" -gt "$BACKUP_RETENTION" ]; then
    local TO_DELETE=$((BACKUP_COUNT - BACKUP_RETENTION))
    info "Найдено $BACKUP_COUNT бэкапов. Удаляем $TO_DELETE старых..."
    
    ls -1d "$LOCAL_BACKUP_DIR"/bedolaga-full-backup-* 2>/dev/null | head -n "$TO_DELETE" | while read OLD_BACKUP; do
      local BACKUP_DATE=$(basename "$OLD_BACKUP" | sed 's/bedolaga-full-backup-//')
      local BACKUP_SIZE=$(du -sh "$OLD_BACKUP" 2>/dev/null | awk '{print $1}')
      
      info "Удаляем бэкап от $BACKUP_DATE ($BACKUP_SIZE)..."
      rm -rf "$OLD_BACKUP" && success "Бэкап от $BACKUP_DATE удалён ✅" || error "Не удалось удалить бэкап от $BACKUP_DATE ❌"
      
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
info "Локальных бэкапов хранится: $BACKUP_RETENTION"
echo ""

# ===== АВТО-ДЕТЕКТ ДОМЕНОВ =====
detect_domains || { error "Не удалось определить домен — проверки могут не работать"; }

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

# ===== МЕНЮ: ИЗМЕНИТЬ НАСТРОЙКИ =====
if [ "$ACTION" = "4" ]; then
  header "⚙️ ИЗМЕНЕНИЕ НАСТРОЕК"
  rm -f "$CONFIG_FILE"
  info "Настройки сброшены. Перезапустите скрипт для ввода новых данных."
  exit 0
fi

# ===== ФУНКЦИЯ БЭКАПА =====
do_backup() {
  header "📦 СОЗДАНИЕ БЭКАПА"
  local BACKUP_DIR="$LOCAL_BACKUP_DIR/bedolaga-full-backup-$(date +%Y%m%d-%H%M)"
  mkdir -p "$BACKUP_DIR/bot" "$BACKUP_DIR/cabinet" "$BACKUP_DIR/caddy"
  log "Создана папка: $BACKUP_DIR"

  # Конфиги бота
  info "Бэкап конфигов бота..."
  cd "$BOT_DIR" || { error "Папка бота не найдена"; return 1; }
  cp .env docker-compose.yml "$BACKUP_DIR/bot/"
  check_backup_file "$BACKUP_DIR/bot/.env" "Конфиг .env"
  check_backup_file "$BACKUP_DIR/bot/docker-compose.yml" "Конфиг docker-compose.yml"

  # БД
  info "Бэкап базы данных..."
  local POSTGRES_VOLUME=$(docker volume ls | grep postgres_data | awk '{print $2}')
  if [ -n "$POSTGRES_VOLUME" ]; then
    docker run --rm -v "$POSTGRES_VOLUME":/source -v "$BACKUP_DIR/bot":/backup alpine tar -czf /backup/postgres_data.tar.gz -C /source .
    check_backup_file "$BACKUP_DIR/bot/postgres_data.tar.gz" "Бэкап БД" || { error "Бэкап БД не создан!"; return 1; }
  else
    error "Том БД не найден"
  fi

  # Redis
  info "Бэкап Redis..."
  local REDIS_VOLUME=$(docker volume ls | grep redis_data | awk '{print $2}')
  if [ -n "$REDIS_VOLUME" ]; then
    docker run --rm -v "$REDIS_VOLUME":/source -v "$BACKUP_DIR/bot":/backup alpine tar -czf /backup/redis_data.tar.gz -C /source .
    check_backup_file "$BACKUP_DIR/bot/redis_data.tar.gz" "Бэкап Redis"
  fi

  # Кабинет
  info "Бэкап кабинета..."
  cd "$CABINET_DIR" 2>/dev/null && { cp .env package*.json "$BACKUP_DIR/cabinet/" 2>/dev/null || true; cp -r src/ "$BACKUP_DIR/cabinet/" 2>/dev/null || true; }
  [ -f "$BACKUP_DIR/cabinet/.env" ] && success "Конфиг кабинета сохранён ✅" || info "Конфиг кабинета не найден (пропущено)"
  [ -d "$BACKUP_DIR/cabinet/src" ] && success "Исходный код кабинета сохранён ✅" || info "Исходный код кабинета не найден (пропущено)"

  # Caddy
  [ -d "$CADDY_DIR" ] && { cp "$CADDY_DIR/Caddyfile" "$BACKUP_DIR/caddy/" 2>/dev/null || true; success "Caddy сохранён ✅"; }

  # Копирование на сервер
  info "Копирование на резервный сервер..."
  read -s -p "🔐 Введите пароль для $BACKUP_USER@$BACKUP_SERVER: " BACKUP_PASS
  echo
  echo "$BACKUP_PASS" | scp -r -o StrictHostKeyChecking=no "$BACKUP_DIR" "${BACKUP_USER}@${BACKUP_SERVER}:${BACKUP_REMOTE_DIR}/" && \
    success "Бэкап скопирован на $BACKUP_SERVER ✅" || error "Не удалось скопировать бэкап ❌"
  
  log "Бэкап завершён: $BACKUP_DIR"
  
  # Ротация бэкапов
  rotate_backups
  
  return 0
}

# ===== ФУНКЦИЯ ОБНОВЛЕНИЯ =====
do_update() {
  header "🔄 ОБНОВЛЕНИЕ"
  info "Запускаю обновление компонентов..."

  # Бот
  info "Обновление бота..."
  cd "$BOT_DIR" || { error "Папка бота не найдена"; return 1; }
  git pull origin main && \
  docker compose down && \
  docker compose up -d --build bot && \
  sleep 10 && \
  (docker compose ps | grep -q "remnawave_bot.*healthy" && success "Бот: healthy ✅" || error "Бот: не healthy ⚠️") || error "Ошибка обновления бота ❌"

  # Кабинет
  info "Обновление кабинета..."
  cd "$CABINET_DIR" || { error "Папка кабинета не найдена"; return 1; }
  git pull origin main && \
  npm install && \
  npm run build && \
  docker compose up -d --build cabinet-frontend && \
  sleep 15 && \
  (docker exec cabinet_frontend wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ 2>&1 | grep -q "200\|exists" && success "Кабинет: healthy ✅" || error "Кабинет: healthcheck failed ⚠️") || error "Ошибка обновления кабинета ❌"

  # Caddy
  info "Перезапуск Caddy..."
  if [ -d "$CADDY_DIR" ]; then
    cd "$CADDY_DIR" && docker compose down && docker compose up -d --build && success "Caddy перезапущен ✅"
  else
    docker restart remnawave_caddy && success "Caddy перезапущен (restart) ✅" || error "Ошибка перезапуска Caddy ❌"
  fi
  
  log "Обновление завершено"
  return 0
}

# ===== ФУНКЦИЯ ПРОВЕРКИ =====
do_check() {
  header "✅ ПРОВЕРКА"
  local STATUS=0

  # Контейнеры
  info "Статус контейнеров:"
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "remnawave|cabinet" | tee -a "$REPORT_FILE"
  if docker ps --format "{{.Status}}" | grep -E "remnawave|cabinet" | grep -qv "healthy"; then
    error "⚠️ Есть контейнеры не в healthy"
    STATUS=1
  else
    success "Все контейнеры: healthy 🟢"
  fi

  # Кабинет (используем авто-детект домена)
  if [ -n "$PRIMARY_DOMAIN" ]; then
    info "Проверка кабинета: $PRIMARY_DOMAIN..."
    if curl -s -o /dev/null -w "%{http_code}" "https://$PRIMARY_DOMAIN" | grep -q "200"; then
      success "Кабинет ($PRIMARY_DOMAIN): HTTP 200 🟢"
    else
      error "Кабинет ($PRIMARY_DOMAIN): не отвечает ❌"
      STATUS=1
    fi
  else
    info "Домен не определён — пропускаем проверку кабинета"
  fi

  # API endpoint (проверяем через hooks или api поддомен, если найден)
  info "Проверка API endpoint..."
  # Пытаемся угадать API домен
  local API_DOMAIN=""
  if [[ "$PRIMARY_DOMAIN" =~ ^app\. ]]; then
    API_DOMAIN="${PRIMARY_DOMAIN/app./api.}"
  elif [[ "$PRIMARY_DOMAIN" =~ ^hooks\. ]]; then
    API_DOMAIN="$PRIMARY_DOMAIN"
  else
    API_DOMAIN="api.$PRIMARY_DOMAIN"
  fi
  
  API_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 "https://$API_DOMAIN" 2>/dev/null || echo "000")
  if [[ "$API_CODE" =~ ^(200|404|405|401|403)$ ]]; then
    success "API endpoint ($API_DOMAIN) доступен (код: $API_CODE) 🟢"
  else
    # Пробуем fallback на hooks
    FALLBACK_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k --connect-timeout 5 "https://hooks.$(echo $PRIMARY_DOMAIN | sed 's/^[^.]*\.//')" 2>/dev/null || echo "000")
    if [[ "$FALLBACK_CODE" =~ ^(200|404|405|401|403)$ ]]; then
      success "API endpoint (fallback) доступен (код: $FALLBACK_CODE) 🟢"
    else
      error "API endpoint не отвечает (код: $API_CODE) ❌"
      STATUS=1
    fi
  fi

  return $STATUS
}

# ===== ФУНКЦИЯ ОТЧЁТА =====
show_report() {
  header "📊 ОТЧЁТ"
  echo "Время завершения: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Отчёт сохранён: $REPORT_FILE"
  echo ""
  cat "$REPORT_FILE"
  echo ""
  if [ $? -eq 0 ]; then
    success "🎉 Все операции завершены успешно!"
  else
    error "⚠️ Завершено с предупреждениями — проверь логи выше"
  fi
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
        info "Обновление отменено пользователем"
      fi
    else
      error "Бэкап завершился с ошибкой — обновление отменено"
    fi
    ;;
esac

# Финальная проверка и отчёт
do_check
CHECK_RESULT=$?
show_report
exit $CHECK_RESULT