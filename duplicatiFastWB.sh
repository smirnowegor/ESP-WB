#!/usr/bin/env bash
# install-duplicati-wb-fixed.sh
# Надёжная установка Duplicati для WirenBoard (исправлены все баги)
set -euo pipefail
IFS=$'\n\t'
trap 'echo "Interrupted"; exit 1' INT TERM

# ---------------- CONFIG ----------------
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"
DOWNLOAD_DIR="/mnt/data/duplicati-downloads"
WORK_DIR="/mnt/data/duplicati"
ENV_FILE="${WORK_DIR}/duplicati.env"
BACKUP_DIR="/mnt/data/duplicati-backups-$(date +%s)"
SERVICE_PATH="/etc/systemd/system/duplicati.service"
# ----------------------------------------

mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR"

# Проверка необходимых утилит
for cmd in curl wget dpkg apt-get systemctl ip openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Требуется утилита: $cmd. Установи и повтори." >&2
    exit 1
  fi
done

# sudo если нужен
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Требуются права root или sudo, но sudo не найден." >&2
    exit 1
  fi
fi

# Ввод паролей — поддержка неинтерактивного запуска
# Можно заранее экспортировать WEB_PASS и/или ENC_KEY в окружение.
if [ -z "${WEB_PASS:-}" ]; then
  if [ -t 0 ]; then
    read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
  else
    WEB_PASS=$(openssl rand -base64 12)
    echo "Нет TTY — сгенерирован пароль для web."
  fi
fi

if [ -z "${ENC_KEY:-}" ]; then
  if [ -t 0 ]; then
    read -rsp "Введите ключ шифрования настроек (>=8 символов, иначе сгенерируется): " ENC_KEY; echo
    if [ "${#ENC_KEY}" -lt 8 ]; then
      ENC_KEY=$(openssl rand -hex 32)
      echo "Ключ слишком короткий — сгенерирован новый."
    fi
  else
    ENC_KEY=$(openssl rand -hex 32)
    echo "Нет TTY — сгенерирован ключ шифрования."
  fi
fi

# Определение архитектуры
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) ARCH_KEY="aarch64" ;;
  armv7l|armhf|armv7*) ARCH_KEY="armv7l" ;;
  x86_64|amd64) ARCH_KEY="x86_64" ;;
  *) echo "Неизвестная архитектура: $ARCH" >&2; exit 1 ;;
esac

# Формируем массив суффиксов корректно (чтобы не было "вставки всего списка")
if [ "$ARCH_KEY" = "aarch64" ]; then
  SUFFIXES=( "linux-arm64-gui.deb" "linux-arm64-cli.deb" "linux-arm64-agent.deb" )
elif [ "$ARCH_KEY" = "armv7l" ]; then
  SUFFIXES=( "linux-arm7-gui.deb" "linux-arm7-cli.deb" "linux-arm7-agent.deb" )
else
  SUFFIXES=( "linux-x64-gui.deb" "linux-x64-cli.deb" "linux-x64-agent.deb" )
fi

# Чистка старого
echo "Удаляю старые установки Duplicati..."
$SUDO systemctl stop duplicati.service 2>/dev/null || true
$SUDO systemctl disable duplicati.service 2>/dev/null || true
[ -f "$SERVICE_PATH" ] && $SUDO cp -a "$SERVICE_PATH" "$BACKUP_DIR/"
[ -f "$ENV_FILE" ] && $SUDO cp -a "$ENV_FILE" "$BACKUP_DIR/"
if command -v dpkg >/dev/null 2>&1; then
  OLD=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^duplicati' || true)
  [ -n "$OLD" ] && $SUDO dpkg --purge $OLD || true
