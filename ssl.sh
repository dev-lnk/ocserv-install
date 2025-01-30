#!/usr/bin/env bash
#
# Автоматическая установка NGINX и выдача сертификата Let's Encrypt
# Пример использования:
#   sudo ./ssl.sh my-vpn.com

set -e

# Проверяем, что скрипт запущен с правами root
if [[ $EUID -ne 0 ]]; then
  echo "Пожалуйста, запустите скрипт от root или через sudo."
  exit 1
fi

# Получаем домен
DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
  read -rp "Введите домен (например, vpn.example.com): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "Домен не задан. Скрипт прерван."
  exit 1
fi

echo ">>> Обновляем пакеты и устанавливаем nginx, certbot..."
apt-get update -y
apt-get install -y nginx python3-certbot-nginx

# Запускаем NGINX (если не запущен) и включаем автозапуск
systemctl enable nginx
systemctl start nginx

echo ">>> Получаем сертификат Let's Encrypt для домена: $DOMAIN"
# certbot certonly --nginx обеспечит автоматическую настройку в конфиге nginx
certbot certonly --nginx -d "$DOMAIN"

echo ">>> Проверка успешной выдачи сертификата..."
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
  echo "Сертификат успешно получен и хранится в:"
  echo "  $CERT_PATH"
  echo "  $KEY_PATH"
else
  echo "Не удалось найти файлы сертификата. Проверьте логи certbot."
  exit 1
fi

echo ">>> Скрипт ssl.sh завершён."
