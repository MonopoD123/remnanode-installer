#!/usr/bin/env bash
# =====================================================================
#  Remnawave Node Installer
#  1) Установка ноды Remnawave (по https://docs.rw/install/remnawave-node)
#  2) Установка ноды + сайт-заглушка на nginx с SSL (Let's Encrypt)
#     (на выбор: «Радио», игра «Курятник», «Клипотека» или свой zip)
#  3) Selfsteal Reality: сайт-заглушка + готовый Config Profile для панели
#     со случайными портами (каждый запуск — новый порт для Hosts)
#  4) Установка / обновление ядра Xray-core на ноде
#  5) Проброс сертификатов Let's Encrypt в ноду для gRPC/TLS inbound'ов
#  6) Запуск установщика rkn-guard (Flecksis/rkn-guard)
# =====================================================================

set -o pipefail

# Для рамок, логотипа и подсчёта ширины нужна UTF-8 локаль
if ! locale charmap 2>/dev/null | grep -qi 'utf-\?8'; then
    export LC_ALL=C.UTF-8
fi

# ================== НАСТРОЙКИ РЕПОЗИТОРИЯ (ЗАМЕНИТЕ) ==================
GITHUB_USER="MonopoD123"      # ваш логин на GitHub
GITHUB_REPO="remnanode-installer"       # имя репозитория
GITHUB_BRANCH="main"                    # ветка
# Архивы сайтов-заглушек в корне репозитория
SITE_TEMPLATES=("radio.zip" "eggs.zip" "tube.zip")
SITE_TEMPLATE_TITLES=("Радио" "Игра «Курятник» (лови яйца, LCD-стиль)" "Клипотека — топ видео с YouTube")
# ======================================================================

REPO_RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
# Можно переопределить при запуске: SITE_ZIP_URL=https://... bash install.sh
# (тогда выбор шаблона не спрашивается)
SITE_ZIP_URL_ENV="${SITE_ZIP_URL:-}"
SITE_ZIP_URL=""
SITE_ZIP_NAME=""

NODE_DIR="/opt/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
WEBROOT_BASE="/var/www"
ACME_ROOT="/var/www/letsencrypt"
STATE_FILE="/etc/remnanode-installer.conf"
DEFAULT_SELFSTEAL_PORT="9443"

# Selfsteal Reality: готовые конфиги для панели и диапазоны случайных портов
SELFSTEAL_CFG_DIR="/opt/remnanode-selfsteal"
LOCAL_PORT_MIN=10000          # локальный порт nginx (Reality target)
LOCAL_PORT_MAX=19999
REALITY_PORT_MIN=20000        # публичный порт inbound'а = порт в Hosts
REALITY_PORT_MAX=60000
XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"

# Своё ядро Xray: бинарник на хосте + docker-compose.override.yml,
# который монтирует его в контейнер поверх встроенного в образ.
XRAY_DIR="/var/lib/remnanode"
XRAY_BIN="${XRAY_DIR}/xray"
OVERRIDE_FILE="${NODE_DIR}/docker-compose.override.yml"
OVERRIDE_MARK="remnanode-installer:"
XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100"

# Сертификаты для gRPC/TLS: монтируем /etc/letsencrypt целиком (read-only).
# Монтировать отдельные файлы из live/ нельзя: это симлинки на archive/,
# и после продления сертификата контейнер продолжил бы видеть старый файл.
LE_DIR="/etc/letsencrypt"
RENEW_HOOK="${LE_DIR}/renewal-hooks/deploy/remnanode-restart.sh"
DEFAULT_GRPC_PORT="8443"

# Сторонний скрипт rkn-guard (https://github.com/Flecksis/rkn-guard)
RKN_GUARD_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/master/install.sh"

NODE_PORT=""
DOMAIN=""
EMAIL=""
SITE_MODE=""          # selfsteal | public
SITE_MODE_PRESET=""   # если задан — режим сайта не спрашивается
SELFSTEAL_PORT=""
GRPC_DOMAIN=""        # домен, сертификат которого используется в ноде
SITE_SOURCE=""        # radio.zip | eggs.zip | URL своего архива
XRAY_VERSION=""
REALITY_PORTS=""      # все выданные порты inbound'ов (чтобы не повторялись)
REALITY_PORT=""
REALITY_PRIV=""
REALITY_PUB=""
SITE_PUBLIC443=""     # 1 — nginx в режиме selfsteal дополнительно отдаёт сайт на публичном 443
BLOCK_RU=""           # 1 — блокировать российские сайты через ноду (по умолчанию)
SELFSTEAL_PROTO=""    # both | tcp | grpc — какие inbound'ы генерировать

# ------------------------------ Оформление ----------------------------
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
MAGENTA=$'\e[35m'; SEL=$'\e[1;97;44m'   # подсветка выбранного пункта: белый на синем

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
# Backspace стирает букву целиком, а не половину UTF-8 символа
# (иначе в ответах остаются «обрывки» кириллицы, и certbot падает)
stty iutf8 </dev/tty 2>/dev/null
restore_tty() {
    printf '\e[?25h' >/dev/tty 2>/dev/null   # вернуть курсор
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" </dev/tty 2>/dev/null
}
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

pause() {
    echo
    echo -ne "  ${DIM}Нажмите любую клавишу, чтобы вернуться в меню...${NC}"
    read -rsn1 _ </dev/tty
    echo
}

# ----------------------- Интерактивное меню ---------------------------
# menu_select VAR РЕЖИМ ЗАГОЛОВОК "ключ|подпись|подсказка" ...
#   РЕЖИМ full   — меню на весь экран, ЗАГОЛОВОК = имя функции, рисующей шапку
#   РЕЖИМ inline — меню на месте (внутри сценариев), ЗАГОЛОВОК = текст вопроса
#   Пункт "---|Текст" — разделитель (необязательно с подписью).
#   Управление: ↑/↓ (или j/k), Enter, цифра/буква — сразу, q или Esc — назад.
#   В VAR попадает ключ пункта; q/Esc дают "0". Подпись — в MENU_LABEL.
#   MENU_DEFAULT=ключ — на каком пункте стоит курсор при открытии.
MENU_LABEL=""

# Цвета 3D: светлая фаска (верх/лево), тёмная фаска (низ/право), тень
C_HI=$'\e[38;5;117m'; C_LO=$'\e[38;5;24m'; C_SH=$'\e[38;5;236m'
C_BTN=$'\e[1;97;48;5;26m'   # «нажатая» кнопка выбранного пункта
C_BTN_EDGE=$'\e[38;5;39m'

# Рисует панель меню с фаской и падающей тенью.
# Использует переменные вызывающей menu_select: n mk ml mw sel pw drawn.
_menu_panel_3d() {
    local i pad kk bar content sp
    printf -v bar '%*s' "$pw" ""
    echo -e "  ${C_HI}┌${bar// /─}${C_LO}┐${NC}"
    for ((i = 0; i < n; i++)); do
        if [[ "${mk[$i]}" == "---" ]]; then
            if [[ -n "${ml[$i]}" ]]; then
                pad=$(( pw - 3 - mw[i] )); (( pad < 0 )) && pad=0
                printf -v sp '%*s' "$pad" ""
                content="  ${MAGENTA}${BOLD}${ml[$i]}${NC} ${sp}"
            else
                content="${DIM}${bar// /┄}${NC}"
            fi
        else
            printf -v kk '%2s' "${mk[$i]}"
            pad=$(( pw - 7 - mw[i] )); (( pad < 0 )) && pad=0
            printf -v sp '%*s' "$pad" ""
            if (( i == sel )); then
                content="${C_BTN} ❯ ${kk}  ${ml[$i]}${C_BTN}${sp}${NC}"
            else
                content="   ${DIM}${kk}${NC}  ${ml[$i]}${NC}${sp}"
            fi
        fi
        if (( i == sel )); then
            echo -e "  ${C_HI}│${NC}${content}${C_LO}│${C_BTN_EDGE}◀${NC}"
        else
            echo -e "  ${C_HI}│${NC}${content}${C_LO}│${C_SH}█${NC}"
        fi
    done
    echo -e "  ${C_HI}└${C_LO}${bar// /─}┘${C_SH}█${NC}"
    echo -e "   ${C_SH}${bar// /▀}▀▀${NC}"
    drawn=$((drawn + n + 3))
}

menu_select() {
    local __var="$1" __mode="$2" __title="$3"; shift 3
    local -a mk ml md
    local spec rest i n sel=-1 key seq k2 buf res="" drawn=0 kk cols desc

    for spec in "$@"; do
        mk+=("${spec%%|*}")
        rest="${spec#*|}"
        [[ "$rest" == "$spec" ]] && rest=""
        if [[ "$rest" == *"|"* ]]; then ml+=("${rest%%|*}"); md+=("${rest#*|}")
        else ml+=("$rest"); md+=(""); fi
    done
    n=${#mk[@]}
    for ((i = 0; i < n; i++)); do
        [[ "${mk[$i]}" == "---" ]] && continue
        (( sel < 0 )) && sel=$i
        if [[ -n "${MENU_DEFAULT:-}" && "${mk[$i]}" == "$MENU_DEFAULT" ]]; then sel=$i; break; fi
    done
    (( sel < 0 )) && return 1

    # Перемещение курсора с пропуском разделителей и переходом по кругу
    _menu_step() {
        local s=$1 j
        for ((j = 0; j < n; j++)); do
            sel=$(( (sel + s + n) % n ))
            [[ "${mk[$sel]}" != "---" ]] && return
        done
    }

    cols="$(tput cols 2>/dev/null || echo 80)"

    # 3D-панель для полноэкранного меню: ширину подписей считаем один раз
    # (wc -L учитывает двойную ширину эмодзи), цветовые коды не считаются.
    local panel=0 pw=0 w
    local -a mw=()
    if [[ "$__mode" == "full" && "${MENU_3D:-1}" == "1" ]] && (( cols >= 60 )); then
        panel=1
        for ((i = 0; i < n; i++)); do
            w="$(printf '%s' "${ml[$i]}" | sed 's/\x1b\[[0-9;]*m//g' | wc -L)"
            mw+=("$w")
            (( w + 9 > pw )) && pw=$((w + 9))
        done
        (( pw < 50 )) && pw=50
        (( pw > cols - 6 )) && pw=$((cols - 6))
    fi

    printf '\e[?25l' >/dev/tty
    [[ "$__mode" == "inline" ]] && echo -e "${BOLD}${CYAN}?${NC} ${BOLD}${__title}${NC}"

    while true; do
        if [[ "$__mode" == "full" ]]; then
            printf '\e[H\e[2J'
            "$__title"
        elif (( drawn > 0 )); then
            printf '\e[%dA\e[J' "$drawn"
        fi
        drawn=0
        (( panel )) && _menu_panel_3d
        for ((i = 0; i < n && ! panel; i++)); do
            if [[ "${mk[$i]}" == "---" ]]; then
                if [[ -n "${ml[$i]}" ]]; then
                    echo -e "   ${MAGENTA}${BOLD}${ml[$i]}${NC}"
                else
                    echo -e "   ${DIM}──────────────────────────────${NC}"
                fi
            else
                printf -v kk '%2s' "${mk[$i]}"
                if (( i == sel )); then
                    echo -e "  ${CYAN}${BOLD}❯${NC} ${SEL} ${kk}  ${ml[$i]} ${NC}"
                else
                    echo -e "    ${DIM}${kk}${NC}  ${ml[$i]}"
                fi
            fi
            drawn=$((drawn + 1))
        done
        desc="${md[$sel]}"
        (( ${#desc} > cols - 8 )) && desc="${desc:0:$((cols - 9))}…"
        echo
        if [[ -n "$desc" ]]; then echo -e "   ${YELLOW}↳${NC} ${DIM}${desc}${NC}"; else echo; fi
        echo -e "   ${DIM}↑↓ выбор · Enter — ок · цифра — сразу · q/Esc — назад${NC}"
        drawn=$((drawn + 3))

        key=""; IFS= read -rsn1 key </dev/tty
        case "$key" in
            $'\e')
                seq=""; IFS= read -rsn2 -t 0.05 seq </dev/tty
                case "$seq" in
                    '[A'|'OA') _menu_step -1 ;;
                    '[B'|'OB') _menu_step 1 ;;
                    '') res="0"; break ;;          # одиночный Esc — назад
                esac
                ;;
            '') res="${mk[$sel]}"; break ;;        # Enter
            *)
                buf="$key"
                # Двузначные пункты (10, 11): ждём вторую цифру
                if [[ "$key" =~ ^[0-9]$ ]]; then
                    for ((i = 0; i < n; i++)); do
                        if [[ "${mk[$i]}" == "${key}"? ]]; then
                            k2=""; IFS= read -rsn1 -t 0.6 k2 </dev/tty
                            [[ "$k2" =~ ^[0-9]$ ]] && buf+="$k2"
                            break
                        fi
                    done
                fi
                res=""
                for ((i = 0; i < n; i++)); do
                    [[ "${mk[$i]}" != "---" && "${mk[$i]}" == "$buf" ]] && { sel=$i; res="$buf"; break; }
                done
                [[ -n "$res" ]] && break
                case "$key" in
                    k|K) _menu_step -1 ;;
                    j|J) _menu_step 1 ;;
                    q|Q) res="0"; break ;;
                esac
                ;;
        esac
    done
    unset -f _menu_step
    printf '\e[?25h' >/dev/tty

    MENU_LABEL=""
    for ((i = 0; i < n; i++)); do
        [[ "${mk[$i]}" == "$res" ]] && MENU_LABEL="${ml[$i]}"
    done
    if [[ "$__mode" == "inline" ]]; then
        # Сворачиваем меню в одну строку с ответом
        printf '\e[%dA\e[J' "$((drawn + 1))"
        if [[ "$res" == "0" && -z "$MENU_LABEL" ]]; then
            echo -e "${BOLD}${CYAN}?${NC} ${BOLD}${__title}${NC} ${DIM}— отмена${NC}"
        else
            echo -e "${BOLD}${CYAN}?${NC} ${BOLD}${__title}${NC} ${GREEN}${MENU_LABEL}${NC}"
        fi
    fi
    printf -v "$__var" '%s' "$res"
}

# Шапка перед запуском выбранного действия
action_header() {
    printf '\e[H\e[2J'
    echo
    echo -e "  ${CYAN}${BOLD}▶ ${1}${NC}"
    line
}

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

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# Порт занят процессом или уже выдан этим скриптом
port_taken() {
    local p="$1"
    [[ -n "$(port_owner "$p")" ]] && return 0
    [[ " ${REALITY_PORTS} ${SELFSTEAL_PORT} ${NODE_PORT} ${DEFAULT_GRPC_PORT} 80 443 " == *" ${p} "* ]]
}

