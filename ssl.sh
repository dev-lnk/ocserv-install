#!/bin/bash
set -e

# Проверка, что скрипт запущен с правами root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт с правами root (например, через sudo)"
  exit 1
fi

# Проверка аргументов командной строки
if [ $# -eq 3 ]; then
  # Если переданы три аргумента, используем их
  DOMAIN="$1"
  SECRET="$2"
  EMAIL="$3"
  
  # Создаем или обновляем .env файл
  echo "Создание/обновление .env файла с переданными параметрами..."
  cat <<EOF > .env
DOMAIN=$DOMAIN
SECRET=$SECRET
EMAIL=$EMAIL
EOF
  echo "Файл .env обновлен"
  
elif [ $# -eq 0 ]; then
  # Если аргументы не переданы, проверяем существование .env файла
  if [ ! -f ".env" ]; then
    echo "Файл .env не найден. Создаем новый..."
    
    # Запрос домена, секрета и email
    read -p "Введите ваш домен (например, example.com): " DOMAIN
    read -sp "Введите секрет (пароль/ключ) для VPN: " SECRET
    echo ""
    read -p "Введите ваш email для certbot: " EMAIL
    
    # Создание .env файла
    cat <<EOF > .env
DOMAIN=$DOMAIN
SECRET=$SECRET
EMAIL=$EMAIL
EOF
    echo "Файл .env создан с введенными данными"
  else
    echo "Загрузка настроек из существующего .env файла..."
    # Загрузка переменных из .env файла
    export $(grep -v '^#' .env | xargs)
  fi
else
  echo "Ошибка: неверное количество аргументов"
  echo "Использование: $0 [DOMAIN SECRET EMAIL]"
  echo "  $0                         - использовать существующий .env или создать новый интерактивно"
  echo "  $0 DOMAIN SECRET EMAIL     - создать/обновить .env с указанными параметрами"
  exit 1
fi

# Если переменные еще не загружены (случай с аргументами), загружаем их из .env
if [ $# -eq 3 ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Проверка, что необходимые переменные установлены
if [ -z "$DOMAIN" ] || [ -z "$SECRET" ] || [ -z "$EMAIL" ]; then
  echo "Ошибка: переменные DOMAIN, SECRET и/или EMAIL не найдены"
  exit 1
fi

echo "Обновление пакетов и установка nginx + certbot..."
apt update
apt-get install -y nginx python3-certbot-nginx

# Создание директории для well-known
echo "Создание директории /var/www/html/.well-known..."
mkdir -p /var/www/html/.well-known
chown -R www-data:www-data /var/www/html

# Создание конфигурационного файла nginx
echo "Создание конфигурации nginx для домена $DOMAIN..."
cat <<EOF > /etc/nginx/sites-available/$DOMAIN.conf
server {
    server_name $DOMAIN www.$DOMAIN;
    listen 80;

    location /.well-known {
    	root /var/www/html;
    }

    location / {
        return 404;
    }
}
EOF

# Создание символической ссылки
echo "Создание символической ссылки в sites-enabled..."
ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/

# Проверка конфигурации nginx и перезагрузка
echo "Проверка конфигурации nginx..."
nginx -t
systemctl reload nginx

# Выдача сертификата для домена
echo "Запускаем certbot для получения сертификата для домена $DOMAIN..."
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"

echo "Сертификат успешно выдан."