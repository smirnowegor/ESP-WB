#!/bin/bash
# Устанавливаем строгий режим: скрипт прервется при любой ошибке.
set -e

# --- Функции для красивого вывода ---
# LOG для информационных сообщений (зеленый цвет)
LOG() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
# ERR для сообщений об ошибках (красный цвет), завершает скрипт
ERR() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# --- Начало скрипта ---

# 1. Проверка, что скрипт запущен от имени суперпользователя (root)
if [[ $EUID -ne 0 ]]; then
   ERR "Этот скрипт необходимо запускать от имени root или через sudo."
fi

LOG "Шаг 1: Установка базовых зависимостей..."
apt-get update -y
# Устанавливаем пакеты, необходимые для добавления репозиториев и для Docker
apt-get install -y ca-certificates curl gnupg lsb-release iptables apt-transport-https --no-install-recommends

# 2. ВАЖНЫЙ ШАГ: Переключаем iptables в режим legacy ПЕРЕД установкой Docker
LOG "Шаг 2: Переключение iptables в режим legacy для совместимости..."
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
# Этот шаг критичен для корректного запуска Docker на некоторых системах, включая Wiren Board.

LOG "Шаг 3: Добавление официального GPG ключа и репозитория Docker..."
# Создаем директорию для ключей, если ее нет
install -m 0755 -d /etc/apt/keyrings
# Скачиваем ключ Docker и сохраняем его
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
# Даем правильные права на файл ключа
chmod a+r /etc/apt/keyrings/docker.asc

# Определяем архитектуру и кодовое имя дистрибутива
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)

# Добавляем репозиторий Docker в систему
echo \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $CODENAME stable" > /etc/apt/sources.list.d/docker.list

LOG "Шаг 4: Установка Docker Engine..."
apt-get update -y
# Устанавливаем пакеты Docker
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --no-install-recommends

LOG "Шаг 5: Проверка статуса Docker..."
# Даем системе несколько секунд, чтобы служба запустилась
sleep 5
# Проверяем, что служба Docker активна
if ! systemctl is-active --quiet docker; then
    LOG "Служба Docker не запустилась автоматически, пробую запустить вручную..."
    systemctl restart docker
    sleep 5
fi

LOG "Шаг 6: Тестирование установки Docker..."
# Запускаем тестовый контейнер hello-world
if docker run --rm hello-world >/dev/null 2>&1; then
  LOG "🎉 Docker успешно установлен и работает!"
else
  # Если тест не прошел, выводим подробную информацию для диагностики
  ERR "Docker установлен, но тестовый контейнер не запустился. Проверьте статус службы: systemctl status docker.service"
fi

LOG "Готово. Можно использовать docker и docker compose."
