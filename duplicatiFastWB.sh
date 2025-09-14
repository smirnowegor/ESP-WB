#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"

# ✨ ИЗМЕНЕНИЕ: Явно указываем все пути в разделе /mnt/data, как ты и просил.
DOWNLOAD_DIR="/mnt/data/duplicati-downloads"
WORK_DIR="/mnt/data/duplicati"
ENV_FILE="${WORK_DIR}/duplicati.env"
BACKUP_DIR="/mnt/data/duplicati-backups-$(date +%s)"
# ----------------------------------------

# --- Создание рабочих каталогов ---
mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR"

# --- Проверка прав и подготовка SUDO ---
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Ошибка: Требуются права root или команда sudo." >&2
    exit 1
  fi
fi

# --- Определение временного файла для репозиториев и его автоочистка ---
TEMP_SOURCES="/tmp/99-duplicati-temp-debian.list"
# Убедимся, что файл точно будет удален при выходе
trap '$SUDO rm -f "$TEMP_SOURCES"' EXIT

# --- Ввод паролей ---
read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек (минимум 8 символов, если короче будет сгенерирован): " ENC_KEY; echo

# --- Простые проверки системы ---
OS_NAME=$(uname -s)
ARCH=$(uname -m)
echo "Определена ОС: ${OS_NAME}, Архитектура: ${ARCH}"
if [ "$OS_NAME" != "Linux" ]; then
  echo "Ошибка: Скрипт поддерживает только Linux." >&2
  exit 1
fi
case "$ARCH" in
  aarch64|arm64) ARCH_KEY="aarch64" ;;
  armv7l|armhf|armv7*) ARCH_KEY="armv7l" ;;
  x86_64|amd64) ARCH_KEY="x86_64" ;;
  *) echo "Ошибка: Неизвестная/неподдерживаемая архитектура: $ARCH" >&2; exit 1 ;;
esac

# --- Ассоциативный массив с кандидатами для скачивания ---
declare -A CANDIDATES
CANDIDATES["x86_64"]="linux-x64-gui.deb"
CANDIDATES["aarch64"]="linux-arm64-gui.deb"
CANDIDATES["armv7l"]="linux-arm7-gui.deb"

# --- Остановка и резервное копирование старого сервиса ---
SERVICE_PATH="/etc/systemd/system/duplicati.service"
echo "Останавливаю и отключаю duplicati.service..."
$SUDO systemctl stop duplicati.service 2>/dev/null || true
$SUDO systemctl disable duplicati.service 2>/dev/null || true
[ -f "$SERVICE_PATH" ] && $SUDO cp -a "$SERVICE_PATH" "${BACKUP_DIR}/duplicati.service.bak"
[ -f "$ENV_FILE" ] && $SUDO cp -a "$ENV_FILE" "${BACKUP_DIR}/duplicati.env.bak"

# --- Полная чистка старых установок ---
echo "Удаляю возможные старые артефакты пакета и конфигов..."
$SUDO rm -f /etc/systemd/system/duplicati.service
if command -v dpkg >/dev/null 2>&1; then
  to_remove=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^duplicati' || true)
  if [ -n "$to_remove" ]; then
    echo "Удаляю пакеты: $to_remove"
    $SUDO apt-get remove --purge -y $to_remove
  fi
