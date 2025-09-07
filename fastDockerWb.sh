#!/bin/bash
set -e

LOG() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
ERR() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# Проверка, что запускаем от root
if [[ $EUID -ne 0 ]]; then
   ERR "Запусти скрипт от root"
fi

LOG "Устанавливаю зависимости..."
apt update -y
apt install -y ca-certificates curl gnupg lsb-release iptables apt-transport-https --no-install-recommends

LOG "Добавляю ключ GPG и репозиторий Docker..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)

echo \
  "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/debian $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

LOG "Ставлю docker-ce, docker-ce-cli, containerd.io и docker-compose-plugin..."
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --no-install-recommends

LOG "Переключаю iptables в режим legacy (обязательно для Wiren Board 8)..."
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

LOG "Перезапускаю docker..."
systemctl restart docker || true

LOG "Тестирую docker hello-world..."
if docker run --rm hello-world >/dev/null 2>&1; then
  LOG "Docker установлен и работает!"
else
  ERR "Docker установлен, но тестовый контейнер не запустился."
fi

LOG "Готово. Можно использовать docker и docker compose."
