#!/bin/bash
set -e

# Проверка, что скрипт запущен с правами root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт с правами root (например, через sudo)"
  exit 1
fi

# Определяем директорию, где находится скрипт (для поиска ocserv.conf)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Проверяем наличие .env файла и читаем переменные из него
if [ -f "$SCRIPT_DIR/.env" ]; then
  echo "Чтение настроек из .env..."
  # Экспортируем переменные из .env файла
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
  
  # Проверяем, что необходимые переменные установлены
  if [ -z "$DOMAIN" ] || [ -z "$SECRET" ] || [ -z "$SSH_PORT" ]; then
    echo "Ошибка: В файле .env не найдены обязательные переменные DOMAIN и/или SECRET"
    echo "Пример содержимого .env файла:"
    echo "DOMAIN=example.com"
    echo "SECRET=your_secret_password"
    echo "SSH_PORT=your_ssh_port"
    exit 1
  fi
else
  echo "Ошибка: Файл .env не найден в директории $SCRIPT_DIR"
  echo "Создайте файл .env со следующим содержимым:"
  echo "DOMAIN=your_domain.com"
  echo "SECRET=your_secret_password"
  exit 1
fi

echo "Устанавливаем необходимые зависимости..."
apt update
apt install -y git ruby-ronn libbsd-dev libsystemd-dev libpcl-dev libwrap0-dev \
  libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev libreadline-dev \
  libnl-route-3-dev libkrb5-dev libradcli-dev libcurl4-gnutls-dev libcjose-dev \
  libjansson-dev libprotobuf-c-dev libtalloc-dev libhttp-parser-dev protobuf-c-compiler \
  gperf nuttcp lcov libuid-wrapper libpam-wrapper libnss-wrapper libsocket-wrapper \
  gss-ntlmssp haproxy iputils-ping freeradius gawk gnutls-bin iproute2 yajl-tools tcpdump \
  autoconf automake ipcalc

# Клонирование репозитория ocserv и компиляция
echo "Клонирование репозитория ocserv..."
git clone https://gitlab.com/openconnect/ocserv.git && cd ocserv

echo "Подготавливаем автоконфигурацию..."
autoreconf -fvi

echo "Конфигурация и компиляция ocserv (это может занять время)..."
./configure && make

echo "Установка ocserv..."
make install

# Настройка systemd-сервиса для ocserv
if [ ! -f /lib/systemd/system/ocserv.service ]; then
    echo "Файл /lib/systemd/system/ocserv.service не найден. Создаю собственный systemd-сервис для ocserv..."

    # Получаем путь к исполняемому файлу ocserv
    OCSERV_BIN=$(which ocserv)
    if [ -z "$OCSERV_BIN" ]; then
        echo "Ошибка: ocserv не найден в системе. Проверьте, что он установлен."
        exit 1
    fi

    # Создаём (или перезаписываем) файл /etc/systemd/system/ocserv.service
    cat <<EOF > /etc/systemd/system/ocserv.service
[Unit]
Description=OpenConnect SSL VPN server
Documentation=man:ocserv(8)
After=network-online.target
After=dbus.service

[Service]
PrivateTmp=true
PIDFile=/run/ocserv.pid
ExecStart=${OCSERV_BIN} --foreground --pid-file /run/ocserv.pid --config /etc/ocserv/ocserv.conf
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

    echo "Файл /etc/systemd/system/ocserv.service создан."
else
    # Если стандартный файл сервиса найден, копируем его в /etc/systemd/system
    cp /lib/systemd/system/ocserv.service /etc/systemd/system/ocserv.service
fi

systemctl daemon-reload
systemctl restart ocserv

# Включаем автозапуск службы ocserv при загрузке системы
echo "Включение автозапуска службы ocserv..."
systemctl enable ocserv

# Копирование шаблона конфигурации ocserv
cd "$SCRIPT_DIR"  # Возвращаемся в корень репозитория
echo "Копирование шаблона конфигурации ocserv.conf в /etc/ocserv..."
mkdir -p /etc/ocserv
cp "$SCRIPT_DIR/ocserv.conf" /etc/ocserv/ocserv.conf

