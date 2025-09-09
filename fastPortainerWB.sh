#!/bin/bash
set -e

echo "Начинаем установку Portainer..."

# Запрос порта у пользователя
DEFAULT_PORT="9000"
read -p "Введите порт для Portainer UI (по умолчанию: ${DEFAULT_PORT}): " USER_PORT

# Если пользователь ничего не ввёл, используем порт по умолчанию
if [ -z "$USER_PORT" ]; then
    PORT_TO_USE="${DEFAULT_PORT}"
else
    PORT_TO_USE="${USER_PORT}"
fi
echo "Portainer UI будет доступен на порту: ${PORT_TO_USE}"

# Очистка предыдущих установок Portainer (если есть)
echo "Проверяем и удаляем предыдущие установки Portainer..."
if sudo docker ps -a --format '{{.Names}}' | grep -q "^portainer$"; then
    echo "Обнаружен существующий контейнер Portainer. Останавливаем и удаляем его..."
    sudo docker stop portainer
    sudo docker rm portainer
else
    echo "Контейнер Portainer не найден или не запущен."
fi

# Удаляем образы Portainer
if sudo docker images --format '{{.Repository}}' | grep -q "^portainer/portainer-ce$"; then
    echo "Обнаружен образ Portainer. Удаляем его..."
    sudo docker rmi portainer/portainer-ce:latest || true
else
    echo "Образ Portainer не найден."
fi

# Удаляем директории Portainer
echo "Удаляем директории и файлы предыдущих установок Portainer..."
sudo rm -rf /mnt/data/udobnidom/portainer/data
sudo rm -rf /mnt/data/udobnidom/portainer/compose.yaml
echo "Предыдущие установки Portainer очищены."

# Создание новой установки Portainer
echo "Создаём необходимые директории для новой установки..."
sudo mkdir -p /mnt/data/udobnidom/portainer/data

# Создаём файл docker-compose.yaml для Portainer
echo "Создаём файл compose.yaml для Portainer..."
cat <<EOL | sudo tee /mnt/data/udobnidom/portainer/compose.yaml > /dev/null
version: '3.8'

services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:2.31.3
    command: -H unix:///var/run/docker.sock
    restart: always
    ports:
      - "${PORT_TO_USE}:9000"
      - "8000:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/data/udobnidom/portainer/data:/data
EOL

# Переходим в директорию Portainer и запускаем контейнер
echo "Переходим в директорию /mnt/data/udobnidom/portainer/ и запускаем Portainer..."
cd /mnt/data/udobnidom/portainer/
sudo docker compose up -d

echo "Portainer успешно установлен и запускается!"

# Вывод ссылки для доступа к Portainer
echo ""
echo "---------------------------------------------------------"
echo "Для доступа к Portainer перейдите по следующей ссылке:"
echo ""
SERVER_IP=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
fi
if [ -z "$SERVER_IP" ]; then
    echo "Не удалось автоматически определить IP-адрес. Попробуйте найти его вручную командой 'ip a' или 'ifconfig'."
    echo "По умолчанию будет использоваться localhost, но это может быть некорректно для внешнего доступа."
    SERVER_IP="localhost"
fi
echo "   http://${SERVER_IP}:${PORT_TO_USE}/"
echo ""
echo "---------------------------------------------------------"
echo "При первом входе вам нужно будет создать учётную запись администратора."
echo ""

# Возвращаемся в домашнюю директорию пользователя
cd ~
echo "Скрипт завершён. Вы вернулись в домашнюю директорию."
