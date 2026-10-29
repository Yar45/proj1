#!/usr/bin/env bash
set -euo pipefail

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: пожалуйста, запустите скрипт с правами суперпользователя: sudo $0"
  exit 1
fi

echo "=========================================================="
echo "          Установка и запуск Hysteria 2 в Docker          "
echo "=========================================================="

# --- 1. Сбор параметров конфигурации ---
DOMAIN="${DOMAIN:-${1:-}}"
if [ -z "$DOMAIN" ]; then
  read -e -rp "1. Введите домен сервера: " DOMAIN
  while [ -z "$DOMAIN" ]; do
    read -e -rp "   Домен не может быть пустым. Введите домен: " DOMAIN
  done
else
  echo "1. Домен сервера: $DOMAIN"
fi

# Проверка наличия .pem сертификатов Let's Encrypt
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
  echo "Ошибка: SSL-сертификаты .pem не найдены для $DOMAIN:"
  echo "  Cert: $CERT_PATH"
  echo "  Key:  $KEY_PATH"
  echo "Убедитесь, что сертификат выпущен (например, через 3x-ui-install.sh или certbot)."
  exit 1
fi

echo "   [OK] Найдены .pem сертификаты для $DOMAIN"

# Порт подключения (UDP)
read -e -rp "2. Введите порт для Hysteria 2 (UDP) [по умолчанию 443]: " INPUT_PORT
HY2_PORT="${INPUT_PORT:-443}"

# Пароль авторизации
GEN_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16 || echo "Hy2_$(date +%s)")
read -e -rp "3. Введите пароль подключения [Enter для генерации: $GEN_PASS]: " INPUT_PASS
HY2_PASSWORD="${INPUT_PASS:-$GEN_PASS}"

# URL маскировки (Masquerade)
DEFAULT_MASQ="https://news.ycombinator.com/"
read -e -rp "4. Введите URL для маскировки [Enter для $DEFAULT_MASQ]: " INPUT_MASQ
MASQ_URL="${INPUT_MASQ:-$DEFAULT_MASQ}"

echo ""
echo "Параметры для развертывания:"
echo "  - Домен:          $DOMAIN"
echo "  - Порт (UDP):     $HY2_PORT"
echo "  - Пароль:         $HY2_PASSWORD"
echo "  - Cert (.pem):    $CERT_PATH"
echo "  - Key (.pem):     $KEY_PATH"
echo "  - Маскировка:     $MASQ_URL"
echo ""

# --- 2. Настройка системы и фаервола (UFW) ---
echo "=== 2. Оптимизация сетевых буферов и фаервол (UFW) ==="
INSTALL_DIR="/opt/hysteria"
mkdir -p "$INSTALL_DIR"

# 1. Чтение и фиксация изначальных системных значений
OLD_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || cat /proc/sys/net/core/rmem_max 2>/dev/null || echo "212992")
OLD_WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null || cat /proc/sys/net/core/wmem_max 2>/dev/null || echo "212992")

echo "Изначальные значения сетевых буферов:"
echo "  - net.core.rmem_max: ${OLD_RMEM}"
echo "  - net.core.wmem_max: ${OLD_WMEM}"

# Сохранение в отдельный файл бэкапа (только если файл еще не создан)
BACKUP_FILE="${INSTALL_DIR}/sysctl_backup.txt"
if [ ! -f "$BACKUP_FILE" ]; then
  cat <<EOF > "$BACKUP_FILE"
# Исходные значения системных буферов до установки Hysteria 2 ($(date))
net.core.rmem_max=${OLD_RMEM}
net.core.wmem_max=${OLD_WMEM}
EOF
  echo "  [OK] Исходные параметры сохранены в $BACKUP_FILE"
else
  echo "  [INFO] Файл с исходными значениями уже существует: $BACKUP_FILE"
fi

# 2. Увеличение системных буферов UDP/QUIC (рекомендация Hysteria 2)
echo "Увеличение буферов до 8388608 (8 MiB)..."
sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1 || true

# Сохранение параметров в sysctl.conf
sed -i '/net\.core\.rmem_max/d' /etc/sysctl.conf 2>/dev/null || true
sed -i '/net\.core\.wmem_max/d' /etc/sysctl.conf 2>/dev/null || true
echo "net.core.rmem_max=8388608" >> /etc/sysctl.conf
echo "net.core.wmem_max=8388608" >> /etc/sysctl.conf

# Настройка UFW
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${HY2_PORT}/udp" comment 'Hysteria 2'
  ufw status | grep "$HY2_PORT" || true
fi

# --- 3. Создание конфигурационных файлов ---
echo ""
echo "=== 3. Генерация конфигурации Hysteria 2 ==="

cat <<EOF > "${INSTALL_DIR}/hysteria.yaml"
listen: :${HY2_PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true

sniff:
  enable: true
  timeout: 2s

acl:
  inline:
    # 1. Отключение UDP 443 внутри туннеля (стабильный YouTube без буферизации)
    #- reject(all, udp/443)
    # 2. Защита от спама (25 порт)
    #- reject(all, tcp/25)
    # 3. Защита локальной сети сервера
    - reject(127.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(fc00::/7)
    # 4. Защита от абуз за торренты
    #- reject(geosite:bittorrent)
    # 5. Блокировка рекламы и трекеров
    #- reject(geosite:category-ads-all)
    # 6. Блокировка всех российских IP-адресов
    #- reject(geoip:ru)
    # 7. Разрешить всё остальное
    - direct(all)
EOF

cat <<EOF > "${INSTALL_DIR}/docker-compose.yaml"
services:
  hysteria:
    image: tobyxdd/hysteria
    container_name: hysteria
    restart: always
    network_mode: "host"
    cap_add:
      - NET_ADMIN
    volumes:
      - ./hysteria.yaml:/etc/hysteria.yaml
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: ["server", "-c", "/etc/hysteria.yaml"]
EOF

# --- 4. Запуск контейнера ---
echo ""
echo "=== 4. Запуск Hysteria 2 в Docker ==="
cd "$INSTALL_DIR"
docker compose up -d

# Небольшая пауза для проверки запуска
sleep 2
if docker ps | grep -q "hysteria"; then
  echo "[OK] Контейнер Hysteria 2 успешно запущен!"
else
  echo "[!] Ошибка: контейнер не запустился. Логи:"
  docker logs hysteria || true
  exit 1
fi

# Формирование клиентской ссылки
CLIENT_LINK="hy2://${HY2_PASSWORD}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#Hysteria2-${DOMAIN}"

echo ""
echo "=========================================================="
echo "          Hysteria 2 успешно развернута!                  "
echo "=========================================================="
echo "Параметры подключения:"
echo "  Сервер (хост):  $DOMAIN"
echo "  Порт (UDP):     $HY2_PORT"
echo "  Пароль:         $HY2_PASSWORD"
echo "  SNI:            $DOMAIN"
echo ""
echo "Ссылка для импорта в приложение (v2rayN, Nekobox, Happ, Shadowrocket, Streisand):"
echo ""
echo "  $CLIENT_LINK"
echo ""
echo "Пример конфигурации для клиента (config.yaml):"
echo "----------------------------------------------------------"
cat <<EOF
server: ${DOMAIN}:${HY2_PORT}
auth: ${HY2_PASSWORD}
tls:
  sni: ${DOMAIN}
  insecure: false
fastOpen: true
EOF
echo "Управление: cd /opt/hysteria && docker compose logs -f"
echo "Бэкап сетевых буферов:  /opt/hysteria/sysctl_backup.txt"
echo "=========================================================="
