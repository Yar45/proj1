#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 3x-ui-install.sh (Версия 3.0 / Полная контейнеризация в Docker Compose)
# 3x-ui + Nginx объединены в один docker-compose.yml без установки Nginx на хост
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: пожалуйста, запустите скрипт с правами суперпользователя: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Проверка наличия шаблонов конфигурации
if [ ! -d "$SCRIPT_DIR/configs" ]; then
  echo "Ошибка: папка с конфигурациями не найдена: $SCRIPT_DIR/configs"
  exit 1
fi

echo "=========================================================="
echo "  3x-ui + Nginx в Docker (Self-Steal SNI + 443 Порт)      "
echo "=========================================================="
echo ""
echo "Выберите роль настраиваемого сервера:"
echo "  1) Российский входной узел (RU - точка входа, сплиттер трафика)"
echo "  2) Зарубежный выходной шлюз (EU - прием туннеля, выход в интернет)"
echo ""
read -rp "Введите номер роли [1 или 2]: " ROLE_CHOICE
while [[ "$ROLE_CHOICE" != "1" && "$ROLE_CHOICE" != "2" ]]; do
  read -rp "Некорректный ввод. Введите 1 (RU) или 2 (EU): " ROLE_CHOICE
done

if [ "$ROLE_CHOICE" == "1" ]; then
  SERVER_ROLE="RU"
  DEFAULT_DOMAIN="ru.example.com"
  ROLE_DESC="Российский входной узел (RU)"
else
  SERVER_ROLE="EU"
  DEFAULT_DOMAIN="eu.example.com"
  ROLE_DESC="Зарубежный выходной шлюз (EU)"
fi

echo ""
echo "----------------------------------------------------------"
echo "Настройка для: $ROLE_DESC"
echo "----------------------------------------------------------"

# --- 1. Интерактивный сбор параметров ---

# 1. Домен сервера
read -e -rp "1. Введите домен сервера [по умолчанию: $DEFAULT_DOMAIN]: " INPUT_DOMAIN
DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"
while [ -z "$DOMAIN" ]; do
  read -e -rp "   Домен не может быть пустым. Введите домен: " DOMAIN
done

# 2. E-mail для Let's Encrypt
while true; do
  read -e -rp "2. Введите ваш e-mail для Let's Encrypt (обязательно): " EMAIL
  EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
  if [ -z "$EMAIL" ]; then
    echo "   [!] Для выпуска SSL-сертификата e-mail обязателен."
  elif [[ "$EMAIL" =~ [^a-zA-Z0-9@._+-] ]]; then
    echo "   [!] Ошибка: e-mail содержит недопустимые символы. Попробуйте снова."
  elif [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "   [!] Некорректный формат e-mail. Попробуйте снова."
  else
    break
  fi
done

# 3. Логин администратора
read -e -rp "3. Введите логин администратора панели [по умолчанию: admin]: " INPUT_USER
PANEL_USER="${INPUT_USER:-admin}"

# 4. Пароль администратора
GEN_PASS=$(tr -dc 'A-Za-z0-9_-' < /dev/urandom 2>/dev/null | head -c 16 || echo "Admin_$(date +%s)")
read -e -rp "4. Введите пароль администратора [Enter для генерации: $GEN_PASS]: " INPUT_PASS
PANEL_PASS="${INPUT_PASS:-$GEN_PASS}"

# 5. Секретный URL-путь (строго 16 случайных символов без префиксов)
RAND_16=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 16 || echo "path$(date +%s)")
DEF_PATH="/${RAND_16}/"
read -e -rp "5. Секретный URL-путь для входа в панель [Enter для генерации: $DEF_PATH]: " INPUT_PATH
PANEL_WEB_BASE_PATH="${INPUT_PATH:-$DEF_PATH}"

# Нормализация URL-пути (должен начинаться и заканчиваться на /)
if [[ ! "$PANEL_WEB_BASE_PATH" =~ ^/ ]]; then
  PANEL_WEB_BASE_PATH="/$PANEL_WEB_BASE_PATH"
fi
if [[ ! "$PANEL_WEB_BASE_PATH" =~ /$ ]]; then
  PANEL_WEB_BASE_PATH="$PANEL_WEB_BASE_PATH/"
fi

# 6. Внутренний порт панели (слушает только локально на 127.0.0.1)
read -e -rp "6. Внутренний порт веб-панели [по умолчанию: 8443]: " INPUT_PANEL_PORT
PANEL_PORT="${INPUT_PANEL_PORT:-8443}"

# 7. Внутренний порт подписок (слушает только локально на 127.0.0.1)
read -e -rp "7. Внутренний порт подписок [по умолчанию: 2087]: " INPUT_SUB_PORT
SUB_PORT="${INPUT_SUB_PORT:-2087}"

