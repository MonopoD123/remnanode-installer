#!/usr/bin/env bash
# =====================================================================
#  Remnawave Node Installer
#  1) Установка ноды Remnawave (по https://docs.rw/install/remnawave-node)
#  2) Установка ноды + сайт-заглушка на nginx с SSL (Let's Encrypt)
# =====================================================================

set -o pipefail

# ================== НАСТРОЙКИ РЕПОЗИТОРИЯ (ЗАМЕНИТЕ) ==================
GITHUB_USER="MonopoD123"      # ваш логин на GitHub
GITHUB_REPO="remnanode-installer"       # имя репозитория
GITHUB_BRANCH="main"                    # ветка
SITE_ZIP_NAME="radio.zip"               # архив с сайтом в корне репозитория
# ======================================================================

# Можно переопределить при запуске: SITE_ZIP_URL=https://... bash install.sh
SITE_ZIP_URL="${SITE_ZIP_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${SITE_ZIP_NAME}}"

NODE_DIR="/opt/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
WEBROOT_BASE="/var/www"
ACME_ROOT="/var/www/letsencrypt"
STATE_FILE="/etc/remnanode-installer.conf"
DEFAULT_SELFSTEAL_PORT="9443"

NODE_PORT=""
DOMAIN=""
EMAIL=""
SITE_MODE=""          # selfsteal | public
SELFSTEAL_PORT=""

# ------------------------------ Оформление ----------------------------
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'

