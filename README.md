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
bash <(curl -fsSL https://raw.githubusercontent.com/ВАШ_ЛОГИН/remnanode-installer/main/install.sh)
```

> Используйте именно `bash <(curl ...)`, а не `curl ... | bash`.

---

# Как залить на GitHub

## Шаг 0. Подготовьте файлы

В папке проекта должно быть:

```
remnanode-installer/
├── install.sh        ← скрипт
├── radio.zip         ← ваш архив с сайтом (в корне!)
├── README.md
└── .gitattributes
```

Откройте `install.sh` и в самом начале замените:

```bash
GITHUB_USER="YOUR_GITHUB_USERNAME"   # ← ваш логин GitHub
GITHUB_REPO="remnanode-installer"    # ← имя репозитория, если назовёте иначе
```

Также замените `ВАШ_ЛОГИН` в команде запуска выше в этом README.

⚠️ Если редактируете на Windows — сохраняйте с окончаниями строк **LF** (в VS Code / Notepad++ справа внизу `CRLF → LF`), иначе bash выдаст ошибки `$'\r': command not found`. Файл `.gitattributes` защищает от этого при заливке через git.

## Шаг 1. Создайте репозиторий

1. Зарегистрируйтесь/войдите на https://github.com
2. Справа вверху **«+» → New repository**
3. Repository name: `remnanode-installer`
4. Выберите **Public** (обязательно — иначе сервер не сможет скачать скрипт и сайт без токена)
5. Галочки README/.gitignore **не ставьте** → **Create repository**

## Шаг 2 (вариант А). Через браузер — самый простой

1. На странице пустого репозитория нажмите ссылку **«uploading an existing file»**
2. Перетащите в окно `install.sh`, `radio.zip`, `README.md`, `.gitattributes`
   (файл `.gitattributes` скрытый — на macOS покажите скрытые файлы `Cmd+Shift+.`)
3. Внизу **Commit changes**

## Шаг 2 (вариант Б). Через git в терминале

```bash
cd remnanode-installer
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/ВАШ_ЛОГИН/remnanode-installer.git
git push -u origin main
```

При `git push` GitHub спросит логин и пароль. **Пароль от аккаунта не подойдёт** — нужен токен:
GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token → отметьте `repo` → скопируйте токен и вставьте его вместо пароля.

## Шаг 3. Проверьте

Откройте в браузере (должен показаться текст скрипта):

```
https://raw.githubusercontent.com/ВАШ_ЛОГИН/remnanode-installer/main/install.sh
```

И архив сайта должен скачиваться по:

```
https://raw.githubusercontent.com/ВАШ_ЛОГИН/remnanode-installer/main/radio.zip
```

## Как обновить сайт или скрипт

- **Браузер:** откройте файл в репозитории → для `radio.zip` загрузите новый через **Add file → Upload files** (с тем же именем, он заменится); для `install.sh` — значок карандаша → правка → **Commit changes**.
- **git:** замените файлы локально, затем
  ```bash
  git add . && git commit -m "update" && git push
  ```
- На сервере выберите пункт **4) Обновить файлы сайта из GitHub**.

> raw.githubusercontent.com кэширует файлы до ~5 минут — если сразу после заливки скачалась старая версия, подождите немного.

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
