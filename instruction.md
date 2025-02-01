
В репозитории будет файл ssl.sh, install.sh и ocserv.conf.

Дано: чистая операционная система Ubuntu 22.04

Пользователь выполняет клонирование данного репозитория

Далее необходимо получить сертификат на домен, пользователь выполняет ssl.sh и получает домен

Далее пользователь выполняет install.sh в котором вводит домен, скрипт полностью установит ocserv и самое главное настроит систему на работу в режиме VPN

Далее представлены инструкции, которые обычно выполнялись вручную

Тебе необходимо всё автоматизировать с помощью двух данных описанных команд

Выдача сертификата (ssl.sh):

1 
```
apt update
apt-get install nginx python3-certbot-nginx
```

2 Диалоговое окно с запросом домена arg DOMAIN и arg SECRET

3 Выдача сертификата
```
certbot certonly --nginx -d
```

Установка ocserv (install.sh)
0 Запрос домена
1
```shell
sudo apt install -y git ruby-ronn libbsd-dev libsystemd-dev libpcl-dev libwrap0-dev libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev libreadline-dev libnl-route-3-dev libkrb5-dev libradcli-dev libcurl4-gnutls-dev libcjose-dev libjansson-dev libprotobuf-c-dev libtalloc-dev libhttp-parser-dev protobuf-c-compiler gperf nuttcp lcov libuid-wrapper libpam-wrapper libnss-wrapper libsocket-wrapper gss-ntlmssp haproxy iputils-ping freeradius gawk gnutls-bin iproute2 yajl-tools tcpdump autoreconf
```
2
```shell
git clone https://gitlab.com/openconnect/ocserv.git && cd ocserv
```
3
```shell
autoreconf -fvi
```
4
```
./configure && make
```
5
```
sudo make install
```
6
```
sudo cp /lib/systemd/system/ocserv.service /etc/systemd/system/ocserv.service
```
7 Edit this file: `sudo nano /etc/systemd/system/ocserv.service`
From
```
ExecStart=**/usr/sbin/ocserv** --foreground --pid-file /run/ocserv.pid --config /etc/ocserv/ocserv.conf
```
To
```
ExecStart=**/usr/local/sbin/ocserv** --foreground --pid-file /run/ocserv.pid --config /etc/ocserv/ocserv.conf
```

```
sudo systemctl daemon-reload
```

```
sudo systemctl restart ocserv
```

8
```
cd ../ && cp ocserv.conf /etc/ocserv/ocserv.conf
```

9 Заменить в /etc/ocserv/ocserv.conf <lets-ssl> на запрошенный домен DOMAIN, заменить SECRET на опрошенный
10 Создать юзера `adduser ocserv`

11 
```
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/60-custom.conf
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.d/60-custom.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.d/60-custom.conf
sudo sysctl -p /etc/sysctl.d/60-custom.conf
```

12
```
sudo apt install ufw
sudo ufw allow 22/tcp
```
Then find the name of your server’s main network interface.

```
ip addr
```
To configure IP masquerading, we have to add iptables command in a UFW configuration file.
```
sudo nano /etc/ufw/before.rules
```
By default, there are some rules for the `filter` table. Add the following lines at the end of this file. Replace `ens3` with your own network interface name.
```
# NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.10.10.0/24 -o ens3 -j MASQUERADE

# End each table with the 'COMMIT' line or these rules won't be processed
COMMIT
```

The above lines will append (**-A**) a rule to the end of of **POSTROUTING** chain of **nat** table. It will link your virtual private network with the Internet. And also hide your network from the outside world. So the Internet can only see your VPN server’s IP, but can’t see your VPN client’s IP, just like your home router hides your private home network.

By default, UFW forbids packet forwarding. We can allow forwarding for our private network. Find the `ufw-before-forward` chain in this file and add the following 3 lines, which will accept packet forwarding if the source IP or destination IP is in the `10.10.10.0/24` range.

```
# allow forwarding for trusted network
-A ufw-before-forward -s 10.10.10.0/24 -j ACCEPT
-A ufw-before-forward -d 10.10.10.0/24 -j ACCEPT
```
```
sudo ufw enable
sudo systemctl restart ufw
```

13

sudo systemctl daemon-reload
sudo ufw allow 22/tcp