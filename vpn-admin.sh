#!/bin/bash
# ============================================================
# 🛡️ VPN Admin Panel (Enterprise Edition)
# Интерактивная консольная панель управления Hysteria2 VPN
# Поддержка: BBR, Cloudflare WARP SOCKS5, Smart ACL, sniffing,
#            Port Hopping, healthcheck, безопасные правки с автооткатом
# GitHub: https://github.com/Fulsepredict/Admin_vpn
# ============================================================

# Без "set -e": это интерактивная панель — одна неудачная команда
# не должна выкидывать пользователя из меню. Ошибки проверяем явно.
set -uo pipefail

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# === Пути и константы ===
# Переменные VPN_ADMIN_* позволяют тестам работать с временными файлами.
CONFIG="${VPN_ADMIN_CONFIG:-/etc/hysteria/config.yaml}"
CERT_FILE="${VPN_ADMIN_CERT:-/etc/hysteria/server.crt}"
BACKUP_DIR="${VPN_ADMIN_BACKUP_DIR:-/etc/hysteria/backups}"
LOG_FILE="${VPN_ADMIN_LOG:-/var/log/vpn-admin.log}"

SERVICE="hysteria-server"
WARP_SERVICE="warp-svc"
WARP_PORT=40000
LISTEN_PORT=443
HOP_PORT_START=20000
HOP_PORT_END=50000
SNIFF_TIMEOUT="2s"
MIN_HYSTERIA_VERSION="2.5.2"
SERVICE_START_WAIT_SEC=3
SERVICE_START_CHECKS=2
MAX_BACKUPS=30
PASSWORD_MIN_LEN=8
PASSWORD_MAX_LEN=64

VPN_ADMIN_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"
VPN_ADMIN_PATH="/usr/local/bin/vpn-admin"
HEALTHCHECK_PATH="/usr/local/bin/vpn-healthcheck"
HEALTHCHECK_LOG="/var/log/vpn-healthcheck.log"
HEALTHCHECK_LOG_MAX_LINES=1000

# Рекомендуемые домены для WARP. ВАЖНО: должен совпадать с WARP_DOMAINS
# в setup.sh — это проверяет tests/test_audit.py.
RECOMMENDED_WARP_DOMAINS=(
    # Instagram & Meta
    instagram.com cdninstagram.com ig.me
    facebook.com facebook.net fbcdn.net fbsbx.com meta.com
    threads.net threads.com
    # OpenAI / ChatGPT
    openai.com chatgpt.com oaistatic.com oaiusercontent.com
    # Anthropic / Claude
    anthropic.com claude.ai claude.com
    # Google, Gemini, Antigravity, ReCaptcha
    google.com googleapis.com googleusercontent.com gstatic.com recaptcha.net
    # Стриминги
    netflix.com netflix.net nflxvideo.net spotify.com
)

# ============================================================
# Вспомогательные функции
# ============================================================

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE" 2>/dev/null || true
}