info() { echo -e "${CYAN}[i]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
line() { echo -e "${DIM}------------------------------------------------------------${NC}"; }

# ------------------------------ Ввод ----------------------------------
# Все чтения идут из /dev/tty, поэтому скрипт работает и через bash <(curl ...)
if [[ ! -r /dev/tty ]]; then
    echo "Нет доступа к терминалу (/dev/tty). Запустите скрипт интерактивно." >&2
    exit 1
fi

ORIG_STTY="$(stty -g </dev/tty 2>/dev/null)"
restore_tty() { [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" </dev/tty 2>/dev/null; }
trap restore_tty EXIT

# ask VAR "Вопрос" [значение_по_умолчанию]
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __ans
    [[ -n "$__def" ]] && __prompt+=" [${__def}]"
    read -r -p "${BOLD}?${NC} ${__prompt}: " __ans </dev/tty
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm "Вопрос" [y|n]  -> код возврата 0 = да
confirm() {
    local __def="${2:-n}" __hint="[y/N]" __ans
    [[ "$__def" == "y" ]] && __hint="[Y/n]"
    read -r -p "${BOLD}?${NC} $1 ${__hint}: " __ans </dev/tty
    __ans="${__ans:-$__def}"
    [[ "${__ans,,}" =~ ^(y|yes|д|да)$ ]]
}

# Чтение очень длинной строки (SECRET_KEY бывает > 4096 символов,
# а в обычном режиме терминала строка обрезается на 4096)
read_long() {
    local __v __old
    __old="$(stty -g </dev/tty)"
    stty -icanon min 1 time 0 </dev/tty
    IFS= read -r __v </dev/tty
    stty "$__old" </dev/tty
    __v="${__v%$'\r'}"
    printf -v "$1" '%s' "$__v"
}

# Чтение многострочного текста до строки END
read_multiline() {
    local __line __out="" __old
    __old="$(stty -g </dev/tty)"
    stty -icanon min 1 time 0 </dev/tty
    while IFS= read -r __line; do
        __line="${__line%$'\r'}"
        [[ "$__line" == "END" ]] && break
        __out+="${__line}"$'\n'
    done </dev/tty
    stty "$__old" </dev/tty
    printf -v "$1" '%s' "$__out"
}

pause() { echo; read -r -p "Нажмите Enter, чтобы вернуться в меню..." _ </dev/tty; }

# ------------------------------ Проверки ------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Запустите скрипт от root (sudo -i)"
        exit 1
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "Поддерживаются только Debian / Ubuntu (apt)"
        exit 1
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

ensure_base_packages() {
    info "Обновляю списки пакетов и ставлю базовые утилиты..."
    apt-get update -qq >/dev/null
    apt_install curl ca-certificates unzip iproute2 || { err "Не удалось установить базовые пакеты"; return 1; }
    ok "Базовые пакеты готовы"
}

get_server_ip() {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

has_ipv6() { [[ -f /proc/net/if_inet6 ]] && [[ -s /proc/net/if_inet6 ]]; }

# Кто слушает TCP-порт (пусто — свободен)
port_owner() {
    ss -tlnpH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {print $0}' \
        | grep -oP 'users:\(\("\K[^"]+' | sort -u | tr '\n' ' '
}

load_state() {
    # shellcheck source=/dev/null
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    return 0
}

save_state() {
    cat >"$STATE_FILE" <<EOF
DOMAIN="${DOMAIN}"
SITE_MODE="${SITE_MODE}"
SELFSTEAL_PORT="${SELFSTEAL_PORT}"
EOF
}

# ============================ DOCKER ==================================
install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "Docker уже установлен: $(docker --version)"
        return 0
    fi
    info "Устанавливаю Docker (curl -fsSL https://get.docker.com | sh)..."
    if ! curl -fsSL https://get.docker.com | sh; then
        err "Не удалось установить Docker"
        return 1
    fi
    systemctl enable --now docker >/dev/null 2>&1
    if ! docker compose version >/dev/null 2>&1; then
        err "Плагин docker compose недоступен"
        return 1
    fi
    ok "Docker установлен"
}

# ============================ НОДА ====================================
configure_node() {
    mkdir -p "$NODE_DIR"

    if [[ -f "$COMPOSE_FILE" ]]; then
        warn "Уже есть конфиг: $COMPOSE_FILE"
        if ! confirm "Перезаписать его?" n; then
            info "Оставляю существующий docker-compose.yml"
            NODE_PORT="$(grep -oP 'NODE_PORT\s*[=:]\s*"?\K[0-9]+' "$COMPOSE_FILE" | head -1)"
            return 0
        fi
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%s)"
        info "Старый конфиг сохранён как бэкап"
    fi

    line
    echo -e "${BOLD}Подготовка в панели Remnawave:${NC}"
    echo "  Nodes → Management → «+» → заполните форму (обратите внимание на Node Port)"
    echo "  → нажмите «Copy docker-compose.yml»"
    line
    echo "Как задать конфигурацию ноды?"
    echo "  1) Вставить docker-compose.yml, скопированный из панели (рекомендуется)"
    echo "  2) Ввести NODE_PORT и SECRET_KEY вручную"
    local method
    ask method "Выбор" "1"

    case "$method" in
        1)
            echo
            info "Вставьте содержимое docker-compose.yml."
            info "После вставки с НОВОЙ строки напишите ${BOLD}END${NC} и нажмите Enter:"
            local content
            read_multiline content
            if ! grep -q 'remnawave/node' <<<"$content"; then
                err "В тексте нет образа remnawave/node — похоже, вставлено не то"
                return 1
            fi
            grep -q 'SECRET_KEY' <<<"$content" || warn "В конфиге не найден SECRET_KEY — проверьте, что скопировали полностью"
            printf '%s' "$content" >"$COMPOSE_FILE"
            ;;
        2)
            local port key
            ask port "NODE_PORT (порт из формы в панели)" "2222"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                err "Некорректный порт: $port"
                return 1
            fi
            echo -e "${BOLD}?${NC} Вставьте SECRET_KEY из панели и нажмите Enter:"
            read_long key
            key="${key#*SECRET_KEY=}"; key="${key#\"}"; key="${key%\"}"
            key="$(echo -n "$key" | tr -d '[:space:]')"
            if [[ -z "$key" ]]; then
                err "SECRET_KEY пустой"
                return 1
            fi
            cat >"$COMPOSE_FILE" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${port}
      - SECRET_KEY="${key}"
EOF
            ;;
        *)
            err "Неверный выбор"
            return 1
            ;;
    esac

    if ! (cd "$NODE_DIR" && docker compose config -q); then
        err "docker-compose.yml содержит ошибку (см. выше). Проверьте вставленный текст."
        return 1
    fi
    NODE_PORT="$(grep -oP 'NODE_PORT\s*[=:]\s*"?\K[0-9]+' "$COMPOSE_FILE" | head -1)"
    ok "Конфиг сохранён: $COMPOSE_FILE (NODE_PORT=${NODE_PORT:-не найден})"
}

