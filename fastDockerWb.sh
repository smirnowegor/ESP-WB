#!/bin/bash
set -e

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    ERR "Этот скрипт необходимо запускать от имени root или через sudo."
fi

if command -v docker &> /dev/null; then
    LOG "Docker уже установлен. Пропускаю шаги установки."
else
    LOG "Шаг 1: Установка базовых зависимостей..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release iptables apt-transport-https rsync --no-install-recommends

    LOG "Шаг 2: Переключение iptables в режим legacy для совместимости..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

    LOG "Шаг 3: Добавление официального GPG ключа и репозитория Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH=$(dpkg --print-architecture)
    CODENAME=$(lsb_release -cs)
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list

    LOG "Шаг 4: Установка Docker Engine..."
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --no-install-recommends
fi

LOG "Шаг 5: Интерактивный выбор диска для данных Docker."

# Собираем подходящие точки монтирования (свободно >1G, исключая /boot)
mapfile -t raw_opts < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" {printf "%s (%0.1fG free)\n", $6, $4/1073741824}' | sort -k2 -hr)

# всегда добавляем опцию "по умолчанию"
raw_opts+=("/var/lib/docker (Оставить по умолчанию)")

# если есть только одна реальная точка (или none), уведомляем
if [ ${#raw_opts[@]} -le 1 ]; then
    WARN "Не найдено других подходящих разделов. Данные Docker останутся в /var/lib/docker."
    DOCKER_PATH="/var/lib/docker"
else
    echo "Пожалуйста, выберите, куда переместить данные Docker:"
    for i in "${!raw_opts[@]}"; do
        idx=$((i+1))
        echo " $idx) ${raw_opts[i]}"
    done

    # Если задана переменная окружения DOCKER_DATA_CHOICE — используем её (удобно для автоматизации)
    if [[ -n "${DOCKER_DATA_CHOICE:-}" ]]; then
        CHOICE="${DOCKER_DATA_CHOICE}"
        LOG "Использую DOCKER_DATA_CHOICE=${CHOICE}"
    else
        # читаем ответ прямо из терминала, даже если stdin занят (curl | bash)
        if [[ -e /dev/tty && -c /dev/tty ]]; then
            # Спрашиваем до тех пор, пока введён валидный номер
            while true; do
                read -rp "Введите номер: " CHOICE < /dev/tty || CHOICE=""
                # если пустая строка — пропустить (оставить по умолчанию — первая опция)
                if [[ -z "$CHOICE" ]]; then
                    WARN "Пустой ввод — выбираю по умолчанию (пункт 1)."
                    CHOICE=1
                    break
                fi
                if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#raw_opts[@]}" ]; then
                    break
                fi
                echo "Неверный выбор. Попробуйте еще раз."
            done
        else
            # нет tty — автоматический выбор: берем первый найденный (самый большой) раздел
            LOG "/dev/tty недоступен — автоматический выбор пункта 1."
            CHOICE=1
        fi
    fi

    # Получаем строку выбранной опции
    sel_index=$((CHOICE-1))
    sel_opt="${raw_opts[$sel_index]}"

    if [[ "$sel_opt" =~ "/var/lib/docker" ]]; then
        DOCKER_PATH="/var/lib/docker"
    else
        # убираем часть " (NNNG free)" и добавляем /docker
        MOUNT_POINT=$(echo "$sel_opt" | sed -E 's/ \([0-9.]+G free\)//; s/ \(Оставить по умолчанию\)//')
        DOCKER_PATH="${MOUNT_POINT%/}/docker"
    fi
fi

# Узнаём текущую docker root dir (если docker работает)
CURRENT_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

if [[ "$DOCKER_PATH" == "$CURRENT_DOCKER_PATH" ]]; then
    LOG "Выбран текущий путь ($DOCKER_PATH). Никаких изменений не требуется."
    LOG "🎉 Docker готов к работе!"
    exit 0
fi

LOG "Шаг 6: Настройка Docker и перенос данных в '$DOCKER_PATH'..."

mkdir -p "$(dirname "$DOCKER_PATH")"
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "data-root": "$DOCKER_PATH"
}
EOF

LOG "Останавливаю службу Docker для безопасного переноса данных..."
systemctl stop docker || true

LOG "Создаю целевую директорию и перенос данных из '$CURRENT_DOCKER_PATH' в '$DOCKER_PATH'..."
mkdir -p "$DOCKER_PATH"
rsync -a --info=progress2 "$CURRENT_DOCKER_PATH/" "$DOCKER_PATH/"

LOG "Запускаю службу Docker с новой конфигурацией..."
systemctl start docker

LOG "Шаг 7: Проверка нового расположения данных Docker..."
sleep 3
NEW_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "Ошибка получения docker info")

if [[ "$NEW_DOCKER_PATH" == "$DOCKER_PATH" ]]; then
    LOG "🎉 Успех! Данные Docker теперь находятся в: $NEW_DOCKER_PATH"
    LOG "Старую директорию '$CURRENT_DOCKER_PATH' можно удалить вручную после проверки."
else
    ERR "Что-то пошло не так. Новое расположение: $NEW_DOCKER_PATH, ожидалось: $DOCKER_PATH"
fi

LOG "Готово. Можно использовать docker и docker compose."
