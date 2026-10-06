#!/bin/bash
# ============================================================
# 🚀 VPN Server Quick Setup (Enterprise Edition)
# Автоматическая установка Hysteria2 VPN:
# - BBR + FQ тюнинг ядра, UDP-буферы 8MB
# - Cloudflare WARP SOCKS5 + Smart ACL (Instagram/Meta, ChatGPT, Claude, Google/Gemini)
# - Protocol sniffing: ACL работает и для клиентов в TUN-режиме
# - Port Hopping 20000-50000 (защита от глушилок провайдеров)
# - UFW (без сброса чужих правил) + Fail2ban + healthcheck WARP
# - Повторный запуск безопасен: пароль и сертификат сохраняются
# GitHub: https://github.com/Fulsepredict/Admin_vpn
# ============================================================

set -euo pipefail

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# === Конфигурация (все «магические числа» собраны здесь) ===
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_CONFIG="${HYSTERIA_DIR}/config.yaml"
HYSTERIA_CERT="${HYSTERIA_DIR}/server.crt"
HYSTERIA_KEY="${HYSTERIA_DIR}/server.key"
BACKUP_DIR="${HYSTERIA_DIR}/backups"
VPN_ADMIN_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"
VPN_ADMIN_PATH="/usr/local/bin/vpn-admin"
HYSTERIA_INSTALLER_URL="https://get.hy2.sh/"
SETUP_LOG="/var/log/vpn-setup.log"

LISTEN_PORT=443
HOP_PORT_START=20000
HOP_PORT_END=50000
WARP_SOCKS_PORT=40000
WARP_CONNECT_WAIT_SEC=20
SERVICE_START_WAIT_SEC=10
APT_LOCK_TIMEOUT_SEC=300
PASSWORD_LENGTH=24
CERT_DAYS=3650
CERT_CN="bing.com"
MASQUERADE_URL="https://www.bing.com"
SNIFF_TIMEOUT="2s"
# Серверный sniffing появился в 2.5.0, его баги (HTTP на нестандартных портах,
# фрагментированный QUIC) исправлены в 2.5.1–2.5.2. Старее — не поддерживаем.
MIN_HYSTERIA_VERSION="2.5.2"
TOTAL_STEPS=8

# Домены, которые идут через Cloudflare WARP (остальное — напрямую).
# ВАЖНО: такой же список RECOMMENDED_WARP_DOMAINS есть в vpn-admin.sh —
# тест tests/test_audit.py проверяет, что списки совпадают.
WARP_DOMAINS=(
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

# Только для CI: подставить локальную копию vpn-admin.sh вместо скачивания с GitHub,
# чтобы тестировать именно проверяемый коммит. В обычной установке не задаётся.
VPN_ADMIN_SOURCE_FILE="${VPN_ADMIN_SOURCE_FILE:-}"

WARP_ENABLED=false

# ============================================================
# Вывод и логирование
# Почему так: раньше почти все команды писали в /dev/null, и сбой (например,
# WARP не поставился) оставался незамеченным. Теперь всё пишется в лог.
# ============================================================

log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$SETUP_LOG" 2>/dev/null || true
}

step() {
    echo -e "${YELLOW}[$1/${TOTAL_STEPS}]${NC} $2"
    log "STEP $1: $2"
}

ok() {
    echo -e "  ${GREEN}✅ $*${NC}"
    log "OK: $*"
}

warn() {
    echo -e "  ${YELLOW}⚠ $*${NC}"
    log "WARN: $*"
}

die() {
    echo -e "  ${RED}❌ $*${NC}" >&2
    echo -e "  ${DIM}Подробности в логе: ${SETUP_LOG}${NC}" >&2
    log "FATAL: $*"
    exit 1
}

# Выполнить команду, отправив её вывод в лог. Возвращает код команды.
run_logged() {
    log "RUN: $*"
    "$@" >> "$SETUP_LOG" 2>&1
}

# ============================================================
# Чистые функции (без побочных эффектов) — покрыты тестами
# ============================================================