start_node() {
    cd "$NODE_DIR" || return 1
    info "Скачиваю образ и запускаю контейнер..."
    if ! docker compose pull || ! docker compose up -d; then
        err "Не удалось запустить ноду"
        return 1
    fi
    sleep 5
    if docker ps --format '{{.Names}}' | grep -qx remnanode; then
        ok "Контейнер remnanode запущен"
    else
        err "Контейнер не запущен. Последние логи:"
        docker compose logs --tail 50 -t
        return 1
    fi
    echo; info "Последние строки логов:"
    docker compose logs --tail 15 -t
}

node_finish_hint() {
    line
    echo -e "${GREEN}${BOLD}Нода установлена.${NC} Завершите добавление в панели:"
    echo "  В карточке создания ноды нажмите «Next» → выберите Config Profile → «Create»."
    [[ -n "$NODE_PORT" ]] && echo -e "  ${YELLOW}Порт ${NODE_PORT} должен быть открыт ТОЛЬКО для IP панели.${NC}"
    line
}

update_node() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    cd "$NODE_DIR" || return 1
    docker compose pull && docker compose up -d && docker image prune -f >/dev/null
    ok "Нода обновлена"
    docker compose ps
}

show_logs() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    info "Логи ноды (выход — Ctrl+C)"
    cd "$NODE_DIR" || return 1
    trap ':' INT
    docker compose logs -f -t --tail 100
    trap - INT
}

# ============================ ФАЕРВОЛ =================================
detect_ssh_port() {
    local p
    p="$(ss -tlnpH 2>/dev/null | grep '"sshd"' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)"
    echo "${p:-22}"
}

setup_firewall() {
    local need_http="${1:-0}"
    echo
    confirm "Настроить фаервол UFW (порт ноды будет открыт только для IP панели)?" n || return 0

    if [[ -z "$NODE_PORT" ]]; then
        ask NODE_PORT "NODE_PORT ноды" "2222"
    fi
    local panel_ip ssh_port extra p
    ask panel_ip "IP-адрес сервера с панелью Remnawave"
    if [[ -z "$panel_ip" ]]; then err "IP панели не указан — пропускаю настройку UFW"; return 1; fi
    ssh_port="$(detect_ssh_port)"
    ask ssh_port "SSH-порт (не ошибитесь, иначе потеряете доступ!)" "$ssh_port"
    ask extra "Публичные порты inbound'ов Xray через пробел" "443"

    apt_install ufw || { err "Не удалось установить ufw"; return 1; }
    ufw allow "${ssh_port}/tcp" >/dev/null
    [[ "$need_http" == "1" ]] && ufw allow 80/tcp >/dev/null
    for p in $extra; do ufw allow "${p}/tcp" >/dev/null; done
    if ! ufw allow from "$panel_ip" to any port "$NODE_PORT" proto tcp >/dev/null; then
        err "Не удалось добавить правило для панели ($panel_ip)"
        return 1
    fi
    ufw --force enable >/dev/null
    ok "UFW включён"
    ufw status numbered
}

# ============================ САЙТ ====================================
normalize_domain() {
    local d="${1,,}"
    d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d// /}"
    echo "$d"
}

