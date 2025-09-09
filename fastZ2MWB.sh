#!/bin/bash
set -euo pipefail

# ----------------------------
# Zigbee2MQTT installer (готовый скрипт)
# - спрашивает, удалить ли старые конфиги
# - аккуратно работает с симлинком /root/zigbee2mqtt/data -> /mnt/data/...
# - исправлен ввод y/n, стабильно выбирает порт
# - systemd override для устройства (если порт задан)
# - красивый countdown
# ----------------------------

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }

# --- ensure cursor restored on exit ---
cleanup_tput() {
    # restore cursor in any case
    if command -v tput &>/dev/null; then
        tput cnorm || true
    fi
}
trap cleanup_tput EXIT

# --- countdown ---
countdown() {
    local seconds=${1:-5}
    if command -v tput &>/dev/null; then
        tput civis || true
    fi
    while [ "$seconds" -gt 0 ]; do
        echo -ne "\e[1;33m[..] Ожидание: ${seconds} сек \e[0m\r"
        sleep 1
        : $((seconds--))
    done
    echo -ne "                      \r"
    if command -v tput &>/dev/null; then
        tput cnorm || true
    fi
}

# --- input normalization helper ---
ask_yesno() {
    # $1 - prompt, returns 0 for yes, 1 for no
    local prompt="$1"
    local default="${2:-}"
    local reply
    while true; do
        read -r -p "$prompt " reply || true
        reply="$(echo -n "$reply" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        if [ -z "$reply" ] && [ -n "$default" ]; then
            reply="$default"
        fi
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Введите y или n." ;;
        esac
    done
}

# --- must be root ---
if [[ $EUID -ne 0 ]]; then
   ERR "Запустите скрипт от root или через sudo."
   exit 1
fi

# --- Переменные ---
BIG_DISK="/mnt/data"
DEFAULT_DATA_DIR="/root/zigbee2mqtt/data"
DATA_DIR="$BIG_DISK/root/zigbee2mqtt/data"
DEFAULT_PARENT_DIR="$(dirname "$DEFAULT_DATA_DIR")"
SERVICE_NAME="zigbee2mqtt"

LOG "Начало установки Zigbee2MQTT"

# --- Спросить удалить старые конфиги ---
if ask_yesno "Удалить старые конфигурационные файлы Zigbee2MQTT (rm -rf) перед установкой? (y/n):" "n"; then
    DELETE_OLD="yes"
else
    DELETE_OLD="no"
fi

# --- Остановка сервиса (если есть) и удаление пакетов/файлов при запросе ---
LOG "Останавливаю сервис (если он запущен): $SERVICE_NAME"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

if [ "$DELETE_OLD" = "yes" ]; then
    LOG "Удаляю пакеты (если установлены) и старые данные..."
    apt remove --purge -y zigbee2mqtt wb-zigbee2mqtt 2>/dev/null || true
    # Удаляем только очевидные директории - осторожно!
    rm -rf "$BIG_DISK/root/zigbee2mqtt" || true
    rm -rf "$DEFAULT_PARENT_DIR" || true
    rm -f /etc/systemd/system/$SERVICE_NAME.service.d/override.conf || true
    systemctl daemon-reload || true
else
    LOG "Сохранение существующих данных (удаление пропущено пользователем)."
fi

# --- Подготовка директории на большом разделе ---
LOG "Создаю целевую директорию на большом разделе: $DATA_DIR"
mkdir -p "$DATA_DIR"

# --- Симлинк / поведение при уже существующем DEFAULT_DATA_DIR ---
if [ -e "$DEFAULT_DATA_DIR" ]; then
    if [ -L "$DEFAULT_DATA_DIR" ]; then
        # это симлинк - проверим, куда он указывает
        LINK_TARGET="$(readlink -f "$DEFAULT_DATA_DIR" || true)"
        if [ "$LINK_TARGET" = "$(readlink -f "$DATA_DIR")" ]; then
            LOG "Символическая ссылка $DEFAULT_DATA_DIR уже указывает на $DATA_DIR — ничего не меняю."
        else
            if [ "$DELETE_OLD" = "yes" ]; then
                LOG "Пересоздаю символическую ссылку $DEFAULT_DATA_DIR -> $DATA_DIR"
                rm -f "$DEFAULT_DATA_DIR"
                ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
            else
                WARN "$DEFAULT_DATA_DIR уже существует и является симлинком на $LINK_TARGET. Оставляю как есть."
                DATA_DIR="$DEFAULT_DATA_DIR"
            fi
        fi
    else
        # существующая реальная директория или файл
        if [ "$DELETE_OLD" = "yes" ]; then
            LOG "Удаляю существующую директорию $DEFAULT_DATA_DIR и создаю симлинк."
            rm -rf "$DEFAULT_DATA_DIR"
            mkdir -p "$DEFAULT_PARENT_DIR"
            ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
        else
            WARN "$DEFAULT_DATA_DIR уже существует и не является симлинком. Оставляю её и буду использовать как директорию данных."
            DATA_DIR="$DEFAULT_DATA_DIR"
        fi
    fi
else
    # не существует - создаём симлинк
    LOG "Создаю родительскую директорию для симлинка: $DEFAULT_PARENT_DIR"
    mkdir -p "$DEFAULT_PARENT_DIR"
    LOG "Создаю символическую ссылку $DEFAULT_DATA_DIR -> $DATA_DIR"
    ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
fi

# --- Установка пакетов ---
LOG "Обновляю список пакетов..."
apt update -y
LOG "Устанавливаю zigbee2mqtt (и wb-zigbee2mqtt если доступен)..."
# пытаемся установить оба пакета (как в оригинале с репозиторием Wiren Board), но не падаем если одного нет
apt install -y zigbee2mqtt wb-zigbee2mqtt || apt install -y zigbee2mqtt || true

