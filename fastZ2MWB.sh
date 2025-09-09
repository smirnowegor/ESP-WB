#!/bin/bash
set -euo pipefail

# ----------------------------
# Zigbee2MQTT installer — safe run (no blocking/bg apt)
# - команды выполняются синхронно (не background) — исключает "Stopped"
# - отдельный фон-таймер лишь показывает секунды выполнения
# - apt-get в noninteractive режиме с Dpkg::Options
# - уникальные лог-файлы через mktemp (сохраняются при ошибке)
# ----------------------------

LOG()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }

# ensure cursor restored and kill timer if running
cleanup() {
    if command -v tput &>/dev/null; then
        tput cnorm || true
    fi
    if [ -n "${TIMER_PID:-}" ]; then
        kill "$TIMER_PID" 2>/dev/null || true
        wait "$TIMER_PID" 2>/dev/null || true
        unset TIMER_PID
    fi
}
trap cleanup EXIT

# timer: prints elapsed seconds every second to the same line
start_timer() {
    local prefix="$1"
    # timer runs in bg and prints to stderr (so stdout is mainly for command output)
    (
        secs=0
        while true; do
            printf "\r\e[1;34m[ %4ds ]\e[0m %s" "$secs" "$prefix" >&2
            sleep 1
            : $((secs++))
        done
    ) &
    TIMER_PID=$!
}

stop_timer_and_clear() {
    if [ -n "${TIMER_PID:-}" ]; then
        kill "$TIMER_PID" 2>/dev/null || true
        wait "$TIMER_PID" 2>/dev/null || true
        unset TIMER_PID
        # clear line
        printf "\r\033[K" >&2
    fi
}

# run_with_timer: runs command synchronously; shows elapsed timer in parallel
# usage: run_with_timer "message" cmd arg...
run_with_timer() {
    local msg="$1"; shift
    local -a cmd=( "$@" )

    local outf
    local errf
    outf="$(mktemp /tmp/installer.stdout.XXXXXX)"
    errf="$(mktemp /tmp/installer.stderr.XXXXXX)"

    LOG "$msg"
    start_timer "$msg"

    # run command synchronously, capture stdout/stderr to files
    set +e
    "${cmd[@]}" >"$outf" 2>"$errf"
    local rc=$?
    set -e

    stop_timer_and_clear

    if [ $rc -eq 0 ]; then
        LOG "$msg — выполнено (время в секундах было показано выше)."
        rm -f "$outf" "$errf" || true
        return 0
    else
        ERR "$msg — ОШИБКА (код $rc). Первые 200 строк логов:"
        echo "----- stdout -----"
        sed -n '1,200p' "$outf" || true
        echo "----- stderr -----"
        sed -n '1,200p' "$errf" || true
        echo "Полные логи сохранены: $outf , $errf"
        return $rc
    fi
}