ask_site_params() {
    ask DOMAIN "Домен для сайта (например site.example.com)"
    DOMAIN="$(normalize_domain "$DOMAIN")"
    if ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]]; then
        err "Некорректный домен: '$DOMAIN'"
        return 1
    fi
    ask EMAIL "Email для Let's Encrypt (Enter — без email)" ""

    echo
    echo "Режим работы сайта:"
    echo "  1) Selfsteal для Reality — nginx слушает только 127.0.0.1, порт 443 занимает Xray"
    echo "     (сайт открывается через Xray, домен используется как SNI/serverName)"
    echo "  2) Обычный сайт — nginx сам слушает публичный 443"
    local m
    ask m "Выбор" "1"
    case "$m" in
        1)
            SITE_MODE="selfsteal"
            ask SELFSTEAL_PORT "Локальный порт nginx для Reality target" "$DEFAULT_SELFSTEAL_PORT"
            if ! [[ "$SELFSTEAL_PORT" =~ ^[0-9]+$ ]] || (( SELFSTEAL_PORT < 1 || SELFSTEAL_PORT > 65535 )); then
                err "Некорректный порт"; return 1
            fi
            ;;
        2) SITE_MODE="public"; SELFSTEAL_PORT="" ;;
        *) err "Неверный выбор"; return 1 ;;
    esac
}

check_dns() {
    local sip dips
    sip="$(get_server_ip)"
    dips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
    if [[ -z "$dips" ]]; then
        warn "Домен $DOMAIN не резолвится. Создайте A-запись на IP ${sip}."
        confirm "Всё равно продолжить?" n || return 1
    elif ! grep -qx "$sip" <<<"$dips"; then
        warn "Домен указывает на: $(echo $dips) — а IP этого сервера: ${sip}"
        warn "Если используете Cloudflare — выключите проксирование (серое облако)."
        confirm "Всё равно продолжить?" n || return 1
    else
        ok "DNS в порядке: $DOMAIN → $sip"
    fi
}

check_ports() {
    local owner
    owner="$(port_owner 80)"
    if [[ -n "$owner" && "$owner" != "nginx " ]]; then
        err "Порт 80 занят процессом: $owner — он нужен для получения сертификата"
        return 1
    fi
    if [[ "$SITE_MODE" == "public" ]]; then
        owner="$(port_owner 443)"
        if [[ -n "$owner" && "$owner" != "nginx " ]]; then
            err "Порт 443 занят процессом: $owner (скорее всего Xray ноды)."
            err "Выберите режим Selfsteal или освободите 443."
            return 1
        fi
    else
        owner="$(port_owner "$SELFSTEAL_PORT")"
        if [[ -n "$owner" && "$owner" != "nginx " ]]; then
            err "Порт $SELFSTEAL_PORT занят процессом: $owner"
            return 1
        fi
    fi
}

install_nginx_certbot() {
    info "Устанавливаю nginx и certbot..."
    apt_install nginx certbot || { err "Не удалось установить nginx/certbot"; return 1; }
    systemctl enable --now nginx >/dev/null 2>&1
    rm -f /etc/nginx/sites-enabled/default
    mkdir -p "$ACME_ROOT"
    ok "nginx и certbot установлены"
}

deploy_site_files() {
    if [[ "$SITE_ZIP_URL" == *"YOUR_GITHUB_USERNAME"* ]]; then
        err "В скрипте не указан GITHUB_USER — отредактируйте переменные в начале install.sh"
        return 1
    fi
    local tmp src dest="${WEBROOT_BASE}/${DOMAIN}"
    tmp="$(mktemp -d)"
    info "Скачиваю сайт: $SITE_ZIP_URL"
    if ! curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp/site.zip" "$SITE_ZIP_URL"; then
        err "Не удалось скачать архив. Проверьте, что репозиторий публичный и файл ${SITE_ZIP_NAME} лежит в корне."
        rm -rf "$tmp"; return 1
    fi
    if ! unzip -q -o "$tmp/site.zip" -d "$tmp/x"; then
        err "Архив повреждён или это не zip"
        rm -rf "$tmp"; return 1
    fi

    # Ищем самый «верхний» index.html — архив может содержать вложенную папку
    src="$(find "$tmp/x" -type f \( -name 'index.html' -o -name 'index.htm' \) -not -path '*/__MACOSX/*' \
            -printf '%d\t%h\n' | sort -n | head -1 | cut -f2)"
    if [[ -z "$src" ]]; then
        warn "index.html в архиве не найден — копирую содержимое архива как есть"
        src="$tmp/x"
    fi

    rm -rf "$dest"; mkdir -p "$dest"
    cp -a "$src"/. "$dest"/
    rm -rf "$dest/__MACOSX"
    chown -R www-data:www-data "$dest"
    find "$dest" -type d -exec chmod 755 {} +
    find "$dest" -type f -exec chmod 644 {} +
    rm -rf "$tmp"
    ok "Сайт размещён в $dest"
}

