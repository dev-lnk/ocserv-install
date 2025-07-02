# Установка ocserv на сервер Ubuntu

Установка осуществляется на "пустой" сервер, работающий на Ubuntu. Подразумевается, что у вас есть домен, направленный на данный сервер.

## Установка
 - Выполните клонирование репозитория `git@github.com:dev-lnk/ocserv-install.git`
 - Скопируйте .env.example в .env файл и настройте нужные параметры
 - Получите LE сертификат для подключения к ocserv `sudo ./ssl.sh`
 - Выполните установку `sudo ./install.sh`
 - Проверьте работу ocserv `sudo systemctl status ocserv`
 - Создать пользователя `sudo ocpasswd -c /etc/ocserv/ocpasswd <username>`
 - Подключение `https://<DOMAIN>?<SECRET>`