# 8. Путь подписок
read -e -rp "8. URL-путь для подписок [по умолчанию: /sub/]: " INPUT_SUB_PATH
SUB_PATH="${INPUT_SUB_PATH:-/sub/}"
if [[ ! "$SUB_PATH" =~ ^/ ]]; then SUB_PATH="/$SUB_PATH"; fi
if [[ ! "$SUB_PATH" =~ /$ ]]; then SUB_PATH="$SUB_PATH/"; fi

# Локальный порт Nginx SSL fallback
NGINX_FALLBACK_PORT="8080"
INSTALL_DIR="/opt/vpn"

echo ""
echo "=========================================================="
echo "Параметры для настройки:"
echo "  - Роль сервера:        $ROLE_DESC"
echo "  - Домен:               $DOMAIN"
echo "  - E-mail:              $EMAIL"
echo "  - Логин панели:        $PANEL_USER"
echo "  - Пароль панели:       $PANEL_PASS"
echo "  - Секретный URL путь:  $PANEL_WEB_BASE_PATH"
echo "  - Вход в панель:       https://$DOMAIN$PANEL_WEB_BASE_PATH (порт 443!)"
echo "  - Сервер подписок:     https://$DOMAIN${SUB_PATH}... (порт 443!)"
echo "  - Каталог сервисов:    $INSTALL_DIR"
echo "=========================================================="
echo ""

# --- 2. Установка Certbot и UFW на хосте (без Nginx на хосте!) ---
echo "=== 2. Установка системных утилит и фаервола ==="
apt update
apt install -y certbot ufw curl

# --- 3. Настройка Фаервола (UFW) ---
echo "=== 3. Настройка фаервола (UFW) ==="
sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw 2>/dev/null || true

ufw default deny incoming
ufw default allow outgoing

# Открываем ТОЛЬКО 22, 80 и 443!
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP / Certbot'
ufw allow 443/tcp comment 'HTTPS / VLESS + REALITY + Web'

# Порты 8443 и 2087 закрыты от внешнего мира
ufw --force enable
ufw status verbose

# --- 4. Получение SSL-сертификата Let's Encrypt через standalone ---
echo "=== 4. Получение SSL-сертификата для $DOMAIN ==="
# Поскольку Docker-контейнеры еще не запущены, порт 80 свободен
if certbot certonly --standalone --agree-tos --non-interactive -m "$EMAIL" -d "$DOMAIN"; then
  echo "[OK] Сертификат успешно получен!"
else
  echo "[!] Ошибка: Не удалось выпустить сертификат для $DOMAIN."
  echo "Убедитесь, что DNS-запись ($DOMAIN) указывает на этот сервер (A для IPv4 или AAAA для IPv6)."
fi

# --- 5. Подготовка каталогов проекта и копирование файлов ---
echo "=== 5. Развертывание файлов конфигурации в $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR/nginx/conf.d"
mkdir -p "$INSTALL_DIR/html"
mkdir -p "$INSTALL_DIR/db"

# 1. Копирование docker-compose.yml
cp "$SCRIPT_DIR/configs/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"

# 2. Подготовка Nginx-конфигурации из шаблона
sed -e "s|{{DOMAIN}}|$DOMAIN|g" \
    -e "s|{{NGINX_FALLBACK_PORT}}|$NGINX_FALLBACK_PORT|g" \
    -e "s|{{SUB_PORT}}|$SUB_PORT|g" \
    -e "s|{{SUB_PATH}}|$SUB_PATH|g" \
    -e "s|{{PANEL_PORT}}|$PANEL_PORT|g" \
    -e "s|{{PANEL_WEB_BASE_PATH}}|$PANEL_WEB_BASE_PATH|g" \
    "$SCRIPT_DIR/configs/nginx.conf" > "$INSTALL_DIR/nginx/conf.d/default.conf"

# 3. Копирование сайта-заглушки (RU или EU)
if [ "$SERVER_ROLE" == "RU" ]; then
  if [ -d "$SCRIPT_DIR/site-ru" ]; then
    echo "Копирование сайта RU в $INSTALL_DIR/html/ ..."
    cp -r "$SCRIPT_DIR/site-ru/"* "$INSTALL_DIR/html/"
  fi
else
  if [ -d "$SCRIPT_DIR/site-eu" ]; then
    echo "Копирование сайта EU в $INSTALL_DIR/html/ ..."
    cp -r "$SCRIPT_DIR/site-eu/"* "$INSTALL_DIR/html/"
  fi
fi

# 4. Настройка вебрута и хука для автопродления через работающий Nginx-контейнер
RENEW_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"
if [ -f "$RENEW_CONF" ]; then
  sed -i "s|authenticator = standalone|authenticator = webroot\nwebroot_path = $INSTALL_DIR/html,|g" "$RENEW_CONF"
