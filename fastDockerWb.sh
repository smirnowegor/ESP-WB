#!/bin/bash
set -e

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    ERR "Этот скрипт необходимо запускать от имени root."
fi

print_supported_boards() {
    LOG "Скрипт рассчитан на контроллеры: Wiren Board 6/7/8 (включая 8+), где используется Debian Linux и раздел /mnt/data для пользовательских данных."
    LOG "Если у вас не Wiren Board или нет /mnt/data, выберите /var/lib/docker."
}

print_supported_boards

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || ERR "Не найдена команда '$cmd'. Установите пакет и повторите."
}

get_mount_point() {
    local path="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -no TARGET --target "$path" 2>/dev/null || true
    else
        df -P "$path" | awk 'NR==2{print $6}'
    fi
}

check_space_and_inodes() {
    local path="$1"
    local min_bytes=$((2*1024*1024*1024))
    local min_inodes=20000
    local free_bytes
    local free_inodes

    free_bytes=$(df -B1 "$path" | awk 'NR==2{print $4}')
    free_inodes=$(df -Pi "$path" | awk 'NR==2{print $4}')

    if [[ -n "$free_bytes" && "$free_bytes" -lt "$min_bytes" ]]; then
        WARN "Свободного места меньше 2 ГБ на разделе $path. Возможны ошибки при распаковке образов."
    fi

    if [[ -n "$free_inodes" && "$free_inodes" -lt "$min_inodes" ]]; then
        WARN "Мало inode на разделе $path. Возможны ошибки 'no space left on device'."
    fi
}

check_writable_dir() {
    local path="$1"
    mkdir -p "$path"
    local testfile="$path/.write_test_$$"
    if ! (echo "test" > "$testfile") 2>/dev/null; then
        ERR "Нет прав записи в $path. Проверьте раздел и права доступа."
    fi
    rm -f "$testfile"
}

# --- ИСПРАВЛЕНИЕ 1: Удаление конфликтов (даже если докер вроде бы есть) ---
LOG "Шаг 0: Подготовка системы и удаление старых/конфликтующих пакетов..."
# Удаляем пакеты Debian, которые конфликтуют с Docker CE, а также старые пакеты Docker CE
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin; do
    apt-get remove -y $pkg >/dev/null 2>&1 || true
done

SKIP_INSTALL=false
if command -v docker &> /dev/null && docker info 2>/dev/null | grep -q "Docker Root Dir"; then
    LOG "Docker обнаружен. Выполним переустановку для чистой установки."
else
    LOG "Docker не обнаружен. Выполним установку."
fi

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

LOG "Шаг 5: Выбор диска для данных."

# Исключаем tmpfs/devtmpfs, чтобы не выбрать непостоянные разделы.
mapfile -t raw_opts < <(df -T -B1 | awk 'NR>1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay)$/ && $4 > 1073741824 && $7 !~ "^/boot" {printf "%s (%0.1fG free)\n", $7, $4/1073741824}' | sort -k2 -hr)
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
        DOCKER_DATA_DIR="docker"
        if [[ "$MOUNT_POINT" == "/mnt/data" ]]; then
            # Рекомендация WB: хранить образы в /mnt/data/.docker
            DOCKER_DATA_DIR=".docker"
        fi
        DOCKER_PATH="${MOUNT_POINT%/}/$DOCKER_DATA_DIR"
    fi
fi

LOG "Выбран путь для данных Docker: $DOCKER_PATH"

CURRENT_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

NEED_MOVE_DOCKER=true
if [[ "$DOCKER_PATH" == "$CURRENT_DOCKER_PATH" ]]; then
    LOG "Путь совпадает ($DOCKER_PATH). Перенос данных не требуется."
    NEED_MOVE_DOCKER=false
fi

USE_EXTERNAL_STORAGE=true
if [[ "$DOCKER_PATH" == "/var/lib/docker" ]]; then
    USE_EXTERNAL_STORAGE=false
fi

if [[ "$USE_EXTERNAL_STORAGE" == "true" ]]; then
    DATA_MOUNT=$(dirname "$DOCKER_PATH")
    CONTAINERD_TARGET="$DATA_MOUNT/var/lib/containerd"
    ETC_DOCKER_TARGET="$DATA_MOUNT/etc/docker"
else
    CONTAINERD_TARGET="/var/lib/containerd"
    ETC_DOCKER_TARGET="/etc/docker"
fi

LOG "Каталог containerd будет: $CONTAINERD_TARGET"
LOG "Каталог конфигурации Docker будет: $ETC_DOCKER_TARGET"

cleanup_old_docker_data() {
    local path="$1"
    local label="$2"

    if [[ -d "$path" && "$path" != "$DOCKER_PATH" ]]; then
        LOG "Найдены остатки старой установки ($label): $path"
        LOG "Удалить каталог? Это удалит контейнеры и образы в нем. (y/N)"
        if [[ -e /dev/tty && -c /dev/tty ]]; then
            if read -r -t 180 REPLY < /dev/tty; then
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    rm -rf "$path"
                    LOG "Удалено: $path"
                else
                    LOG "Пропускаю удаление: $path"
                fi
            else
                LOG "Время ожидания истекло. Пропускаю удаление: $path"
            fi
        else
            LOG "Нет интерактивного ввода. Пропускаю удаление: $path"
        fi
    fi
}

ensure_link() {
    local link_path="$1"
    local target_path="$2"

    mkdir -p "$target_path"

    if [ -L "$link_path" ]; then
        local resolved
        resolved=$(readlink -f "$link_path" || true)
        if [[ "$resolved" == "$target_path" ]]; then
            return 0
        fi
        rm -f "$link_path"
    elif [ -e "$link_path" ]; then
        local backup_path="${link_path}.bak.$(date +%s)"
        rsync -a "$link_path/" "$target_path/"
        mv "$link_path" "$backup_path"
        LOG "Сохранена резервная копия $link_path в $backup_path"
    fi

    ln -s "$target_path" "$link_path"
}