header() {
    [[ -t 1 ]] && clear
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Пауза нужна только человеку у терминала; в скриптах и CI её пропускаем.
pause() {
    [[ -t 0 ]] || return 0
    echo ""
    echo -ne "  ${DIM}Нажми Enter чтобы продолжить...${NC}"
    read -r _
}

status_line() {
    printf "  %-24s %b\n" "$1" "$2"
}

ok()   { echo -e "  ${GREEN}✅ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}❌ $*${NC}"; }

# confirm "Вопрос" — да/нет. Флаг ASSUME_YES=true (опция -y) отвечает «да» сам.
ASSUME_YES=false
confirm() {
    [[ "$ASSUME_YES" == true ]] && return 0
    [[ -t 0 ]] || return 1
    local answer
    echo -ne "  $1 ${BOLD}(y/n)${NC}: "
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

get_ip() {
    local ip="" url
    for url in https://ifconfig.me https://icanhazip.com https://api.ipify.org; do
        ip=$(curl -s -4 --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
        ip=$(printf '%s' "$ip" | tr -d ' \r\n')
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
    done
    hostname -I 2>/dev/null | awk '{ print $1 }'
}

# version_ge A B — истина, если версия A >= B.
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

hysteria_version() {
    hysteria version 2>/dev/null | awk '/^Version:/ { print $2 }' | sed 's/^v//'
}

# Вывод curl сохраняем в переменную, а не передаём в grep -q: при pipefail
# grep -q может оборвать curl (SIGPIPE), и проверка ложно скажет «WARP выключен».
warp_trace() {
    curl -s -x "socks5h://127.0.0.1:${WARP_PORT}" --connect-timeout 5 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true
}

warp_is_on() {
    local trace
    trace=$(warp_trace)
    [[ "$trace" == *"warp=on"* ]]
}

# ============================================================
# Проверка ввода (никогда не доверяем тому, что ввёл пользователь)
# ============================================================

# Только [A-Za-z0-9_-]: такой пароль не ломает YAML, sed/awk и ссылку hy2://
validate_password() {
    local value="$1"
    (( ${#value} >= PASSWORD_MIN_LEN && ${#value} <= PASSWORD_MAX_LEN )) || return 1
    LC_ALL=C grep -Eqx '[A-Za-z0-9_-]+' <<< "$value"
}

# Домен вида example.com / sub.example.co.uk (только латиница, цифры, дефис)
validate_domain() {
    local value="$1"
    (( ${#value} >= 4 && ${#value} <= 253 )) || return 1
    LC_ALL=C grep -Eqx '([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}' <<< "$value"
}

# ============================================================
# Работа с конфигом. Все функции получают путь к файлу первым
# аргументом и меняют его на месте — так их легко тестировать и
# безопасно применять через apply_config_change (бэкап + автооткат).
# ============================================================

# Перезаписать файл содержимым временного, сохранив владельца и права.
replace_file_content() {
    local file="$1" tmp="$2"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Пароль из секции auth: (а не первая попавшаяся строка "password:").
get_auth_password() {
    local file="$1"
    awk '
        /^[^[:space:]#]/ { in_auth = ($0 ~ /^auth:[[:space:]]*$/); next }
        in_auth && /^[[:space:]]+password:/ {
            sub(/^[[:space:]]+password:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            gsub(/^["\047]|["\047]$/, "")
            print
            exit
        }
    ' "$file"
}

# Меняет пароль ТОЛЬКО в секции auth:, сохраняя отступ.
# Раньше sed менял все строки "password:" (включая будущие obfs/socks5).
set_auth_password() {
    local file="$1" new_password="$2" tmp
    validate_password "$new_password" || return 2
    tmp=$(mktemp)
    if ! awk -v pw="$new_password" '
        /^[^[:space:]#]/ { in_auth = ($0 ~ /^auth:[[:space:]]*$/) }
        in_auth && !done && /^[[:space:]]+password:/ {
            match($0, /^[[:space:]]+/)
            print substr($0, 1, RLENGTH) "password: " pw
            done = 1
            next
        }
        { print }
        END { if (!done) exit 3 }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 3
    fi
    replace_file_content "$file" "$tmp"
}

# Блок sniffing. ВАЖНО: идентичен sniff_block в setup.sh — тест сверяет.
sniff_block() {
    cat <<EOF
# Sniffing: сервер достаёт имя сайта из TLS SNI / HTTP Host / QUIC.
# Без него клиенты в TUN-режиме присылают только IP, и правила
# warp_proxy(suffix:...) в ACL не срабатывают.
sniff:
  enable: true
  timeout: ${SNIFF_TIMEOUT}
  rewriteDomain: false
  tcpPorts: 80,443
  udpPorts: 443
EOF
}

config_has_sniff() {
    grep -Eq '^sniff:' "$1"
}

sniff_is_enabled() {
    awk '
        /^[^[:space:]#]/ { in_sniff = ($0 ~ /^sniff:/) }
        in_sniff && /^[[:space:]]+enable:[[:space:]]*true/ { found = 1 }
        END { exit !found }
    ' "$1"
}

add_sniff_block() {
    local file="$1"
    config_has_sniff "$file" && return 0
    # Если файл не заканчивается переводом строки — добавим его
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        echo "" >> "$file"
    fi
    { echo ""; sniff_block; } >> "$file"
}

# Блок sniff: есть, но выключен (enable: false) — включаем, остальное не трогаем.
enable_sniff() {
    local file="$1" tmp
    tmp=$(mktemp)
    awk '
        /^[^[:space:]#]/ { in_sniff = ($0 ~ /^sniff:/) }
        in_sniff && /^[[:space:]]+enable:/ {
            match($0, /^[[:space:]]+/)
            print substr($0, 1, RLENGTH) "enable: true"
            next
        }
        { print }
    ' "$file" > "$tmp"
    replace_file_content "$file" "$tmp"
    sniff_is_enabled "$file" && return 0
    # Строки enable не было вовсе (по умолчанию sniffing выключен) — добавим её
    tmp=$(mktemp)
    awk '
        /^sniff:[[:space:]]*$/ { print; print "  enable: true"; next }
        { print }
    ' "$file" > "$tmp"
    replace_file_content "$file" "$tmp"
}

config_has_acl() {
    grep -Eq '^acl:' "$1" && grep -Eq '^[[:space:]]+- direct\(all\)[[:space:]]*$' "$1"
}

acl_list_domains() {
    grep -oE 'warp_proxy\(suffix:[^)]+\)' "$1" | sed -E 's/^warp_proxy\(suffix:(.*)\)$/\1/'
}

acl_has_domain() {
    grep -Fq "warp_proxy(suffix:${2})" "$1"
}

# Добавляет домен перед "- direct(all)" (порядок правил в ACL важен:
# первое совпавшее правило выигрывает, direct(all) должен быть последним).
acl_add_domain() {
    local file="$1" domain="$2" tmp
    validate_domain "$domain" || return 2
    acl_has_domain "$file" "$domain" && return 0
    tmp=$(mktemp)
    if ! awk -v rule="warp_proxy(suffix:${domain})" '
        !done && /^[[:space:]]+- direct\(all\)[[:space:]]*$/ {
            match($0, /^[[:space:]]+/)
            print substr($0, 1, RLENGTH) "- " rule
            done = 1
        }
        { print }
        END { if (!done) exit 3 }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 3
    fi
    replace_file_content "$file" "$tmp"
}

acl_remove_domain() {
    local file="$1" domain="$2" tmp
    validate_domain "$domain" || return 2
    acl_has_domain "$file" "$domain" || return 3
    tmp=$(mktemp)
    awk -v rule="- warp_proxy(suffix:${domain})" '
        { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
        line == rule { next }
        { print }
    ' "$file" > "$tmp"
    replace_file_content "$file" "$tmp"
}

# Убирает повторы правил и комментариев внутри секции acl:
acl_dedupe() {
    local file="$1" tmp
    tmp=$(mktemp)
    awk '
        /^[^[:space:]#]/ { in_acl = ($0 ~ /^acl:/) }
        in_acl {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^(- |#)/ && seen[line]++) next
        }
        { print }
    ' "$file" > "$tmp"
    replace_file_content "$file" "$tmp"
}

# Приводит конфиг к актуальному виду: sniffing + рекомендуемые домены + без дублей.
# Печатает, что именно изменилось.
upgrade_config_file() {
    local file="$1" domain
    if ! config_has_acl "$file"; then
        echo "no-acl"
        return 4
    fi
    if ! config_has_sniff "$file"; then
        add_sniff_block "$file"
        echo "sniff-added"
    elif ! sniff_is_enabled "$file"; then
        enable_sniff "$file"
        echo "sniff-enabled"
    fi
    for domain in "${RECOMMENDED_WARP_DOMAINS[@]}"; do
        if ! acl_has_domain "$file" "$domain"; then
            acl_add_domain "$file" "$domain" || return 1
            echo "domain-added ${domain}"
        fi
    done
    local before after
    before=$(wc -l < "$file")
    acl_dedupe "$file"
    after=$(wc -l < "$file")
    if (( before != after )); then
        echo "duplicates-removed $(( before - after ))"
    fi
    return 0
}

# SHA-256 отпечаток сертификата (hex, без двоеточий) для параметра pinSHA256.
cert_pin() {
    local cert="${1:-$CERT_FILE}" fingerprint
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null) || return 1
    fingerprint="${fingerprint#*=}"
    fingerprint="${fingerprint//:/}"
    printf '%s\n' "${fingerprint,,}"
}

# Ссылки для клиентов: "метка<TAB>ссылка". ВАЖНО: идентична build_links в setup.sh.
build_links() {
    local ip="$1" password="$2" pin="$3"
    local base="insecure=1&alpn=h3"
    local pinned="$base"
    [[ -n "$pin" ]] && pinned="${base}&pinSHA256=${pin}"
    local ports="${LISTEN_PORT},${HOP_PORT_START}-${HOP_PORT_END}"

    printf 'porthop\thy2://%s@%s:%s?%s&mport=%s#Hysteria2-PortHop\n' "$password" "$ip" "$LISTEN_PORT" "$pinned" "$ports"
    printf 'standard\thy2://%s@%s:%s?%s#Hysteria2\n' "$password" "$ip" "$LISTEN_PORT" "$pinned"
    printf 'nopin\thy2://%s@%s:%s?%s&mport=%s#Hysteria2-PortHop-NoPin\n' "$password" "$ip" "$LISTEN_PORT" "$base" "$ports"
    printf 'official\thysteria2://%s@%s:%s/?%s#Hysteria2-Official\n' "$password" "$ip" "$ports" "$pinned"
}

# ============================================================
# Бэкапы и безопасное применение изменений
# ============================================================

backup_config_file() {
    local label="$1" target
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    target="${BACKUP_DIR}/config_${label}_$(date +%Y%m%d_%H%M%S)_$$.yaml"
    cp -p "$CONFIG" "$target" || return 1
    chmod 600 "$target" 2>/dev/null || true
    # Храним только последние MAX_BACKUPS бэкапов
    local old
    while IFS= read -r old; do
        rm -f "$old"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'config_*.yaml' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +$(( MAX_BACKUPS + 1 )) | cut -d' ' -f2-)
    printf '%s\n' "$target"
}

restart_and_verify() {
    systemctl restart "$SERVICE" >/dev/null 2>&1 || return 1
    local i
    for (( i = 0; i < SERVICE_START_CHECKS; i++ )); do
        sleep "$SERVICE_START_WAIT_SEC"
        systemctl is-active --quiet "$SERVICE" || return 1
    done
    return 0
}

# apply_config_change ОПИСАНИЕ ФУНКЦИЯ [АРГУМЕНТЫ...]
# Правит копию конфига, подменяет оригинал, перезапускает Hysteria.
# Если служба не поднялась — автоматически возвращает бэкап.
apply_config_change() {
    local description="$1" edit_function="$2"
    shift 2
    if [[ ! -f "$CONFIG" ]]; then
        fail "Конфиг не найден: ${CONFIG}"
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    cp "$CONFIG" "$tmp"
    local status=0
    # Вывод функции-правки (например, список изменений) здесь не нужен
    "$edit_function" "$tmp" "$@" >/dev/null || status=$?
    if (( status != 0 )); then
        rm -f "$tmp"
        return "$status"
    fi
    if cmp -s "$tmp" "$CONFIG"; then
        rm -f "$tmp"
        echo -e "  ${DIM}Изменений нет — конфиг уже в нужном состоянии.${NC}"
        return 0
    fi

    local backup
    if ! backup=$(backup_config_file "before_${description}"); then
        rm -f "$tmp"
        fail "Не удалось создать бэкап — изменения не применены"
        return 1
    fi
    replace_file_content "$CONFIG" "$tmp"

    if restart_and_verify; then
        log_action "CONFIG_CHANGED: ${description} (backup: ${backup})"
        return 0
    fi

    cat "$backup" > "$CONFIG"
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    fail "Hysteria не запустилась с новым конфигом — выполнен автооткат"
    echo -e "  ${DIM}Бэкап: ${backup}. Журнал: journalctl -u ${SERVICE} -n 30${NC}"
    log_action "CONFIG_ROLLBACK: ${description}"
    return 1
}

# ============================================================
# Healthcheck (cron каждые 5 минут)
# ============================================================

healthcheck_script() {
    sed -e "s|__WARP_PORT__|${WARP_PORT}|g" \
        -e "s|__LOG__|${HEALTHCHECK_LOG}|g" \
        -e "s|__MAX_LINES__|${HEALTHCHECK_LOG_MAX_LINES}|g" \
        -e "s|__SERVICE__|${SERVICE}|g" \
        -e "s|__WARP_SERVICE__|${WARP_SERVICE}|g" <<'EOF'
#!/bin/bash
# vpn-healthcheck — ставится командой "vpn-admin install-healthcheck".
# Проверяет не только то, что службы запущены, но и что туннель WARP
# реально работает (warp=on) — иначе сайты из ACL молча перестают открываться.
set -uo pipefail

LOG="__LOG__"
MAX_LINES=__MAX_LINES__
WARP_PORT=__WARP_PORT__

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOG"; }

warp_ok() {
    local trace
    trace=$(curl -s -x "socks5h://127.0.0.1:${WARP_PORT}" --connect-timeout 5 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    [[ "$trace" == *"warp=on"* ]]
}

if ! systemctl is-active --quiet __SERVICE__; then
    systemctl restart __SERVICE__
    log "Hysteria2 was down - restarted"
fi

if command -v warp-cli >/dev/null 2>&1 && ! warp_ok; then
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
    sleep 5
    if warp_ok; then
        log "WARP reconnected"
    else
        systemctl restart __WARP_SERVICE__
        sleep 5
        warp-cli --accept-tos connect >/dev/null 2>&1 || true
        sleep 5
        if warp_ok; then
            log "WARP recovered after warp-svc restart"
        else
            log "WARP is DOWN (warp=off): sites from ACL are unavailable"
        fi
    fi
fi

# Ротация лога, чтобы он не рос бесконечно
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > MAX_LINES )); then
    tail -n "$MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
exit 0
EOF
}

install_healthcheck() {
    local tmp
    tmp=$(mktemp)
    healthcheck_script > "$tmp"
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        fail "Скрипт healthcheck не прошёл проверку синтаксиса"
        return 1
    fi
    install -m 755 -o root -g root "$tmp" "$HEALTHCHECK_PATH" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    # Идемпотентно: удаляем старую строку и добавляем одну актуальную
    ( crontab -l 2>/dev/null | grep -v 'vpn-healthcheck'; echo "*/5 * * * * ${HEALTHCHECK_PATH}" ) | crontab - || return 1
    log_action "HEALTHCHECK_INSTALLED"
    ok "Healthcheck установлен: ${HEALTHCHECK_PATH} (cron каждые 5 минут)"
}

# ============================================================
# Команды меню
# ============================================================

# 1. Статус сервера
show_status() {
    header "📊 Статус Hysteria 2 VPN"

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        local pid
        pid=$(systemctl show --property MainPID --value "$SERVICE" 2>/dev/null || echo "N/A")
        status_line "Hysteria 2:" "${GREEN}● РАБОТАЕТ${NC} (PID: ${pid}, v$(hysteria_version))"
    else
        status_line "Hysteria 2:" "${RED}● ОСТАНОВЛЕН${NC}"
    fi

    if systemctl is-active --quiet "$WARP_SERVICE" 2>/dev/null; then
        if warp_is_on; then
            status_line "Cloudflare WARP:" "${GREEN}● АКТИВЕН${NC} (SOCKS5 127.0.0.1:${WARP_PORT}, warp=on)"
        else
            status_line "Cloudflare WARP:" "${RED}● ТУННЕЛЬ НЕ РАБОТАЕТ${NC} (warp=off — сайты из ACL недоступны)"
        fi
    else
        status_line "Cloudflare WARP:" "${YELLOW}○ НЕ ИСПОЛЬЗУЕТСЯ${NC} (прямое подключение)"
    fi

    if [[ -f "$CONFIG" ]]; then
        if config_has_acl "$CONFIG"; then
            status_line "Smart ACL:" "${GREEN}● $(acl_list_domains "$CONFIG" | wc -l) доменов через WARP${NC}"
            if sniff_is_enabled "$CONFIG"; then
                status_line "Sniffing:" "${GREEN}● ВКЛЮЧЁН${NC} (ACL работает и для TUN-клиентов)"
            else
                status_line "Sniffing:" "${YELLOW}● ВЫКЛЮЧЕН${NC} — выполни: vpn-admin upgrade"
            fi
        else
            status_line "Smart ACL:" "${YELLOW}○ НЕ НАСТРОЕН${NC}"
        fi
    fi

    local bbr_status
    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$bbr_status" == "bbr" ]]; then
        status_line "Google BBR:" "${GREEN}● ВКЛЮЧЕН${NC}"
    else
        status_line "Google BBR:" "${YELLOW}● ${bbr_status}${NC}"
    fi

    local nat_rules
    nat_rules=$(iptables -t nat -S PREROUTING 2>/dev/null || true)
    if [[ "$nat_rules" == *"${HOP_PORT_START}:${HOP_PORT_END}"* ]]; then
        status_line "Port Hopping:" "${GREEN}● АКТИВЕН${NC} (${HOP_PORT_START}-${HOP_PORT_END} UDP -> ${LISTEN_PORT})"
    else
        status_line "Port Hopping:" "${YELLOW}● НЕ НАСТРОЕН${NC}"
    fi

    echo ""
    local cpu_usage
    cpu_usage=$(top -bn1 2>/dev/null | awk '/Cpu\(s\)/ { print $2 + $4; exit }')
    status_line "Загрузка CPU:" "${cpu_usage:-0}%"

    local mem_line
    mem_line=$(free -h 2>/dev/null | awk '/^Mem:/ { print $3 " / " $2 }')
    status_line "Оперативная память:" "${mem_line:-N/A}"

    local disk_line
    disk_line=$(df -h / 2>/dev/null | awk 'NR == 2 { print $3 " / " $2 " (" $5 ")" }')
    status_line "Диск (/):" "${disk_line:-N/A}"

    pause
}

# 2. Логи
show_logs() {
    header "📋 Логи Hysteria 2"
    echo -e "  ${DIM}(последние 40 строк)${NC}\n"
    journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null || echo "Логи недоступны"
    pause
}

# 3. Смена пароля. Аргумент — новый пароль (для неинтерактивного режима).
change_password() {
    header "🔑 Смена пароля VPN"

    local new_pass="${1:-}"
    if [[ -z "$new_pass" ]]; then
        if confirm "Сгенерировать случайный надёжный пароль?"; then
            local raw
            raw=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
            new_pass="${raw:0:24}"
        elif [[ -t 0 ]]; then
            echo -ne "  Новый пароль (${PASSWORD_MIN_LEN}-${PASSWORD_MAX_LEN} символов: латиница, цифры, _ и -): "
            read -r new_pass
        fi
    fi

    if ! validate_password "$new_pass"; then
        fail "Недопустимый пароль: нужно ${PASSWORD_MIN_LEN}-${PASSWORD_MAX_LEN} символов из A-Z, a-z, 0-9, _ и -"
        pause
        return 2
    fi

    if apply_config_change "password" set_auth_password "$new_pass"; then
        echo ""
        ok "Пароль изменён: ${BOLD}${new_pass}${NC}"
        warn "Старые ссылки больше не работают — обнови их в клиентах (vpn-admin link)"
        log_action "PASSWORD_CHANGED"
        pause
        return 0
    fi
    pause
    return 1
}

# 4. Ссылки
show_link() {
    header "🔗 Ссылки для подключения"

    if [[ ! -f "$CONFIG" ]]; then
        fail "Конфиг не найден: ${CONFIG}"
        pause
        return 1
    fi

    local ip pass pin
    ip=$(get_ip)
    pass=$(get_auth_password "$CONFIG")
    pin=$(cert_pin "$CERT_FILE" || true)

    local label link
    while IFS=$'\t' read -r label link; do
        case "$label" in
            porthop)  echo -e "  ${BOLD}1. Рекомендуемая (port hopping + закреплённый сертификат):${NC}" ;;
            standard) echo -e "  ${BOLD}2. Стандартная (порт ${LISTEN_PORT}):${NC}" ;;
            nopin)    echo -e "  ${BOLD}3. Если клиент не подключается по ссылкам 1–2 (без pinSHA256):${NC}" ;;
            official) echo -e "  ${BOLD}4. Официальный формат Hysteria (порты в адресе):${NC}" ;;
            *)        echo -e "  ${BOLD}${label}:${NC}" ;;
        esac
        echo -e "  ${CYAN}${link}${NC}\n"
    done < <(build_links "$ip" "$pass" "$pin")

    if [[ -n "$pin" ]]; then
        echo -e "  ${DIM}pinSHA256 — клиент примет только сертификат этого сервера (защита от подмены).${NC}"
    fi
    echo -e "  ${DIM}Клиенты: NekoBox, Hiddify, v2rayN, Streisand, Shadowrocket${NC}"
    pause
}

# 5. Тест обхода антифрода
check_site_via_warp() {
    local name="$1" url="$2" code
    code=$(curl -s -o /dev/null -w "%{http_code}" -x "socks5h://127.0.0.1:${WARP_PORT}" \
        --connect-timeout 6 --max-time 15 "$url" 2>/dev/null || true)
    case "$code" in
        2??|3??) printf "  %-26s ${GREEN}✅ Доступен (HTTP %s)${NC}\n" "$name" "$code" ;;
        403)     printf "  %-26s ${YELLOW}⚠ HTTP 403 (антибот-заглушка, в браузере обычно открывается)${NC}\n" "$name" ;;
        *)       printf "  %-26s ${RED}❌ Нет ответа (HTTP %s)${NC}\n" "$name" "${code:-000}" ;;
    esac
}

test_ai() {
    header "🧪 Тест обхода антифрода (ИИ & Meta)"

    local trace
    trace=$(warp_trace)
    if [[ "$trace" != *"warp=on"* ]]; then
        warn "Cloudflare WARP не активен на 127.0.0.1:${WARP_PORT} — трафик идёт напрямую с IP сервера"
        pause
        return 1
    fi

    local warp_ip warp_loc
    warp_ip=$(awk -F= '$1 == "ip" { print $2 }' <<< "$trace")
    warp_loc=$(awk -F= '$1 == "loc" { print $2 }' <<< "$trace")
    ok "Cloudflare WARP работает. Выходной IP: ${warp_ip} (страна: ${warp_loc})"
    echo ""

    check_site_via_warp "ChatGPT (chatgpt.com)" "https://chatgpt.com"
    check_site_via_warp "Claude (claude.ai)" "https://claude.ai"
    check_site_via_warp "Instagram" "https://www.instagram.com"
    check_site_via_warp "Gemini API (googleapis)" "https://generativelanguage.googleapis.com"
    echo ""

    if [[ -f "$CONFIG" ]]; then
        if sniff_is_enabled "$CONFIG"; then
            ok "Sniffing включён — ACL работает и для клиентов в TUN-режиме"
        else
            warn "Sniffing выключен — клиенты в TUN-режиме обходят WARP. Исправить: vpn-admin upgrade"
        fi
        local domain missing=""
        for domain in "${RECOMMENDED_WARP_DOMAINS[@]}"; do
            acl_has_domain "$CONFIG" "$domain" || missing+=" ${domain}"
        done
        if [[ -n "$missing" ]]; then
            warn "В ACL нет рекомендуемых доменов:${missing}. Исправить: vpn-admin upgrade"
        else
            ok "Все рекомендуемые домены есть в ACL"
        fi
    fi
    pause
}

# 6. Перезапуск
restart_server() {
    header "🔄 Перезапуск VPN и WARP"
    systemctl restart "$WARP_SERVICE" 2>/dev/null || true
    if restart_and_verify; then
        ok "Hysteria 2 и WARP перезапущены"
    else
        fail "Hysteria 2 не запустилась. Журнал: journalctl -u ${SERVICE} -n 30"
    fi
    log_action "SERVICES_RESTARTED"
    pause
}

# 7. Стоп / Старт
toggle_server() {
    header "⏯️ Стоп / Старт Hysteria 2"
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        if confirm "Остановить VPN?"; then
            systemctl stop "$SERVICE" 2>/dev/null || true
            echo -e "\n  ${RED}⏹ Сервер остановлен.${NC}"
            log_action "SERVER_STOPPED"
        fi
    else
        systemctl start "$SERVICE" 2>/dev/null || true
        echo -e "\n  ${GREEN}▶ Сервер запущен!${NC}"
        log_action "SERVER_STARTED"
    fi
    pause
}

# 8. Обновить Hysteria2
update_hysteria() {
    header "⬆️ Обновление Hysteria 2"
    echo -e "  ${DIM}Текущая версия:${NC} $(hysteria_version)"
    echo ""
    if ! confirm "Начать обновление до последней версии?"; then
        echo -e "  ${DIM}Отменено.${NC}"
        pause
        return 0
    fi

    local installer
    installer=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 https://get.hy2.sh/ -o "$installer"; then
        rm -f "$installer"
        fail "Не удалось скачать установщик"
        pause
        return 1
    fi
    bash "$installer"
    rm -f "$installer"
    if restart_and_verify; then
        ok "Hysteria 2 обновлена до $(hysteria_version) и перезапущена"
    else
        fail "После обновления Hysteria не запустилась. Журнал: journalctl -u ${SERVICE} -n 30"
    fi
    log_action "HYSTERIA_UPDATED"
    pause
}

# 9. Бэкап
backup_config() {
    header "💾 Бэкап конфигурации"
    local backup_file
    if ! backup_file=$(backup_config_file "manual"); then
        fail "Не удалось создать бэкап"
        pause
        return 1
    fi
    ok "Бэкап сохранён: ${backup_file}"
    echo ""
    echo -e "  ${BOLD}Последние бэкапы:${NC}"
    find "$BACKUP_DIR" -maxdepth 1 -name 'config_*.yaml' -type f -printf '%T@ %f\n' 2>/dev/null \
        | sort -rn | head -n 10 | cut -d' ' -f2- | sed 's/^/    /'
    log_action "BACKUP_CREATED: ${backup_file}"
    pause
}

# 10. Системная информация
system_info() {
    header "🖥️ Информация о системе"
    status_line "ОС:" "$(lsb_release -ds 2>/dev/null || awk -F'"' '/^PRETTY_NAME/ { print $2 }' /etc/os-release)"
    status_line "Ядро Linux:" "$(uname -r)"
    status_line "TCP Congestion:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
    status_line "IPv4:" "$(get_ip)"
    local ipv6
    ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { print $2; exit }')
    status_line "IPv6:" "${ipv6:-нет}"
    echo ""
    echo -e "  ${BOLD}Файрвол (UFW):${NC}"
    ufw status 2>/dev/null | grep -v '^$' | head -n 15 | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}Fail2ban:${NC}"
    fail2ban-client status sshd 2>/dev/null | sed 's/^/    /'
    pause
}

# 11. Миграция
migration() {
    header "🚚 Миграция / Смена IP"
    echo -e "  ${BOLD}Текущий IP:${NC} ${CYAN}$(get_ip)${NC}\n"
    echo -e "  ${BOLD}Как развернуть VPN на новом сервере:${NC}\n"
    echo -e "  ${DIM}1.${NC} Купи новый VPS (Ubuntu 22.04 / 24.04 или Debian 12)"
    echo -e "  ${DIM}2.${NC} Подключись по SSH"
    echo -e "  ${DIM}3.${NC} Вставь одну команду:\n"
    echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/setup.sh)${NC}\n"
    echo -e "  ${DIM}4.${NC} Скопируй полученную ссылку в клиент"
    pause
}

# 12. Домены WARP
list_domains() {
    header "🌐 Домены, которые идут через WARP"
    if [[ ! -f "$CONFIG" ]] || ! config_has_acl "$CONFIG"; then
        warn "Smart ACL не настроен (WARP не был установлен)"
        pause
        return 1
    fi
    acl_list_domains "$CONFIG" | sed 's/^/    • /'
    echo ""
    echo -e "  ${DIM}Всего: $(acl_list_domains "$CONFIG" | wc -l). Остальной трафик идёт напрямую.${NC}"
    pause
}

add_domain() {
    header "➕ Добавить домен в WARP"
    local domain="${1:-}"
    if [[ -z "$domain" && -t 0 ]]; then
        echo -ne "  Домен (например, tiktok.com): "
        read -r domain
    fi
    domain="${domain,,}"
    if ! validate_domain "$domain"; then
        fail "Некорректный домен: '${domain}'. Пример: example.com"
        pause
        return 2
    fi
    if [[ ! -f "$CONFIG" ]] || ! config_has_acl "$CONFIG"; then
        fail "Smart ACL не настроен — добавить домен некуда"
        pause
        return 1
    fi
    if acl_has_domain "$CONFIG" "$domain"; then
        ok "${domain} уже идёт через WARP"
        pause
        return 0
    fi
    if apply_config_change "add_domain" acl_add_domain "$domain"; then
        ok "${domain} (и все его поддомены) теперь идёт через WARP"
        log_action "DOMAIN_ADDED: ${domain}"
        pause
        return 0
    fi
    pause
    return 1
}

remove_domain() {
    header "➖ Убрать домен из WARP"
    local domain="${1:-}"
    if [[ -z "$domain" && -t 0 ]]; then
        echo -ne "  Домен: "
        read -r domain
    fi
    domain="${domain,,}"
    if ! validate_domain "$domain"; then
        fail "Некорректный домен: '${domain}'"
        pause
        return 2
    fi
    if [[ ! -f "$CONFIG" ]] || ! acl_has_domain "$CONFIG" "$domain"; then
        warn "${domain} нет в списке WARP"
        pause
        return 3
    fi
    if apply_config_change "remove_domain" acl_remove_domain "$domain"; then
        ok "${domain} теперь идёт напрямую"
        log_action "DOMAIN_REMOVED: ${domain}"
        pause
        return 0
    fi
    pause
    return 1
}

domains_menu() {
    while true; do
        header "🌐 Домены WARP"
        echo -e "   ${BOLD}1${NC} │ Показать список"
        echo -e "   ${BOLD}2${NC} │ Добавить домен"
        echo -e "   ${BOLD}3${NC} │ Убрать домен"
        echo -e "   ${BOLD}0${NC} │ Назад"
        echo ""
        echo -ne "  ${BOLD}Выбери пункт: ${NC}"
        local choice
        read -r choice || return 0
        case "$choice" in
            1) list_domains ;;
            2) add_domain ;;
            3) remove_domain ;;
            0) return 0 ;;
            *) echo -e "\n  ${RED}Неверный выбор${NC}"; sleep 1 ;;
        esac
    done
}