fi

mkdir -p /etc/letsencrypt/renewal-hooks/post
cp "$SCRIPT_DIR/configs/reload-hook.sh" /etc/letsencrypt/renewal-hooks/post/reload.sh
chmod +x /etc/letsencrypt/renewal-hooks/post/reload.sh

# --- 6. Запуск Docker Compose стека (3x-ui + Nginx) ---
echo "=== 6. Запуск Docker Compose (3x-ui + Nginx) ==="
cd "$INSTALL_DIR"
docker compose down >/dev/null 2>&1 || true
docker compose up -d

echo "Ожидание инициализации базы данных 3x-ui..."
for i in {1..20}; do
  if docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "Применение учетных данных и секретного URL пути..."
docker exec 3x-ui /app/x-ui setting \
  -username "$PANEL_USER" \
  -password "$PANEL_PASS" \
  -port "$PANEL_PORT" \
  -webBasePath "$PANEL_WEB_BASE_PATH"

docker restart 3x-ui

echo ""
echo "=========================================================="
echo "          Установка $ROLE_DESC завершена!                 "
echo "=========================================================="
echo "Адрес веб-панели управления (через защищенный порт 443):"
echo "  https://$DOMAIN$PANEL_WEB_BASE_PATH"
echo ""
echo "Учетные данные для входа:"
echo "  Логин:          $PANEL_USER"
echo "  Пароль:         $PANEL_PASS"
echo ""
echo "Ссылка на подписку для клиентов (через 443 порт):"
echo "  https://$DOMAIN${SUB_PATH}<ВАШ_ТОКЕН>"
echo ""
echo "Управление контейнерами:"
echo "  cd $INSTALL_DIR && docker compose ps"
echo "  cd $INSTALL_DIR && docker compose logs -f"
echo ""
echo "----------------------------------------------------------"
echo "ИНСТРУКЦИЯ ПО НАСТРОЙКЕ XRAY ВНУТРИ ВЕБ-ПАНЕЛИ:"
echo "----------------------------------------------------------"

if [ "$SERVER_ROLE" == "EU" ]; then
  cat <<EOF
Вы настраиваете Зарубежный сервер (EU - Шлюз):
1. Откройте панель: https://$DOMAIN$PANEL_WEB_BASE_PATH
2. Перейдите в «Подключения» (Inbounds) -> «Добавить подключение»:
   - Протокол:           vless
   - Порт:               443
   - Сеть (Transport):   xhttp (SplitHTTP)
   - Flow:               None (ОБЯЗАТЕЛЬНО ПУСТО!)
   - Безопасность:       Reality
   - uTLS:               firefox
   - Dest (Target):      127.0.0.1:8080   <-- Наш Nginx в Docker!
   - Server Names (SNI): $DOMAIN
   - Нажмите «Сгенерировать» ключи (Private/Public Key и ShortId).
3. Перейдите в «Настройки Xray» -> «Исходящие» (Outbounds):
   - У правила с тегом 'direct' (протокол freedom) укажите Domain Strategy: UseIPv4
     (чтобы в интернет сервер всегда выходил с чистого IPv4).
4. Скопируйте сгенерированные Public Key, ShortId и UUID клиента — они понадобятся для связи с сервером в РФ!
EOF
else
  cat <<EOF
Вы настраиваете Российский сервер (RU - Входной узел):
1. Откройте панель: https://$DOMAIN$PANEL_WEB_BASE_PATH
2. В «Подключениях» (Inbounds) добавьте вход для ваших устройств:
   - Протокол:           vless
   - Порт:               443
   - Сеть (Transport):   xhttp
   - Flow:               None (ПУСТО!)
   - Безопасность:       Reality
   - uTLS:               firefox
   - Dest:               127.0.0.1:8080   <-- Наш Nginx в Docker!
   - Server Names (SNI): $DOMAIN
3. В «Настройки Xray» -> «Исходящие» (Outbounds) добавьте туннель на EU-сервер:
   - Протокол:           vless
   - Адрес:              eu.example.com (или IPv6 адрес EU-сервера)
   - Порт:               443
   - Сеть:               xhttp
   - Безопасность:       Reality
   - SNI:                eu.example.com
   - Fingerprint:        firefox
   - Public Key, ShortId и UUID возьмите из панели EU-сервера!
   - Тег (Tag):          tunnel-to-eu
4. В «Настройки Xray» -> «Правила маршрутизации» (Routing Rules):
   - Правило 1: geosite:category-ru, geoip:ru -> Direct (выход в РФ)
   - Правило 2: geosite:blocked, все остальное -> tunnel-to-eu
EOF
fi

echo "=========================================================="