fi
$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati || true
$SUDO rm -f "$WORK_DIR"/*.sqlite* || true

# Ищем доступный релизный .deb по суффиксам
VERSION="${TAG#v}"
FOUND_URL=""
FOUND_FNAME=""
for suffix in "${SUFFIXES[@]}"; do
  FNAME="duplicati-${VERSION}-${suffix}"
  URL="${GITHUB_BASE}/${TAG}/${FNAME}"
  echo -n "Проверяю: ${URL} ... "
  # Форсируем HTTP/1.1 для избежания PROTOCOL_ERROR с HTTP/2 на некоторых зеркалах
  if curl --http1.1 -sfSLI "$URL" >/dev/null 2>&1; then
    echo "доступен"
    FOUND_URL="$URL"
    FOUND_FNAME="$FNAME"
    break
  else
    echo "нет"
  fi
done

if [ -z "$FOUND_URL" ]; then
  echo "Не найден пакет для ${TAG}/${ARCH_KEY}"
  exit 1
fi

# Скачивание .deb с простым ретраем
TARGET_PATH="${DOWNLOAD_DIR}/${FOUND_FNAME}"
if [ -f "$TARGET_PATH" ]; then
  echo "♻️ Использую кэшированный пакет ${FOUND_FNAME}"
else
  echo "⬇️ Скачиваю ${FOUND_FNAME}..."
  if ! wget -q --tries=3 --timeout=30 -O "$TARGET_PATH" "$FOUND_URL"; then
    echo "Ошибка загрузки ${FOUND_URL}" >&2
    rm -f "$TARGET_PATH" || true
    exit 1
  fi
fi

# Установка: dpkg -> apt --fix-broken
echo "Устанавливаю пакет (.deb) через dpkg..."
$SUDO dpkg -i "$TARGET_PATH" || true

echo "Обновляю индексы apt и исправляю зависимости (noninteractive)..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get -y -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" --fix-broken install

# Если duplicati-server всё ещё не найден, пробуем apt установить локальный .deb
if ! command -v duplicati-server >/dev/null 2>&1; then
  echo "Попытка установки локального .deb через apt..."
  $SUDO apt-get install -y "$TARGET_PATH" || true
fi

# Проверяем duplicati-server
BIN_PATH=$(command -v duplicati-server || find /usr /opt /usr/local -type f -name duplicati-server 2>/dev/null | head -n1 || true)
if [ -z "$BIN_PATH" ]; then
  echo "❌ duplicati-server не найден после установки"
  echo "Посмотреть журнал: sudo journalctl -u duplicati.service -n 200 --no-pager"
  exit 1
fi

# Создание .env
echo "Создаю $ENV_FILE"
$SUDO mkdir -p "$(dirname "$ENV_FILE")"
$SUDO bash -c "umask 077; printf '%s\n' 'WEB_PASS=${WEB_PASS}' > '${ENV_FILE}'"
$SUDO bash -c "printf '%s\n' 'ENC_KEY=${ENC_KEY}' >> '${ENV_FILE}'"
$SUDO chmod 600 "$ENV_FILE"

# Создание systemd unit
echo "Создаю systemd unit ${SERVICE_PATH}"
$SUDO tee "${SERVICE_PATH}" >/dev/null <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
User=root
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH} --webservice-interface=any --webservice-port=8200 --server-datafolder=${WORK_DIR} --webservice-password=\${WEB_PASS} --settings-encryption-key=\${ENC_KEY} --webservice-allowed-hostnames=*
Restart=on-failure
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

# Запуск и включение сервиса
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now duplicati.service

sleep 1
if $SUDO systemctl is-active --quiet duplicati.service; then
  STATUS="active"
else
  STATUS="failed"
fi

echo -e "\n===== Установка завершена — сервис: $STATUS ====="
echo "Доступно по адресам:"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read -r ip; do
  echo "  http://${ip}:8200"
done

echo -e "\nПароль (WEB): ${WEB_PASS}"
echo "Ключ шифрования: ${ENC_KEY}"
echo "Бэкапы старых конфигов: ${BACKUP_DIR}"

if [ "$STATUS" != "active" ]; then
  echo -e "\nПоследние 120 строк журнала duplicati.service:"
  $SUDO journalctl -u duplicati.service -n 120 --no-pager || true
fi

exit 0