echo "Подстановка домена и секрета в конфигурационный файл..."
# Подстановка для плейсхолдеров <lets-ssl> и <DOMAIN>, а также замена SECRET на $SECRET
sed -i "s|<DOMAIN>|$DOMAIN|g" /etc/ocserv/ocserv.conf
sed -i "s|<SECRET>|$SECRET|g" /etc/ocserv/ocserv.conf

# Создание системного пользователя для ocserv
echo "Создание системного пользователя 'ocserv'..."
adduser ocserv

# Настройка sysctl: включение форвардинга и оптимизация TCP
echo "Настройка параметров ядра..."
cat <<EOF > /etc/sysctl.d/60-custom.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/60-custom.conf

# Установка и базовая настройка UFW
echo "Устанавливаем ufw и разрешаем доступ по SSH..."
apt install -y ufw
ufw allow $SSH_PORT/tcp

# Перед внесением изменений делаем резервную копию файла before.rules
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

echo "Определяем основной сетевой интерфейс..."
# Автоматически определяем интерфейс, по умолчанию используется тот, через который идет маршрут по умолчанию
IFACE=$(ip route | awk '/^default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo "Основной сетевой интерфейс не найден. Проверьте настройки сети."
  exit 1
fi
echo "Найден основной сетевой интерфейс: $IFACE"

echo "Настройка UFW (NAT и форвардинг)..."

# 1. Вставка правил форвардинга для сети VPN.
#    Правила должны быть добавлены до строки "# allow dhcp client to work"
if ! grep -q "^-A ufw-before-forward -s 10.10.10.0/24 -j ACCEPT" /etc/ufw/before.rules; then
    sed -i '/^# allow dhcp client to work/i \
-A ufw-before-forward -s 10.10.10.0\/24 -j ACCEPT\n-A ufw-before-forward -d 10.10.10.0\/24 -j ACCEPT' /etc/ufw/before.rules
    echo "Правила форвардинга для сети VPN добавлены в /etc/ufw/before.rules."
fi

# 2. Добавление блока NAT для ocserv, если его ещё нет
if ! grep -q "# --- NAT table rules for ocserv ---" /etc/ufw/before.rules; then
    cat <<EOF >> /etc/ufw/before.rules

# --- NAT table rules for ocserv ---
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.10.10.0/24 -o ${IFACE} -j MASQUERADE

COMMIT
EOF
    echo "Блок NAT правил для ocserv добавлен в /etc/ufw/before.rules."
fi

# Разрешаем порт 443 (TCP и UDP) перед перезапуском ufw
echo "Разрешение порта 443 (TCP и UDP)..."
ufw allow 443/tcp
ufw allow 443/udp

# Разрешаем порт 443 (TCP и UDP) перед перезапуском ufw
echo "Разрешение порта 80 (TCP и UDP)..."
ufw allow 80/tcp
ufw allow 80/udp

echo "Включаем ufw и перезапускаем службу..."
ufw --force enable
systemctl restart ufw

# Финальная перезагрузка демона systemd и разрешение SSH-порта (на всякий случай)
systemctl daemon-reload
systemctl restart ocserv

# Добавление cron задания для перезапуска ocserv каждое первое число месяца в 4:00 ночи
CRON_FILE="/etc/cron.d/ocserv_restart"
CRON_JOB="0 4 1 * * root systemctl restart ocserv"
echo "Добавление cron задания для перезапуска ocserv..."
if [ -f "$CRON_FILE" ]; then
    if grep -q "systemctl restart ocserv" "$CRON_FILE"; then
         echo "Крон задание уже существует в $CRON_FILE."
    else
         echo "$CRON_JOB" >> "$CRON_FILE"
         echo "Крон задание обновлено в $CRON_FILE."
    fi
else
    echo "$CRON_JOB" > "$CRON_FILE"
    echo "Крон задание создано в $CRON_FILE."
fi

echo "Установка и настройка ocserv завершены."