fi
$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati
$SUDO rm -f "${DOWNLOAD_DIR}"/*.deb
echo "Очищаю рабочий каталог ${WORK_DIR} от старой базы данных..."
$SUDO rm -f "${WORK_DIR}"/*.sqlite*

# --- ✨ ИЗМЕНЕНИЕ: Изолированная установка зависимостей ---
# Этот блок теперь полностью автономен и не трогает системные репозитории Wiren Board.
echo "Начинаю изолированную установку зависимостей..."
CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release || echo "bullseye")
$SUDO tee "$TEMP_SOURCES" >/dev/null <<EOF
deb http://deb.debian.org/debian ${CODENAME} main
deb http://deb.debian.org/debian ${CODENAME}-updates main
deb http://security.debian.org/debian-security ${CODENAME}-security main
EOF

echo "Обновляю список пакетов ТОЛЬКО из временного репозитория..."
# Команды apt-get теперь используют опции -o, чтобы работать только с нашим временным файлом.
$SUDO apt-get update \
  -o Dir::Etc::SourceList="$TEMP_SOURCES" \
  -o Dir::Etc::SourceParts="/dev/null"

echo "Устанавливаю wget, unzip, ca-certificates, libicu-dev..."
# ✨ ИЗМЕНЕНИЕ: Используется "пуленепробиваемый" синтаксис для выполнения команды.
$SUDO bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends \
  -o Dir::Etc::SourceList=\"$TEMP_SOURCES\" \
  -o Dir::Etc::SourceParts=\"/dev/null\" \
  wget unzip ca-certificates libicu-dev"
echo "Изолированная установка зависимостей завершена."
# Временный файл $TEMP_SOURCES будет автоматически удален в конце скрипта.

# --- Подбор и скачивание .deb пакета ---
VERSION="${TAG#v}"
FOUND_URL=""
FNAME=""
for suffix in ${CANDIDATES[$ARCH_KEY]}; do
  FNAME="duplicati-${VERSION}-${suffix}"
  URL="${GITHUB_BASE}/${TAG}/${FNAME}"
  echo -n "Проверяю доступность: ${FNAME} ... "
  if curl --output /dev/null --silent --head --fail -L "$URL"; then
    echo "OK"
    FOUND_URL="$URL"
    break
  else
    echo "нет"
  fi
done

if [ -z "$FOUND_URL" ]; then
  echo "Ошибка: Не найден подходящий .deb пакет для ${TAG}/${ARCH_KEY}." >&2
  exit 1
fi

FPATH="${DOWNLOAD_DIR}/${FNAME}"
echo "Скачиваю ${FNAME} -> ${FPATH}..."
$SUDO rm -f "$FPATH"
wget --progress=bar:force -O "$FPATH" "$FOUND_URL"
$SUDO chown root:root "$FPATH"; $SUDO chmod 644 "$FPATH"

# --- Установка .deb с обработкой зависимостей ---
echo "Устанавливаю пакет и его зависимости..."
if ! $SUDO apt-get install -y "$FPATH"; then
  echo "Первая попытка установки не удалась, пробую исправить зависимости..."
  $SUDO dpkg -i "$FPATH" || true
  $SUDO apt-get -y -f install
fi

# --- Поиск исполняемого файла duplicati-server ---
BIN_PATH=$(command -v duplicati-server || echo "/usr/bin/duplicati-server")
if [ ! -x "$BIN_PATH" ]; then
    echo "Внимание: не удалось найти бинарный файл duplicati-server. Указан путь по умолчанию." >&2
fi
echo "Использую бинарный файл: $BIN_PATH"

# --- Проверка/генерация ключа шифрования ---
if [ "${#ENC_KEY}" -lt 8 ]; then
  echo "Ключ шифрования слишком короткий, генерирую новый..."
  ENC_KEY=$(openssl rand -hex 32)
fi

# --- Санитизация (очистка) пароля и ключа ---
WEB_CLEAN=$(printf "%s" "$WEB_PASS" | tr -d '\r\n')
ENC_CLEAN=$(printf "%s" "$ENC_KEY" | tr -d '\r\n')

# --- Запись .env файла с учетными данными ---
echo "Записываю переменные окружения в ${ENV_FILE}..."
$SUDO bash -c "cat > '${ENV_FILE}' <<EOF
WEB_PASS=${WEB_CLEAN}
ENC_KEY=${ENC_CLEAN}
EOF"
$SUDO chown root:root "$ENV_FILE"
$SUDO chmod 600 "$ENV_FILE"

# --- Создание systemd unit файла ---
echo "Создаю systemd unit файл: ${SERVICE_PATH}..."
$SUDO bash -c "cat > '${SERVICE_PATH}' <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/bash -c 'exec \"${BIN_PATH}\" --webservice-interface=any --webservice-port=8200 --server-datafolder=\"${WORK_DIR}\" --webservice-password=\"\\\$WEB_PASS\" --settings-encryption-key=\"\\\$ENC_KEY\" --webservice-allowed-hostnames=*'
Restart=on-failure
RestartSec=10
WorkingDirectory=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF"
$SUDO chmod 644 "$SERVICE_PATH"

# --- Перезагрузка systemd и запуск сервиса ---
echo "Перезагружаю systemd и запускаю сервис duplicati..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable duplicati.service
$SUDO systemctl restart duplicati.service

# --- Проверка статуса и вывод информации ---
echo "Ожидаю запуск сервиса..."
sleep 3
$SUDO systemctl status duplicati.service --no-pager -l || true

echo -e "\n✅ ===== Установка завершена ===== ✅"
echo "Веб-интерфейс должен быть доступен по одному из этих адресов:"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\d+' | while read -r ip; do echo "  -> http://${ip}:8200"; done

echo -e "\n🔒 Учетные данные (сохранены в ${ENV_FILE}):"
printf "  • Веб-пароль:      %s\n" "$WEB_CLEAN"
printf "  • Ключ шифрования: %s\n" "$ENC_CLEAN"

echo -e "\nℹ️ Старые конфигурационные файлы сохранены в: ${BACKUP_DIR}"
echo "Готово."
exit 0