# random_free_port MIN MAX — случайный свободный порт, не выдававшийся ранее
random_free_port() {
    local min="$1" max="$2" p i
    for ((i = 0; i < 200; i++)); do
        p="$(shuf -i "${min}-${max}" -n 1)"
        port_taken "$p" || { echo "$p"; return 0; }
    done
    return 1
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
GRPC_DOMAIN="${GRPC_DOMAIN}"
SITE_SOURCE="${SITE_SOURCE}"
REALITY_PORTS="${REALITY_PORTS}"
SITE_PUBLIC443="${SITE_PUBLIC443}"
BLOCK_RU="${BLOCK_RU}"
SELFSTEAL_PROTO="${SELFSTEAL_PROTO}"
EOF
    chmod 600 "$STATE_FILE"
}

# Email для Let's Encrypt: только латиница, иначе ACME отказывает в регистрации.
# Пустой ответ — регистрация без email.
ask_email() {
    local e
    while true; do
        ask e "Email для Let's Encrypt (Enter — без email)" ""
        e="${e//[[:space:]]/}"
        if [[ -z "$e" ]]; then
            EMAIL=""; return 0
        fi
        if LC_ALL=C grep -q '[^ -~]' <<<"$e"; then
            warn "В email есть русские или непечатаемые символы — переключите раскладку на EN и введите заново."
            continue
        fi
        if [[ ! "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            warn "Похоже, это не email: '${e}'. Пример: admin@example.com"
            continue
        fi
        EMAIL="$e"; return 0
    done
}

normalize_domain() {
    local d="${1,,}"
    d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d// /}"
    echo "$d"
}

valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]]
}

get_node_port() {
    [[ -f "$COMPOSE_FILE" ]] && grep -oP 'NODE_PORT\s*[=:]\s*"?\K[0-9]+' "$COMPOSE_FILE" | head -1
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

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
            NODE_PORT="$(get_node_port)"
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
    local method
    menu_select method inline "Как задать конфигурацию ноды?" \
        "1|Вставить docker-compose.yml из панели|Рекомендуется: скопируйте целиком кнопкой «Copy docker-compose.yml»" \
        "2|Ввести NODE_PORT и SECRET_KEY вручную|Скрипт сам соберёт docker-compose.yml"

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
            if ! valid_port "$port"; then
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
    cap_add:
      - NET_ADMIN
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
            info "Отменено"
            return 1
            ;;
    esac

    if ! (cd "$NODE_DIR" && docker compose config -q); then
        err "docker-compose.yml содержит ошибку (см. выше). Проверьте вставленный текст."
        return 1
    fi
    NODE_PORT="$(get_node_port)"
    ok "Конфиг сохранён: $COMPOSE_FILE (NODE_PORT=${NODE_PORT:-не найден})"
    if certs_mounted; then
        info "Сертификаты из ${LE_DIR} остаются проброшенными (через ${OVERRIDE_FILE})"
    fi
    return 0
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
        [[ -f "$OVERRIDE_FILE" ]] && warn "Используется также ${OVERRIDE_FILE} — проверьте и его."
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
    if custom_core_active; then
        echo
        warn "Используется своё ядро Xray $(host_xray_version) — встроенное в новый образ не применяется."
        warn "Вернуть встроенное ядро: пункт «Ядро Xray» → «Вернуть встроенное»."
    fi
}

show_logs() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    info "Логи ноды (выход — Ctrl+C)"
    cd "$NODE_DIR" || return 1
    trap ':' INT
    docker compose logs -f -t --tail 100
    trap - INT
}

# ===================== ЗАПУСК / ОСТАНОВКА НОДЫ ========================
node_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; }

node_start() {
    cd "$NODE_DIR" || return 1
    info "Запускаю ноду..."
    docker compose up -d || { err "Не удалось запустить ноду"; return 1; }
    sleep 4
    if node_running; then
        ok "Нода запущена"
        docker compose logs --tail 10 -t
    else
        err "Контейнер не поднялся. Последние логи:"
        docker compose logs --tail 30 -t
        return 1
    fi
}

node_stop() {
    warn "Пользователи этой ноды потеряют подключение, пока она остановлена."
    confirm "Остановить ноду?" y || return 0
    cd "$NODE_DIR" || return 1
    info "Останавливаю ноду..."
    docker compose stop || { err "Не удалось остановить ноду"; return 1; }
    if node_running; then
        err "Контейнер всё ещё работает — проверьте: docker ps"
        return 1
    fi
    ok "Нода остановлена"
    echo -e "  ${DIM}Настройки и конфиг сохранены — запустить снова можно этим же пунктом.${NC}"
    echo -e "  ${DIM}После перезагрузки сервера нода запустится сама (restart: always).${NC}"
}

node_restart() {
    cd "$NODE_DIR" || return 1
    info "Перезапускаю ноду..."
    docker compose restart || { err "Не удалось перезапустить ноду"; return 1; }
    sleep 4
    if node_running; then
        ok "Нода перезапущена"
        docker compose logs --tail 10 -t
    else
        err "После перезапуска контейнер не работает. Последние логи:"
        docker compose logs --tail 30 -t
        return 1
    fi
}

node_power_menu() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    local c def st
    if node_running; then
        st="${GREEN}работает${NC}"; def="2"
    else
        st="${YELLOW}остановлена${NC}"; def="1"
    fi
    echo -e "  Сейчас нода: ${st}"
    echo
    MENU_DEFAULT="$def" menu_select c inline "Нода" \
        "1|▶ Запустить|docker compose up -d" \
        "2|⏹ Остановить|Контейнер останавливается, настройки сохраняются" \
        "3|🔄 Перезапустить|Например, если Happ не пингует сервер после смены профиля" \
        "0|Назад|"
    case "$c" in
        1) if node_running; then info "Нода уже работает"; else node_start; fi ;;
        2) if node_running; then node_stop; else info "Нода уже остановлена"; fi ;;
        3) node_restart ;;
        *) return 2 ;;
    esac
}

# ===================== docker-compose.override.yml ====================
# Один override-файл управляет и своим ядром Xray, и сертификатами.
# Основной docker-compose.yml (из панели) скрипт не трогает.

# Имя сервиса ноды из основного docker-compose.yml (обычно remnanode)
node_service() {
    (cd "$NODE_DIR" && docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null | head -1)
}

override_has()       { [[ -f "$OVERRIDE_FILE" ]] && grep -qF -- "$1" "$OVERRIDE_FILE"; }
custom_core_active() { override_has ':/usr/local/bin/xray'; }
custom_geo_active()  { override_has ':/usr/local/share/xray/geoip.dat'; }
certs_mounted()      { override_has "${LE_DIR}:${LE_DIR}"; }

# Если override написан не этим скриптом — спросить перед перезаписью
check_foreign_override() {
    if [[ -f "$OVERRIDE_FILE" ]] && ! grep -qF "$OVERRIDE_MARK" "$OVERRIDE_FILE"; then
        warn "Найден ваш собственный $OVERRIDE_FILE — он будет перезаписан (с бэкапом)."
        confirm "Продолжить?" n || return 1
    fi
    return 0
}

# write_override <своё_ядро 0|1> <geo-файлы 0|1> <сертификаты 0|1>
write_override() {
    local core="${1:-0}" geo="${2:-0}" certs="${3:-0}" svc bak=""
    svc="$(node_service)"
    if [[ -z "$svc" ]]; then
        err "Не удалось определить сервис в $COMPOSE_FILE"
        return 1
    fi
    if [[ -f "$OVERRIDE_FILE" ]]; then
        bak="${OVERRIDE_FILE}.bak.$(date +%s)"
        cp "$OVERRIDE_FILE" "$bak"
    fi

    if [[ "$core" != "1" && "$certs" != "1" ]]; then
        rm -f "$OVERRIDE_FILE"
        return 0
    fi

    {
        echo "# ${OVERRIDE_MARK} managed override (xray-core / сертификаты)"
        echo "# Файл создан Remnawave Node Installer. Удалите его и пересоздайте контейнер,"
        echo "# чтобы вернуть ноду к конфигурации из docker-compose.yml."
        echo "services:"
        echo "  ${svc}:"
        echo "    volumes:"
        if [[ "$core" == "1" ]]; then
            echo "      - ${XRAY_BIN}:/usr/local/bin/xray:ro"
            if [[ "$geo" == "1" ]]; then
                echo "      - ${XRAY_DIR}/geoip.dat:/usr/local/share/xray/geoip.dat:ro"
                echo "      - ${XRAY_DIR}/geosite.dat:/usr/local/share/xray/geosite.dat:ro"
            fi
        fi
        if [[ "$certs" == "1" ]]; then
            echo "      - ${LE_DIR}:${LE_DIR}:ro"
        fi
    } >"$OVERRIDE_FILE"

    if ! (cd "$NODE_DIR" && docker compose config -q); then
        err "Итоговая конфигурация docker compose невалидна — откатываю override"
        if [[ -n "$bak" ]]; then cp "$bak" "$OVERRIDE_FILE"; else rm -f "$OVERRIDE_FILE"; fi
        return 1
    fi
}

# Пересоздать контейнер (bind-mount подхватывается только так)
recreate_node() {
    local svc; svc="$(node_service)"
    (cd "$NODE_DIR" && docker compose up -d --force-recreate) || return 1
    sleep 5
    (cd "$NODE_DIR" && docker compose ps --status running --services) | grep -qx "$svc"
}

# ============================ ЯДРО XRAY ===============================
# Схема как в remnanode-xray-update.sh (DigneZzZ/remnawave-scripts):
# бинарник лежит в /var/lib/remnanode/xray и монтируется в контейнер
# поверх /usr/local/bin/xray.

xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "64" ;;
        aarch64|armv8*) echo "arm64-v8a" ;;
        armv7*)         grep -qw vfp /proc/cpuinfo && echo "arm32-v7a" || echo "arm32-v5" ;;
        armv6*)         grep -qw vfp /proc/cpuinfo && echo "arm32-v6" || echo "arm32-v5" ;;
        i386|i686)      echo "32" ;;
        riscv64)        echo "riscv64" ;;
        s390x)          echo "s390x" ;;
        *) return 1 ;;
    esac
}

host_xray_version() {
    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}'
}

container_xray_version() {
    local svc; svc="$(node_service)"
    [[ -z "$svc" ]] && return 1
    (cd "$NODE_DIR" && docker compose exec -T "$svc" xray version 2>/dev/null) | awk 'NR==1{print $2}'
}

# Список релизов: "тег<TAB>prerelease<TAB>дата". $1 = 1 — включая pre-release.
fetch_xray_releases() {
    local json
    json="$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' "$XRAY_RELEASES_API")" || return 1
    jq -r --argjson pre "${1:-0}" '
        [ .[] | select(.draft | not) | select($pre == 1 or (.prerelease | not)) ][:8][]
        | "\(.tag_name)\t\(.prerelease)\t\(.published_at[:10])"' <<<"$json"
}

# Интерактивный выбор версии, результат — в XRAY_VERSION
choose_xray_version() {
    local pre=0 list choice i t p d mark
    local -a tags flags dates
    XRAY_VERSION=""
    while true; do
        info "Получаю список релизов Xray-core..."
        if ! list="$(fetch_xray_releases "$pre")" || [[ -z "$list" ]]; then
            if (( pre == 0 )); then
                warn "Стабильных релизов не нашлось — показываю все, включая pre-release"
                pre=1
                continue
            fi
            err "Не удалось получить список релизов (нет доступа к api.github.com или исчерпан лимит запросов)"
            ask XRAY_VERSION "Введите версию вручную, например v26.7.28 (Enter — отмена)" ""
            [[ -z "$XRAY_VERSION" ]] && return 1
            [[ "$XRAY_VERSION" == v* ]] || XRAY_VERSION="v${XRAY_VERSION}"
            return 0
        fi

        tags=(); flags=(); dates=()
        while IFS=$'\t' read -r t p d; do
            tags+=("$t"); flags+=("$p"); dates+=("$d")
        done <<<"$list"

        local -a items=()
        for i in "${!tags[@]}"; do
            mark=""
            if [[ "${flags[$i]}" == "true" ]]; then
                mark=" ${YELLOW}pre-release${NC}"
            elif (( i == 0 )); then
                mark=" ${GREEN}последняя стабильная${NC}"
            fi
            items+=("$((i + 1))|${tags[$i]}${mark}|Опубликована ${dates[$i]}")
        done
        items+=("---" "m|Ввести версию вручную|Например v26.7.28")
        if (( pre )); then
            items+=("s|Показать только стабильные|Скрыть pre-release")
        else
            items+=("a|Показать и pre-release|Тестовые сборки могут быть нестабильны")
        fi
        items+=("0|Отмена|")
        echo
        menu_select choice inline "Версия Xray-core" "${items[@]}"

        case "${choice,,}" in
            0) return 1 ;;
            a) pre=1 ;;
            s) pre=0 ;;
            m)
                ask XRAY_VERSION "Версия (например v26.7.28)"
                [[ -z "$XRAY_VERSION" ]] && continue
                [[ "$XRAY_VERSION" == v* ]] || XRAY_VERSION="v${XRAY_VERSION}"
                return 0
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tags[@]} )); then
                    XRAY_VERSION="${tags[$((choice - 1))]}"
                    if [[ "${flags[$((choice - 1))]}" == "true" ]]; then
                        warn "${XRAY_VERSION} — pre-release, в нём могут быть ошибки."
                        confirm "Ставить на эту ноду?" n || continue
                    fi
                    return 0
                fi
                warn "Нет такого пункта"
                ;;
        esac
    done
}

# Скачивание, проверка SHA-256 и установка бинарника в $XRAY_BIN
download_xray() {
    local ver="$1" arch zip url tmp expected sum got f
    arch="$(xray_arch)" || { err "Архитектура $(uname -m) не поддерживается"; return 1; }
    zip="Xray-linux-${arch}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${ver}/${zip}"
    tmp="$(mktemp -d)"

    info "Скачиваю Xray-core ${ver} (${arch})..."
    if ! curl -fL --retry 3 --connect-timeout 10 --progress-bar -o "$tmp/$zip" "$url"; then
        err "Не удалось скачать $url"
        err "Проверьте, что версия ${ver} существует и для неё есть сборка ${arch}."
        rm -rf "$tmp"; return 1
    fi

    if curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp/$zip.dgst" "$url.dgst"; then
        expected="$(awk -F '= ' '/256=/ {print $2; exit}' "$tmp/$zip.dgst")"
        sum="$(sha256sum "$tmp/$zip" | awk '{print $1}')"
        if [[ -z "$expected" ]]; then
            warn "В файле .dgst нет SHA-256 — пропускаю проверку"
        elif [[ "$sum" != "$expected" ]]; then
            err "Контрольная сумма не совпадает — архив повреждён"
            rm -rf "$tmp"; return 1
        else
            ok "Контрольная сумма SHA-256 совпадает"
        fi
    else
        warn "Файл контрольной суммы не найден — пропускаю проверку"
    fi

    if ! unzip -q -o "$tmp/$zip" -d "$tmp/x" || [[ ! -f "$tmp/x/xray" ]]; then
        err "В архиве нет бинарника xray"
        rm -rf "$tmp"; return 1
    fi
    chmod +x "$tmp/x/xray"
    got="$("$tmp/x/xray" version 2>/dev/null | awk 'NR==1{print $2}')"
    if [[ -z "$got" ]]; then
        err "Скачанный бинарник не запускается на этом сервере"
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "$XRAY_DIR"
    [[ -f "$XRAY_BIN" ]] && cp -a "$XRAY_BIN" "${XRAY_BIN}.prev"
    install -m 755 "$tmp/x/xray" "${XRAY_BIN}.new" && mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
    for f in geoip.dat geosite.dat; do
        [[ -f "$tmp/x/$f" ]] && install -m 644 "$tmp/x/$f" "${XRAY_DIR}/$f"
    done
    rm -rf "$tmp"
    ok "Xray-core ${got} сохранён в ${XRAY_BIN}"
}