write_nginx_http_only() {
    local v6=""; has_ipv6 && v6="    listen [::]:80;"
    cat >"/etc/nginx/sites-available/${DOMAIN}.conf" <<EOF
server {
    listen 80;
${v6}
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
    }

    location / {
        root ${WEBROOT_BASE}/${DOMAIN};
        index index.html index.htm;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
    nginx -t && systemctl reload nginx
}

write_nginx_ssl() {
    local v6_80="" v6_443="" listen_443
    if has_ipv6; then v6_80="    listen [::]:80;"; fi
    if [[ "$SITE_MODE" == "selfsteal" ]]; then
        listen_443="    listen 127.0.0.1:${SELFSTEAL_PORT} ssl http2;"
    else
        listen_443="    listen 443 ssl http2;"
        has_ipv6 && v6_443="    listen [::]:443 ssl http2;"
    fi

    cat >"/etc/nginx/sites-available/${DOMAIN}.conf" <<EOF
server {
    listen 80;
${v6_80}
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
${listen_443}
${v6_443}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    server_tokens off;
    root  ${WEBROOT_BASE}/${DOMAIN};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
    if ! nginx -t; then
        err "Ошибка в конфиге nginx"
        return 1
    fi
    systemctl reload nginx
}

obtain_certificate() {
    local email_args=(--register-unsafely-without-email)
    [[ -n "$EMAIL" ]] && email_args=(-m "$EMAIL")
    info "Получаю сертификат Let's Encrypt для $DOMAIN..."
    if ! certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
            --agree-tos --non-interactive --keep-until-expiring \
            "${email_args[@]}" \
            --deploy-hook "systemctl reload nginx"; then
        err "Не удалось получить сертификат. Проверьте DNS и доступность порта 80 извне."
        return 1
    fi
    systemctl enable --now certbot.timer >/dev/null 2>&1
    ok "Сертификат получен, автопродление включено"
}

site_summary() {
    line
    echo -e "${GREEN}${BOLD}Сайт-заглушка установлен.${NC}"
    echo "  Домен:        $DOMAIN"
    echo "  Файлы сайта:  ${WEBROOT_BASE}/${DOMAIN}"
    echo "  Конфиг nginx: /etc/nginx/sites-available/${DOMAIN}.conf"
    echo "  Сертификат:   /etc/letsencrypt/live/${DOMAIN}/"
    if [[ "$SITE_MODE" == "selfsteal" ]]; then
        echo "  nginx слушает: 127.0.0.1:${SELFSTEAL_PORT} (снаружи сайт доступен через Xray на 443)"
        line
        echo -e "${BOLD}Пример inbound для Config Profile в панели Remnawave:${NC}"
        cat <<EOF
{
  "tag": "VLESS_REALITY_SELFSTEAL",
  "port": 443,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "127.0.0.1:${SELFSTEAL_PORT}",
      "spiderX": "",
      "shortIds": [""],
      "privateKey": "СГЕНЕРИРУЙТЕ_КЛЮЧ_В_ПАНЕЛИ",
      "serverNames": ["${DOMAIN}"]
    }
  }
}
EOF
        echo -e "${DIM}Пока в профиле ноды нет inbound на 443, сайт по https://${DOMAIN} открываться не будет — это нормально.${NC}"
    else
        echo "  Проверьте: https://${DOMAIN}"
    fi
    line
}