# simple yes/no prompt
ask_yesno() {
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

# check root
if [[ $EUID -ne 0 ]]; then
   ERR "Запустите скрипт от root или через sudo."
   exit 1
fi

# variables
BIG_DISK="/mnt/data"
DEFAULT_DATA_DIR="/root/zigbee2mqtt/data"
DATA_DIR="$BIG_DISK/root/zigbee2mqtt/data"
DEFAULT_PARENT_DIR="$(dirname "$DEFAULT_DATA_DIR")"
SERVICE_NAME="zigbee2mqtt"

LOG "Начало установки Zigbee2MQTT"

# ask about deleting old configs
if ask_yesno "Удалить старые конфигурационные файлы Zigbee2MQTT (rm -rf) перед установкой? (y/n):" "n"; then
    DELETE_OLD="yes"
else
    DELETE_OLD="no"
fi

LOG "Останавливаю сервис (если запущен): $SERVICE_NAME"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

if [ "$DELETE_OLD" = "yes" ]; then
    LOG "Удаляю пакеты (если установлены) и старые данные..."
    # use apt-get remove in noninteractive mode
    run_with_timer "Удаление пакетов: apt-get remove" env DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y zigbee2mqtt wb-zigbee2mqtt || true
    run_with_timer "Удаление старых директорий данных" bash -c "rm -rf '$BIG_DISK/root/zigbee2mqtt' '$DEFAULT_PARENT_DIR' || true"
    run_with_timer "Удаление systemd override (если есть)" bash -c "rm -f /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf || true"
    run_with_timer "systemctl daemon-reload" systemctl daemon-reload || true
else
    LOG "Сохранение существующих данных (удаление пропущено)."
fi

LOG "Создаю целевую директорию: $DATA_DIR"
run_with_timer "Создание директории" mkdir -p "$DATA_DIR"

# setup symlink logic (safe)
if [ -e "$DEFAULT_DATA_DIR" ]; then
    if [ -L "$DEFAULT_DATA_DIR" ]; then
        LINK_TARGET="$(readlink -f "$DEFAULT_DATA_DIR" || true)"
        if [ "$LINK_TARGET" = "$(readlink -f "$DATA_DIR")" ]; then
            LOG "Симлинк $DEFAULT_DATA_DIR уже указывает на $DATA_DIR."
        else
            if [ "$DELETE_OLD" = "yes" ]; then
                LOG "Пересоздаю симлинк $DEFAULT_DATA_DIR -> $DATA_DIR"
                run_with_timer "Удаляю старый файл/симлинк" rm -f "$DEFAULT_DATA_DIR"
                run_with_timer "Создаю симлинк" ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
            else
                WARN "$DEFAULT_DATA_DIR уже существует и является симлинком на $LINK_TARGET. Оставляю."
                DATA_DIR="$DEFAULT_DATA_DIR"
            fi
        fi
    else
        if [ "$DELETE_OLD" = "yes" ]; then
            LOG "Удаляю существующую директорию $DEFAULT_DATA_DIR и создаю симлинк."
            run_with_timer "Удаляю существующую директорию" rm -rf "$DEFAULT_DATA_DIR"
            run_with_timer "Создаю родительскую директорию" mkdir -p "$DEFAULT_PARENT_DIR"
            run_with_timer "Создаю симлинк" ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
        else
            WARN "$DEFAULT_DATA_DIR уже существует и не является симлинком. Оставляю её и буду использовать как директорию данных."
            DATA_DIR="$DEFAULT_DATA_DIR"
        fi
    fi
else
    LOG "Создаю родительскую директорию и симлинк."
    run_with_timer "Создаю родительскую директорию" mkdir -p "$DEFAULT_PARENT_DIR"
    run_with_timer "Создаю символическую ссылку" ln -s "$DATA_DIR" "$DEFAULT_DATA_DIR"
fi

# update packages
LOG "Обновляю список пакетов..."
run_with_timer "apt-get update" apt-get update -y

LOG "Устанавливаю zigbee2mqtt и wb-zigbee2mqtt (если доступны)..."
# noninteractive apt-get install with dpkg options to avoid prompts
PKG_CMD=(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" zigbee2mqtt wb-zigbee2mqtt)

# run synchronously
if ! run_with_timer "apt-get install zigbee2mqtt wb-zigbee2mqtt" "${PKG_CMD[@]}"; then
    LOG "Попытка установить только zigbee2mqtt..."
    PKG_CMD2=(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" zigbee2mqtt)
    run_with_timer "apt-get install zigbee2mqtt" "${PKG_CMD2[@]}" || true
fi

# find adapter
LOG "Ищу Zigbee-адаптер..."
PORT_FOUND=""
for dev in /dev/ttyMOD*; do
    [ -e "$dev" ] && PORT_FOUND="$dev" && break
done
if [ -z "$PORT_FOUND" ]; then
    for dev in /dev/ttyUSB* /dev/serial/by-id/*; do
        [ -e "$dev" ] && PORT_FOUND="$dev" && break
    done
fi

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

# MQTT / HA
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

LOG "Создаю конфигурацию Zigbee2MQTT в $DATA_DIR/configuration.yaml ..."
run_with_timer "Создаю директорию конфигурации" mkdir -p "$DATA_DIR"
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
LOG "Конфигурация записана."

# systemd override if port set
if [ -n "${PORT_FOUND}" ]; then
    if command -v systemd-escape &>/dev/null; then
        DEVICE_UNIT=$(systemd-escape -p --suffix=device "$PORT_FOUND")
        OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
        run_with_timer "Создаю systemd override dir" mkdir -p "$OVERRIDE_DIR"
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

LOG "Перезагружаю systemd и запускаю сервис..."
run_with_timer "systemctl daemon-reload" systemctl daemon-reload || true
run_with_timer "systemctl enable $SERVICE_NAME" systemctl enable "$SERVICE_NAME" || true
if ! run_with_timer "systemctl restart $SERVICE_NAME" systemctl restart "$SERVICE_NAME"; then
    ERR "Сбой при запуске сервиса. Журналы:"
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
    exit 1
fi

LOG "Проверяю запуск сервиса..."
# краткое ожидание, визуально
run_with_timer "Ожидание 5 секунд" sleep 5

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
    WARN "--- Последние 50 строк лога для диагностики ---"
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
    exit 1
fi

echo ""
LOG "Проверка места на rootfs:"
df -h /

LOG "Готово."