# 13. Обновление конфига до актуальной версии
upgrade_config() {
    header "🛠️ Обновление конфига (sniffing + домены + чистка дублей)"

    if [[ ! -f "$CONFIG" ]]; then
        fail "Конфиг не найден: ${CONFIG}"
        pause
        return 1
    fi

    local version
    version=$(hysteria_version)
    if [[ -n "$version" ]] && ! version_ge "$version" "$MIN_HYSTERIA_VERSION"; then
        fail "Hysteria ${version} не поддерживает sniffing (нужна ${MIN_HYSTERIA_VERSION}+). Сначала: vpn-admin update"
        pause
        return 1
    fi

    # Пробный прогон на копии — показываем, что изменится
    local preview changes status=0
    preview=$(mktemp)
    cp "$CONFIG" "$preview"
    changes=$(upgrade_config_file "$preview") || status=$?
    rm -f "$preview"

    if (( status == 4 )); then
        warn "Smart ACL не настроен (WARP не установлен) — обновлять нечего. Переустанови через setup.sh"
        pause
        return 1
    elif (( status != 0 )); then
        fail "Не удалось подготовить изменения"
        pause
        return 1
    fi

    if [[ -z "$changes" ]]; then
        ok "Конфиг уже актуален: sniffing включён, все домены на месте, дублей нет"
        pause
        return 0
    fi

    echo -e "  ${BOLD}Будут внесены изменения:${NC}"
    local kind value
    while read -r kind value; do
        case "$kind" in
            sniff-added)        echo "    • включить sniffing (ACL заработает для TUN-клиентов)" ;;
            sniff-enabled)      echo "    • включить выключенный sniffing (enable: false → true)" ;;
            domain-added)       echo "    • добавить в WARP: ${value}" ;;
            duplicates-removed) echo "    • удалить дубли в ACL: ${value} строк" ;;
            *)                  echo "    • ${kind} ${value}" ;;
        esac
    done <<< "$changes"
    echo ""

    if ! confirm "Применить? Перед изменением будет создан бэкап, при сбое — автооткат."; then
        echo -e "  ${DIM}Отменено.${NC}"
        pause
        return 0
    fi

    if apply_config_change "upgrade" upgrade_config_file; then
        ok "Конфиг обновлён, Hysteria перезапущена"
        log_action "CONFIG_UPGRADED"
    else
        pause
        return 1
    fi

    # Старые установки ставили healthcheck без проверки warp=on — обновим его
    install_healthcheck || warn "Не удалось обновить healthcheck"
    pause
}

