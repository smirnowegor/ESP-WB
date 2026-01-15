#!/bin/bash
set -e

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    ERR "Этот скрипт необходимо запускать от имени root."
fi

# --- ИСПРАВЛЕНИЕ 1: Удаление конфликтов (даже если докер вроде бы есть) ---
LOG "Шаг 0: Подготовка системы и удаление старых/конфликтующих пакетов..."
# Удаляем пакеты Debian, которые конфликтуют с Docker CE
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg >/dev/null 2>&1 || true
done

# Теперь проверяем, установлен ли именно Docker CE
if command -v docker &> /dev/null && docker info 2>/dev/null | grep -q "Docker Root Dir"; then
    LOG "Docker CE корректно установлен. Пропускаем тяжелую установку."
else
    LOG "Шаг 1: Установка зависимостей..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release iptables apt-transport-https rsync --no-install-recommends

    LOG "Шаг 2: Настройка iptables (legacy)..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

    LOG "Шаг 3: Добавление репозитория..."
    install -m 0755 -d /etc/apt/keyrings
    # Используем pipe в gpg, так надежнее чем скачивать файл
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    ARCH=$(dpkg --print-architecture)
    CODENAME=$(lsb_release -cs)
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list

    LOG "Шаг 4: Установка Docker Engine..."
    # --- ИСПРАВЛЕНИЕ 2: Лечим ошибку 404 ---
    LOG "Очистка кэша APT для предотвращения ошибок 404..."
    rm -rf /var/lib/apt/lists/*
    apt-get update -y

    # Ставим с флагом --fix-missing
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin --no-install-recommends
fi

LOG "Шаг 5: Выбор диска для данных."

# (Твой код выбора диска - он хороший, оставляем как есть)
mapfile -t raw_opts < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%0.1fG free)\n", $6, $4/1073741824}' | sort -k2 -hr)
raw_opts+=("/var/lib/docker (Оставить по умолчанию)")

if [ ${#raw_opts[@]} -le 1 ]; then
    WARN "Нет подходящих разделов. Оставляем /var/lib/docker."
    DOCKER_PATH="/var/lib/docker"
else
    echo "Куда установить данные Docker?"
    for i in "${!raw_opts[@]}"; do
        echo " $((i+1))) ${raw_opts[i]}"
    done

    if [[ -n "${DOCKER_DATA_CHOICE:-}" ]]; then
        CHOICE="${DOCKER_DATA_CHOICE}"
    else
        if [[ -e /dev/tty && -c /dev/tty ]]; then
            while true; do
                read -rp "Ваш выбор: " CHOICE < /dev/tty || CHOICE=""
                [[ -z "$CHOICE" ]] && CHOICE=1
                if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#raw_opts[@]}" ]; then
                    break
                fi
                echo "Неверно."
            done
        else
            CHOICE=1
        fi
    fi

    sel_index=$((CHOICE-1))
    sel_opt="${raw_opts[$sel_index]}"

    if [[ "$sel_opt" =~ "/var/lib/docker" ]]; then
        DOCKER_PATH="/var/lib/docker"
    else
        MOUNT_POINT=$(echo "$sel_opt" | sed -E 's/ \([0-9.]+G free\)//; s/ \(Оставить по умолчанию\)//')
        DOCKER_PATH="${MOUNT_POINT%/}/docker"
    fi
fi

CURRENT_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

if [[ "$DOCKER_PATH" == "$CURRENT_DOCKER_PATH" ]]; then
    LOG "Путь совпадает ($DOCKER_PATH). Изменения не нужны."
    # Убеждаемся, что сервис включен в автозагрузку
    systemctl enable docker
    exit 0
fi

LOG "Шаг 6: Настройка и перенос в '$DOCKER_PATH'..."

mkdir -p "$(dirname "$DOCKER_PATH")"
mkdir -p /etc/docker

# --- ИСПРАВЛЕНИЕ 3: Защита контроллера от переполнения логами ---
LOG "Применяю настройки ротации логов (защита от переполнения диска)..."
cat <<EOF > /etc/docker/daemon.json
{
  "data-root": "$DOCKER_PATH",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

LOG "Остановка Docker..."
systemctl stop docker || true

LOG "Перенос данных (rsync)..."
mkdir -p "$DOCKER_PATH"
rsync -a --info=progress2 "$CURRENT_DOCKER_PATH/" "$DOCKER_PATH/"

LOG "Запуск Docker..."
systemctl start docker
systemctl enable docker

LOG "Шаг 7: Проверка..."
sleep 3
NEW_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "Error")

if [[ "$NEW_DOCKER_PATH" == "$DOCKER_PATH" ]]; then
    LOG "🎉 Успех! Новый путь: $NEW_DOCKER_PATH"
    LOG "Версия Docker: $(docker --version)"
    LOG "Старую папку '$CURRENT_DOCKER_PATH' можно удалить вручную."
else
    ERR "Ошибка! Путь не изменился: $NEW_DOCKER_PATH"
