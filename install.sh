#!/usr/bin/env bash
#
# Автоматическая сборка, установка и настройка OpenConnect Server (ocserv)
# Пример использования:
#   sudo ./install.sh [домен] [имя_интерфейса]

set -e

# Проверяем, что скрипт запущен с правами root
if [[ $EUID -ne 0 ]]; then
  echo "Пожалуйста, запустите скрипт от root или через sudo."
  exit 1
fi

# --- 0. Запрос домена ---
DOMAIN="$1"
if [ -z "$DOMAIN" ]; then
  read -rp "Введите домен (например, vpn.example.com): " DOMAIN
fi
if [ -z "$DOMAIN" ]; then
  echo "Домен не задан. Прерывание скрипта."
  exit 1
fi

# --- 0.1 Запрашиваем имя интерфейса или пытаемся определить автоматически ---
DEFAULT_IFACE="$2"
if [ -z "$DEFAULT_IFACE" ]; then
  # Пытаемся автоматически узнать интерфейс с default route
  DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n 1)
  echo "Автоматически определили сетевой интерфейс: $DEFAULT_IFACE"
  echo "Если это неверно, прервите скрипт (Ctrl+C) и запустите заново, указав интерфейс вручную."
  sleep 5
fi

if [ -z "$DEFAULT_IFACE" ]; then
  echo "Не удалось автоматически определить интерфейс. Укажите его вручную."
  read -rp "Имя сетевого интерфейса (например, ens3 или eth0): " DEFAULT_IFACE
fi

if [ -z "$DEFAULT_IFACE" ]; then
  echo "Не задан интерфейс. Прерывание скрипта."
  exit 1
fi

# --- 1. Устанавливаем зависимости для сборки ocserv ---
echo ">>> Устанавливаем необходимые пакеты..."
apt-get update -y
apt-get install -y git ruby-ronn libbsd-dev libsystemd-dev libpcl-dev libwrap0-dev \
                   libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev \
                   libreadline-dev libnl-route-3-dev libkrb5-dev libradcli-dev \
                   libcurl4-gnutls-dev libcjose-dev libjansson-dev libprotobuf-c-dev \
                   libtalloc-dev libhttp-parser-dev protobuf-c-compiler gperf \
                   nuttcp lcov libuid-wrapper libpam-wrapper libnss-wrapper \
                   libsocket-wrapper gss-ntlmssp haproxy iputils-ping freeradius \
                   gawk gnutls-bin iproute2 yajl-tools tcpdump autoreconf ufw

# --- 2. Клонируем исходники ocserv ---
echo ">>> Клонируем репозиторий ocserv..."
if [ ! -d "ocserv" ]; then
  git clone https://gitlab.com/openconnect/ocserv.git
fi
cd ocserv

# --- 3. autoreconf ---
echo ">>> Выполняем autoreconf..."
autoreconf -fvi

# --- 4. configure & make ---
echo ">>> Конфигурируем и компилируем ocserv..."
./configure && make

# --- 5. make install ---
echo ">>> Устанавливаем ocserv (make install)..."
make install

# --- 6. Копируем ocserv.service ---
echo ">>> Настраиваем systemd service для ocserv..."
if [ ! -f /etc/systemd/system/ocserv.service ]; then
  cp /lib/systemd/system/ocserv.service /etc/systemd/system/ocserv.service
fi

# --- 7. Редактируем ExecStart в /etc/systemd/system/ocserv.service ---
echo ">>> Меняем ExecStart в /etc/systemd/system/ocserv.service на путь /usr/local/sbin/ocserv..."
sed -i 's|ExecStart=/usr/sbin/ocserv|ExecStart=/usr/local/sbin/ocserv|' /etc/systemd/system/ocserv.service

echo ">>> Перезагружаем демоны systemd и рестартуем ocserv..."
systemctl daemon-reload
systemctl restart ocserv

# --- 8. Копируем конфиг ocserv.conf в /etc/ocserv/ ---
cd ..
if [ ! -d /etc/ocserv ]; then
  mkdir /etc/ocserv
fi

echo ">>> Копируем ocserv.conf в /etc/ocserv/ocserv.conf..."
cp ./ocserv.conf /etc/ocserv/ocserv.conf

# --- 9. Заменяем <lets-ssl> на запрошенный домен в /etc/ocserv/ocserv.conf ---
echo ">>> Заменяем <lets-ssl> на $DOMAIN в /etc/ocserv/ocserv.conf..."
sed -i "s|<lets-ssl>|$DOMAIN|g" /etc/ocserv/ocserv.conf

# --- 10. Создаём пользователя ocserv (если ещё не создан) ---
echo ">>> Создаём системного пользователя ocserv (если не существует)..."
if id "ocserv" &>/dev/null; then
  echo "Пользователь ocserv уже существует, пропускаем..."
else
  adduser --system --no-create-home --group ocserv
fi

# --- 11. Включаем IP Forwarding и bbr ---
echo ">>> Настраиваем sysctl для включения IP Forwarding и bbr..."
cat <<EOF >/etc/sysctl.d/60-custom.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p /etc/sysctl.d/60-custom.conf

# --- 12. Настраиваем UFW для проброса VPN трафика ---
echo ">>> Настраиваем UFW..."

# Разрешаем SSH (порт 22)
ufw allow 22/tcp

# Файл /etc/ufw/before.rules - добавляем правила NAT, если их ещё нет
UFW_BEFORE_FILE="/etc/ufw/before.rules"

# Проверим, есть ли уже блок "NAT table rules"
# Если нет - добавим
if ! grep -q "NAT table rules" "$UFW_BEFORE_FILE"; then
  echo ">>> Добавляем блок NAT в $UFW_BEFORE_FILE"
  cat <<EOF >>"$UFW_BEFORE_FILE"

# NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.10.10.0/24 -o $DEFAULT_IFACE -j MASQUERADE

# End each table with the 'COMMIT' line
COMMIT
EOF
fi

# Добавим правила форвардинга (ufw-before-forward)
if ! grep -q "allow forwarding for trusted network" "$UFW_BEFORE_FILE"; then
  echo ">>> Добавляем правила форвардинга в $UFW_BEFORE_FILE"
  cat <<EOF >>"$UFW_BEFORE_FILE"

# allow forwarding for trusted network
-A ufw-before-forward -s 10.10.10.0/24 -j ACCEPT
-A ufw-before-forward -d 10.10.10.0/24 -j ACCEPT
EOF
fi

# Включаем UFW (если ещё не включён). Будьте внимательны: UFW может запросить подтверждение.
echo ">>> Включаем UFW..."
yes | ufw enable

echo ">>> Перезапускаем UFW..."
systemctl restart ufw

echo ">>> Перезапускаем ocserv для надёжности..."
systemctl restart ocserv

echo
echo "#############################################"
echo "ocserv установлен и сконфигурирован!"
echo "Домена: $DOMAIN"
echo "Интерфейс: $DEFAULT_IFACE"
echo "#############################################"
echo
echo "Проверьте логи и убедитесь, что ocserv успешно запущен:"
echo "  journalctl -u ocserv --follow"
echo
echo "Для добавления/управления пользователями OpenConnect (если будет использоваться утилита внутри ocserv),"
echo "ознакомьтесь с оф. документацией ocserv, либо используйте PAM/Radius и т.д."
echo
echo "Установка завершена!"