update_core() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    if ! command -v jq >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        info "Ставлю jq и unzip..."
        apt-get update -qq >/dev/null
        apt_install curl unzip jq || { err "Не удалось установить jq/unzip"; return 1; }
    fi

    local now src="встроенное в образ" certs=0
    custom_core_active && src="своё, ${XRAY_BIN}"
    certs_mounted && certs=1
    now="$(container_xray_version)"
    info "Сейчас в ноде: Xray ${now:-неизвестно} (${src})"

    check_foreign_override || return 0

    choose_xray_version || { info "Отменено"; return 0; }
    download_xray "$XRAY_VERSION" || return 1

    local geo=0
    echo
    info "В образе ноды уже есть geoip.dat / geosite.dat. Обычно их трогать не нужно."
    confirm "Заменить их файлами из релиза Xray ${XRAY_VERSION}?" n && geo=1
    write_override 1 "$geo" "$certs" || return 1

    info "Пересоздаю контейнер ноды..."
    if ! recreate_node; then
        err "Нода не поднялась с новым ядром — возвращаю встроенное"
        write_override 0 0 "$certs"
        recreate_node && warn "Нода запущена со встроенным ядром"
        (cd "$NODE_DIR" && docker compose logs --tail 30 -t)
        return 1
    fi

    now="$(container_xray_version)"
    line
    ok "Нода работает, ядро в контейнере: Xray ${now:-?}"
    [[ -n "$now" && "v${now#v}" != "v${XRAY_VERSION#v}" ]] && \
        warn "Версия в контейнере отличается от выбранной ${XRAY_VERSION} — проверьте логи."
    echo "  Бинарник:  ${XRAY_BIN}"
    echo "  Override:  ${OVERRIDE_FILE}"
    echo -e "  ${DIM}Проверьте в панели, что нода online и Xray запущен.${NC}"
    echo -e "  ${DIM}Если нода не принимает конфиг — верните встроенное ядро (пункт 2 этого меню).${NC}"
    line
}

restore_bundled_core() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    if ! custom_core_active; then
        info "Уже используется ядро, встроенное в образ ноды"
        return 0
    fi
    confirm "Вернуть ядро, встроенное в образ ноды?" y || return 0
    local certs=0; certs_mounted && certs=1
    write_override 0 0 "$certs" || return 1
    info "Пересоздаю контейнер ноды..."
    if recreate_node; then
        ok "Нода работает со встроенным ядром: Xray $(container_xray_version)"
    else
        err "Контейнер не запустился. Последние логи:"
        (cd "$NODE_DIR" && docker compose logs --tail 30 -t)
        return 1
    fi
}

core_menu() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    local c
    menu_select c inline "Ядро Xray" \
        "1|Установить / обновить ядро|Выбор версии из релизов XTLS/Xray-core, проверка SHA-256" \
        "2|Вернуть встроенное в образ ядро|Убрать своё ядро и пересоздать контейнер" \
        "0|Назад|"
    case "$c" in
        1) update_core ;;
        2) restore_bundled_core ;;
        *) return 2 ;;
    esac
}

# ===================== СЕРТИФИКАТЫ ДЛЯ gRPC ===========================
cert_exists() {
    [[ -f "${LE_DIR}/live/$1/fullchain.pem" && -f "${LE_DIR}/live/$1/privkey.pem" ]]
}

# Получить сертификат для домена ноды (без сайта-заглушки).
# Если 80-й порт держит nginx — используем webroot (продление тоже через nginx),
# если порт свободен — standalone (certbot сам поднимает сервер на 80).
obtain_node_certificate() {
    local d="$1" owner email_args=(--register-unsafely-without-email)
    apt_install certbot || { err "Не удалось установить certbot"; return 1; }

    [[ -z "$EMAIL" ]] && ask_email
    [[ -n "$EMAIL" ]] && email_args=(-m "$EMAIL")

    owner="$(port_owner 80)"
    if [[ "$owner" == "nginx " ]]; then
        mkdir -p "$ACME_ROOT"
        if [[ ! -f "/etc/nginx/sites-available/${d}.conf" ]]; then
            info "Добавляю в nginx обработку ACME-проверок для $d"
            cat >"/etc/nginx/sites-available/acme-${d}.conf" <<EOF
server {
    listen 80;
    server_name ${d};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
    }

    location / {
        return 404;
    }
}
EOF
            ln -sf "/etc/nginx/sites-available/acme-${d}.conf" "/etc/nginx/sites-enabled/acme-${d}.conf"
            nginx -t && systemctl reload nginx || { err "nginx не принял конфиг"; return 1; }
        fi
        certbot certonly --webroot -w "$ACME_ROOT" -d "$d" \
            --agree-tos --non-interactive --keep-until-expiring "${email_args[@]}" || {
            err "Не удалось получить сертификат. Проверьте DNS и доступность порта 80 извне."
            return 1
        }
    elif [[ -n "$owner" ]]; then
        err "Порт 80 занят процессом: $owner — он нужен для получения сертификата"
        return 1
    else
        certbot certonly --standalone --preferred-challenges http -d "$d" \
            --agree-tos --non-interactive --keep-until-expiring "${email_args[@]}" || {
            err "Не удалось получить сертификат. Проверьте DNS и доступность порта 80 извне."
            return 1
        }
        warn "Сертификат получен в режиме standalone: для автопродления порт 80 должен быть открыт снаружи."
    fi
    systemctl enable --now certbot.timer >/dev/null 2>&1
    ok "Сертификат для $d получен"
}

# После продления сертификата перезапускаем ноду, чтобы Xray перечитал файлы
install_renew_hook() {
    mkdir -p "$(dirname "$RENEW_HOOK")"
    cat >"$RENEW_HOOK" <<EOF
#!/bin/sh
# remnanode-installer: перезапуск ноды после продления сертификата для gRPC
. ${STATE_FILE} 2>/dev/null
[ -n "\$GRPC_DOMAIN" ] || exit 0
case "\$RENEWED_LINEAGE" in
    */live/"\$GRPC_DOMAIN") ;;
    *) exit 0 ;;
esac
cd ${NODE_DIR} 2>/dev/null && docker compose restart >/dev/null 2>&1 || docker restart remnanode >/dev/null 2>&1
exit 0
EOF
    chmod 755 "$RENEW_HOOK"
}

grpc_hint() {
    local d="${1:-$GRPC_DOMAIN}"
    [[ -z "$d" ]] && return 0
    line
    echo -e "${BOLD}Пути к сертификатам внутри контейнера ноды:${NC}"
    echo "  certificateFile: ${LE_DIR}/live/${d}/fullchain.pem"
    echo "  keyFile:         ${LE_DIR}/live/${d}/privkey.pem"
    line
    echo -e "${BOLD}Пример gRPC inbound для Config Profile в панели Remnawave:${NC}"
    cat <<EOF
{
  "tag": "VLESS_GRPC_TLS",
  "port": ${DEFAULT_GRPC_PORT},
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": { "serviceName": "grpc" },
    "security": "tls",
    "tlsSettings": {
      "serverName": "${d}",
      "alpn": ["h2"],
      "certificates": [
        {
          "certificateFile": "${LE_DIR}/live/${d}/fullchain.pem",
          "keyFile": "${LE_DIR}/live/${d}/privkey.pem"
        }
      ]
    }
  }
}
EOF
    echo -e "${DIM}Порт ${DEFAULT_GRPC_PORT} — пример; не используйте порт, занятый Reality или nginx.${NC}"
    echo -e "${DIM}После продления сертификата нода перезапускается автоматически (${RENEW_HOOK}).${NC}"
    line
}

# setup_grpc_certs [домен_по_умолчанию] [defer]
# defer=1 — нода ещё не запущена: только пишем override, контейнер
# не пересоздаём (монтирование применится при первом запуске ноды).
setup_grpc_certs() {
    local def="${1:-$GRPC_DOMAIN}" defer="${2:-0}" d core=0 geo=0 dflt="n"
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    [[ -n "$def" ]] && dflt="y"

    echo
    confirm "Пробросить в ноду сертификаты Let's Encrypt (для gRPC/TLS inbound'ов)?" "$dflt" || return 0
    check_foreign_override || return 0

    ask d "Домен сертификата" "$def"
    d="$(normalize_domain "$d")"
    if ! valid_domain "$d"; then err "Некорректный домен: '$d'"; return 1; fi

    if ! cert_exists "$d"; then
        warn "Сертификата для $d в ${LE_DIR}/live/ нет."
        confirm "Получить его сейчас через Let's Encrypt?" y || return 1
        check_dns "$d" || return 1
        obtain_node_certificate "$d" || return 1
    else
        ok "Сертификат найден: ${LE_DIR}/live/${d}/"
    fi

    GRPC_DOMAIN="$d"
    save_state
    install_renew_hook

    if certs_mounted; then
        ok "${LE_DIR} уже проброшен в контейнер — пересоздавать ноду не нужно"
    elif [[ "$defer" == "1" ]]; then
        custom_core_active && core=1
        custom_geo_active && geo=1
        write_override "$core" "$geo" 1 || return 1
        ok "Монтирование ${LE_DIR} добавлено в ${OVERRIDE_FILE} — применится при запуске ноды"
    else
        custom_core_active && core=1
        custom_geo_active && geo=1
        write_override "$core" "$geo" 1 || return 1
        info "Пересоздаю контейнер ноды..."
        if ! recreate_node; then
            err "Нода не поднялась после монтирования сертификатов — откатываю"
            write_override "$core" "$geo" 0
            recreate_node
            (cd "$NODE_DIR" && docker compose logs --tail 30 -t)
            return 1
        fi
        ok "Сертификаты проброшены в контейнер: ${LE_DIR} → ${LE_DIR} (только чтение)"
    fi
    grpc_hint "$d"
}

remove_grpc_certs() {
    if ! certs_mounted; then info "Сертификаты в ноду не проброшены"; return 0; fi
    warn "Если в Config Profile есть inbound'ы с этими сертификатами, Xray не запустится."
    confirm "Убрать сертификаты из контейнера ноды?" n || return 0
    local core=0 geo=0
    custom_core_active && core=1
    custom_geo_active && geo=1
    write_override "$core" "$geo" 0 || return 1
    GRPC_DOMAIN=""
    save_state
    rm -f "$RENEW_HOOK"
    info "Пересоздаю контейнер ноды..."
    recreate_node && ok "Сертификаты убраны из ноды" || err "Контейнер не запустился — проверьте логи"
}

certs_menu() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then err "Нода не установлена"; return 1; fi
    load_state
    local c
    menu_select c inline "Сертификаты для gRPC" \
        "1|Пробросить сертификаты / сменить домен|Монтирует /etc/letsencrypt в контейнер ноды (только чтение)" \
        "2|Показать пути и пример gRPC inbound|Готовый JSON для Config Profile" \
        "3|Убрать сертификаты из ноды|Inbound'ы с этими сертификатами перестанут работать" \
        "0|Назад|"
    case "$c" in
        1) setup_grpc_certs "${GRPC_DOMAIN:-$DOMAIN}" ;;
        2) if [[ -n "$GRPC_DOMAIN" ]]; then grpc_hint; else info "Сертификаты ещё не настроены"; fi ;;
        3) remove_grpc_certs ;;
        *) return 2 ;;
    esac
}

# ===================== ЗАЩИТА ПОРТА НОДЫ ==============================
# API ноды (NODE_PORT) должен быть доступен только панели: открытый порт
# позволяет сканерам определить, что это нода Remnawave.
# Отдельная цепочка iptables касается ТОЛЬКО этого порта — SSH, сайт и
# порты Reality не затрагиваются. Правила восстанавливаются после
# перезагрузки systemd-сервисом.
GUARD_SCRIPT="/usr/local/sbin/remnanode-guard.sh"
GUARD_UNIT="/etc/systemd/system/remnanode-guard.service"
GUARD_CONF="/etc/remnanode-guard.conf"

guard_active() {
    iptables -S INPUT 2>/dev/null | grep -q -- '-j RW_NODE_GUARD'
}

# IP, с которых сейчас подключена панель к порту ноды
panel_peers() {
    local p="${1:-$NODE_PORT}"
    [[ -z "$p" ]] && return 0
    ss -tnH state established "( sport = :${p} )" 2>/dev/null \
        | awk '{print $NF}' | sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/; s/^::ffff://' | sort -u | tr '\n' ' '
}

valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && return 0
    [[ "$1" =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]] && return 0
    return 1
}

write_guard_files() {
    cat >"$GUARD_SCRIPT" <<'EOF'
#!/bin/sh
# remnanode-installer: порт ноды открыт только для IP панели
CONF=/etc/remnanode-guard.conf
[ -f "$CONF" ] || exit 0
. "$CONF"

unhook() {   # убрать переходы в цепочку для порта $2
    while $1 -D INPUT -p tcp --dport "$2" -j RW_NODE_GUARD 2>/dev/null; do :; done
}

apply() {
    ipt="$1"
    command -v "$ipt" >/dev/null 2>&1 || return 0
    $ipt -N RW_NODE_GUARD 2>/dev/null || true
    $ipt -F RW_NODE_GUARD
    $ipt -A RW_NODE_GUARD -i lo -j ACCEPT
    for ip in $PANEL_IPS; do
        case "$ipt:$ip" in
            iptables:*:*) continue ;;    # IPv6-адрес — не для iptables
            ip6tables:*.*) continue ;;   # IPv4-адрес — не для ip6tables
        esac
        $ipt -A RW_NODE_GUARD -s "$ip" -j ACCEPT
    done
    $ipt -A RW_NODE_GUARD -j DROP
    unhook "$ipt" "$NODE_PORT"
    $ipt -I INPUT 1 -p tcp --dport "$NODE_PORT" -j RW_NODE_GUARD
}

remove() {
    ipt="$1"
    command -v "$ipt" >/dev/null 2>&1 || return 0
    unhook "$ipt" "$NODE_PORT"
    $ipt -F RW_NODE_GUARD 2>/dev/null
    $ipt -X RW_NODE_GUARD 2>/dev/null
    return 0
}