# version_ge A B — истина, если версия A >= B (например, 2.6.1 >= 2.5.2).
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# Случайный пароль только из [A-Za-z0-9]: безопасен в YAML и в ссылке hy2://
generate_password() {
    local raw
    raw=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    printf '%s\n' "${raw:0:${PASSWORD_LENGTH}}"
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

# SHA-256 отпечаток сертификата (hex, без двоеточий) для параметра pinSHA256.
cert_pin() {
    local cert="${1:-$HYSTERIA_CERT}" fingerprint
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null) || return 1
    fingerprint="${fingerprint#*=}"
    fingerprint="${fingerprint//:/}"
    printf '%s\n' "${fingerprint,,}"
}

# Ссылки для клиентов в формате "метка<TAB>ссылка".
# ВАЖНО: функция продублирована в vpn-admin.sh — тест проверяет идентичность вывода.
#  porthop  — port hopping через параметр mport (NekoBox, v2rayN, 3x-ui-совместимые)
#  standard — только порт 443
#  nopin    — port hopping без pinSHA256 (если клиент не понимает закрепление)
#  official — официальная схема Hysteria: диапазон портов прямо в адресе
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

# Блок sniffing. ВАЖНО: продублирован в vpn-admin.sh (sniff_block) — тест сверяет.
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

