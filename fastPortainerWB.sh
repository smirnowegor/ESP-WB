#!/bin/bash
set -e

BIG_DISK="/mnt/data"
PORTAINER_DIR="$BIG_DISK/udobnidom/portainer"

echo "=== Установка Portainer на большой раздел ==="

# Проверка, где хранит данные Docker
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "")
if [[ -n "$DOCKER_ROOT" && "$DOCKER_ROOT" != "$BIG_DISK"* ]]; then
    echo "[WARN] Docker хранит образы в $DOCKER_ROOT (rootfs)."
    echo "       Образ Portainer (~250МБ) займёт место на маленьком разделе!"
    echo "       Рекомендуется перенести Docker data-root на $BIG_DISK."
fi

# Запрос порта
DEFAULT_PORT="9000"
read -p "Введите порт для Portainer UI (по умолчанию: ${DEFAULT_PORT}): " USER_PORT
PORT_TO_USE="${USER_PORT:-$DEFAULT_PORT}"
echo "Portainer UI будет доступен на порту: ${PORT_TO_USE}"

# Очистка старой установки
echo "Очищаю предыдущую установку Portainer..."
docker rm -f portainer 2>/dev/null || true
docker rmi portainer/portainer-ce:latest 2>/dev/null || true
rm -rf "$PORTAINER_DIR"

# Создание структуры
mkdir -p "$PORTAINER_DIR/data"

# Создание compose.yaml
cat > "$PORTAINER_DIR/compose.yaml" <<EOL
version: '3.8'
services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:latest
    command: -H unix:///var/run/docker.sock
    restart: always
    ports:
      - "${PORT_TO_USE}:9000"
      - "8000:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $PORTAINER_DIR/data:/data
EOL

# Запуск
cd "$PORTAINER_DIR"
docker compose up -d

# Вывод ссылки
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "---------------------------------------------------------"
echo "Portainer запущен!"
echo "Адрес: http://${SERVER_IP}:${PORT_TO_USE}/"
echo "При первом входе создайте учётную запись администратора."
echo "Данные Portainer: $PORTAINER_DIR/data"
echo "---------------------------------------------------------"