case "$1" in
    stop) remove iptables; remove ip6tables ;;
    *)    apply iptables;  apply ip6tables ;;
esac
exit 0
EOF
    chmod 755 "$GUARD_SCRIPT"

    cat >"$GUARD_UNIT" <<EOF
[Unit]
Description=Remnawave node port guard (NODE_PORT only for panel IP)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${GUARD_SCRIPT}
ExecStop=${GUARD_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF
}

protect_node_port() {
    NODE_PORT="${NODE_PORT:-$(get_node_port)}"
    if [[ -z "$NODE_PORT" ]]; then
        err "Не найден NODE_PORT — сначала установите ноду"
        return 1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        info "Ставлю iptables..."
        apt_install iptables || { err "Не удалось установить iptables"; return 1; }
    fi

    local peers ips ip bad=0 old_ips=""
    [[ -f "$GUARD_CONF" ]] && old_ips="$(. "$GUARD_CONF"; echo "$PANEL_IPS")"
    peers="$(panel_peers "$NODE_PORT")"
    peers="${peers% }"
    echo -e "  Порт ноды: ${BOLD}${NODE_PORT}${NC}"
    if [[ -n "$peers" ]]; then
        ok "Сейчас к ноде подключена панель с IP: ${GREEN}${peers}${NC}"
    else
        warn "Подключения панели к порту ${NODE_PORT} сейчас нет — введите IP панели вручную."
    fi
    if [[ -n "${1:-}" ]]; then
        ips="$1"
    else
        ask ips "IP панели (несколько — через пробел)" "${peers:-$old_ips}"
    fi
    ips="${ips//,/ }"
    if [[ -z "${ips// /}" ]]; then err "IP не указан — порт не закрыт"; return 1; fi
    for ip in $ips; do
        valid_ip "$ip" || { err "Некорректный IP: ${ip}"; bad=1; }
    done
    (( bad )) && return 1

    # Снять старые правила (порт мог смениться), затем записать новые
    [[ -x "$GUARD_SCRIPT" ]] && "$GUARD_SCRIPT" stop
    printf 'NODE_PORT="%s"\nPANEL_IPS="%s"\n' "$NODE_PORT" "$(echo $ips)" >"$GUARD_CONF"
    chmod 600 "$GUARD_CONF"
    write_guard_files
    systemctl daemon-reload
    systemctl enable remnanode-guard.service >/dev/null 2>&1
    if ! systemctl restart remnanode-guard.service; then
        "$GUARD_SCRIPT" || { err "Не удалось применить правила iptables"; return 1; }
    fi

    if guard_active; then
        ok "Порт ${NODE_PORT} закрыт для всех, кроме: $(echo $ips)"
        info "SSH, сайт и порты Reality не затронуты. Правила восстановятся после перезагрузки."
        sleep 3
        peers="$(panel_peers "$NODE_PORT")"
        if [[ -n "$peers" ]]; then ok "Панель по-прежнему подключена: ${peers}"
        else warn "Проверьте в панели, что нода online. Если нет — неверный IP: пункт «Открыть порт снова»."; fi
    else
        err "Правила не применились — проверьте: iptables -S INPUT"
        return 1
    fi
}

unprotect_node_port() {
    if [[ ! -f "$GUARD_CONF" ]] && ! guard_active; then
        info "Защита порта ноды не настроена"
        return 0
    fi
    confirm "Снять ограничение — порт ноды снова будет доступен всем?" n || return 0
    systemctl disable --now remnanode-guard.service >/dev/null 2>&1
    [[ -x "$GUARD_SCRIPT" ]] && "$GUARD_SCRIPT" stop
    rm -f "$GUARD_UNIT" "$GUARD_CONF"
    systemctl daemon-reload
    ok "Ограничение снято — порт ноды открыт для всех"
}

# После запуска ноды ждём, пока панель к ней подключится, и сразу закрываем порт
auto_protect_node_port() {
    NODE_PORT="${NODE_PORT:-$(get_node_port)}"
    [[ -z "$NODE_PORT" ]] && return 0
    local i peers=""
    info "Жду подключения панели к порту ${NODE_PORT}, чтобы закрыть его для остальных..."
    echo -e "  ${DIM}(если нода ещё не добавлена в панели — нажмите там «Next» / «Create»)${NC}"
    for ((i = 0; i < 45; i++)); do
        peers="$(panel_peers "$NODE_PORT")"; peers="${peers% }"
        [[ -n "$peers" ]] && break
        sleep 2
    done
    if [[ -n "$peers" ]]; then
        protect_node_port "$peers"
    else
        warn "Панель пока не подключилась — порт ${NODE_PORT} открыт для всех."
        warn "Когда нода станет online в панели: главное меню → «Закрыть порт ноды»."
    fi
}

guard_status() {
    local np; np="${NODE_PORT:-$(get_node_port)}"
    if guard_active && [[ -f "$GUARD_CONF" ]]; then
        ok "Порт ${np} открыт только для: $(. "$GUARD_CONF"; echo "$PANEL_IPS")"
        echo -e "${DIM}$(iptables -S RW_NODE_GUARD 2>/dev/null | sed 's/^/     /')${NC}"
    else
        warn "Порт ноды ${np:-?} открыт для всех"
    fi
    local peers; peers="$(panel_peers "$np")"
    [[ -n "$peers" ]] && info "Активные подключения к ноде: ${peers}"
}

guard_menu() {
    local c def="1"
    guard_active && def="3"
    MENU_DEFAULT="$def" menu_select c inline "Порт ноды" \
        "1|Закрыть порт для всех, кроме панели|IP панели определяется по текущему подключению к ноде" \
        "2|Открыть порт снова|Снять ограничение (например, если сменился IP панели)" \
        "3|Показать состояние|Какие IP разрешены, кто сейчас подключён" \
        "0|Назад|"
    case "$c" in
        1) protect_node_port ;;
        2) unprotect_node_port ;;
        3) guard_status ;;
        *) return 2 ;;
    esac
}

# ============================ САЙТ ====================================
# Локальный порт nginx для Reality target: по умолчанию — случайный
ask_selfsteal_port() {
    local rnd
    rnd="$(random_free_port "$LOCAL_PORT_MIN" "$LOCAL_PORT_MAX")" || rnd="$DEFAULT_SELFSTEAL_PORT"
    ask SELFSTEAL_PORT "Локальный порт nginx для Reality target (случайный)" "$rnd"
    if ! valid_port "$SELFSTEAL_PORT"; then
        err "Некорректный порт"; return 1
    fi
}

ask_site_params() {
    ask DOMAIN "Домен для сайта (например site.example.com)"
    DOMAIN="$(normalize_domain "$DOMAIN")"
    if ! valid_domain "$DOMAIN"; then
        err "Некорректный домен: '$DOMAIN'"
        return 1
    fi
    if suspicious_domain_warn "$DOMAIN" | grep -q .; then
        suspicious_domain_warn "$DOMAIN"
        confirm "Продолжить с этим доменом?" y || return 1
    fi
    ask_email

    choose_site_template || return 1

    if [[ "$SITE_MODE_PRESET" == "selfsteal" ]]; then
        SITE_MODE="selfsteal"
        ask_selfsteal_port || return 1
        return 0
    fi

    local m
    menu_select m inline "Режим работы сайта" \
        "1|Selfsteal для Reality|nginx только на 127.0.0.1, сайт открывается через Xray, домен = SNI" \
        "2|Обычный сайт|nginx сам слушает публичный 443"
    case "$m" in
        1) SITE_MODE="selfsteal"; ask_selfsteal_port || return 1 ;;
        2) SITE_MODE="public"; SELFSTEAL_PORT="" ;;
        *) info "Отменено"; return 1 ;;
    esac
}

# URL архива для текущего SITE_SOURCE
resolve_site_url() {
    if [[ -n "$SITE_ZIP_URL_ENV" ]]; then
        SITE_ZIP_URL="$SITE_ZIP_URL_ENV"; SITE_ZIP_NAME="${SITE_ZIP_URL##*/}"
    elif [[ "$SITE_SOURCE" == http://* || "$SITE_SOURCE" == https://* ]]; then
        SITE_ZIP_URL="$SITE_SOURCE"; SITE_ZIP_NAME="${SITE_SOURCE##*/}"
    else
        SITE_ZIP_NAME="${SITE_SOURCE:-${SITE_TEMPLATES[0]}}"
        SITE_ZIP_URL="${REPO_RAW}/${SITE_ZIP_NAME}"
    fi
}

choose_site_template() {
    if [[ -n "$SITE_ZIP_URL_ENV" ]]; then
        info "Сайт берётся из SITE_ZIP_URL: $SITE_ZIP_URL_ENV"
        SITE_SOURCE="$SITE_ZIP_URL_ENV"
        resolve_site_url
        return 0
    fi
    local i c def=1 url
    for i in "${!SITE_TEMPLATES[@]}"; do
        [[ "${SITE_TEMPLATES[$i]}" == "$SITE_SOURCE" ]] && def=$((i + 1))
    done
    local -a items=()
    for i in "${!SITE_TEMPLATES[@]}"; do
        items+=("$((i + 1))|${SITE_TEMPLATE_TITLES[$i]}|Архив ${SITE_TEMPLATES[$i]} из репозитория ${GITHUB_USER}/${GITHUB_REPO}")
    done
    items+=("---" "r|Случайный из списка|Каждая нода получит свой вид — так их сложнее связать между собой")
    items+=("u|Свой zip-архив по ссылке|Прямая ссылка https://…/site.zip с index.html внутри")
    echo
    MENU_DEFAULT="$def" menu_select c inline "Сайт-заглушка" "${items[@]}"
    case "${c,,}" in
        u)
            ask url "Прямая ссылка на .zip (https://...)"
            if [[ ! "$url" =~ ^https?:// ]]; then err "Нужна ссылка вида https://..."; return 1; fi
            SITE_SOURCE="$url"
            ;;
        r)
            SITE_SOURCE="${SITE_TEMPLATES[$((RANDOM % ${#SITE_TEMPLATES[@]}))]}"
            ;;
        *)
            if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#SITE_TEMPLATES[@]} )); then
                SITE_SOURCE="${SITE_TEMPLATES[$((c - 1))]}"
            else
                info "Отменено"; return 1
            fi
            ;;
    esac
    resolve_site_url
    ok "Сайт: ${SITE_ZIP_NAME}"
}

# check_dns [домен]  (по умолчанию — $DOMAIN)
check_dns() {
    local d="${1:-$DOMAIN}" sip dips
    sip="$(get_server_ip)"
    dips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)"
    if [[ -z "$dips" ]]; then
        warn "Домен $d не резолвится. Создайте A-запись на IP ${sip}."
        confirm "Всё равно продолжить?" n || return 1
    elif ! grep -qx "$sip" <<<"$dips"; then
        warn "Домен указывает на: $(echo $dips) — а IP этого сервера: ${sip}"
        warn "Если используете Cloudflare — выключите проксирование (серое облако)."
        confirm "Всё равно продолжить?" n || return 1
    else
        ok "DNS в порядке: $d → $sip"
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
        if [[ "$SITE_PUBLIC443" == "1" ]]; then
            owner="$(port_owner 443)"
            if [[ -n "$owner" && "$owner" != "nginx " ]]; then
                warn "Порт 443 занят процессом: ${owner}— сайт напрямую на 443 не опубликую."
                warn "Он будет доступен только через Xray (порт Reality)."
                SITE_PUBLIC443="0"
            fi
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
    [[ -z "$SITE_ZIP_URL" ]] && resolve_site_url
    if [[ "$SITE_ZIP_URL" == *"YOUR_GITHUB_USERNAME"* ]]; then
        err "В скрипте не указан GITHUB_USER — отредактируйте переменные в начале install.sh"
        return 1
    fi
    local tmp src dest="${WEBROOT_BASE}/${DOMAIN}"
    tmp="$(mktemp -d)"
    info "Скачиваю сайт: $SITE_ZIP_URL"
    if ! curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp/site.zip" "$SITE_ZIP_URL"; then
        err "Не удалось скачать архив ${SITE_ZIP_NAME}."
        err "Проверьте, что репозиторий публичный и файл лежит в его корне (или что ссылка верная)."
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
    # Временный ACME-конфиг для этого домена больше не нужен
    rm -f "/etc/nginx/sites-enabled/acme-${DOMAIN}.conf" "/etc/nginx/sites-available/acme-${DOMAIN}.conf"
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
        # Reality не на 443 — сайт открываем и напрямую, чтобы домен работал как обычный сайт
        if [[ "$SITE_PUBLIC443" == "1" ]]; then
            listen_443+=$'\n'"    listen 443 ssl http2;"
            has_ipv6 && v6_443="    listen [::]:443 ssl http2;"
        fi
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

# Доступен ли сервер Let's Encrypt с этой машины
acme_reachable() {
    curl -fsS --max-time 10 -o /dev/null https://acme-v02.api.letsencrypt.org/directory 2>/dev/null
}

# Проверка, что ACME-запрос дойдёт до nginx через 80 порт (с самого сервера)
acme_selfcheck() {
    local token="selfcheck-$RANDOM$RANDOM" got
    mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
    echo "$token" >"${ACME_ROOT}/.well-known/acme-challenge/${token}"
    got="$(curl -s --noproxy '*' --max-time 5 --resolve "${DOMAIN}:80:127.0.0.1" \
            "http://${DOMAIN}/.well-known/acme-challenge/${token}" 2>/dev/null)"
    rm -f "${ACME_ROOT}/.well-known/acme-challenge/${token}"
    [[ "$got" == "$token" ]]
}

obtain_certificate() {
    local email_args log
    if ! acme_reachable; then
        err "Сервер Let's Encrypt (acme-v02.api.letsencrypt.org) недоступен с этого сервера."
        err "Проверьте исходящий интернет / DNS сервера (cat /etc/resolv.conf) и повторите."
        return 1
    fi
    if ! acme_selfcheck; then
        warn "nginx не отдаёт файлы проверки по http://${DOMAIN}/.well-known/acme-challenge/ — certbot может не пройти проверку."
    fi

    log="$(mktemp)"
    while true; do
        email_args=(--register-unsafely-without-email)
        [[ -n "$EMAIL" ]] && email_args=(-m "$EMAIL")
        info "Получаю сертификат Let's Encrypt для $DOMAIN${EMAIL:+ (email: $EMAIL)}..."
        # Подробный трейсбек certbot прячем в лог, на экран — только суть
        if PYTHONIOENCODING=utf-8 certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
                --agree-tos --non-interactive --keep-until-expiring \
                "${email_args[@]}" \
                --deploy-hook "systemctl reload nginx" >"$log" 2>&1; then
            break
        fi
        grep -vE '^\s|^Traceback|^--- Logging|^Call stack|^Message:|^Arguments:|UnicodeEncodeError' "$log" \
            | grep -v '^$' | tail -n 8 | sed 's/^/     /'

        if grep -q 'register an account' "$log" && [[ -n "$EMAIL" ]]; then
            warn "Let's Encrypt не принял email '${EMAIL}'."
            if confirm "Повторить без email?" y; then EMAIL=""; continue; fi
        elif grep -qi 'too many\|rateLimited' "$log"; then
            err "Превышен лимит Let's Encrypt для этого домена — подождите и повторите позже."
        else
            err "Не удалось получить сертификат. Проверьте DNS (A-запись на этот сервер) и доступность порта 80 извне."
            if confirm "Попробовать ещё раз?" n; then continue; fi
        fi
        warn "Полный лог: /var/log/letsencrypt/letsencrypt.log"
        rm -f "$log"
        return 1
    done
    rm -f "$log"
    systemctl enable --now certbot.timer >/dev/null 2>&1
    ok "Сертификат получен, автопродление включено"
}

site_summary() {
    line
    echo -e "${GREEN}${BOLD}Сайт-заглушка установлен.${NC}"
    echo "  Домен:        $DOMAIN"
    echo "  Шаблон:       ${SITE_ZIP_NAME}"
    echo "  Файлы сайта:  ${WEBROOT_BASE}/${DOMAIN}"
    echo "  Конфиг nginx: /etc/nginx/sites-available/${DOMAIN}.conf"
    echo "  Сертификат:   /etc/letsencrypt/live/${DOMAIN}/"
    if [[ "$SITE_MODE" == "selfsteal" ]]; then
        echo "  nginx слушает: 127.0.0.1:${SELFSTEAL_PORT} (снаружи сайт доступен через Xray)"
        # В сценарии Selfsteal готовый конфиг генерируется следующим шагом
        [[ "$SITE_MODE_PRESET" == "selfsteal" ]] && { line; return 0; }
        line
        echo -e "${BOLD}Готовый Config Profile со случайным портом и ключами:${NC}"
        echo "  пункт «Selfsteal Reality» → «Новый конфиг для Hosts»"
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

# ======================= SELFSTEAL REALITY ============================
# Ключи x25519: из работающей ноды → из своего ядра → из образа Xray.
# Старый вывод xray: "Private key / Public key",
# новый: "PrivateKey / Password" (Password = публичный ключ).
gen_reality_keys() {
    local out=""
    REALITY_PRIV=""; REALITY_PUB=""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        out="$(docker exec remnanode xray x25519 2>/dev/null)"
    fi
    if [[ -z "$out" && -x "$XRAY_BIN" ]]; then
        out="$("$XRAY_BIN" x25519 2>/dev/null)"
    fi
    if [[ -z "$out" ]] && command -v docker >/dev/null 2>&1; then
        info "Генерирую ключи x25519 через образ ${XRAY_IMAGE}..."
        out="$(docker run --rm "$XRAY_IMAGE" x25519 2>/dev/null)"
    fi
    REALITY_PRIV="$(awk -F':' 'tolower($1) ~ /^private ?key/ {print $2; exit}' <<<"$out")"
    REALITY_PUB="$(awk -F':' 'tolower($1) ~ /^(public ?key|password)/ {print $2; exit}' <<<"$out")"
    REALITY_PRIV="${REALITY_PRIV//[[:space:]]/}"
    REALITY_PUB="${REALITY_PUB//[[:space:]]/}"
    [[ -n "$REALITY_PRIV" ]]
}

gen_short_id() {
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# make_inbound_json TAG PORT PRIVKEY SHORTID SNI TARGET
make_inbound_json() {
    # settings.flow — Remnawave берёт flow для пользователей именно отсюда;
    # без него в подписке нет flow=xtls-rprx-vision (виден «TLS внутри TLS»).
    # sniffing.routeOnly — домен из SNI/HTTP используется только для маршрутизации,
    # адрес назначения не подменяется (меньше сбоев и странного поведения)
    cat <<EOF
{
  "tag": "$1",
  "port": $2,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "flow": "xtls-rprx-vision"
  },
  "sniffing": {
    "enabled": true,
    "routeOnly": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "$6",
      "spiderX": "",
      "shortIds": ["$4"],
      "privateKey": "$3",
      "serverNames": ["$5"]
    }
  }
}
EOF
}

# make_grpc_inbound_json TAG PORT PRIVKEY SHORTID SNI TARGET SERVICENAME
# gRPC несовместим с Vision: flow явно пустой, иначе панель может подставить
# xtls-rprx-vision и клиенты не подключатся.
make_grpc_inbound_json() {
    cat <<EOF
{
  "tag": "$1",
  "port": $2,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "flow": ""
  },
  "sniffing": {
    "enabled": true,
    "routeOnly": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": {
      "serviceName": "$7",
      "multiMode": false
    },
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "$6",
      "spiderX": "",
      "shortIds": ["$4"],
      "privateKey": "$3",
      "serverNames": ["$5"]
    }
  }
}
EOF
}