# Домен вида example.com (только латиница, цифры, дефис).
# ВАЖНО: идентична validate_domain в vpn-admin.sh — тест сверяет.
validate_domain() {
    local value="$1"
    (( ${#value} >= 4 && ${#value} <= 253 )) || return 1
    LC_ALL=C grep -Eqx '([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}' <<< "$value"
}

# Домены, которые пользователь сам добавил в ACL (через vpn-admin add-domain),
# то есть которых нет в стандартном списке WARP_DOMAINS. Повторный запуск
# setup.sh переносит их в новый конфиг, а не стирает.
custom_domains_from_config() {
    local file="$1" domain standard
    [[ -f "$file" ]] || return 0
    while IFS= read -r domain; do
        validate_domain "$domain" || continue
        for standard in "${WARP_DOMAINS[@]}"; do
            [[ "$domain" == "$standard" ]] && continue 2
        done
        printf '%s\n' "$domain"
    done < <(grep -oE 'warp_proxy\(suffix:[^)]+\)' "$file" | sed -E 's/^warp_proxy\(suffix:(.*)\)$/\1/' | awk '!seen[$0]++')
}

# Полный конфиг Hysteria2. $2 = true — со Smart ACL через WARP.
# $3... — дополнительные (пользовательские) домены для WARP.
render_config() {
    local password="$1" warp_enabled="$2"
    shift 2
    local extra_domains=("$@")
    cat <<EOF
listen: :${LISTEN_PORT}

tls:
  cert: ${HYSTERIA_CERT}
  key: ${HYSTERIA_KEY}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF

    if [[ "$warp_enabled" == true ]]; then
        echo ""
        sniff_block
        cat <<EOF

outbounds:
  - name: warp_proxy
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_SOCKS_PORT}

acl:
  inline:
EOF
        local domain
        for domain in "${WARP_DOMAINS[@]}"; do
            printf '    - warp_proxy(suffix:%s)\n' "$domain"
        done
        if (( ${#extra_domains[@]} > 0 )); then
            printf '    # --- Добавлены вручную (vpn-admin add-domain) ---\n'
            for domain in "${extra_domains[@]}"; do
                validate_domain "$domain" || continue
                printf '    - warp_proxy(suffix:%s)\n' "$domain"
            done
        fi
        printf '    - direct(all)\n'
    fi
}

# Порты SSH, которые нельзя закрыть файрволом (иначе потеряем доступ к серверу).
detect_ssh_ports() {
    local ports=""
    # 1) Порт текущей SSH-сессии — самый надёжный источник
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ports+=" ${SSH_CONNECTION##* }"
    fi
    # 2) Итоговая конфигурация sshd
    if command -v sshd >/dev/null 2>&1; then
        ports+=" $(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | tr '\n' ' ')"
    fi
    # 3) Что реально слушает sshd
    if command -v ss >/dev/null 2>&1; then
        ports+=" $(ss -Htlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' | tr '\n' ' ')"
    fi

    local result="" port
    for port in $ports; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        (( port >= 1 && port <= 65535 )) || continue
        [[ " $result " == *" $port "* ]] || result+=" $port"
    done
    [[ -z "$result" ]] && result=" 22"
    printf '%s\n' "${result# }"
}

get_public_ip() {
    local ip="" url
    for url in https://ifconfig.me https://icanhazip.com https://api.ipify.org; do
        ip=$(curl -s -4 --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
        ip=$(printf '%s' "$ip" | tr -d ' \r\n')
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
    done
    hostname -I 2>/dev/null | awk '{ print $1 }'
}

# Проверка WARP. Вывод curl сохраняем в переменную, а не передаём в grep -q:
# при set -o pipefail grep -q может оборвать curl (SIGPIPE), и проверка
# ложно сообщит, что WARP выключен.
warp_is_on() {
    local trace
    trace=$(curl -s -x "socks5h://127.0.0.1:${WARP_SOCKS_PORT}" --connect-timeout 5 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    [[ "$trace" == *"warp=on"* ]]
}

# ============================================================
# Шаги установки
# ============================================================

preflight_checks() {
    [[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash setup.sh"
    command -v apt-get >/dev/null 2>&1 || die "Поддерживаются только Ubuntu/Debian (нужен apt-get)"
    mkdir -p "$(dirname "$SETUP_LOG")"
    touch "$SETUP_LOG" && chmod 600 "$SETUP_LOG"
    log "===== setup.sh started ====="
}

# Ждём, пока apt освободится. Почему не «убить apt и удалить lock-файлы» (как было раньше):
# убийство dpkg посреди автообновления может повредить систему пакетов.
wait_for_apt() {
    local waited=0
    while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 \
        || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f '/usr/bin/unattended-upgrade' >/dev/null 2>&1; do
        if (( waited == 0 )); then
            echo -e "  ${DIM}apt занят (идёт автообновление), жду до ${APT_LOCK_TIMEOUT_SEC} сек...${NC}"
        fi
        (( waited >= APT_LOCK_TIMEOUT_SEC )) && die "apt занят дольше ${APT_LOCK_TIMEOUT_SEC} сек. Подожди и запусти снова."
        sleep 5
        waited=$(( waited + 5 ))
    done
    run_logged dpkg --configure -a || warn "dpkg --configure -a завершился с ошибкой"
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a run_logged apt-get \
        -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT_SEC}" \
        -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=3 \
        "$@"
}

install_packages() {
    step 1 "Обновление списков пакетов..."
    wait_for_apt
    apt_get update -qq || warn "apt-get update завершился с ошибкой (продолжаю со старыми списками)"
    ok "Списки пакетов обновлены"

    step 2 "Установка базовых утилит..."
    apt_get install -y -qq curl ufw fail2ban openssl unattended-upgrades iptables lsb-release gnupg cron \
        || warn "Часть пакетов не установилась — проверяю обязательные"

    local required
    for required in curl openssl ufw iptables crontab; do
        command -v "$required" >/dev/null 2>&1 || die "Не установлен обязательный пакет: ${required}"
    done
    command -v fail2ban-client >/dev/null 2>&1 || warn "fail2ban не установлен — защита SSH от перебора отключена"
    run_logged dpkg-reconfigure -f noninteractive unattended-upgrades || true
    ok "curl, ufw, fail2ban, iptables, cron, автообновления"
}

tune_kernel() {
    step 3 "Настройка BBR и UDP-буферов ядра Linux..."
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
# Алгоритм контроля перегрузок Google BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Буферы UDP 8MB (убирают дропы пакетов на высоких скоростях)
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# Быстрая очистка закрытых соединений
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
EOF
    run_logged sysctl --system || warn "sysctl --system вернул ошибку"
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        ok "BBR + FQ + UDP-буферы 8MB активированы"
    else
        warn "BBR не включился (ядро без модуля tcp_bbr?) — VPN будет работать, но медленнее"
    fi
}

install_warp() {
    step 4 "Настройка Cloudflare WARP (SOCKS5 для Smart ACL)..."

    if command -v warp-cli >/dev/null 2>&1 && warp_is_on; then
        WARP_ENABLED=true
        ok "Cloudflare WARP уже работает на 127.0.0.1:${WARP_SOCKS_PORT}"
        return 0
    fi

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    if [[ "$arch" != "amd64" ]]; then
        warn "WARP пропущен: архитектура ${arch} не поддерживается этим скриптом (только amd64)"
        return 0
    fi

    if ! command -v warp-cli >/dev/null 2>&1; then
        local codename
        codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
        install -m 0755 -d /etc/apt/keyrings
        if curl -fsSL --connect-timeout 10 https://pkg.cloudflareclient.com/pubkey.gpg \
            | gpg --yes --dearmor --output /etc/apt/keyrings/cloudflare-warp.gpg 2>>"$SETUP_LOG"; then
            echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt_get update -qq || true
            apt_get install -y -qq cloudflare-warp || warn "Пакет cloudflare-warp не установился (дистрибутив ${codename} может не поддерживаться)"
        else
            warn "Не удалось скачать ключ репозитория Cloudflare"
        fi
    fi

    if ! command -v warp-cli >/dev/null 2>&1; then
        warn "WARP недоступен — Hysteria будет работать напрямую, без Smart ACL"
        return 0
    fi

    run_logged systemctl enable --now warp-svc || true
    sleep 2
    # Синтаксис warp-cli менялся между версиями — пробуем новый, затем старый
    run_logged warp-cli --accept-tos registration new || run_logged warp-cli --accept-tos register || true
    run_logged warp-cli --accept-tos mode proxy || run_logged warp-cli --accept-tos set-mode proxy || true
    run_logged warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" \
        || run_logged warp-cli --accept-tos set-proxy-port "${WARP_SOCKS_PORT}" || true
    run_logged warp-cli --accept-tos connect || true

    local waited=0
    while (( waited < WARP_CONNECT_WAIT_SEC )); do
        if warp_is_on; then
            WARP_ENABLED=true
            ok "Cloudflare WARP запущен на 127.0.0.1:${WARP_SOCKS_PORT} (SOCKS5, warp=on)"
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    warn "WARP установлен, но не подключился за ${WARP_CONNECT_WAIT_SEC} сек — Smart ACL не будет включён"
}

install_hysteria() {
    step 5 "Установка Hysteria2..."
    local installer
    installer=$(mktemp)
    curl -fsSL --connect-timeout 15 "$HYSTERIA_INSTALLER_URL" -o "$installer" \
        || { rm -f "$installer"; die "Не удалось скачать установщик Hysteria2 (${HYSTERIA_INSTALLER_URL})"; }
    run_logged bash "$installer" || { rm -f "$installer"; die "Установщик Hysteria2 завершился с ошибкой"; }
    rm -f "$installer"

    local version
    version=$(hysteria version 2>/dev/null | awk '/^Version:/ { print $2 }' | sed 's/^v//')
    if [[ -z "$version" ]]; then
        warn "Не удалось определить версию Hysteria2"
    elif ! version_ge "$version" "$MIN_HYSTERIA_VERSION"; then
        die "Hysteria2 ${version} слишком старая: нужна ${MIN_HYSTERIA_VERSION}+ (для sniffing)"
    fi
    ok "Hysteria2 ${version:-?} установлен"
}

hysteria_group() {
    if getent group hysteria >/dev/null 2>&1; then echo "hysteria"; else echo "root"; fi
}

# Сертификат создаём только один раз: при повторном запуске он сохраняется,
# иначе pinSHA256 в уже выданных ссылках перестал бы совпадать.
ensure_certificate() {
    if [[ -s "$HYSTERIA_CERT" && -s "$HYSTERIA_KEY" ]] && openssl x509 -noout -in "$HYSTERIA_CERT" 2>/dev/null; then
        ok "Сертификат уже есть — сохраняю (ссылки клиентов останутся рабочими)"
        return 0
    fi
    run_logged openssl ecparam -genkey -name prime256v1 -out "$HYSTERIA_KEY" || die "Не удалось создать ключ"
    run_logged openssl req -new -x509 -days "$CERT_DAYS" -key "$HYSTERIA_KEY" \
        -out "$HYSTERIA_CERT" -subj "/CN=${CERT_CN}" || die "Не удалось создать сертификат"
    ok "Создан самоподписанный сертификат (CN=${CERT_CN}, ${CERT_DAYS} дней)"
}

# Пароль тоже сохраняем при повторном запуске — чтобы не отключить клиентов.
resolve_password() {
    local existing=""
    if [[ -f "$HYSTERIA_CONFIG" ]]; then
        existing=$(get_auth_password "$HYSTERIA_CONFIG" || true)
    fi
    if [[ "$existing" =~ ^[A-Za-z0-9_-]{8,64}$ ]]; then
        printf '%s\n' "$existing"
    else
        generate_password
    fi
}

# Права: ключ и конфиг (с паролем) читают только root и служба hysteria.
# Раньше было 644 — их мог прочитать любой процесс на сервере, включая ботов.
secure_permissions() {
    local group
    group=$(hysteria_group)
    chown root:"$group" "$HYSTERIA_DIR" "$HYSTERIA_CERT" "$HYSTERIA_KEY" "$HYSTERIA_CONFIG"
    chmod 750 "$HYSTERIA_DIR"
    chmod 640 "$HYSTERIA_KEY" "$HYSTERIA_CONFIG"
    chmod 644 "$HYSTERIA_CERT"
    if [[ -d "$BACKUP_DIR" ]]; then
        chown -R root:root "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
        find "$BACKUP_DIR" -type f -exec chmod 600 {} +
    fi
}

write_config() {
    step 6 "Настройка конфига Hysteria2..."
    mkdir -p "$HYSTERIA_DIR"
    ensure_certificate

    VPN_PASSWORD=$(resolve_password)

    local custom_domains=()
    if [[ -f "$HYSTERIA_CONFIG" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
        cp -p "$HYSTERIA_CONFIG" "${BACKUP_DIR}/config_before_setup_$(date +%Y%m%d_%H%M%S).yaml"
        ok "Старый конфиг сохранён в ${BACKUP_DIR}"
        mapfile -t custom_domains < <(custom_domains_from_config "$HYSTERIA_CONFIG")
    fi

    local tmp
    tmp=$(mktemp)
    render_config "$VPN_PASSWORD" "$WARP_ENABLED" "${custom_domains[@]}" > "$tmp"
    cat "$tmp" > "$HYSTERIA_CONFIG"
    rm -f "$tmp"
    secure_permissions

    if [[ "$WARP_ENABLED" == true ]]; then
        ok "Конфиг: Bing-маскировка + sniffing + Smart ACL (${#WARP_DOMAINS[@]} доменов через WARP)"
        if (( ${#custom_domains[@]} > 0 )); then
            ok "Сохранены домены, добавленные вручную: ${custom_domains[*]}"
        fi
    else
        ok "Конфиг: Bing-маскировка + прямое подключение"
    fi
}

# NAT-редирект port hopping в правилах UFW (переживает перезагрузку).
ensure_nat_redirect_in_ufw() {
    local rules="/etc/ufw/before.rules"
    if [[ ! -f "$rules" ]]; then
        warn "${rules} не найден — port hopping не переживёт перезагрузку"
        return 0
    fi
    if grep -q -- "--dport ${HOP_PORT_START}:${HOP_PORT_END} -j REDIRECT" "$rules"; then
        return 0
    fi
    local tmp
    tmp=$(mktemp)
    {
        echo "# Admin_vpn: Hysteria2 port hopping (UDP ${HOP_PORT_START}-${HOP_PORT_END} -> ${LISTEN_PORT})"
        echo "*nat"
        echo ":PREROUTING ACCEPT [0:0]"
        echo "-A PREROUTING -p udp --dport ${HOP_PORT_START}:${HOP_PORT_END} -j REDIRECT --to-ports ${LISTEN_PORT}"
        echo "COMMIT"
        echo ""
        cat "$rules"
    } > "$tmp"
    cat "$tmp" > "$rules"
    rm -f "$tmp"
}

# То же правило в текущей сессии — без дублей при повторных запусках.
ensure_live_nat_rule() {
    local rule=(PREROUTING -p udp --dport "${HOP_PORT_START}:${HOP_PORT_END}" -j REDIRECT --to-ports "${LISTEN_PORT}")
    if ! iptables -t nat -C "${rule[@]}" 2>/dev/null; then
        iptables -t nat -A "${rule[@]}" 2>>"$SETUP_LOG" || warn "Не удалось добавить iptables-правило port hopping"
    fi
}

# Почему без полного сброса UFW (reset, как было раньше): сброс стирал правила,
# открытые для ботов и других сервисов на этом же VPS, и открывал только SSH 22 —
# с SSH на нестандартном порту это означало потерю доступа к серверу.
configure_firewall() {
    step 7 "Настройка файрвола и Port Hopping (${HOP_PORT_START}-${HOP_PORT_END} UDP)..."

    local ufw_status ufw_was_active=false
    ufw_status=$(ufw status 2>/dev/null || true)
    [[ "$ufw_status" == *"Status: active"* ]] && ufw_was_active=true

    if [[ "$ufw_was_active" == false ]]; then
        run_logged ufw default deny incoming || true
        run_logged ufw default allow outgoing || true
    fi

    local ssh_ports port
    ssh_ports=$(detect_ssh_ports)
    for port in $ssh_ports; do
        run_logged ufw allow "${port}/tcp" comment 'SSH' || warn "Не удалось открыть SSH-порт ${port}"
    done
    run_logged ufw allow "${LISTEN_PORT}/udp" comment 'Hysteria2' || warn "Не удалось открыть ${LISTEN_PORT}/udp"
    run_logged ufw allow "${HOP_PORT_START}:${HOP_PORT_END}/udp" comment 'Hysteria2 port hopping' \
        || warn "Не удалось открыть диапазон port hopping"

    ensure_nat_redirect_in_ufw
    run_logged ufw --force enable || warn "ufw не включился"
    ensure_live_nat_rule

    ok "Файрвол: SSH (${ssh_ports// /, }/tcp) + Hysteria (${LISTEN_PORT}/udp) + Port Hopping"

    # UFW был выключен и сейчас стал запрещать входящие — предупредим о сервисах,
    # которые слушают публичные TCP-порты (вебхуки ботов, панели и т.п.)
    if [[ "$ufw_was_active" == false ]] && command -v ss >/dev/null 2>&1; then
        local listening other=""
        listening=$(ss -Htln 2>/dev/null | awk '{ print $4 }' | grep -vE '^(127\.|\[::1\]|::1)' \
            | awk -F: '{ print $NF }' | sort -un || true)
        for port in $listening; do
            [[ " $ssh_ports " == *" $port "* ]] || other+=" $port"
        done
        if [[ -n "$other" ]]; then
            warn "Эти TCP-порты слушают сервисы, но теперь закрыты UFW:${other}"
            echo -e "  ${DIM}Если они нужны (например, вебхуки ботов): ufw allow ПОРТ/tcp${NC}"
        fi
    fi
}

install_admin_panel() {
    local tmp
    tmp=$(mktemp)
    if [[ -n "$VPN_ADMIN_SOURCE_FILE" && -f "$VPN_ADMIN_SOURCE_FILE" ]]; then
        cp "$VPN_ADMIN_SOURCE_FILE" "$tmp"
    elif ! curl -fsSL --connect-timeout 15 "$VPN_ADMIN_URL" -o "$tmp"; then
        rm -f "$tmp"
        warn "Не удалось скачать vpn-admin — healthcheck не установлен"
        return 1
    fi
    sed -i 's/\r$//' "$tmp"
    if ! bash -n "$tmp" 2>>"$SETUP_LOG"; then
        rm -f "$tmp"
        warn "Скачанный vpn-admin повреждён — пропускаю"
        return 1
    fi
    install -m 755 -o root -g root "$tmp" "$VPN_ADMIN_PATH"
    rm -f "$tmp"
    return 0
}

setup_services() {
    step 8 "Мониторинг, автоперезапуск и панель управления..."

    mkdir -p /etc/systemd/system/hysteria-server.service.d/
    cat > /etc/systemd/system/hysteria-server.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
    run_logged systemctl daemon-reload || true

    if install_admin_panel; then
        run_logged "$VPN_ADMIN_PATH" install-healthcheck || warn "Не удалось установить healthcheck"
        ok "Панель vpn-admin и healthcheck (WARP + Hysteria, каждые 5 минут)"
    fi

    run_logged systemctl enable hysteria-server || true
    run_logged systemctl restart hysteria-server || true

    local waited=0
    while (( waited < SERVICE_START_WAIT_SEC )); do
        sleep 2
        waited=$(( waited + 2 ))
        if systemctl is-active --quiet hysteria-server; then
            ok "Hysteria2 запущен и добавлен в автозагрузку"
            return 0
        fi
    done
    journalctl -u hysteria-server -n 20 --no-pager >> "$SETUP_LOG" 2>&1 || true
    die "Hysteria2 не запустился. Последние строки журнала записаны в ${SETUP_LOG}"
}

print_summary() {
    local server_ip pin
    server_ip=$(get_public_ip)
    pin=$(cert_pin "$HYSTERIA_CERT" || true)

    local label link porthop="" standard="" nopin=""
    while IFS=$'\t' read -r label link; do
        case "$label" in
            porthop)  porthop="$link" ;;
            standard) standard="$link" ;;
            nopin)    nopin="$link" ;;
            *)        ;;  # official — показывается в "vpn-admin link"
        esac
    done < <(build_links "$server_ip" "$VPN_PASSWORD" "$pin")

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  ✅ УСТАНОВКА ENTERPRISE VPN ЗАВЕРШЕНА!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}IP сервера:${NC}      ${server_ip}"
    echo -e "  ${BOLD}Пароль VPN:${NC}      ${VPN_PASSWORD}"
    if [[ "$WARP_ENABLED" == true ]]; then
        echo -e "  ${BOLD}WARP + ACL:${NC}      ${GREEN}Активен (${#WARP_DOMAINS[@]} доменов, sniffing включён)${NC}"
    else
        echo -e "  ${BOLD}WARP + ACL:${NC}      ${YELLOW}Отключен (прямой режим)${NC}"
    fi
    echo -e "  ${BOLD}Port Hopping:${NC}    ${GREEN}${HOP_PORT_START}-${HOP_PORT_END} UDP${NC}"
    echo ""
    echo -e "  ${BOLD}1. Рекомендуемая ссылка (port hopping + закреплённый сертификат):${NC}"
    echo -e "  ${CYAN}${porthop}${NC}"
    echo ""
    echo -e "  ${BOLD}2. Стандартная ссылка (порт ${LISTEN_PORT}):${NC}"
    echo -e "  ${DIM}${standard}${NC}"
    echo ""
    echo -e "  ${BOLD}3. Если клиент не подключается по ссылкам 1–2 (без pinSHA256):${NC}"
    echo -e "  ${DIM}${nopin}${NC}"
    echo ""
    echo -e "  ${DIM}Все ссылки и официальный формат: vpn-admin link${NC}"
    echo -e "  ${DIM}Клиенты: NekoBox / v2rayN / Hiddify / Streisand / Shadowrocket${NC}"
    echo ""
    echo -e "  ${BOLD}Управление:${NC}"
    echo -e "  ${DIM}vpn-admin${NC}          — интерактивное меню"
    echo -e "  ${DIM}vpn-admin status${NC}   — статус сервисов, WARP и sniffing"
    echo -e "  ${DIM}vpn-admin test-ai${NC}  — проверить доступность ChatGPT/Claude/Instagram"
    echo ""
    echo -e "  ${DIM}Лог установки: ${SETUP_LOG}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}🚀 VPN Server Quick Setup (Enterprise Edition)${NC}       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${DIM}Hysteria2 + BBR + WARP SOCKS5 + Port Hopping${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    preflight_checks
    install_packages
    tune_kernel
    install_warp
    install_hysteria
    write_config
    configure_firewall
    setup_services
    print_summary
    log "===== setup.sh finished ====="
}

# Запускаем main только при прямом запуске (bash setup.sh, bash <(curl ...), curl | bash),
# но не при подключении через source — так функции можно тестировать.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
