#!/usr/bin/env bash
set -euo pipefail

# --- Настройки ---
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"

DOWNLOAD_DIR="/mnt/data/udobnidom"
WORK_DIR="/mnt/data/duplicati"
ENV_FILE="${WORK_DIR}/duplicati.env"
mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR"
chmod 700 "$WORK_DIR"

declare -A CANDIDATES
CANDIDATES["x86_64"]="linux-x64-cli.deb linux-x64-agent.deb linux-x64-gui.deb"
CANDIDATES["aarch64"]="linux-arm64-cli.deb linux-arm64-agent.deb linux-arm64-gui.deb"
CANDIDATES["armv7l"]="linux-arm7-cli.deb linux-arm7-agent.deb linux-arm7-gui.deb"

SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Требуются права root или sudo, но sudo не найден." >&2
    exit 1
  fi
fi

# 1) Запрос паролей
read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек (минимум 8 символов, если короче будет сгенерирован): " ENC_KEY; echo

# 2) Определение ОС/архитектуры
OS_NAME=$(uname -s)
ARCH=$(uname -m)
echo "Определена ОС: ${OS_NAME}, Архитектура: ${ARCH}"

if [ "$OS_NAME" != "Linux" ]; then
  echo "Скрипт поддерживает только Linux (Armbian/Debian/Ubuntu)." >&2
  exit 1
fi

case "$ARCH" in
  aarch64|arm64) ARCH_KEY="aarch64" ;;
  armv7l|armhf|armv7*) ARCH_KEY="armv7l" ;;
  x86_64|amd64) ARCH_KEY="x86_64" ;;
  *) echo "Неизвестная/неподдерживаемая архитектура: $ARCH" >&2; exit 1 ;;
esac

# 3) Очистка предыдущих установок (systemd, пакеты, конфиги, старые deb в /mnt/data)
echo "Останавливаю и удаляю предыдущие установки Duplicati..."
$SUDO systemctl stop duplicati.service 2>/dev/null || true
$SUDO systemctl disable duplicati.service 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/duplicati.service

if command -v dpkg >/dev/null 2>&1; then
  to_remove=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^duplicati' || true)
  if [ -n "$to_remove" ]; then
    echo "Удаляю пакеты: $to_remove"
    $SUDO apt-get remove --purge -y $to_remove || true
  fi
fi