# make_xhttp_inbound_json TAG PORT PRIVKEY SHORTID SNI TARGET PATH PADDING
# XHTTP разбивает трафик на отдельные HTTP/2-запросы — нет одного длинного
# TCP-потока, который ТСПУ «замораживает» после ~16 КБ. flow явно пустой:
# панель не должна подставлять Vision. xPaddingBytes — случайный padding
# в каждом запросе (диапазон свой для каждой генерации).
make_xhttp_inbound_json() {
    cat <<EOF
{
  "tag": "$1",
  "port": $2,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "flow": ""
  },
  "sniffing": {
    "enabled": true,
    "routeOnly": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "path": "$7",
      "mode": "auto",
      "xPaddingBytes": "$8"
    },
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "$6",
      "spiderX": "",
      "shortIds": ["$4"],
      "privateKey": "$3",
      "serverNames": ["$5"]
    }
  }
}
EOF
}

# rand_range LO_MIN LO_MAX HI_MIN HI_MAX — строка "a-b" со случайными границами
rand_range() {
    printf '%d-%d' "$(shuf -i "$1-$2" -n 1)" "$(shuf -i "$3-$4" -n 1)"
}

# Путь XHTTP в стиле обычного сайта, а не «/xhttp»
gen_xhttp_path() {
    local -a pre=(assets static media cdn api content files img)
    local -a mid=(v1 v2 v3 build dist pub res)
    printf '/%s/%s/%s' "${pre[$((RANDOM % ${#pre[@]}))]}" "${mid[$((RANDOM % ${#mid[@]}))]}" \
        "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# Клиентские настройки XHTTP для поля «extra» хоста в панели:
#   xPaddingBytes — тот же диапазон, что на сервере;
#   xmux — переиспользование соединений: меньше параллельных TLS-рукопожатий
#          к одному SNI (по наблюдениям, их всплеск — триггер заморозки).
#   Все значения — случайные диапазоны, свои для каждой генерации.
#   maxConnections не задаём: Xray не разрешает его вместе с maxConcurrency.
make_xhttp_extra_json() {
    cat <<EOF
{
  "xPaddingBytes": "$1",
  "xmux": {
    "maxConcurrency": "$(rand_range 12 18 24 32)",
    "cMaxReuseTimes": "$(rand_range 48 80 96 160)",
    "hMaxRequestTimes": "$(rand_range 500 700 800 1000)",
    "hMaxReusableSecs": "$(rand_range 1500 2100 2400 3300)",
    "hKeepAlivePeriod": 0
  }
}
EOF
}

# serviceName для gRPC: не «grpc» по умолчанию, а случайное имя в стиле API
gen_service_name() {
    local -a pre=(api app sync data media feed core user stream event)
    local -a suf=(Service Gateway Stream Sync Api Hub)
    printf '%s.v%d.%s%s' "${pre[$((RANDOM % ${#pre[@]}))]}" "$((RANDOM % 3 + 1))" \
        "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" "${suf[$((RANDOM % ${#suf[@]}))]}"
}

# profile_inbounds BASE — все inbound'ы конфига через запятую (для make_profile_json)
profile_inbounds() {
    local f out=""
    for f in "$1-inbound.json" "$1-grpc-inbound.json" "$1-xhttp-inbound.json"; do
        [[ -f "$f" ]] || continue
        [[ -n "$out" ]] && out+=$',\n'
        out+="$(cat "$f")"
    done
    printf '%s' "$out"
}

# make_profile_json "<inbound json>" [блокировать_ru 1|0]
#   log.access none      — журнал подключений не пишется
#   dns DoH              — сервер резолвит домены не через DNS хостера;
#                          localhost — запасной системный DNS, если DoH заблокирован
#   UseIPv4              — без внезапных выходов по IPv6
#   geoip:private        — нет доступа к внутренней сети сервера через туннель
#   bittorrent           — нет жалоб правообладателей хостеру
#   geoip/geosite ru     — российские сервисы не видят IP ноды (по желанию)
make_profile_json() {
    local inb ru_rules=""
    inb="$(sed 's/^/    /' <<<"$1")"
    if [[ "${2:-1}" == "1" ]]; then
        ru_rules=$',\n      { "domain": ["geosite:category-ru"], "outboundTag": "BLOCK" },\n      { "ip": ["geoip:ru"], "outboundTag": "BLOCK" }'
    fi
    cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
${inb}
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom",
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } }
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }${ru_rules}
    ]
  }
}
EOF
}

# validate_profile ФАЙЛ — проверка профиля ядром Xray самой ноды (с её geo-файлами).
#   0 — профиль валиден, 1 — ошибка (текст в VALIDATE_OUT), 2 — проверить нечем (нода не запущена)
VALIDATE_OUT=""
validate_profile() {
    VALIDATE_OUT=""
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode || return 2
    local tmp="/tmp/rw-profile-check-$$.json"
    docker exec -i remnanode sh -c "cat > ${tmp}" <"$1" 2>/dev/null || return 2
    if VALIDATE_OUT="$(docker exec remnanode xray run -test -c "$tmp" 2>&1)"; then
        docker exec remnanode rm -f "$tmp" >/dev/null 2>&1
        return 0
    fi
    docker exec remnanode rm -f "$tmp" >/dev/null 2>&1
    return 1
}

# check_and_fix_profile PORT — проверяет сохранённый профиль; если в geo-файлах
# ноды нет нужных категорий, пересобирает профиль без RU-правил.
check_and_fix_profile() {
    local base="${SELFSTEAL_CFG_DIR}/$1" rc
    [[ -f "${base}-profile.json" ]] || return 0
    validate_profile "${base}-profile.json"; rc=$?
    case $rc in
        0) ok "Профиль проверен ядром Xray ноды — ошибок нет" ;;
        2) info "Нода не запущена — профиль проверится при применении в панели" ;;
        1)
            if grep -qiE 'category-ru|geoip:ru|geosite|geoip' <<<"$VALIDATE_OUT" \
                    && grep -q 'category-ru' "${base}-profile.json"; then
                warn "В geo-файлах ноды нет списков для России — убираю RU-правила из профиля."
                make_profile_json "$(profile_inbounds "$base")" 0 >"${base}-profile.json"
                BLOCK_RU="0"; save_state
                if validate_profile "${base}-profile.json"; then
                    ok "Исправленный профиль проверен — ошибок нет"
                    info "Чтобы вернуть блокировку RU: пункт 9 → обновить ядро и заменить geoip/geosite, затем новый конфиг."
                    echo; cat "${base}-profile.json"
                else
                    err "Xray всё ещё не принимает профиль:"; tail -n 5 <<<"$VALIDATE_OUT" | sed 's/^/     /'
                fi
            else
                err "Xray не принимает профиль:"; tail -n 5 <<<"$VALIDATE_OUT" | sed 's/^/     /'
            fi
            ;;
    esac
}

# Слова в имени домена, по которым его легко найти в логах Certificate Transparency
suspicious_domain_warn() {
    local d="$1" w
    for w in vpn proxy xray v2ray vless reality tunnel node socks wg wireguard trojan; do
        if [[ "$d" == *"$w"* ]]; then
            warn "В домене есть «${w}». Все сертификаты Let's Encrypt публикуются в открытых логах (crt.sh),"
            warn "и такие имена легко ищутся. Лучше нейтральное: play., radio., cdn., static., media."
            return 0
        fi
    done
}

# Выбор публичного порта inbound'а (= порт в Hosts). По умолчанию — случайный.
choose_reality_port() {
    local rnd c owner
    NODE_PORT="${NODE_PORT:-$(get_node_port)}"
    rnd="$(random_free_port "$REALITY_PORT_MIN" "$REALITY_PORT_MAX")" || {
        err "Не удалось подобрать свободный порт"; return 1; }
    echo
    menu_select c inline "Порт inbound'а (он же порт в Hosts)" \
        "1|Случайный: ${GREEN}${rnd}${NC}|Из диапазона ${REALITY_PORT_MIN}–${REALITY_PORT_MAX}, не совпадает с выданными ранее" \
        "2|443|Стандартный HTTPS — трафик выглядит естественнее" \
        "3|Указать вручную|"
    case "$c" in
        1) REALITY_PORT="$rnd" ;;
        2) REALITY_PORT="443" ;;
        3)
            ask REALITY_PORT "Порт"
            valid_port "$REALITY_PORT" || { err "Некорректный порт"; return 1; }
            ;;
        *) info "Отменено"; return 1 ;;
    esac
    if [[ " ${REALITY_PORTS} " == *" ${REALITY_PORT} "* ]]; then
        warn "Порт ${REALITY_PORT} уже выдавался ранее — убедитесь, что в профиле нет дубля."
    fi
    owner="$(port_owner "$REALITY_PORT")"
    if [[ "$REALITY_PORT" != "$rnd" && -n "$owner" ]]; then
        warn "Порт ${REALITY_PORT} сейчас занят: ${owner}"
        warn "Если это Xray ноды со старым профилем — порт освободится после смены профиля."
        confirm "Использовать всё равно?" n || return 1
    fi
}