# --- Поиск Zigbee-адаптера ---
LOG "Ищу Zigbee-адаптер..."
PORT_FOUND=""
# сначала MOD*, затем ttyUSB*
for dev in /dev/ttyMOD*; do
    [ -e "$dev" ] && PORT_FOUND="$dev" && break
done
if [ -z "$PORT_FOUND" ]; then
    for dev in /dev/ttyUSB* /dev/serial/by-id/*; do
        [ -e "$dev" ] && PORT_FOUND="$dev" && break
    done
fi

# --- Подтверждение / ручной выбор ---
if [ -n "$PORT_FOUND" ]; then
    if ask_yesno "Обнаружен адаптер на $PORT_FOUND. Использовать его? (y/n):" "y"; then
        LOG "Подтверждён порт: $PORT_FOUND"
    else
        PORT_FOUND=""
    fi
fi

if [ -z "$PORT_FOUND" ]; then
    echo "Выберите порт вручную:"
    PS3="#? "
    options=(MOD1 MOD2 MOD3 MOD4 USB OTHER)
    select choice in "${options[@]}"; do
        if [ -z "$choice" ]; then
            echo "Неверный выбор. Попробуйте ещё раз."
            continue
        fi
        case "$choice" in
            MOD1|MOD2|MOD3|MOD4)
                PORT_FOUND="/dev/tty${choice}"
                break
                ;;
            USB)
                read -r -p "Введите имя устройства (например /dev/ttyUSB0): " PORT_INPUT
                PORT_INPUT="$(echo -n "$PORT_INPUT" | xargs)"
                if [ -z "$PORT_INPUT" ]; then
                    echo "Пустой ввод, возвращаюсь к выбору."
                    continue
                fi
                PORT_FOUND="$PORT_INPUT"
                break
                ;;
            OTHER)
                read -r -p "Введите полный путь к устройству (например /dev/ttyS0 или /dev/serial/by-id/...): " PORT_INPUT
                PORT_INPUT="$(echo -n "$PORT_INPUT" | xargs)"
                if [ -z "$PORT_INPUT" ]; then
                    echo "Пустой ввод, возвращаюсь к выбору."
                    continue
                fi
                PORT_FOUND="$PORT_INPUT"
                break
                ;;
        esac
    done
fi

LOG "Использую порт: ${PORT_FOUND:-<не задан>}"

# --- Настройка MQTT и Home Assistant ---
if ask_yesno "Подключаться к локальному MQTT брокеру (mqtt://localhost)? (y/n):" "y"; then
    MQTT_SERVER="mqtt://localhost"
else
    read -r -p "Введите адрес и порт MQTT (например mqtt://192.168.1.10:1883): " MQTT_SERVER
    MQTT_SERVER="$(echo -n "$MQTT_SERVER" | xargs)"
fi

if ask_yesno "Установлен ли Home Assistant на этой машине? (y/n):" "y"; then
    HA_ENABLED="true"
else
    HA_ENABLED="false"
fi

# --- Создание configuration.yaml ---
LOG "Создаю конфигурацию Zigbee2MQTT в $DATA_DIR/configuration.yaml ..."
mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/configuration.yaml" <<EOF
homeassistant:
  enabled: ${HA_ENABLED}
mqtt:
  base_topic: zigbee2mqtt
  server: '${MQTT_SERVER}'
serial:
  port: '${PORT_FOUND}'
  adapter: zstack
  rtscts: false
advanced:
  last_seen: epoch
  pan_id: GENERATE
  ext_pan_id: GENERATE
  network_key: GENERATE
frontend:
  enabled: true
  port: 8080
  host: 0.0.0.0
permit_join: true
version: 4
EOF

# --- systemd override: ждать устройство (если порт задан) ---
if [ -n "${PORT_FOUND}" ]; then
    if command -v systemd-escape &>/dev/null; then
        DEVICE_UNIT=$(systemd-escape -p --suffix=device "$PORT_FOUND")
        OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
        mkdir -p "$OVERRIDE_DIR"
        cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Unit]
After=${DEVICE_UNIT}
Requires=${DEVICE_UNIT}
EOF
        LOG "Создан systemd-override для ожидания устройства: ${DEVICE_UNIT}"
    else
        WARN "systemd-escape недоступен — не создаю override unit."
    fi
fi

# --- enable/restart service ---
LOG "Перезагружаю конфигурацию systemd и запускаю Zigbee2MQTT..."
systemctl daemon-reload || true
systemctl enable "$SERVICE_NAME" || true
systemctl restart "$SERVICE_NAME" || true

LOG "Проверяю запуск сервиса..."
countdown 5

if systemctl is-active --quiet "$SERVICE_NAME"; then
    LOG "Сервис Zigbee2MQTT успешно запущен! ✅"
    IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    echo "---------------------------------------------------------"
    echo "Веб-интерфейс: http://${IP_ADDR}:8080"
    echo "MQTT сервер: ${MQTT_SERVER}"
    echo "Конфиг: ${DATA_DIR}/configuration.yaml"
    echo "---------------------------------------------------------"
else
    ERR "Не удалось запустить сервис Zigbee2MQTT. ❌"
    WARN "--- Последние 20 строк лога для диагностики ---"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    WARN "Возможная причина: Zigbee-модуль не активирован в настройках контроллера."
    exit 1
fi

# --- Проверка места на rootfs ---
echo ""
LOG "Проверка места на rootfs:"
df -h /

LOG "Готово."
