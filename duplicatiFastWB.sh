#!/usr/bin/env bash
set -euo pipefail

# --- Настройки ---
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"

# Все рабочие и установочные файлы в /mnt/data
DOWNLOAD_DIR="/mnt/data/udobnidom"
WORK_DIR="/mnt/data/duplicati"
mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR"
chmod 700 "$WORK_DIR"

# Кандидаты (предпочтение: cli -> agent -> gui чтобы не тянуть X11)
declare -A CANDIDATES
CANDIDATES["x86_64"]="linux-x64-cli.deb linux-x64-agent.deb linux-x64-gui.deb"
CANDIDATES["aarch64"]="linux-arm64-cli.deb linux-arm64-agent.deb linux-arm64-gui.deb"
CANDIDATES["armv7l"]="linux-arm7-cli.deb linux-arm7-agent.deb linux-arm7-gui.deb"

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

# 1) Запрос паролей
read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек: " ENC_KEY; echo

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
# Пакеты duplicati (удаляем аккуратно найденные пакеты по имени)
if command -v dpkg >/dev/null 2>&1; then
  to_remove=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^duplicati' || true)
  if [ -n "$to_remove" ]; then
    echo "Удаляю пакеты: $to_remove"
    $SUDO apt-get remove --purge -y $to_remove || true
  fi
fi
# Старые конфиги/данные — перемещаем/удаляем в /mnt/data (публикуем рабочую папку туда)
$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati || true
# Оставляем место для работы в /mnt/data
$SUDO rm -f "${DOWNLOAD_DIR}"/*.deb || true

# 4) Временное добавление рабочих репозиториев (чтобы не упираться в битое зеркало)
# Получаем codename (bullseye/focal/...)
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

# 5) Установка зависимостей базовых инструментов (wget, unzip, ca-certificates, libicu-dev)
echo "Обновляю индексы и устанавливаю зависимости (wget, unzip, ca-certificates, libicu-dev)..."
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -y || true
  # ставим минимально необходимые пакеты (без рекомендаций)
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wget unzip ca-certificates libicu-dev || true
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y wget unzip ca-certificates libicu || true
else
  echo "Пакетный менеджер не поддерживается автоматически. Установите wget и libicu вручную." >&2
fi

# 6) Поиск подходящего .deb в релизе
VERSION="${TAG#v}"
FOUND_URL=""
FOUND_FNAME=""

# Проверим, что есть список кандидатов для архитектуры
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

# 7) Скачивание .deb в /mnt/data
FPATH="${DOWNLOAD_DIR}/${FOUND_FNAME}"
echo "Скачиваю ${FOUND_FNAME} в ${FPATH} ..."
$SUDO rm -f "$FPATH" || true
if ! wget --progress=bar:force -O "$FPATH" "$FOUND_URL"; then
  echo "Ошибка при скачивании ${FOUND_URL}" >&2
  exit 1
fi
$SUDO chown root:root "$FPATH"
$SUDO chmod 644 "$FPATH"

# 8) Установка .deb с обработкой зависимостей
echo "Устанавливаю пакет ${FOUND_FNAME} ..."
if command -v apt-get >/dev/null 2>&1; then
  if ! $SUDO apt-get install -y "${FPATH}"; then
    echo "apt-get install завершился с ошибкой, пробуем dpkg + исправление зависимостей..."
    $SUDO dpkg -i "${FPATH}" || true
    $SUDO apt-get -y -f install
  fi
else
  if command -v dpkg >/dev/null 2>&1; then
    $SUDO dpkg -i "${FPATH}" || true
  else
    echo "Невозможно автоматически установить .deb: нет apt/dpkg." >&2
    exit 1
  fi
fi

# 9) После установки — определяем путь до исполняемого файлика duplicati-server
BIN_PATH=""
# наиболее вероятные варианты
for candidate in /usr/bin/duplicati-server /usr/lib/duplicati/duplicati-server /usr/local/bin/duplicati-server; do
  if [ -x "$candidate" ]; then
    BIN_PATH="$candidate"
    break
  fi
done
# fallback: пробуем command -v
if [ -z "$BIN_PATH" ]; then
  BIN_PATH=$(command -v duplicati-server 2>/dev/null || true)
fi
if [ -z "$BIN_PATH" ]; then
  echo "Внимание: не найден duplicati-server после установки. Попробуйте запустить вручную." >&2
else
  echo "Найден duplicati-server: $BIN_PATH"
fi

# 10) Создаём systemd unit (используем HOME в /mnt/data/duplicati чтобы все файлы были в /mnt/data)
SERVICE_PATH="/etc/systemd/system/duplicati.service"
echo "Создаю unit-файл ${SERVICE_PATH} (HOME -> ${WORK_DIR}) ..."
$SUDO tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
Type=simple
User=root
Environment=HOME=${WORK_DIR}
ExecStart=${BIN_PATH:-/usr/bin/duplicati-server} --webservice-interface=any --webservice-port=8200 --webservice-password=${WEB_PASS} --settings-encryption-key=${ENC_KEY} --webservice-allowed-hostnames=*
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO chmod 644 "$SERVICE_PATH"

# 11) systemd reload + enable + start
$SUDO systemctl daemon-reload
$SUDO systemctl enable duplicati.service
$SUDO systemctl restart duplicati.service || {
  echo "Сервис не запустился: вывод 'systemctl status duplicati' ниже:" >&2
  $SUDO systemctl status duplicati.service --no-pager || true
}

# 12) UFW / firewall — не трогаем (не просили)
# 13) Результат: IP и пароли
echo -e "\n===== Установка завершена ====="
echo "Доступно по адресам (порт 8200):"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read -r ip; do
  echo "  http://${ip}:8200"
done

echo -e "\nИспользованные пароли:"
echo "  • Веб-пароль:         ${WEB_PASS}"
echo "  • Ключ шифрования:    ${ENC_KEY}"
echo -e "\nФайлы скачаны в: ${FPATH}"
echo "Рабочая папка Duplicati: ${WORK_DIR} (HOME для сервиса)"

# 14) Внимание: оставляем временный sources-файл на месте — можно удалить вручную, если хотите вернуть старые настройки
echo -e "\nЕсли вы хотите вернуть прежние репозитории, удалите файл: ${TEMP_SOURCES}"
exit 0