# 14. Самообновление панели
self_update() {
    header "⬆️ Обновление vpn-admin"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 "$VPN_ADMIN_URL" -o "$tmp"; then
        rm -f "$tmp"
        fail "Не удалось скачать ${VPN_ADMIN_URL}"
        pause
        return 1
    fi
    sed -i 's/\r$//' "$tmp"
    if [[ "$(head -n 1 "$tmp")" != "#!/bin/bash" ]] || ! bash -n "$tmp"; then
        rm -f "$tmp"
        fail "Скачанный файл повреждён — обновление отменено"
        pause
        return 1
    fi
    install -m 755 -o root -g root "$tmp" "$VPN_ADMIN_PATH"
    rm -f "$tmp"
    "$VPN_ADMIN_PATH" install-healthcheck || warn "Не удалось обновить healthcheck"
    ok "vpn-admin обновлён. Запусти его заново."
    log_action "SELF_UPDATED"
    exit 0
}

usage() {
    cat <<'EOF'
Использование: vpn-admin [команда]

  (без команды)          интерактивное меню
  status                 статус Hysteria, WARP, sniffing, ACL
  logs                   последние строки журнала
  link                   ссылки для клиентов
  password [НОВЫЙ]       сменить пароль (без аргумента — интерактивно)
  test-ai                проверить ChatGPT / Claude / Instagram через WARP
  restart                перезапустить Hysteria и WARP
  toggle                 остановить / запустить Hysteria
  update                 обновить Hysteria до последней версии
  backup                 бэкап конфига
  info                   информация о системе
  migrate                как переехать на новый сервер
  domains                список доменов через WARP
  add-domain ДОМЕН       отправить домен через WARP
  remove-domain ДОМЕН    убрать домен из WARP
  upgrade [-y]           включить sniffing, добавить домены, убрать дубли
  self-update            обновить vpn-admin с GitHub
  install-healthcheck    (пере)установить healthcheck в cron
EOF
}