generate_selfsteal_config() {
    load_state
    if [[ -z "$DOMAIN" || "$SITE_MODE" != "selfsteal" || -z "$SELFSTEAL_PORT" ]]; then
        err "Сайт в режиме Selfsteal не установлен — сначала выполните установку (пункт 1 этого меню)"
        return 1
    fi
    # $1 — порт, уже выбранный в сценарии установки
    if [[ -n "${1:-}" ]]; then
        REALITY_PORT="$1"
    else
        choose_reality_port || return 1
    fi

    # 443 может занимать либо nginx (сайт напрямую), либо Reality — не оба сразу
    if [[ "$REALITY_PORT" == "443" && "$SITE_PUBLIC443" == "1" ]]; then
        warn "Reality займёт 443 — nginx перестаёт слушать его напрямую."
        warn "Сайт снова откроется по https://${DOMAIN}, когда профиль с этим inbound применится к ноде."
        SITE_PUBLIC443="0"
        write_nginx_ssl || return 1
    elif [[ "$REALITY_PORT" != "443" && "$SITE_PUBLIC443" != "1" \
            && " ${REALITY_PORTS} " != *" 443 "* && -z "$(port_owner 443)" ]]; then
        if confirm "443 свободен — открыть сайт https://${DOMAIN} напрямую через nginx?" y; then
            SITE_PUBLIC443="1"
            write_nginx_ssl || return 1
        fi
    fi

    if ! gen_reality_keys; then
        warn "Не удалось сгенерировать ключи автоматически."
        warn "Сгенерируйте их в панели (Config Profiles → кнопка генерации ключей) и вставьте privateKey."
        REALITY_PRIV="ВСТАВЬТЕ_PRIVATE_KEY"
        REALITY_PUB="-"
    fi

    # Российские сайты через ноду: по умолчанию блокируем, чтобы IP ноды не собирали RU-сервисы
    local ru
    echo
    MENU_DEFAULT="${BLOCK_RU:-1}" menu_select ru inline "Российские сайты через ноду" \
        "1|Блокировать (рекомендуется)|RU-сервисы не увидят IP ноды; в клиенте пустите .ru напрямую (маршрутизация «Россия — direct»)" \
        "0|Пропускать|Всё идёт через ноду, но IP сервера могут занести в списки"
    [[ "$ru" == "1" ]] && BLOCK_RU="1" || BLOCK_RU="0"

    # Протоколы — любой набор из TCP Vision, gRPC и XHTTP. Все — Reality SelfSteal
    # на один и тот же сайт-заглушку. Первый в наборе занимает выбранный порт,
    # остальные получают свои случайные порты.
    local proto
    echo
    MENU_DEFAULT="${SELFSTEAL_PROTO:-both}" menu_select proto inline "Протоколы в профиле" \
        "both|TCP Vision + gRPC|Основной и запасной inbound на разных портах" \
        "txh|TCP Vision + XHTTP|XHTTP — запасной, если TCP «замерзает» после ~16 КБ" \
        "all|TCP Vision + gRPC + XHTTP|Три inbound'а: максимум запасных вариантов" \
        "xhttp|Только XHTTP (при заморозке TCP)|Рекомендуется, если ТСПУ режет raw TCP; лучше ставить на 443" \
        "tcp|Только TCP Vision|Один inbound — самый быстрый вариант" \
        "grpc|Только gRPC|Без Vision; трафик похож на обычный HTTP/2 API"
    [[ "$proto" == "0" ]] && { info "Отменено"; return 1; }
    SELFSTEAL_PROTO="$proto"

    local -a kinds=()
    case "$proto" in
        both)  kinds=(tcp grpc) ;;
        txh)   kinds=(tcp xhttp) ;;
        all)   kinds=(tcp grpc xhttp) ;;
        *)     kinds=("$proto") ;;
    esac
    has_kind() { [[ " ${kinds[*]} " == *" $1 "* ]]; }

    # Порты: первый протокол — выбранный порт, остальные — случайные, без повторов
    local -A kport=() ktag=() ksid=()
    local k taken="${REALITY_PORTS} ${REALITY_PORT}" first=1
    for k in "${kinds[@]}"; do
        if (( first )); then
            kport[$k]="$REALITY_PORT"; first=0
        else
            kport[$k]="$(REALITY_PORTS="$taken" random_free_port "$REALITY_PORT_MIN" "$REALITY_PORT_MAX")" \
                || { err "Не удалось подобрать порт для ${k}"; return 1; }
        fi
        taken+=" ${kport[$k]}"
        ksid[$k]="$(gen_short_id)"
    done
    ktag[tcp]="VLESS_REALITY_SELFSTEAL_${kport[tcp]:-}"
    ktag[grpc]="VLESS_GRPC_REALITY_${kport[grpc]:-}"
    ktag[xhttp]="VLESS_XHTTP_REALITY_${kport[xhttp]:-}"

    local target="127.0.0.1:${SELFSTEAL_PORT}" gservice="" xpath="" xpad="" xextra="" base inbounds
    mkdir -p "$SELFSTEAL_CFG_DIR"
    chmod 700 "$SELFSTEAL_CFG_DIR"
    base="${SELFSTEAL_CFG_DIR}/${REALITY_PORT}"
    rm -f "${base}-inbound.json" "${base}-grpc-inbound.json" "${base}-xhttp-inbound.json" "${base}-xhttp-extra.json"

    if has_kind tcp; then
        make_inbound_json "${ktag[tcp]}" "${kport[tcp]}" "$REALITY_PRIV" "${ksid[tcp]}" "$DOMAIN" "$target" >"${base}-inbound.json"
    fi
    if has_kind grpc; then
        gservice="$(gen_service_name)"
        make_grpc_inbound_json "${ktag[grpc]}" "${kport[grpc]}" "$REALITY_PRIV" "${ksid[grpc]}" "$DOMAIN" "$target" "$gservice" \
            >"${base}-grpc-inbound.json"
    fi
    if has_kind xhttp; then
        xpath="$(gen_xhttp_path)"
        xpad="$(rand_range 100 300 900 1400)"
        make_xhttp_inbound_json "${ktag[xhttp]}" "${kport[xhttp]}" "$REALITY_PRIV" "${ksid[xhttp]}" "$DOMAIN" "$target" "$xpath" "$xpad" \
            >"${base}-xhttp-inbound.json"
        xextra="$(make_xhttp_extra_json "$xpad")"
        printf '%s\n' "$xextra" >"${base}-xhttp-extra.json"
    fi

    inbounds="$(profile_inbounds "$base")"
    make_profile_json "$inbounds" "$BLOCK_RU" >"${base}-profile.json"
    if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${base}-profile.json" 2>/dev/null; then
        err "Сгенерированный профиль — невалидный JSON (${base}-profile.json). Сообщите об ошибке."
        return 1
    fi

    {
        echo "Создан:         $(date '+%Y-%m-%d %H:%M')"
        echo "Public key:     ${REALITY_PUB}"
        echo "Reality target: ${target}"
        if has_kind tcp; then
            echo; echo "[TCP + Vision]"
            echo "Inbound tag:    ${ktag[tcp]}"
            echo "Address:        ${DOMAIN}"
            echo "Port:           ${kport[tcp]}"
            echo "SNI:            ${DOMAIN}"
            echo "Fingerprint:    chrome"
            echo "Short ID:       ${ksid[tcp]}"
        fi
        if has_kind grpc; then
            echo; echo "[gRPC]"
            echo "Inbound tag:    ${ktag[grpc]}"
            echo "Address:        ${DOMAIN}"
            echo "Port:           ${kport[grpc]}"
            echo "SNI:            ${DOMAIN}"
            echo "Fingerprint:    chrome"
            echo "serviceName:    ${gservice}"
            echo "Short ID:       ${ksid[grpc]}"
        fi
        if has_kind xhttp; then
            echo; echo "[XHTTP]"
            echo "Inbound tag:    ${ktag[xhttp]}"
            echo "Address:        ${DOMAIN}"
            echo "Port:           ${kport[xhttp]}"
            echo "SNI:            ${DOMAIN}"
            echo "Fingerprint:    chrome"
            echo "Path:           ${xpath}"
            echo "Mode:           auto"
            echo "Short ID:       ${ksid[xhttp]}"
            echo "XHTTP extra (xmux, padding) — вставить в настройки хоста:"
            echo "$xextra"
        fi
    } >"${base}-host.txt"
    chmod 600 "${base}"-*

    for k in "${kinds[@]}"; do
        [[ " ${REALITY_PORTS} " != *" ${kport[$k]} "* ]] && REALITY_PORTS="${REALITY_PORTS:+$REALITY_PORTS }${kport[$k]}"
    done
    save_state

    if ufw_active; then
        for k in "${kinds[@]}"; do
            ufw allow "${kport[$k]}/tcp" >/dev/null && ok "UFW: открыт порт ${kport[$k]}/tcp"
        done
        ufw allow 80/tcp >/dev/null
        [[ "$SITE_PUBLIC443" == "1" ]] && ufw allow 443/tcp >/dev/null
    fi

    line
    echo -e "${BOLD}1. Config Profile для панели${NC} (Config Profiles → создать → вставить):"
    line
    cat "${base}-profile.json"
    line
    echo -e "${DIM}Отдельные inbound'ы (чтобы добавить в существующий профиль): ${base}-*inbound.json${NC}"
    echo
    local tags="" n=${#kinds[@]}
    for k in "${kinds[@]}"; do tags+="${tags:+, }${CYAN}${ktag[$k]}${NC}"; done
    echo -e "${BOLD}2. Nodes${NC} → нода → выбрать профиль и отметить ${tags}"
    if (( n > 1 )); then
        echo -e "${BOLD}3. Hosts${NC} → создать хост для каждого inbound:"
    else
        echo -e "${BOLD}3. Hosts${NC} → создать хост:"
    fi
    if has_kind tcp; then
        echo -e "     ${BOLD}TCP Vision${NC}  Inbound: ${ktag[tcp]}"
        echo -e "                 Address: ${DOMAIN}   Port: ${GREEN}${kport[tcp]}${NC}   SNI: ${DOMAIN}   Fingerprint: chrome"
    fi
    if has_kind grpc; then
        echo -e "     ${BOLD}gRPC${NC}        Inbound: ${ktag[grpc]}"
        echo -e "                 Address: ${DOMAIN}   Port: ${GREEN}${kport[grpc]}${NC}   SNI: ${DOMAIN}   Fingerprint: chrome"
        echo -e "                 ${DIM}serviceName (${gservice}) панель берёт из inbound сама${NC}"
    fi
    if has_kind xhttp; then
        echo -e "     ${BOLD}XHTTP${NC}       Inbound: ${ktag[xhttp]}"
        echo -e "                 Address: ${DOMAIN}   Port: ${GREEN}${kport[xhttp]}${NC}   SNI: ${DOMAIN}   Fingerprint: chrome"
        echo -e "                 ${DIM}path (${xpath}) и mode панель берёт из inbound сама${NC}"
        echo -e "                 ${BOLD}XHTTP extra${NC} (в настройках хоста) — вставьте:"
        sed 's/^/                   /' <<<"$xextra"
        echo -e "                 ${DIM}Это xmux и padding для клиентов: меньше параллельных TLS-рукопожатий${NC}"
        echo -e "                 ${DIM}к одному SNI. Если такого поля в панели нет — хост работает и без него.${NC}"
    fi
    echo -e "${BOLD}4. Internal Squads${NC} → добавить inbound'ы в сквад пользователей"
    line
    echo -e "  Сохранено: ${base}-profile.json / -host.txt"
    if [[ "$SITE_PUBLIC443" == "1" ]]; then
        echo -e "  Сайт: ${GREEN}https://${DOMAIN}${NC} — открывается сразу (nginx на 443)"
    elif [[ "$REALITY_PORT" == "443" ]]; then
        echo -e "  Сайт: ${GREEN}https://${DOMAIN}${NC} — откроется, когда профиль применится к ноде (шаг 2)"
    else
        echo -e "  Сайт: ${GREEN}https://${DOMAIN}:${REALITY_PORT}${NC} — через Xray, после применения профиля"
    fi
    if [[ "$REALITY_PORT" != "443" ]]; then
        echo -e "  ${DIM}Порт ${REALITY_PORT} не 443: откройте его и в фаерволе хостера, если он есть.${NC}"
    fi
    line
    security_notes
    check_and_fix_profile "$REALITY_PORT"
}

# Памятка: что ещё может выдать ноду, кроме самого конфига
security_notes() {
    local np; np="${NODE_PORT:-$(get_node_port)}"
    echo -e "${BOLD}Безопасность — проверьте:${NC}"
    if [[ "$REALITY_PORT" == "443" ]]; then
        echo -e "  ${GREEN}✓${NC} Reality на 443 — трафик выглядит как обычный HTTPS"
    else
        echo -e "  ${YELLOW}!${NC} Порт ${REALITY_PORT}: долгий TLS на высокий порт заметнее для DPI."
        echo -e "    ${DIM}Для основного хоста лучше 443, случайные порты — для запасных.${NC}"
    fi
    local pr="${SELFSTEAL_PROTO:-both}"
    if [[ "$pr" =~ ^(both|txh|all|tcp)$ ]]; then
        echo -e "  ${GREEN}✓${NC} TCP: flow=xtls-rprx-vision прописан в inbound — проверьте, что он есть в ссылке подписки"
        [[ "$pr" == "tcp" ]] && echo -e "    ${DIM}Если TCP «замерзает» после ~16 КБ — сгенерируйте конфиг с XHTTP${NC}"
    fi
    if [[ "$pr" =~ ^(both|all|grpc)$ ]]; then
        echo -e "  ${GREEN}✓${NC} gRPC: flow пустой (Vision с gRPC не работает), serviceName случайный, не «grpc»"
    fi
    if [[ "$pr" =~ ^(txh|all|xhttp)$ ]]; then
        echo -e "  ${GREEN}✓${NC} XHTTP: трафик разбит на HTTP/2-запросы — нет длинного TCP-потока, который «замерзает»"
        echo -e "    ${DIM}Случайные path и padding; вставьте XHTTP extra в хост — xmux снизит число рукопожатий${NC}"
        echo -e "    ${DIM}Во время заморозки не меняйте fingerprint и не переподключайтесь — это продлевает бан${NC}"
    fi
    if guard_active; then
        echo -e "  ${GREEN}✓${NC} Порт ноды ${np} открыт только для панели"
    else
        echo -e "  ${YELLOW}!${NC} Порт ноды ${np:-NODE_PORT} открыт для всех — закроется сам после подключения панели"
        echo -e "    ${DIM}или вручную: главное меню → «Закрыть порт ноды»${NC}"
    fi
    local ru_hint=""; [[ "$BLOCK_RU" == "1" ]] && ru_hint=" и правило «Россия — напрямую»"
    echo -e "  ${YELLOW}!${NC} В клиенте включите DNS через туннель / DoH${ru_hint}"
    [[ "$BLOCK_RU" != "1" ]] && echo -e "  ${DIM}  (RU-сайты идут через ноду — её IP могут собирать российские сервисы)${NC}"
    echo -e "  ${YELLOW}!${NC} Не публикуйте privateKey: при утечке — «Новый конфиг для Hosts»"
    suspicious_domain_warn "$DOMAIN"
    line
}