$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati || true
$SUDO rm -f "${DOWNLOAD_DIR}"/*.deb || true

# 4) Временное добавление рабочих репозиториев (если нужно)
CODENAME="bullseye"
if [ -r /etc/os-release ]; then
  codename_tmp=$(awk -F= '/VERSION_CODENAME/ {print $2}' /etc/os-release | tr -d '"')
  if [ -n "$codename_tmp" ]; then
    CODENAME="$codename_tmp"
  fi
fi
TEMP_SOURCES="/etc/apt/sources.list.d/99-temporary-official-debian.list"
echo "Добавляю временные репозитории deb.debian.org ($CODENAME) -> $TEMP_SOURCES"
$SUDO tee "$TEMP_SOURCES" > /dev/null <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free
deb http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free
EOF

# 5) Установка минимальных зависимостей
echo "Обновляю индексы и устанавливаю базовые зависимости..."
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -y || true
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wget unzip ca-certificates libicu-dev || true
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y wget unzip ca-certificates libicu || true
else
  echo "Пакетный менеджер не поддерживается автоматически. Установите wget и libicu вручную." >&2
fi

# 6) Поиск подходящего .deb
VERSION="${TAG#v}"
FOUND_URL=""
FOUND_FNAME=""
if [ -z "${CANDIDATES[$ARCH_KEY]:-}" ]; then
  echo "Нет списка пакетов для архитектуры ${ARCH_KEY}" >&2
  exit 1
fi

for suffix in ${CANDIDATES[$ARCH_KEY]}; do
  FNAME="duplicati-${VERSION}-${suffix}"
  URL="${GITHUB_BASE}/${TAG}/${FNAME}"
  echo -n "Проверяю: ${URL} ... "
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -L -I -o /dev/null -w '%{http_code}' "$URL" || echo "000")
    if [ "$code" = "200" ]; then
      echo "OK"
      FOUND_URL="$URL"
      FOUND_FNAME="$FNAME"
      break
    else
      echo "нет ($code)"
    fi
  else
    if wget --spider --timeout=10 --tries=1 "$URL" 2>&1 | grep -q "200 OK"; then
      echo "OK"
      FOUND_URL="$URL"
      FOUND_FNAME="$FNAME"
      break
    else
      echo "нет"
    fi
  fi
done

if [ -z "$FOUND_URL" ]; then
  echo "Не найдено .deb для релиза ${TAG} и архитектуры ${ARCH}. Посмотрите релиз вручную:" >&2
  echo "  https://github.com/duplicati/duplicati/releases/tag/${TAG}"
  exit 1
fi

# 7) Скачивание .deb
FPATH="${DOWNLOAD_DIR}/${FOUND_FNAME}"
echo "Скачиваю ${FOUND_FNAME} в ${FPATH} ..."
$SUDO rm -f "$FPATH" || true
if ! wget --progress=bar:force -O "$FPATH" "$FOUND_URL"; then
  echo "Ошибка при скачивании ${FOUND_URL}" >&2
  exit 1
fi
$SUDO chown root:root "$FPATH"
$SUDO chmod 644 "$FPATH"

# 8) Установка .deb (dpkg + apt-get -f)
echo "Устанавливаю пакет ${FOUND_FNAME} ..."
if command -v apt-get >/dev/null 2>&1; then
  if ! $SUDO apt-get install -y "${FPATH}"; then
    echo "apt-get install завершился с ошибкой, пробуем dpkg + исправление зависимостей..."
    $SUDO dpkg -i "${FPATH}" || true
    $SUDO apt-get -y -f install || true
  fi
else
  if command -v dpkg >/dev/null 2>&1; then
    $SUDO dpkg -i "${FPATH}" || true
  else
    echo "Невозможно автоматически установить .deb: нет apt/dpkg." >&2
    exit 1
  fi
fi

# 9) Найти бинарь duplicati-server
BIN_PATH=""
for candidate in /usr/bin/duplicati-server /usr/lib/duplicati/duplicati-server /usr/local/bin/duplicati-server; do
  if [ -x "$candidate" ]; then
    BIN_PATH="$candidate"
    break
  fi
done
if [ -z "$BIN_PATH" ]; then
  BIN_PATH=$(command -v duplicati-server 2>/dev/null || true)
fi
if [ -z "$BIN_PATH" ]; then
  echo "Внимание: duplicati-server не найден после установки. Проверьте пакет." >&2
  # не выходим — создадим unit с дефолтным путём; systemd покажет ошибку
  BIN_PATH="/usr/bin/duplicati-server"
fi
echo "Использую бинарь: $BIN_PATH"

# 10) Проверка/генерация ENC_KEY (>=8)
if [ "${#ENC_KEY}" -lt 8 ]; then
  echo "Введённый ключ короткий (${#ENC_KEY}) — генерирую безопасный ключ (hex, 64 символа)..."
  # openssl может отсутствовать — fallback к /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    ENC_KEY=$(openssl rand -hex 32)
  else
    # 32 bytes -> 64 hex chars
    ENC_KEY=$(xxd -p -l 32 /dev/urandom 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    # если всё равно коротко — pad
    [ "${#ENC_KEY}" -lt 8 ] && ENC_KEY="$(date +%s)-generated-key-$(head -c16 /dev/urandom | tr -dc 'a-f0-9' | head -c24)"
  fi
  echo "Сгенерированный ключ будет сохранён и использован."
fi

# 11) Сохраняем пароли в защищённый env-файл (shell-экранируем одинарные кавычки)
escape_for_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}
WEB_ESC=$(escape_for_single_quotes "$WEB_PASS")
ENC_ESC=$(escape_for_single_quotes "$ENC_KEY")

$SUDO tee "$ENV_FILE" > /dev/null <<EOF
WEB_PASS='${WEB_ESC}'
ENC_KEY='${ENC_ESC}'
EOF
$SUDO chown root:root "$ENV_FILE"
$SUDO chmod 600 "$ENV_FILE"
echo "Пароли сохранены в ${ENV_FILE} (mode 600)."

# 12) Создаём systemd unit, использующий EnvironmentFile и найденный бинарь
SERVICE_PATH="/etc/systemd/system/duplicati.service"
echo "Создаю unit-файл ${SERVICE_PATH} ..."
$SUDO tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=${ENV_FILE}
Environment=HOME=${WORK_DIR}
ExecStart=${BIN_PATH} --webservice-interface=any --webservice-port=8200 --webservice-password=\$WEB_PASS --settings-encryption-key=\$ENC_KEY --webservice-allowed-hostnames=*
Restart=on-failure
RestartSec=5
WorkingDirectory=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF

$SUDO chmod 644 "$SERVICE_PATH"

# 13) systemd reload + enable + start
$SUDO systemctl daemon-reload
$SUDO systemctl enable duplicati.service
$SUDO systemctl restart duplicati.service || {
  echo "Сервис не запустился — покажу 200 последних строк журнала..."
  $SUDO journalctl -u duplicati.service -n 200 --no-pager || true
}

# 14) Результат
echo -e "\n===== Установка завершена (или запущена попытка) ====="
echo "Доступно по адресам (порт 8200):"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read -r ip; do
  echo "  http://${ip}:8200"
done
echo -e "\nИспользованные пароли/ключ (сохранил в ${ENV_FILE}):"
echo "  • Веб-пароль:      (в файле WEB_PASS)"
echo "  • Ключ шифрования: (в файле ENC_KEY)"
echo -e "\nФайлы скачаны в: ${FPATH}"
echo "Рабочая папка Duplicati: ${WORK_DIR}"

# 15) Подсказка: если нужно вернуть старые репозитории — удалите ${TEMP_SOURCES}"
exit 0
