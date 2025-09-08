#!/bin/bash
# Устанавливаем строгий режим: скрипт прервется при любой ошибке.
set -e

# --- Функции для красивого вывода ---
LOG() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# --- Начало скрипта ---

# 1. Проверка, что скрипт запущен от имени суперпользователя (root)
if [[ $EUID -ne 0 ]]; then
   ERR "Этот скрипт необходимо запускать от имени root или через sudo."
fi

# Проверяем, установлен ли уже Docker
if command -v docker &> /dev/null; then
    LOG "Docker уже установлен. Пропускаю шаги установки."
else
    LOG "Шаг 1: Установка базовых зависимостей..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release iptables apt-transport-https --no-install-recommends

    LOG "Шаг 2: Переключение iptables в режим legacy для совместимости..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

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

# --- НОВЫЕ ШАГИ ---

LOG "Шаг 5: Интерактивный выбор диска для данных Docker."

# Находим все подходящие разделы (размер больше 1ГБ, не / и не /boot)
# IFS - разделитель, read -r - не интерпретировать обратные слеши, -a - записать в массив
# df выводит в байтах, awk фильтрует, sort сортирует по размеру
mapfile -t options < <(df -B1 | awk 'NR>1 && $4 > 1073741824 && $6 !~ "^/boot" && $6 ~ "^/" {printf "%s (%s free)\n", $6, substr($4/1073741824, 1, 4)"G"}' | sort -k2 -hr)

# Добавляем опцию "оставить по умолчанию"
options+=("Оставить по умолчанию в /var/lib/docker")

if [ ${#options[@]} -eq 1 ]; then
    WARN "Не найдено других подходящих разделов. Данные Docker останутся в /var/lib/docker."
    DOCKER_PATH="/var/lib/docker"
else
    echo "Пожалуйста, выберите, куда переместить данные Docker:"
    PS3="Введите номер: "
    select opt in "${options[@]}"; do
        if [[ -n "$opt" ]]; then
            if [[ "$opt" == "Оставить по умолчанию в /var/lib/docker" ]]; then
                DOCKER_PATH="/var/lib/docker"
                break
            else
                # Извлекаем путь из строки, например, из "/mnt/data (52G free)" получаем "/mnt/data"
                CHOSEN_MOUNT=$(echo "$opt" | awk '{print $1}')
                DOCKER_PATH="${CHOSEN_MOUNT}/docker"
                break
            fi
        else
            echo "Неверный выбор. Попробуйте еще раз."
        fi
    done
fi

# Получаем текущий путь к данным Docker
CURRENT_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}')

if [[ "$DOCKER_PATH" == "$CURRENT_DOCKER_PATH" ]]; then
    LOG "Выбран текущий путь. Никаких изменений не требуется."
    LOG "🎉 Docker готов к работе!"
    exit 0
fi

LOG "Шаг 6: Настройка Docker и перенос данных в '$DOCKER_PATH'..."

# Создаем файл конфигурации демона
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "data-root": "$DOCKER_PATH"
}
EOF

LOG "Останавливаю службу Docker для безопасного переноса данных..."
systemctl stop docker

LOG "Переношу данные из '$CURRENT_DOCKER_PATH' в '$DOCKER_PATH' (это может занять время)..."
# Используем rsync для корректного копирования прав и атрибутов
rsync -a -q "$CURRENT_DOCKER_PATH/" "$DOCKER_PATH"

LOG "Запускаю службу Docker с новой конфигурацией..."
systemctl start docker

LOG "Шаг 7: Проверка нового расположения данных Docker..."
sleep 5 # Даем демону время на запуск
NEW_DOCKER_PATH=$(docker info -f '{{.DockerRootDir}}')

if [[ "$NEW_DOCKER_PATH" == "$DOCKER_PATH" ]]; then
    LOG "🎉 Успех! Данные Docker теперь находятся в: $NEW_DOCKER_PATH"
    LOG "Старую директорию '$CURRENT_DOCKER_PATH' можно будет удалить после проверки."
else
    ERR "Что-то пошло не так. Новое расположение: $NEW_DOCKER_PATH, ожидалось: $DOCKER_PATH"
fi

LOG "Готово. Можно использовать docker и docker compose."
