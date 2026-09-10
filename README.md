# Remnawave Node Installer

Скрипт с меню для быстрой установки ноды [Remnawave](https://docs.rw/install/remnawave-node) и сайта‑заглушки на nginx с сертификатом Let's Encrypt.

## Возможности

| Пункт | Что делает |
|---|---|
| 1 | Устанавливает Docker и ноду Remnawave в `/opt/remnanode` |
| 2 | Нода + сайт‑заглушка на nginx + SSL‑сертификат на ваш домен |
| 3 | Только сайт‑заглушка |
| 4 | Обновить файлы сайта из GitHub (после замены `radio.zip` в репозитории) |
| 5 | Логи ноды |
| 6 | Обновить ноду (новый образ) |
| 7 | Удаление ноды / сайта |

Сайт можно поставить в двух режимах: **Selfsteal** (nginx на `127.0.0.1:9443`, порт 443 занимает Xray Reality, домен используется как SNI) или **обычный** (nginx сам слушает 443).

## Запуск на сервере

Требования: Ubuntu 22.04+/Debian 11+, root, A‑запись домена указывает на IP сервера (для пункта 2/3).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MonopoD123/remnanode-installer/main/install.sh)
```

> Используйте именно `bash <(curl ...)`, а не `curl ... | bash`.

---


## Где что лежит на сервере

| Что | Путь |
|---|---|
| Нода | `/opt/remnanode/docker-compose.yml` |
| Файлы сайта | `/var/www/<домен>/` |
| Конфиг nginx | `/etc/nginx/sites-available/<домен>.conf` |
| Сертификат | `/etc/letsencrypt/live/<домен>/` (автопродление через `certbot.timer`) |

Полезные команды:

```bash
cd /opt/remnanode && docker compose logs -f -t   # логи ноды
docker compose restart                            # перезапуск ноды
certbot renew --dry-run                           # проверка автопродления сертификата
```