# Диагностика: почему не открывается сайт
check_selfsteal_site() {
    load_state
    if [[ -z "$DOMAIN" ]]; then err "Сайт не установлен"; return 1; fi
    local code p owner end
    _http() {   # _http ПОРТ -> HTTP-код при запросе https://DOMAIN:ПОРТ на этот же сервер
        curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 6 \
            --resolve "${DOMAIN}:$1:127.0.0.1" "https://${DOMAIN}:$1/" 2>/dev/null
    }
    _good() { [[ "$1" =~ ^(200|301|302|304|403)$ ]]; }

    echo -e "${BOLD}Домен:${NC} ${DOMAIN}"
    local sip dips
    sip="$(get_server_ip)"
    dips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [[ -z "$dips" ]]; then err "Домен не резолвится — нет A-записи на ${sip}"
    elif [[ " $dips" == *" ${sip} "* ]]; then ok "DNS: ${DOMAIN} → ${sip}"
    else err "DNS: ${DOMAIN} → ${dips}, а IP сервера ${sip} (Cloudflare-прокси выключен?)"; fi

    if systemctl is-active --quiet nginx; then ok "nginx запущен"; else err "nginx не запущен: systemctl status nginx"; fi

    if [[ -f "${LE_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
        end="$(openssl x509 -enddate -noout -in "${LE_DIR}/live/${DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2)"
        ok "Сертификат есть${end:+, действует до ${end}}"
    else
        err "Сертификата для ${DOMAIN} нет"
    fi

    if [[ -n "$SELFSTEAL_PORT" ]]; then
        code="$(_http "$SELFSTEAL_PORT")"
        if _good "$code"; then ok "nginx отвечает на 127.0.0.1:${SELFSTEAL_PORT} (HTTP ${code}) — Reality target в порядке"
        else err "nginx не отвечает на 127.0.0.1:${SELFSTEAL_PORT} (код ${code:-нет ответа})"; fi
    fi

    code="$(_http 443)"
    owner="$(port_owner 443)"
    if _good "$code"; then
        ok "https://${DOMAIN} отвечает (HTTP ${code}, порт 443 слушает: ${owner:-?})"
    else
        warn "На 443 сайт не отвечает${owner:+ (порт слушает: ${owner})}"
        [[ -z "$owner" ]] && warn "  443 никто не слушает: либо примените профиль с Reality на 443, либо откройте сайт через пункт «Новый конфиг для Hosts»."
    fi

    for p in $REALITY_PORTS; do
        [[ "$p" == "443" ]] && continue
        owner="$(port_owner "$p")"
        if [[ -z "$owner" ]]; then
            warn "Reality-порт ${p} никто не слушает — профиль с ним ещё не применён к ноде в панели"
            continue
        fi
        code="$(_http "$p")"
        if _good "$code"; then ok "Reality на ${p} отдаёт сайт (HTTP ${code}) — маскировка работает"
        else warn "Порт ${p} слушает ${owner}, но сайт через него не открылся (код ${code:-нет ответа})"; fi
    done

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        ok "Нода remnanode запущена"
        # Xray не смог занять порт — самая частая причина «нет пинга»
        local busy
        busy="$(docker logs --tail 300 remnanode 2>&1 | grep -iE 'address already in use|failed to listen' | tail -n 3)"
        if [[ -n "$busy" ]]; then
            err "Xray не смог занять порт — inbound не работает, пинга не будет:"
            sed 's/^/     /' <<<"$busy"
        fi
    else
        warn "Нода remnanode не запущена"
    fi

    # Конфликт: Reality хочет 443, а его держит nginx (сайт напрямую)
    if [[ "$(port_owner 443)" == "nginx " ]] && [[ " ${REALITY_PORTS} " == *" 443 "* || -n "${busy:-}" ]]; then
        err "Порт 443 занят nginx, а профиль ноды использует Reality на 443 — Xray не запускается."
        if confirm "Освободить 443 для Xray (сайт будет открываться через Reality)?" y; then
            SITE_PUBLIC443="0"; save_state
            if write_nginx_ssl; then
                ok "nginx больше не слушает 443"
                node_running && node_restart
            fi
        fi
    fi

    # DoH из профиля должен быть доступен с сервера, иначе Xray не резолвит домены
    local doh_ok=0
    curl -s --noproxy '*' --max-time 5 -H 'accept: application/dns-json' \
        'https://1.1.1.1/dns-query?name=google.com&type=A' 2>/dev/null | grep -q '"Status":0' && doh_ok=1
    curl -s --noproxy '*' --max-time 5 'https://8.8.8.8/resolve?name=google.com&type=A' 2>/dev/null \
        | grep -q '"Status":0' && doh_ok=$((doh_ok + 1))
    case $doh_ok in
        2) ok "DoH 1.1.1.1 и 8.8.8.8 доступны с сервера" ;;
        1) warn "Доступен только один DoH-сервер — DNS в Xray будет работать, но медленнее" ;;
        0) err "DoH 1.1.1.1 и 8.8.8.8 недоступны с сервера — без запасного DNS Xray не резолвит сайты."
           warn "  Сгенерируйте профиль заново («Новый конфиг для Hosts») — в нём есть запасной DNS «localhost»," ;;
    esac
    (( doh_ok == 0 )) && warn "  или добавьте \"localhost\" в dns.servers текущего профиля в панели."

    if ufw_active; then
        info "UFW включён, разрешённые порты:"
        ufw status | awk 'NR>4 && /ALLOW/ {print "     " $1}' | sort -u | tr '\n' ' '; echo
    fi
    echo -e "  ${DIM}Проверка идёт с самого сервера. Если тут всё зелёное, а снаружи не открывается —${NC}"
    echo -e "  ${DIM}проверьте фаервол у хостера и что Cloudflare не проксирует домен (серое облако).${NC}"
    unset -f _http _good
}

