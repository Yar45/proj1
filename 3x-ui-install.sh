#!/usr/bin/env bash
set -euo pipefail

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: пожалуйста, запустите скрипт с правами суперпользователя: sudo $0"
  exit 1
fi

echo "=========================================================="
echo "       Установка и первоначальная настройка 3x-ui         "
echo "=========================================================="

# --- 1. Сбор параметров доступа, сети и домена ---
SERVER_IP="${SERVER_IP:-${1:-}}"
if [ -z "$SERVER_IP" ]; then
  read -rp "1. Введите внешний IP-адрес сервера: " SERVER_IP
  while [ -z "$SERVER_IP" ]; do
    read -rp "   IP-адрес не может быть пустым. Введите IP сервера: " SERVER_IP
  done
else
  echo "1. IP-адрес сервера: $SERVER_IP"
fi

DOMAIN="${DOMAIN:-${2:-}}"
EMAIL="${EMAIL:-${3:-}}"
if [ -z "$DOMAIN" ]; then
  read -rp "2. Введите ваш домен (или Enter, чтобы пропустить выпуск SSL): " DOMAIN
else
  echo "2. Домен: $DOMAIN"
fi

if [ -n "$DOMAIN" ]; then
  while true; do
    read -e -rp "   Введите ваш e-mail для Let's Encrypt (обязательно): " EMAIL
    # Удаляем случайные пробелы
    EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
    
    if [ -z "$EMAIL" ]; then
      echo "   [!] Для выпуска SSL-сертификата e-mail обязателен."
    elif [[ "$EMAIL" =~ [^a-zA-Z0-9@._+-] ]]; then
      echo "   [!] Ошибка: e-mail содержит недопустимые символы (проверьте русскую раскладку): '$EMAIL'"
      EMAIL=""
    elif [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      echo "   [!] Некорректный формат e-mail адреса. Попробуйте снова."
      EMAIL=""
    else
      break
    fi
  done
fi

read -rp "3. Введите порт для веб-панели [по умолчанию 2053]: " INPUT_PORT
PANEL_PORT="${INPUT_PORT:-2053}"

read -rp "4. Введите логин администратора [по умолчанию admin]: " INPUT_USER
PANEL_USER="${INPUT_USER:-admin}"

GEN_PASS=$(tr -dc 'A-Za-z0-9_-' < /dev/urandom 2>/dev/null | head -c 12 || echo "Admin_$(date +%s)")
read -rp "5. Введите пароль администратора [Enter для генерации: $GEN_PASS]: " INPUT_PASS
PANEL_PASS="${INPUT_PASS:-$GEN_PASS}"

read -rp "6. Введите секретный путь URL (BasePath) [например: /panel/ или Enter для /]: " INPUT_PATH
PANEL_WEB_BASE_PATH="${INPUT_PATH:-/}"

# Нормализация URL-пути (должен начинаться и заканчиваться на /)
if [[ ! "$PANEL_WEB_BASE_PATH" =~ ^/ ]]; then
  PANEL_WEB_BASE_PATH="/$PANEL_WEB_BASE_PATH"
fi
if [[ ! "$PANEL_WEB_BASE_PATH" =~ /$ ]]; then
  PANEL_WEB_BASE_PATH="$PANEL_WEB_BASE_PATH/"
fi

SUB_PORT="${SUB_PORT:-2087}"
SUB_PATH="${SUB_PATH:-/sub/}"

echo ""
echo "Параметры для настройки:"
echo "  - IP сервера:     $SERVER_IP"
echo "  - Домен:          ${DOMAIN:-'Не указан (только по IP)'}"
if [ -n "$DOMAIN" ]; then
  echo "  - E-mail:         $EMAIL"
fi
echo "  - Порт панели:    $PANEL_PORT"
echo "  - Порт подписки:  $SUB_PORT"
echo "  - Путь подписки:  $SUB_PATH"
echo "  - Логин:          $PANEL_USER"
echo "  - Пароль:         $PANEL_PASS"
echo "  - URL-путь:       $PANEL_WEB_BASE_PATH"
echo ""

echo "=== 2. Настройка фаервола (UFW) ==="
apt update
apt install -y ufw sqlite3

ufw default deny incoming
ufw default allow outgoing

# Открытие необходимых портов
ufw allow 22/tcp comment 'SSH'
ufw allow "${PANEL_PORT}/tcp" comment '3x-ui Panel'
ufw allow "${SUB_PORT}/tcp" comment '3x-ui Subscription'
ufw allow 443/tcp comment 'HTTPS/VLESS'
ufw allow 443/udp comment 'HTTPS/HTTP3'
ufw allow 80/tcp comment 'HTTP/Certbot'

# Включение UFW без интерактивного подтверждения
ufw --force enable
ufw status verbose

echo ""
echo "=== 3. Получение SSL-сертификата через Certbot ==="
if [ -n "$DOMAIN" ]; then
  apt install -y certbot

  echo "Запрос сертификата Let's Encrypt для $DOMAIN ($EMAIL)..."
  if certbot certonly --standalone --agree-tos --non-interactive -m "$EMAIL" -d "$DOMAIN"; then
    echo "Сертификат для $DOMAIN успешно получен!"
  else
    echo "Предупреждение: не удалось получить сертификат для $DOMAIN."
    echo "Убедитесь, что DNS-запись домена (A-запись) указывает на этот сервер."
    echo "Установка продолжается..."
  fi
else
  echo "Выпуск сертификата пропущен."
fi

echo ""
echo "=== 4. Развертывание 3x-ui в Docker ==="
mkdir -p /opt/3x-ui/db
mkdir -p /etc/letsencrypt

cat <<'EOF' > /opt/3x-ui/docker-compose.yml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: always
    network_mode: host
    volumes:
      - ./db/:/etc/x-ui/
      - /etc/letsencrypt/:/root/cert/:ro
EOF

cd /opt/3x-ui
docker compose up -d

echo ""
echo "=== 5. Применение параметров доступа к панели ==="
echo "Ожидание инициализации базы данных..."
for i in {1..20}; do
  if docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "Установка логина, пароля, порта и базового пути..."
docker exec 3x-ui /app/x-ui setting \
  -username "$PANEL_USER" \
  -password "$PANEL_PASS" \
  -port "$PANEL_PORT" \
  -webBasePath "$PANEL_WEB_BASE_PATH"

echo "Настройка SSL-сертификатов и сервера подписок (порт $SUB_PORT)..."
CERT_FILE=""
KEY_FILE=""
SSL_ENABLED="false"

if [ -n "$DOMAIN" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  CERT_FILE="/root/cert/live/$DOMAIN/fullchain.pem"
  KEY_FILE="/root/cert/live/$DOMAIN/privkey.pem"
  SSL_ENABLED="true"
  echo "SSL-сертификаты обнаружены и привязаны к панели и подписке."
fi

sqlite3 /opt/3x-ui/db/x-ui.db <<SQL
UPDATE settings SET value = '$CERT_FILE' WHERE key = 'webCertFile';
UPDATE settings SET value = '$KEY_FILE' WHERE key = 'webKeyFile';
UPDATE settings SET value = 'true' WHERE key = 'subEnable';
UPDATE settings SET value = '$SUB_PORT' WHERE key = 'subPort';
UPDATE settings SET value = '$SUB_PATH' WHERE key = 'subPath';
UPDATE settings SET value = '${DOMAIN:-}' WHERE key = 'subDomain';
UPDATE settings SET value = '$CERT_FILE' WHERE key = 'subCertFile';
UPDATE settings SET value = '$KEY_FILE' WHERE key = 'subKeyFile';
SQL

echo "Перезапуск контейнера для применения всех настроек..."
docker restart 3x-ui

# Формирование пути для вывода
URL_PATH=""
if [ "$PANEL_WEB_BASE_PATH" != "/" ]; then
  URL_PATH="${PANEL_WEB_BASE_PATH#/}"
fi

echo ""
echo "=========================================================="
echo "          3x-ui успешно настроен и запущен!               "
echo "=========================================================="
echo "Панель управления доступна по адресам:"
if [ "$SSL_ENABLED" == "true" ]; then
  echo "  https://$DOMAIN:$PANEL_PORT/$URL_PATH  (Защищено SSL)"
  echo "  http://$SERVER_IP:$PANEL_PORT/$URL_PATH"
  echo ""
  echo "Сервер подписок (Subscription):"
  echo "  https://$DOMAIN:$SUB_PORT$SUB_PATH  (Защищено SSL)"
else
  if [ -n "$DOMAIN" ]; then
    echo "  http://$DOMAIN:$PANEL_PORT/$URL_PATH"
  fi
  echo "  http://$SERVER_IP:$PANEL_PORT/$URL_PATH"
  echo ""
  echo "Сервер подписок (Subscription):"
  echo "  http://${DOMAIN:-$SERVER_IP}:$SUB_PORT$SUB_PATH"
fi
echo ""
echo "Параметры авторизации:"
echo "  Логин:          $PANEL_USER"
echo "  Пароль:         $PANEL_PASS"
echo "  Порт панели:    $PANEL_PORT"
echo "  URL-путь:       $PANEL_WEB_BASE_PATH"
echo "  Порт подписки:  $SUB_PORT"
echo "  Путь подписки:  $SUB_PATH"
echo "=========================================================="
