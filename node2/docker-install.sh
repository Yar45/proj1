#!/usr/bin/env bash
set -euo pipefail

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: пожалуйста, запустите скрипт с правами суперпользователя: sudo $0"
  exit 1
fi

echo "=========================================================="
echo "         Установка официального Docker и Compose          "
echo "=========================================================="

# 1. Удаление устаревших/конфликтующих пакетов
echo "1. Удаление старых версий пакетов..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt remove -y "$pkg" >/dev/null 2>&1 || true
done

# 2. Установка зависимостей и GPG-ключа Docker
echo "2. Установка зависимостей и добавление официального GPG-ключа..."
apt update
apt install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 3. Добавление официального репозитория Docker
echo "3. Настройка репозитория Docker..."
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# 4. Установка Docker Engine и Compose
echo "4. Установка пакетов Docker..."
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. Включение и проверка сервиса
systemctl enable --now docker

echo ""
echo "=========================================================="
echo "           Docker успешно установлен и запущен!           "
echo "=========================================================="
docker --version
docker compose version
echo "=========================================================="