install_site() {
    ask_site_params     || return 1
    check_dns           || return 1
    check_ports         || return 1
    install_nginx_certbot || return 1
    deploy_site_files   || return 1
    write_nginx_http_only || { err "nginx не принял временный конфиг"; return 1; }
    obtain_certificate  || return 1
    write_nginx_ssl     || return 1
    save_state
    site_summary
}

# ============================ СЦЕНАРИИ ================================
flow_node() {
    ensure_base_packages || return 1
    install_docker       || return 1
    configure_node       || return 1
    start_node           || return 1
    setup_firewall 0
    node_finish_hint
}

flow_node_and_site() {
    ensure_base_packages || return 1
    install_docker       || return 1
    configure_node       || return 1
    start_node           || return 1
    install_site         || return 1
    setup_firewall 1
    node_finish_hint
}

flow_site_only() {
    ensure_base_packages || return 1
    install_site         || return 1
}

update_site_files() {
    load_state
    if [[ -z "$DOMAIN" ]]; then err "Сайт ещё не установлен"; return 1; fi
    deploy_site_files && systemctl reload nginx && ok "Файлы сайта обновлены из GitHub"
}

uninstall_menu() {
    echo
    echo "  1) Удалить ноду Remnawave"
    echo "  2) Удалить сайт-заглушку"
    echo "  0) Назад"
    local c; ask c "Выбор" "0"
    case "$c" in
        1)
            confirm "Точно удалить ноду (контейнер и ${NODE_DIR})?" n || return 0
            if [[ -f "$COMPOSE_FILE" ]]; then (cd "$NODE_DIR" && docker compose down); fi
            rm -rf "$NODE_DIR"
            ok "Нода удалена"
            ;;
        2)
            load_state
            if [[ -z "$DOMAIN" ]]; then ask DOMAIN "Домен сайта для удаления"; fi
            [[ -z "$DOMAIN" ]] && return 1
            confirm "Удалить сайт $DOMAIN (конфиг nginx и файлы)?" n || return 0
            rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" "/etc/nginx/sites-available/${DOMAIN}.conf"
            rm -rf "${WEBROOT_BASE:?}/${DOMAIN}"
            nginx -t >/dev/null 2>&1 && systemctl reload nginx
            if confirm "Удалить также сертификат Let's Encrypt?" n; then
                certbot delete --cert-name "$DOMAIN" --non-interactive
            fi
            rm -f "$STATE_FILE"
            ok "Сайт удалён"
            ;;
    esac
}

# ============================ МЕНЮ ====================================
status_line() {
    local node_st site_st
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        node_st="${GREEN}работает${NC}"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        node_st="${YELLOW}установлена, но не запущена${NC}"
    else
        node_st="${DIM}не установлена${NC}"
    fi
    load_state
    if [[ -n "$DOMAIN" ]]; then site_st="${GREEN}${DOMAIN}${NC} (${SITE_MODE})"; else site_st="${DIM}нет${NC}"; fi
    echo -e "  Нода: ${node_st}    Сайт: ${site_st}"
}

show_menu() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║          Remnawave Node Installer            ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    status_line
    line
    echo "  1) Установить ноду Remnawave"
    echo "  2) Установить ноду + сайт-заглушку (nginx + SSL)"
    line
    echo "  3) Установить только сайт-заглушку"
    echo "  4) Обновить файлы сайта из GitHub"
    echo "  5) Логи ноды"
    echo "  6) Обновить ноду"
    echo "  7) Удаление"
    echo "  0) Выход"
    line
}

main() {
    check_root
    check_os
    while true; do
        show_menu
        local choice; ask choice "Выберите пункт"
        case "$choice" in
            1) flow_node;          pause ;;
            2) flow_node_and_site; pause ;;
            3) flow_site_only;     pause ;;
            4) update_site_files;  pause ;;
            5) show_logs;          pause ;;
            6) update_node;        pause ;;
            7) uninstall_menu;     pause ;;
            0) echo "Пока!"; exit 0 ;;
            *) warn "Нет такого пункта"; sleep 1 ;;
        esac
    done
}

main "$@"