LOG "Шаг 5.5: Проверки системы и выбранного раздела..."
require_cmd df
require_cmd rsync

DOCKER_ACTIVE=false
if systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_ACTIVE=true
fi

if [[ "$DOCKER_ACTIVE" == "false" ]]; then
    cleanup_old_docker_data "/var/lib/docker" "docker data-root"
    cleanup_old_docker_data "/mnt/data/.docker" "WB data-root"
    cleanup_old_docker_data "/mnt/data/docker" "legacy data-root"
fi

DOCKER_MOUNT=$(get_mount_point "$DOCKER_PATH")
if [[ -z "$DOCKER_MOUNT" ]]; then
    # Папка data-root может не существовать, определяем по родителю.
    DOCKER_MOUNT=$(get_mount_point "$(dirname "$DOCKER_PATH")")
fi
if [[ -z "$DOCKER_MOUNT" ]]; then
    ERR "Не удалось определить точку монтирования для $DOCKER_PATH"
fi

LOG "Точка монтирования выбранного пути: $DOCKER_MOUNT"

if [[ "$USE_EXTERNAL_STORAGE" == "true" && "$DOCKER_MOUNT" == "/" ]]; then
    ERR "Выбранный путь $DOCKER_PATH находится на rootfs (/). Нужен большой раздел (например, /mnt/data)."
fi

SPACE_CHECK_PATH="$DOCKER_PATH"
if [[ ! -e "$SPACE_CHECK_PATH" ]]; then
    SPACE_CHECK_PATH="$(dirname "$DOCKER_PATH")"
fi
check_space_and_inodes "$SPACE_CHECK_PATH"
check_writable_dir "$(dirname "$DOCKER_PATH")"

LOG "Шаг 6: Настройка и перенос в '$DOCKER_PATH'..."

mkdir -p "$(dirname "$DOCKER_PATH")"

LOG "Остановка Docker..."
systemctl stop docker || true
systemctl stop containerd || true

if [[ "$USE_EXTERNAL_STORAGE" == "true" ]]; then
    LOG "Настройка путей Docker и containerd на $DATA_MOUNT (рекомендации WB)..."
    ensure_link "/etc/docker" "$ETC_DOCKER_TARGET"
    ensure_link "/var/lib/containerd" "$CONTAINERD_TARGET"
else
    mkdir -p /etc/docker /var/lib/containerd
fi

LOG "Конфигурация Docker будет записана в /etc/docker/daemon.json"

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

LOG "Перенос данных (rsync)..."
mkdir -p "$DOCKER_PATH"
if [[ "$NEED_MOVE_DOCKER" == "true" ]]; then
    rsync -a --info=progress2 "$CURRENT_DOCKER_PATH/" "$DOCKER_PATH/"
fi

LOG "Запуск Docker..."
systemctl start containerd
systemctl start docker
systemctl enable docker

if ! systemctl is-active --quiet containerd; then
    WARN "containerd не активен. Проверьте: systemctl status containerd"
fi
if ! systemctl is-active --quiet docker; then
    WARN "docker не активен. Проверьте: systemctl status docker"
fi

LOG "Шаг 7: Проверка..."
sleep 3
NEW_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "Error")
CONTAINERD_PATH=$(readlink -f /var/lib/containerd 2>/dev/null || echo "/var/lib/containerd")
ETC_DOCKER_PATH=$(readlink -f /etc/docker 2>/dev/null || echo "/etc/docker")
LOG "containerd dir: $CONTAINERD_PATH"
LOG "docker config dir: $ETC_DOCKER_PATH"

if [[ "$NEW_DOCKER_PATH" == "$DOCKER_PATH" ]]; then
    LOG "🎉 Успех! Новый путь: $NEW_DOCKER_PATH"
    LOG "Версия Docker: $(docker --version)"
    DOCKER_OK=true
    if ! docker info >/dev/null 2>&1; then
        DOCKER_OK=false
        WARN "docker info не сработал. Пропускаю удаление старой папки."
    fi

    if [[ "${RUN_DOCKER_TEST:-0}" == "1" ]]; then
        LOG "Тест: docker run hello-world"
        if ! docker run --rm hello-world; then
            DOCKER_OK=false
            WARN "Тест hello-world не прошёл. Пропускаю удаление старой папки."
        fi
    fi

    if [[ "$DOCKER_OK" == "true" ]]; then
        if [[ "$CURRENT_DOCKER_PATH" != "$DOCKER_PATH" && -d "$CURRENT_DOCKER_PATH" ]]; then
            LOG "Можно удалить старую папку '$CURRENT_DOCKER_PATH' для освобождения места."
            LOG "Удалить её сейчас? (y/N). Если нет ответа 3 минуты, напомню про ручную очистку."
            if read -r -t 180 REPLY < /dev/tty; then
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    LOG "Удаляю '$CURRENT_DOCKER_PATH'..."
                    rm -rf "$CURRENT_DOCKER_PATH"
                    LOG "Старая папка удалена."
                else
                    LOG "Ок, пропускаю удаление. Старую папку можно удалить вручную."
                fi
            else
                LOG "Время ожидания истекло. Новый Docker установлен, старую папку удалите вручную."
            fi
        else
            LOG "Старую папку '$CURRENT_DOCKER_PATH' можно удалить вручную."
        fi
    fi
else
    ERR "Ошибка! Путь не изменился: $NEW_DOCKER_PATH"
fi
