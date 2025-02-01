#!/bin/bash
set -e

# Проверка, что скрипт запущен с правами root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт с правами root (например, через sudo)"
  exit 1
fi

# Определяем директорию, где находится скрипт (для поиска ocserv.conf)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Если файл настроек (из ssl.sh) существует, читаем из него домен и секрет
if [ -f "$SCRIPT_DIR/install_settings.conf" ]; then
  echo "Чтение настроек из install_settings.conf..."
  source "$SCRIPT_DIR/install_settings.conf"
else
  echo "Файл install_settings.conf не найден."
  read -p "Введите ваш домен (например, example.com): " DOMAIN
  read -sp "Введите секрет (пароль/ключ) для VPN: " SECRET
  echo ""
fi

echo "Устанавливаем необходимые зависимости..."
apt install -y git ruby-ronn libbsd-dev libsystemd-dev libpcl-dev libwrap0-dev \
  libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev libreadline-dev \
  libnl-route-3-dev libkrb5-dev libradcli-dev libcurl4-gnutls-dev libcjose-dev \
  libjansson-dev libprotobuf-c-dev libtalloc-dev libhttp-parser-dev protobuf-c-compiler \
  gperf nuttcp lcov libuid-wrapper libpam-wrapper libnss-wrapper libsocket-wrapper \
  gss-ntlmssp haproxy iputils-ping freeradius gawk gnutls-bin iproute2 yajl-tools tcpdump autoreconf

# Клонирование репозитория ocserv и компиляция
echo "Клонирование репозитория ocserv..."
git clone https://gitlab.com/openconnect/ocserv.git && cd ocserv

echo "Подготавливаем автоконфигурацию..."
autoreconf -fvi

echo "Конфигурация и компиляция ocserv (это может занять время)..."
./configure && make

echo "Установка ocserv..."
make install

# Копирование systemd‑сервис файла
echo "Настройка systemd-сервиса для ocserv..."
cp /lib/systemd/system/ocserv.service /etc/systemd/system/ocserv.service

# Правка пути в файле сервиса (замена /usr/sbin/ocserv на /usr/local/sbin/ocserv)
sed -i 's|/usr/sbin/ocserv|/usr/local/sbin/ocserv|g' /etc/systemd/system/ocserv.service

systemctl daemon-reload
systemctl restart ocserv

# Копирование шаблона конфигурации ocserv
cd "$SCRIPT_DIR"  # Возвращаемся в корень клонированного репозитория
echo "Копирование шаблона конфигурации ocserv.conf в /etc/ocserv..."
mkdir -p /etc/ocserv
cp "$SCRIPT_DIR/ocserv.conf" /etc/ocserv/ocserv.conf

# Замена плейсхолдеров <lets-ssl> и SECRET на введённые значения
echo "Подстановка домена и секрета в конфигурационный файл..."
sed -i "s|<lets-ssl>|$DOMAIN|g" /etc/ocserv/ocserv.conf
sed -i "s|SECRET|$SECRET|g" /etc/ocserv/ocserv.conf

# Создание системного пользователя для ocserv
echo "Создание системного пользователя 'ocserv'..."
adduser ocserv

# Настройка sysctl: включение форвардинга и оптимизация TCP
echo "Настройка параметров ядра..."
tee /etc/sysctl.d/60-custom.conf > /dev/null <<EOF
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/60-custom.conf

# Установка и настройка UFW
echo "Устанавливаем ufw и разрешаем доступ по SSH (порт 22)..."
apt install -y ufw
ufw allow 22/tcp

# Запрос имени основного сетевого интерфейса
read -p "Введите имя основного сетевого интерфейса (например, ens3): " IFACE

# Редактирование файла /etc/ufw/before.rules для добавления правил NAT и форвардинга
echo "Настройка UFW (NAT и форвардинг)..."
cat <<EOF >> /etc/ufw/before.rules

# --- NAT table rules for ocserv ---
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.10.10.0/24 -o $IFACE -j MASQUERADE
COMMIT

# --- Дополнительные правила форвардинга для сети VPN ---
-A ufw-before-forward -s 10.10.10.0/24 -j ACCEPT
-A ufw-before-forward -d 10.10.10.0/24 -j ACCEPT
EOF

echo "Включаем ufw и перезапускаем службу..."
ufw enable
systemctl restart ufw

# Финальная перезагрузка демона systemd и разрешение порта 22 (на всякий случай)
systemctl daemon-reload
ufw allow 22/tcp

echo "Установка и настройка ocserv завершены."