run_cli() {
    local command="$1"
    shift
    case "$command" in
        status)              show_status ;;
        logs)                show_logs ;;
        password)            change_password "${1:-}" ;;
        link)                show_link ;;
        test-ai)             test_ai ;;
        restart)             restart_server ;;
        toggle)              toggle_server ;;
        update)              update_hysteria ;;
        backup)              backup_config ;;
        info)                system_info ;;
        migrate)             migration ;;
        domains)             list_domains ;;
        add-domain)          add_domain "${1:-}" ;;
        remove-domain)       remove_domain "${1:-}" ;;
        upgrade)
            [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && ASSUME_YES=true
            upgrade_config ;;
        self-update)         self_update ;;
        install-healthcheck) install_healthcheck ;;
        help|-h|--help)      usage ;;
        *)                   usage; return 2 ;;
    esac
}

interactive_menu() {
    local choice local_status
    while true; do
        [[ -t 1 ]] && clear
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            local_status="${GREEN}● РАБОТАЕТ${NC}"
        else
            local_status="${RED}● ОСТАНОВЛЕН${NC}"
        fi

        echo ""
        echo -e "${CYAN}  ═══════════════════════════════════════════════${NC}"
        echo -e "   ${BOLD}🛡️  VPN Admin Panel (Enterprise)${NC}   ${local_status}"
        echo -e "   ${DIM}Hysteria2 + WARP + BBR + Sniffing${NC}"
        echo -e "${CYAN}  ═══════════════════════════════════════════════${NC}"
        echo ""
        echo -e "    ${BOLD}1${NC} │ 📊  Статус сервера и WARP"
        echo -e "    ${BOLD}2${NC} │ 📋  Логи Hysteria 2"
        echo -e "    ${BOLD}3${NC} │ 🔑  Сменить пароль"
        echo -e "    ${BOLD}4${NC} │ 🔗  Показать ссылки"
        echo -e "    ${BOLD}5${NC} │ 🧪  Тест обхода антифрода (ИИ & Meta)"
        echo -e "    ${BOLD}6${NC} │ 🔄  Перезапуск сервисов"
        echo -e "    ${BOLD}7${NC} │ ⏯️   Стоп / Старт"
        echo -e "    ${BOLD}8${NC} │ ⬆️   Обновить Hysteria 2"
        echo -e "    ${BOLD}9${NC} │ 💾  Бэкап конфига"
        echo -e "   ${BOLD}10${NC} │ 🖥️   Инфо о системе и BBR"
        echo -e "   ${BOLD}11${NC} │ 🚚  Миграция / Справка"
        echo -e "   ${BOLD}12${NC} │ 🌐  Домены WARP (список / добавить / убрать)"
        echo -e "   ${BOLD}13${NC} │ 🛠️   Обновить конфиг (sniffing + домены)"
        echo -e "   ${BOLD}14${NC} │ ⬆️   Обновить vpn-admin"
        echo ""
        echo -e "    ${RED}0${NC} │ 🚪  Выход"
        echo ""
        echo -ne "  ${BOLD}Выбери пункт [0-14]: ${NC}"
        read -r choice || exit 0

        case "$choice" in
            1) show_status ;;
            2) show_logs ;;
            3) change_password ;;
            4) show_link ;;
            5) test_ai ;;
            6) restart_server ;;
            7) toggle_server ;;
            8) update_hysteria ;;
            9) backup_config ;;
            10) system_info ;;
            11) migration ;;
            12) domains_menu ;;
            13) upgrade_config ;;
            14) self_update ;;
            0) echo -e "\n  ${DIM}👋 До встречи!${NC}\n"; exit 0 ;;
            *) echo -e "\n  ${RED}Неверный выбор. Попробуй ещё раз.${NC}"; sleep 1 ;;
        esac
    done
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: запусти от root (sudo vpn-admin)${NC}"
        exit 1
    fi
    if [[ $# -gt 0 ]]; then
        run_cli "$@"
        exit $?
    fi
    interactive_menu
}

# main запускается только при прямом вызове, но не при source (для тестов)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
