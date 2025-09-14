#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
TAG="v2.1.1.101_canary_2025-08-19"
GITHUB_BASE="https://github.com/duplicati/duplicati/releases/download"
DOWNLOAD_DIR="/mnt/data/duplicati-downloads"
WORK_DIR="/mnt/data/duplicati"
ENV_FILE="${WORK_DIR}/duplicati.env"
BACKUP_DIR="/mnt/data/duplicati-backups-$(date +%s)"
SERVICE_PATH="/etc/systemd/system/duplicati.service"
DEBIAN_MIRROR="http://deb.debian.org/debian"
CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release || echo "bullseye")
ARCH_DEB=$(dpkg --print-architecture)
# ----------------------------------------

mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR"

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

# Ввод паролей
read -rsp "Введите пароль для веб-интерфейса Duplicati: " WEB_PASS; echo
read -rsp "Введите ключ шифрования настроек (>=8 символов, иначе сгенерируется): " ENC_KEY; echo
[ "${#ENC_KEY}" -lt 8 ] && ENC_KEY=$(openssl rand -hex 32)

# Определение архитектуры
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) ARCH_KEY="aarch64" ;;
  armv7l|armhf|armv7*) ARCH_KEY="armv7l" ;;
  x86_64|amd64) ARCH_KEY="x86_64" ;;
  *) echo "Неизвестная архитектура: $ARCH" >&2; exit 1;;
esac

declare -A CANDIDATES
CANDIDATES["x86_64"]="linux-x64-gui.deb linux-x64-cli.deb linux-x64-agent.deb"
CANDIDATES["aarch64"]="linux-arm64-gui.deb linux-arm64-cli.deb linux-arm64-agent.deb"
CANDIDATES["armv7l"]="linux-arm7-gui.deb linux-arm7-cli.deb linux-arm7-agent.deb"

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
$SUDO rm -rf /root/.config/Duplicati /etc/duplicati /var/lib/duplicati
$SUDO rm -f "$WORK_DIR"/*.sqlite*

# Подбор и скачивание .deb
VERSION="${TAG#v}"
FOUND_URL=""
FOUND_FNAME=""
for suffix in ${CANDIDATES[$ARCH_KEY]}; do
  FNAME="duplicati-${VERSION}-${suffix}"
  URL="${GITHUB_BASE}/${TAG}/${FNAME}"
  echo -n "Проверяю: ${URL} ... "
  if curl -s -L -I -o /dev/null -w '%{http_code}' "$URL" | grep -q '^200$'; then
    echo "OK"
    FOUND_URL="$URL"
    FOUND_FNAME="$FNAME"
    break
  else
    echo "нет"
  fi
done
[ -z "$FOUND_URL" ] && { echo "Не найден пакет для ${TAG}/${ARCH_KEY}"; exit 1; }

# Скачивание Duplicati
if [ -f "${DOWNLOAD_DIR}/${FOUND_FNAME}" ]; then
  echo "♻️ Использую кэшированный пакет ${FOUND_FNAME}"
else
  echo "⬇️ Скачиваю ${FOUND_FNAME}..."
  wget -O "${DOWNLOAD_DIR}/${FOUND_FNAME}" "$FOUND_URL"
fi

# Парсинг зависимостей из .deb
RAW_DEPS=$(dpkg-deb -f "${DOWNLOAD_DIR}/${FOUND_FNAME}" Depends | tr -d ' ' | tr ',' '\n' | cut -d'(' -f1)
DEPS=()
for dep in $RAW_DEPS; do
  first_alt=$(echo "$dep" | cut -d'|' -f1)
  DEPS+=("$first_alt")
done

# Скачивание и установка зависимостей напрямую
for pkg in "${DEPS[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "✅ $pkg уже установлен"
    continue
  fi
  if [ -f "${DOWNLOAD_DIR}/${pkg}.deb" ]; then
    echo "♻️ Использую кэшированный ${pkg}.deb"
  else
    echo "📦 Скачиваю $pkg..."
    PKG_FILE=$(wget -qO- "${DEBIAN_MIRROR}/dists/${CODENAME}/main/binary-${ARCH_DEB}/Packages.gz" \
      | gzip -dc | awk -v p="$pkg" '$1=="Package:" && $2==p {found=1} found && $1=="Filename:" {print $2; exit}')
    if [ -z "$PKG_FILE" ]; then
      echo "⚠️ Не найден пакет $pkg в репозитории $CODENAME"
      continue
    fi
    FULL_URL="${DEBIAN_MIRROR}/${PKG_FILE}"
    wget -O "${DOWNLOAD_DIR}/${pkg}.deb" "$FULL_URL"
  fi
  $SUDO dpkg -i "${DOWNLOAD_DIR}/${pkg}.deb" || true
done

# Установка Duplicati
$SUDO dpkg -i "${DOWNLOAD_DIR}/${FOUND_FNAME}" || true
$SUDO apt-get -f install -y || true

# Поиск duplicati-server
BIN_PATH=$(command -v duplicati-server || find /usr /opt /usr/local -type f -name duplicati-server 2>/dev/null | head -n1)
[ -z "$BIN_PATH" ] && { echo "❌ duplicati-server не найден"; exit 1; }

# Создание .env
echo "WEB_PASS=${WEB_PASS}" | $SUDO tee "$ENV_FILE" >/dev/null
echo "ENC_KEY=${ENC_KEY}" | $SUDO tee -a "$ENV_FILE" >/dev/null
$SUDO chmod 600 "$ENV_FILE"

# Создание systemd unit с корректной подстановкой переменных
$SUDO tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Duplicati Backup Service
After=network.target

[Service]
User=root
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH} --webservice-interface=any --webservice-port=8200 --server-datafolder=${WORK_DIR} --webservice-password=\${WEB_PASS} --settings-encryption-key=\${ENC_KEY} --webservice-allowed-hostnames=*
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Запуск сервиса
$SUDO systemctl daemon-reload
$SUDO systemctl enable duplicati.service
$SUDO systemctl restart duplicati.service

echo -e "\n===== Установка завершена ====="
echo "Доступно по адресам:"
ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | while read -r ip; do
  echo "  http://${ip}:8200"
done
echo -e "\nПароль: ${WEB_PASS}"
echo "Ключ шифрования: ${ENC_KEY}"
echo "Бэкапы старых конфигов: ${BACKUP_DIR}"
