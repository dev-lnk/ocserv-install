#!/bin/bash
set -e

# Проверка, что скрипт запущен с правами root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт с правами root (например, через sudo)"
  exit 1
fi

echo "Обновление пакетов и установка nginx + certbot..."
apt update
apt-get install -y nginx python3-certbot-nginx

# Запрос домена и секрета
read -p "Введите ваш домен (например, example.com): " DOMAIN
read -sp "Введите секрет (пароль/ключ) для VPN: " SECRET
echo ""

# Сохранение введённых данных в файл настроек (будет использован install.sh)
cat <<EOF > install_settings.conf
DOMAIN="$DOMAIN"
SECRET="$SECRET"
EOF
echo "Данные сохранены в install_settings.conf"

# Выдача сертификата для домена
echo "Запускаем certbot для получения сертификата для домена $DOMAIN..."
certbot certonly --nginx -d "$DOMAIN"

echo "Сертификат успешно выдан."