show_selfsteal_configs() {
    local f found=0
    for f in "$SELFSTEAL_CFG_DIR"/*-host.txt; do
        [[ -f "$f" ]] || continue
        found=1
        line
        cat "$f"
        echo -e "${DIM}Профиль: ${f%-host.txt}-profile.json${NC}"
    done
    if (( found == 0 )); then
        info "Сохранённых конфигов пока нет"
    else
        line
    fi
}

flow_selfsteal() {
    load_state
    if [[ "$SITE_MODE" == "selfsteal" && -n "$DOMAIN" ]]; then
        warn "Selfsteal уже установлен для ${DOMAIN} (nginx на 127.0.0.1:${SELFSTEAL_PORT})."
        warn "Переустановка сменит локальный порт — старые профили перестанут работать."
        info "Чтобы просто получить новый порт для Hosts, используйте «Новый конфиг для Hosts»."
        confirm "Всё равно переустановить?" n || return 0
    fi
    local rc step="${CYAN}${BOLD}"
    stopped() { echo; err "Установка Selfsteal остановлена на шаге $1/5 — причина в сообщениях выше."; }
    echo -e "${step}Шаг 1/5 · Подготовка сервера${NC}"
    ensure_base_packages || { stopped 1; return 1; }
    install_docker       || { stopped 1; return 1; }

    echo; echo -e "${step}Шаг 2/5 · Нода Remnawave${NC}"
    configure_node       || { stopped 2; return 1; }

    echo; echo -e "${step}Шаг 3/5 · Порт Reality для Hosts${NC}"
    # Порты ноды и выданные ранее не должны совпасть со случайным
    choose_reality_port  || { stopped 3; return 1; }
    # Reality не на 443 — nginx сам публикует сайт на 443, и он открывается сразу
    if [[ "$REALITY_PORT" == "443" ]]; then SITE_PUBLIC443="0"; else SITE_PUBLIC443="1"; fi

    echo; echo -e "${step}Шаг 4/5 · Сайт-заглушка и сертификат${NC}"
    SITE_MODE_PRESET="selfsteal"
    install_site
    rc=$?
    SITE_MODE_PRESET=""
    (( rc == 0 )) || { stopped 4; return 1; }
    generate_selfsteal_config "$REALITY_PORT" || { stopped 4; return 1; }

    echo; echo -e "${step}Шаг 5/5 · Запуск ноды${NC}"
    start_node || { stopped 5; return 1; }
    auto_protect_node_port
    echo
    check_and_fix_profile "$REALITY_PORT"
    check_selfsteal_site
    node_finish_hint
}

# Проверка соответствия схеме SelfSteal — так же, как проверяет хостер:
# на каждый TLS-порт Xray подключаемся с разными SNI и смотрим, чей сертификат вернулся.
# При SelfSteal на ЛЮБОМ порту и ЛЮБОМ SNI должен быть сертификат только своего домена.
selfsteal_audit() {
    load_state
    if [[ -z "$DOMAIN" ]]; then err "Домен Selfsteal не настроен — сначала пункт 1 этого меню"; return 1; fi
    command -v openssl >/dev/null 2>&1 || apt_install openssl || { err "Нужен openssl"; return 1; }

    local -a ports=() snis=("$DOMAIN" "www.microsoft.com" "www.google.com" "dl.google.com" "")
    local p sni subj bad=0 checked=0 line_out

    # Порты, которые слушает Xray ноды (+ выданные скриптом и 443)
    while read -r p; do [[ -n "$p" ]] && ports+=("$p"); done < <(
        { ss -tlnpH 2>/dev/null | grep -E '"(xray|rw-core|remnanode)"' | awk '{print $4}' | grep -oE '[0-9]+$'
          for p in $REALITY_PORTS 443; do echo "$p"; done; } | sort -un)

    echo -e "${BOLD}Домен SelfSteal:${NC} ${DOMAIN}"
    echo -e "${DIM}Для каждого порта: какой сертификат сервер отдаёт на разные SNI (как при проверке хостером)${NC}"
    line
    for p in "${ports[@]}"; do
        [[ -z "$(port_owner "$p")" ]] && continue
        [[ "$p" == "$NODE_PORT" || "$p" == "$(get_node_port)" ]] && continue   # API ноды — не TLS-маскировка
        echo -e "${BOLD}Порт ${p}${NC} ${DIM}($(port_owner "$p"))${NC}"
        for sni in "${snis[@]}"; do
            if [[ -n "$sni" ]]; then
                subj="$(timeout 8 openssl s_client -connect "127.0.0.1:${p}" -servername "$sni" </dev/null 2>/dev/null \
                        | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | tr '\n' ' ')"
            else
                subj="$(timeout 8 openssl s_client -connect "127.0.0.1:${p}" -noservername </dev/null 2>/dev/null \
                        | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | tr '\n' ' ')"
            fi
            local lbl="${sni:-(без SNI)}" padn
            padn=$(( 20 - ${#lbl} )); (( padn < 1 )) && padn=1
            printf -v line_out '  SNI %s%*s → ' "$lbl" "$padn" ""
            if [[ -z "$subj" ]]; then
                echo -e "${line_out}${DIM}нет TLS-ответа${NC}"
            elif grep -qF "$DOMAIN" <<<"$subj"; then
                echo -e "${line_out}${GREEN}свой сертификат ✓${NC}"
            else
                echo -e "${line_out}${RED}ЧУЖОЙ: $(grep -oE 'CN ?= ?[^,/ ]+' <<<"$subj" | head -1)${NC}"
                bad=1
            fi
            checked=1
        done
    done
    line
    if (( ! checked )); then
        warn "Не найдено ни одного TLS-порта Xray — нода не запущена или профиль не применён."
        return 1
    fi
    if (( bad )); then
        err "Найдены порты с ЧУЖИМ сертификатом — это и есть нарушение «маскировка через чужие ресурсы»."
        echo -e "  Исправьте в панели Remnawave для ЭТОЙ ноды:"
        echo -e "  1) ${BOLD}Config Profiles${NC}: у каждого Reality-inbound'а"
        echo -e "       target       = ${GREEN}127.0.0.1:${SELFSTEAL_PORT}${NC}  (не чужой сайт:443)"
        echo -e "       serverNames  = ${GREEN}[\"${DOMAIN}\"]${NC}  (только свой домен)"
        echo -e "     Inbound'ы с чужим target/serverNames удалите или пересоздайте: «Новый конфиг для Hosts»."
        echo -e "  2) ${BOLD}Nodes${NC}: ноде назначен только профиль SelfSteal, лишние inbound'ы не отмечены."
        echo -e "  3) ${BOLD}Hosts${NC}: у всех хостов этой ноды SNI = ${GREEN}${DOMAIN}${NC}."
        echo -e "  Затем: пункт 7 → «Перезапустить» и снова эта проверка."
        return 1
    fi
    ok "Все TLS-порты отдают только сертификат ${DOMAIN} — схема SelfSteal соблюдена."
    echo -e "  ${DIM}Проверьте ещё в панели: у всех Hosts этой ноды SNI = ${DOMAIN} — его клиенты шлют в каждом подключении.${NC}"
}

selfsteal_menu() {
    load_state
    local c def="1"
    if [[ "$SITE_MODE" == "selfsteal" && -n "$DOMAIN" ]]; then
        echo -e "  Сейчас: ${GREEN}${DOMAIN}${NC} → 127.0.0.1:${SELFSTEAL_PORT}, порты Hosts: ${GREEN}${REALITY_PORTS:-нет}${NC}"
        echo
        def="2"
    fi
    MENU_DEFAULT="$def" menu_select c inline "Selfsteal Reality" \
        "1|Установить ноду + Selfsteal|Нода, сайт-заглушка, сертификат и готовый Config Profile за один проход" \
        "2|Новый конфиг для Hosts|Новый случайный порт, ключи x25519 и shortId" \
        "3|Показать сохранённые конфиги|Все выданные порты и настройки хостов" \
        "4|Проверить сайт|DNS, nginx, сертификат, порты Reality — почему сайт не открывается" \
        "5|Проверка на соответствие SelfSteal|Какой сертификат отдаёт каждый порт на чужие SNI — как проверяет хостер" \
        "0|Назад|"
    case "$c" in
        1) flow_selfsteal ;;
        2) generate_selfsteal_config ;;
        3) show_selfsteal_configs ;;
        4) check_selfsteal_site ;;
        5) selfsteal_audit ;;
        *) return 2 ;;
    esac
}

# ============================ СЦЕНАРИИ ================================
# Нода запускается последним шагом: к этому моменту уже готовы
# сайт, сертификаты (и их монтирование в override) и фаервол,
# поэтому контейнер стартует сразу с итоговой конфигурацией.
# Чистая нода: только Docker + docker-compose.yml из панели + запуск.
# Без сайта, сертификатов, фаервола и дополнительных вопросов.
flow_node() {
    ensure_base_packages || return 1
    install_docker       || return 1
    configure_node       || return 1
    start_node           || return 1
    auto_protect_node_port
    node_finish_hint
    echo -e "  ${DIM}Сертификаты для gRPC — пункт 10, сайт-заглушка — пункты 3/4.${NC}"
}

flow_node_and_site() {
    ensure_base_packages || return 1
    install_docker       || return 1
    configure_node       || return 1
    if ! install_site; then
        warn "Сайт-заглушку установить не удалось (см. ошибки выше)."
        confirm "Продолжить установку ноды без сайта?" y || return 1
    fi
    setup_grpc_certs "${DOMAIN:-$GRPC_DOMAIN}" 1
    start_node           || return 1
    auto_protect_node_port
    node_finish_hint
}

flow_site_only() {
    ensure_base_packages || return 1
    install_site         || return 1
}

update_site_files() {
    load_state
    if [[ -z "$DOMAIN" ]]; then err "Сайт ещё не установлен"; return 1; fi
    resolve_site_url
    echo -e "  Сейчас установлен: ${GREEN}${SITE_ZIP_NAME}${NC} на ${DOMAIN}"
    echo
    local c
    menu_select c inline "Сайт-заглушка" \
        "1|Обновить текущий из GitHub|Скачать свежую версию ${SITE_ZIP_NAME}" \
        "2|Сменить на другой сайт|Выбрать другой шаблон или свой zip" \
        "0|Назад|"
    case "$c" in
        1) ;;
        2) choose_site_template || return 1 ;;
        *) return 2 ;;
    esac
    deploy_site_files && save_state && systemctl reload nginx && ok "Сайт ${SITE_ZIP_NAME} развёрнут для ${DOMAIN}"
}

uninstall_menu() {
    load_state
    local c
    MENU_DEFAULT="0" menu_select c inline "Что удалить?" \
        "1|${RED}Ноду Remnawave${NC}|Контейнер и ${NODE_DIR}; при желании — своё ядро Xray" \
        "2|${RED}Сайт-заглушку${NC}|Конфиг nginx, файлы сайта, по желанию — сертификат и Selfsteal-конфиги" \
        "0|Назад|"
    case "$c" in
        1)
            confirm "Точно удалить ноду (контейнер и ${NODE_DIR})?" n || return 0
            if [[ -f "$COMPOSE_FILE" ]]; then (cd "$NODE_DIR" && docker compose down); fi
            rm -rf "$NODE_DIR"
            if [[ -f "$GUARD_CONF" ]]; then
                systemctl disable --now remnanode-guard.service >/dev/null 2>&1
                [[ -x "$GUARD_SCRIPT" ]] && "$GUARD_SCRIPT" stop
                rm -f "$GUARD_UNIT" "$GUARD_CONF"; systemctl daemon-reload
            fi
            rm -f "$RENEW_HOOK"
            GRPC_DOMAIN=""
            save_state
            if [[ -f "$XRAY_BIN" ]] && confirm "Удалить также своё ядро Xray (${XRAY_DIR})?" y; then
                rm -f "$XRAY_BIN" "${XRAY_BIN}.prev" "${XRAY_DIR}/geoip.dat" "${XRAY_DIR}/geosite.dat"
                rmdir "$XRAY_DIR" 2>/dev/null
            fi
            ok "Нода удалена"
            ;;
        2)
            if [[ -z "$DOMAIN" ]]; then ask DOMAIN "Домен сайта для удаления"; fi
            [[ -z "$DOMAIN" ]] && return 1
            confirm "Удалить сайт $DOMAIN (конфиг nginx и файлы)?" n || return 0
            rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" "/etc/nginx/sites-available/${DOMAIN}.conf"
            rm -rf "${WEBROOT_BASE:?}/${DOMAIN}"
            nginx -t >/dev/null 2>&1 && systemctl reload nginx
            if [[ "$GRPC_DOMAIN" == "$DOMAIN" ]]; then
                warn "Сертификат $DOMAIN используется нодой для gRPC — удалять его не рекомендуется."
                warn "Без сайта продление пойдёт через webroot nginx и может перестать работать:"
                warn "перенастройте сертификат через пункт «Сертификаты для gRPC»."
            fi
            if confirm "Удалить также сертификат Let's Encrypt?" n; then
                certbot delete --cert-name "$DOMAIN" --non-interactive
            fi
            if [[ -d "$SELFSTEAL_CFG_DIR" ]] && confirm "Удалить сохранённые Selfsteal-конфиги (${SELFSTEAL_CFG_DIR})?" y; then
                rm -rf "${SELFSTEAL_CFG_DIR:?}"
                REALITY_PORTS=""
            fi
            DOMAIN=""; SITE_MODE=""; SELFSTEAL_PORT=""; SITE_SOURCE=""
            save_state
            ok "Сайт удалён"
            ;;
        *) return 2 ;;
    esac
}

# ============================ RKN-GUARD ================================
# Скрипт сначала скачивается во временный файл, а не передаётся через
# «curl | bash»: так у него остаётся терминал для вопросов, а при обрыве
# загрузки не выполнится недокачанный кусок.
run_rkn_guard() {
    line
    echo -e "${BOLD}rkn-guard${NC} — сторонний скрипт: ${RKN_GUARD_URL}"
    warn "Он будет запущен от root. Запускайте, только если доверяете автору репозитория."
    line
    confirm "Запустить установку rkn-guard?" n || return 0

    local tmp
    tmp="$(mktemp -d)"
    info "Скачиваю install.sh..."
    if ! curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp/install.sh" "$RKN_GUARD_URL"; then
        err "Не удалось скачать $RKN_GUARD_URL"
        rm -rf "$tmp"; return 1
    fi
    if [[ ! -s "$tmp/install.sh" ]]; then
        err "Скачан пустой файл"
        rm -rf "$tmp"; return 1
    fi

    info "Запускаю: install.sh install"
    line
    bash "$tmp/install.sh" install </dev/tty
    local rc=$?
    line
    rm -rf "$tmp"
    if (( rc == 0 )); then
        ok "rkn-guard: установка завершена"
    else
        err "rkn-guard завершился с кодом $rc"
        return 1
    fi
}

# ============================ МЕНЮ ====================================
SERVER_INFO=""
STATUS_CACHE=""

# Строка рамки: box_row "видимый текст (ASCII)" "текст с цветами"
BOX_W=50
box_row() {
    local pad=$(( BOX_W - ${#1} ))
    (( pad < 0 )) && pad=0
    printf "  ${CYAN}│${NC}%s%*s${CYAN}│${NC}\n" "$2" "$pad" ""
}
box_edge() {
    local l="$1" r="$2" bar
    printf -v bar '%*s' "$BOX_W" ""
    echo -e "  ${CYAN}${l}${bar// /─}${r}${NC}"
}

# dot ЦВЕТ "Метка" "значение" — строка статуса с цветной точкой
dot() { echo -e "   ${1}●${NC} ${DIM}${2}${NC} ${3}"; }

status_block() {
    load_state
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        dot "$GREEN"  "Нода      " "${GREEN}работает${NC}"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        dot "$YELLOW" "Нода      " "${YELLOW}установлена, но не запущена${NC}"
    else
        dot "$DIM"    "Нода      " "${DIM}не установлена${NC}"
    fi

    if [[ -n "$DOMAIN" ]]; then
        dot "$GREEN" "Сайт      " "${DOMAIN} ${DIM}(${SITE_MODE}${SELFSTEAL_PORT:+ → 127.0.0.1:${SELFSTEAL_PORT}})${NC}"
    else
        dot "$DIM"   "Сайт      " "${DIM}нет${NC}"
    fi

    if [[ -n "$REALITY_PORTS" ]]; then
        dot "$GREEN" "Hosts     " "порты ${GREEN}${REALITY_PORTS}${NC}"
    fi

    if [[ -f "$COMPOSE_FILE" ]]; then
        if custom_core_active; then
            dot "$GREEN" "Ядро Xray " "$(host_xray_version) ${DIM}(своё)${NC}"
        else
            dot "$DIM"   "Ядро Xray " "${DIM}встроенное в образ${NC}"
        fi
        if guard_active; then
            dot "$GREEN"  "Порт ноды " "${GREEN}только для панели${NC}"
        else
            dot "$YELLOW" "Порт ноды " "${YELLOW}открыт для всех${NC} ${DIM}→ пункт 11${NC}"
        fi
        if certs_mounted; then
            dot "$GREEN" "gRPC/TLS  " "${GRPC_DOMAIN:-сертификаты проброшены}"
        else
            dot "$DIM"   "gRPC/TLS  " "${DIM}сертификаты не проброшены${NC}"
        fi
    fi
}

# ----------------------- 3D-логотип (шрифт ANSI Shadow) --------------
# Блоки █ — «лицевая» сторона с градиентом, линии ╗╔═║ — тень букв.
glyph() {   # glyph БУКВА СТРОКА -> GLYPH
    local -a g
    case "$1" in
        R) g=("██████╗ " "██╔══██╗" "██████╔╝" "██╔══██╗" "██║  ██║" "╚═╝  ╚═╝") ;;
        E) g=("███████╗" "██╔════╝" "█████╗  " "██╔══╝  " "███████╗" "╚══════╝") ;;
        M) g=("███╗   ███╗" "████╗ ████║" "██╔████╔██║" "██║╚██╔╝██║" "██║ ╚═╝ ██║" "╚═╝     ╚═╝") ;;
        N) g=("███╗   ██╗" "████╗  ██║" "██╔██╗ ██║" "██║╚██╗██║" "██║ ╚████║" "╚═╝  ╚═══╝") ;;
        A) g=(" █████╗ " "██╔══██╗" "███████║" "██╔══██║" "██║  ██║" "╚═╝  ╚═╝") ;;
        W) g=("██╗    ██╗" "██║    ██║" "██║ █╗ ██║" "██║███╗██║" "╚███╔███╔╝" " ╚══╝╚══╝ ") ;;
        V) g=("██╗   ██╗" "██║   ██║" "██║   ██║" "╚██╗ ██╔╝" " ╚████╔╝ " "  ╚═══╝  ") ;;
        O) g=(" ██████╗ " "██╔═══██╗" "██║   ██║" "██║   ██║" "╚██████╔╝" " ╚═════╝ ") ;;
        D) g=("██████╗ " "██╔══██╗" "██║  ██║" "██║  ██║" "██████╔╝" "╚═════╝ ") ;;
        *) g=("  " "  " "  " "  " "  " "  ") ;;
    esac
    GLYPH="${g[$2]}"
}

# build_banner СЛОВО -> текст логотипа с градиентом сверху вниз
build_banner() {
    local word="$1" r j i ch want cur row out=""
    local -a grad=(87 81 75 69 63 99)
    for ((r = 0; r < 6; r++)); do
        row=""
        for ((j = 0; j < ${#word}; j++)); do
            glyph "${word:j:1}" "$r"
            row+="$GLYPH"
        done
        out+="  "; cur=""
        for ((i = 0; i < ${#row}; i++)); do
            ch="${row:i:1}"
            if [[ "$ch" == " " ]]; then out+=" "; continue; fi
            if [[ "$ch" == "█" ]]; then want=$'\e[1;38;5;'"${grad[$r]}m"; else want=$'\e[38;5;239m'; fi
            [[ "$want" != "$cur" ]] && { out+="$want"; cur="$want"; }
            out+="$ch"
        done
        out+="${NC}"$'\n'
    done
    printf '%s' "$out"
}

BANNER_BIG=""; BANNER_SMALL=""
init_banners() {
    BANNER_BIG="$(build_banner REMNAWAVE)"
    BANNER_SMALL="$(build_banner NODE)"
}

main_header() {
    local c; c="$(tput cols 2>/dev/null || echo 80)"
    echo
    if [[ "${MENU_3D:-1}" == "1" ]] && (( c >= 86 )); then
        echo "$BANNER_BIG"
        echo -e "  ${C_SH}▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀${NC}"
        echo -e "  ${BOLD}N O D E   I N S T A L L E R${NC}   ${DIM}node · selfsteal · xray-core · certs${NC}"
    elif [[ "${MENU_3D:-1}" == "1" ]] && (( c >= 50 )); then
        echo "$BANNER_SMALL"
        echo -e "  ${BOLD}REMNAWAVE${NC} ${DIM}node installer${NC}"
    else
        BOX_W=$(( c - 5 )); (( BOX_W > 50 )) && BOX_W=50; (( BOX_W < 40 )) && BOX_W=40
        box_edge "╭" "╮"
        box_row "  REMNAWAVE NODE INSTALLER" "  ${BOLD}REMNAWAVE${NC} ${CYAN}${BOLD}NODE INSTALLER${NC}"
        box_row "  node | selfsteal | xray-core | certs" "  ${DIM}node | selfsteal | xray-core | certs${NC}"
        box_edge "╰" "╯"
    fi
    echo -e "  ${DIM}${SERVER_INFO}${NC}"
    echo
    echo "$STATUS_CACHE"
    echo
}

init_server_info() {
    local os="" ip
    [[ -r /etc/os-release ]] && os="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
    ip="$(get_server_ip)"
    SERVER_INFO="$(hostname) · ${ip:-?}${os:+ · $os}"
}

main() {
    check_root
    check_os
    load_state
    init_server_info
    init_banners
    local choice last="1" rc
    while true; do
        STATUS_CACHE="$(status_block)"
        MENU_DEFAULT="$last" menu_select choice full main_header \
            "---|Установка" \
            "1|📦 Чистая нода Remnawave|Docker + docker-compose.yml из панели и запуск — без лишних вопросов" \
            "2|🌐 Нода + сайт-заглушка|Нода, nginx с SSL, сертификаты и фаервол за один проход" \
            "3|🎭 Selfsteal Reality|Нода + сайт-заглушка + готовый Config Profile со случайными портами для Hosts" \
            "---|Сайт" \
            "4|🧱 Только сайт-заглушка|nginx + Let's Encrypt без установки ноды" \
            "5|🎨 Обновить / сменить сайт|Скачать свежую версию или поставить другой шаблон" \
            "---|Обслуживание" \
            "6|📜 Логи ноды|Живой вывод docker compose logs, выход — Ctrl+C" \
            "7|⏯ Запуск / остановка ноды|Запустить, остановить или перезапустить контейнер ноды" \
            "8|🔄 Обновить ноду|Скачать свежий образ remnawave/node и перезапустить" \
            "9|🧬 Ядро Xray|Поставить нужную версию Xray-core или вернуть встроенную" \
            "10|🔐 Сертификаты gRPC|Пробросить сертификаты Let's Encrypt в контейнер ноды" \
            "11|🔒 Закрыть порт ноды|API ноды доступен только IP панели — сканеры не увидят Remnawave" \
            "12|🚧 rkn-guard|Запустить сторонний установщик Flecksis/rkn-guard" \
            "---" \
            "13|❌ Удаление|Удалить ноду или сайт-заглушку" \
            "0|🚪 Выход|"
        [[ "$choice" == "0" ]] && { printf '\e[H\e[2J'; echo -e "  ${CYAN}Пока!${NC}"; exit 0; }
        last="$choice"
        action_header "$MENU_LABEL"
        rc=0
        case "$choice" in
            1)  flow_node ;;
            2)  flow_node_and_site ;;
            3)  selfsteal_menu ;;
            4)  flow_site_only ;;
            5)  update_site_files ;;
            6)  show_logs ;;
            7)  node_power_menu ;;
            8)  update_node ;;
            9)  core_menu ;;
            10) certs_menu ;;
            11) guard_menu ;;
            12) run_rkn_guard ;;
            13) uninstall_menu ;;
        esac
        rc=$?
        (( rc == 2 )) || pause      # 2 = «Назад» из подменю — сразу в главное меню
    done
}

main "$@"
