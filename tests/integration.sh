#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015 («A && B || C — не if-then-else»): здесь это безопасно, потому что
# t_ok всегда возвращает 0, и t_fail срабатывает только при ложном условии.
# SC2329 («функция не вызывается»): функции вызываются косвенно — через trap,
# t_check и apply_config_change, которые получают имя функции аргументом.
# ============================================================
# Интеграционный тест Admin_vpn (запускается в GitHub Actions)
#
# Порядок: sudo bash setup.sh  →  sudo bash tests/integration.sh
#
# Почему так устроено: юнит-тесты проверяют функции на временных файлах,
# а здесь проверяется НАСТОЯЩИЙ сервер на чистой Ubuntu: служба, права,
# команды vpn-admin, автооткат, реальный туннель Hysteria, WARP и sniffing.
#
# Клиент запускается в отдельном сетевом пространстве имён (netns) —
# это как второй компьютер, подключённый к серверу проводом. Поэтому пакеты
# клиента проходят через настоящий файрвол и NAT-правило port hopping,
# а не «срезают путь» через localhost.
#
# Тесты WARP/ACL выполняются, только если setup.sh смог включить WARP
# (на раннерах GitHub это зависит от Cloudflare). Иначе — предупреждение.
# ============================================================

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Берём функции из vpn-admin.sh (main при source не запускается).
# Отсюда же переменные CONFIG, CERT_FILE, SERVICE, BACKUP_DIR и др.
# shellcheck source=vpn-admin.sh
source "${REPO_DIR}/vpn-admin.sh"

# === Параметры теста ===
NETNS="hytest"
VETH_HOST="veth-hyhost"
VETH_CLIENT="veth-hycli"
HOST_IP="10.200.0.1"
CLIENT_IP="10.200.0.2"
CLIENT_SOCKS="127.0.0.1:1080"
TRACE_HOST="www.cloudflare.com"
TRACE_URL="https://${TRACE_HOST}/cdn-cgi/trace"
TEST_DOMAIN="cloudflare.com"
CUSTOM_DOMAIN="example.org"
CLIENT_START_WAIT_SEC=15
SERVICE_WAIT_SEC=20
WRONG_PIN="0000000000000000000000000000000000000000000000000000000000000000"

WORK_DIR=$(mktemp -d)
CLIENT_PID=""
FAILURES=0
PASSED=0
WARP_ACTIVE=false

# === Отчёт ===
t_ok()      { echo "  ✅ $*"; PASSED=$(( PASSED + 1 )); }
t_fail()    { echo "  ❌ $*"; echo "::error::$*"; FAILURES=$(( FAILURES + 1 )); }
t_skip()    { echo "  ⏭  $*"; echo "::warning::$*"; }
t_section() { echo ""; echo "=== $* ==="; }

# t_check "описание" команда [аргументы...] — успех, если команда вернула 0
t_check() {
    local description="$1"
    shift
    if "$@"; then t_ok "$description"; else t_fail "$description"; fi
}

# === Вспомогательные функции ===

stop_client() {
    if [[ -n "$CLIENT_PID" ]]; then
        kill "$CLIENT_PID" 2>/dev/null || true
        wait "$CLIENT_PID" 2>/dev/null || true
        CLIENT_PID=""
    fi
}

cleanup() {
    stop_client
    ip netns del "$NETNS" 2>/dev/null || true
    ip link del "$VETH_HOST" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

config_hash() { sha256sum "$CONFIG" | awk '{ print $1 }'; }

wait_service_active() {
    local waited=0
    while (( waited < SERVICE_WAIT_SEC )); do
        systemctl is-active --quiet "$SERVICE" && return 0
        sleep 1
        waited=$(( waited + 1 ))
    done
    return 1
}

file_mode_owner() { stat -c '%a %U:%G' "$1"; }

yaml_is_valid_without_duplicates() {
    python3 - "$CONFIG" <<'PY'
import sys
import yaml

config = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
rules = (config.get("acl") or {}).get("inline") or []
assert len(rules) == len(set(rules)), "duplicate ACL rules"
assert not rules or rules[-1] == "direct(all)", "direct(all) must be last"
PY
}

# Ссылка нужного типа (porthop / standard / nopin / official) на адрес HOST_IP.
link_for() {
    local kind="$1" password pin
    password=$(get_auth_password "$CONFIG")
    pin=$(cert_pin "$CERT_FILE")
    build_links "$HOST_IP" "$password" "$pin" | awk -F'\t' -v k="$kind" '$1 == k { print $2 }'
}

setup_netns() {
    ip netns add "$NETNS" || return 1
    ip link add "$VETH_HOST" type veth peer name "$VETH_CLIENT" || return 1
    ip link set "$VETH_CLIENT" netns "$NETNS" || return 1
    ip addr add "${HOST_IP}/24" dev "$VETH_HOST" || return 1
    ip link set "$VETH_HOST" up || return 1
    ip netns exec "$NETNS" ip addr add "${CLIENT_IP}/24" dev "$VETH_CLIENT" || return 1
    ip netns exec "$NETNS" ip link set "$VETH_CLIENT" up || return 1
    ip netns exec "$NETNS" ip link set lo up || return 1
}

# start_client ССЫЛКА — запускает hysteria-клиент в netns.
# Ссылка передаётся прямо в поле server: так проверяется именно тот формат,
# который получают пользователи. Успех = SOCKS5-порт клиента открылся
# (клиент открывает его только после успешного подключения к серверу).
start_client() {
    local link="$1" waited=0
    stop_client
    printf 'server: "%s"\nsocks5:\n  listen: %s\n' "$link" "$CLIENT_SOCKS" > "${WORK_DIR}/client.yaml"
    ip netns exec "$NETNS" hysteria client -c "${WORK_DIR}/client.yaml" > "${WORK_DIR}/client.log" 2>&1 &
    CLIENT_PID=$!
    local listening
    while (( waited < CLIENT_START_WAIT_SEC )); do
        if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
            CLIENT_PID=""
            return 1
        fi
        listening=$(ip netns exec "$NETNS" ss -Htln 2>/dev/null || true)
        if [[ "$listening" == *"${CLIENT_SOCKS}"* ]]; then
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    return 1
}

# trace_via_client hostname|ip — запрос к Cloudflare trace через клиента.
#  hostname: клиент передаёт серверу ИМЯ сайта (как обычный прокси-режим)
#  ip:       клиент передаёт только IP (так делают клиенты в TUN-режиме)
TRACE_IP=""
trace_via_client() {
    local mode="$1"
    if [[ "$mode" == "hostname" ]]; then
        ip netns exec "$NETNS" curl -s --max-time 20 --socks5-hostname "$CLIENT_SOCKS" "$TRACE_URL" 2>/dev/null || true
    else
        ip netns exec "$NETNS" curl -s --max-time 20 --socks5 "$CLIENT_SOCKS" \
            --resolve "${TRACE_HOST}:443:${TRACE_IP}" "$TRACE_URL" 2>/dev/null || true
    fi
}

warp_state() {
    local trace="$1"
    case "$trace" in
        *"warp=on"*)  echo "on" ;;
        *"warp=off"*) echo "off" ;;
        *)            echo "none" ;;
    esac
}

# Правка для проверки автоотката: ломает YAML, Hysteria не сможет стартовать
break_config_for_test() { printf '\nthis: is: not: valid: yaml: [\n' >> "$1"; }

# Правка для отрицательного контроля: выключить sniffing
disable_sniff_for_test() {
    local tmp
    tmp=$(mktemp)
    awk '
        /^[^[:space:]#]/ { in_sniff = ($0 ~ /^sniff:/) }
        in_sniff && /^[[:space:]]+enable:/ { sub(/true/, "false") }
        { print }
    ' "$1" > "$tmp"
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

legacy_config() {
    local password="$1"
    cat <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

outbounds:
  - name: warp_proxy
    type: socks5
    socks5:
      addr: 127.0.0.1:40000

acl:
  inline:
    # --- Instagram & Meta Ecosystem ---
    - warp_proxy(suffix:instagram.com)
    - warp_proxy(suffix:cdninstagram.com)
    - warp_proxy(suffix:facebook.com)
    # --- Instagram & Meta Ecosystem ---
    - warp_proxy(suffix:instagram.com)
    - warp_proxy(suffix:cdninstagram.com)
    - warp_proxy(suffix:facebook.com)
    - warp_proxy(suffix:openai.com)
    - warp_proxy(suffix:googleapis.com)
    - direct(all)
EOF
}

# ============================================================
t_section "1. Служба, файлы и права"
# ============================================================

t_check "hysteria-server активен" systemctl is-active --quiet "$SERVICE"
t_check "hysteria-server в автозагрузке" systemctl is-enabled --quiet "$SERVICE"
[[ "$(file_mode_owner "$CONFIG")" == "640 root:hysteria" ]] \
    && t_ok "config.yaml: 640 root:hysteria" || t_fail "config.yaml: $(file_mode_owner "$CONFIG")"
[[ "$(file_mode_owner /etc/hysteria/server.key)" == "640 root:hysteria" ]] \
    && t_ok "server.key: 640 root:hysteria" || t_fail "server.key: $(file_mode_owner /etc/hysteria/server.key)"
t_check "config.yaml — валидный YAML без дублей в ACL" yaml_is_valid_without_duplicates
t_check "vpn-admin установлен" test -x /usr/local/bin/vpn-admin
t_check "vpn-healthcheck установлен" test -x /usr/local/bin/vpn-healthcheck
CRON_LINES=$(crontab -l 2>/dev/null | grep -c 'vpn-healthcheck' || true)
[[ "$CRON_LINES" == "1" ]] && t_ok "healthcheck в cron (1 строка)" || t_fail "строк healthcheck в cron: ${CRON_LINES}"
NAT_RULES=$(iptables -t nat -S PREROUTING | grep -c -- "--dport ${HOP_PORT_START}:${HOP_PORT_END}" || true)
[[ "$NAT_RULES" == "1" ]] && t_ok "NAT-правило port hopping (1 шт.)" || t_fail "NAT-правил port hopping: ${NAT_RULES}"
UFW_STATUS=$(ufw status 2>/dev/null || true)
[[ "$UFW_STATUS" == *"Status: active"* ]] && t_ok "UFW включён" || t_fail "UFW выключен"
[[ "$UFW_STATUS" == *"443/udp"* && "$UFW_STATUS" == *"${HOP_PORT_START}:${HOP_PORT_END}/udp"* ]] \
    && t_ok "UFW: открыты 443/udp и диапазон port hopping" || t_fail "UFW: нет правил для Hysteria"
SYSCTL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
[[ "$SYSCTL_CC" == "bbr" ]] && t_ok "BBR включён" || t_skip "BBR не включён (ядро раннера: ${SYSCTL_CC})"

# ============================================================
t_section "2. WARP и Smart ACL"
# ============================================================

if config_has_acl "$CONFIG"; then
    t_check "sniffing включён в конфиге" sniff_is_enabled "$CONFIG"
    MISSING=""
    for domain in "${RECOMMENDED_WARP_DOMAINS[@]}"; do
        acl_has_domain "$CONFIG" "$domain" || MISSING+=" ${domain}"
    done
    [[ -z "$MISSING" ]] && t_ok "все ${#RECOMMENDED_WARP_DOMAINS[@]} рекомендуемых доменов в ACL" \
        || t_fail "в ACL нет доменов:${MISSING}"
    if warp_is_on; then
        WARP_ACTIVE=true
        t_ok "WARP работает (warp=on на 127.0.0.1:${WARP_PORT})"
    else
        t_fail "ACL включён, но WARP не отвечает (warp=on не получен)"
    fi
else
    t_skip "setup.sh не смог включить WARP на раннере — тесты WARP/ACL пропущены"
    if grep -q '^sniff:' "$CONFIG"; then
        t_fail "sniff без ACL не нужен"
    else
        t_ok "конфиг без WARP: без ACL и sniff (прямой режим)"
    fi
fi

# ============================================================
t_section "3. Команды vpn-admin"
# ============================================================

PIN=$(cert_pin "$CERT_FILE")
[[ "$PIN" =~ ^[0-9a-f]{64}$ ]] && t_ok "pinSHA256 сертификата: ${PIN:0:16}…" || t_fail "некорректный pin: ${PIN}"

LINK_OUT=$(vpn-admin link 2>&1)
[[ "$LINK_OUT" == *"pinSHA256=${PIN}"* ]] && t_ok "vpn-admin link: ссылки содержат правильный pinSHA256" \
    || t_fail "vpn-admin link: нет pinSHA256=${PIN}"
[[ "$LINK_OUT" == *"hysteria2://"* && "$LINK_OUT" == *"mport=443,20000-50000"* ]] \
    && t_ok "vpn-admin link: есть официальная ссылка и ссылка с mport" || t_fail "vpn-admin link: не все типы ссылок"

STATUS_OUT=$(vpn-admin status 2>&1)
[[ "$STATUS_OUT" == *"РАБОТАЕТ"* ]] && t_ok "vpn-admin status: служба работает" || t_fail "vpn-admin status: ${STATUS_OUT}"

HELP_OUT=$(vpn-admin help 2>&1)
[[ "$HELP_OUT" == *"add-domain"* && "$HELP_OUT" == *"upgrade"* ]] && t_ok "vpn-admin help" || t_fail "vpn-admin help"

vpn-admin no-such-command > /dev/null 2>&1
RC=$?
[[ $RC -eq 2 ]] && t_ok "неизвестная команда → код 2" || t_fail "неизвестная команда: код ${RC}"

HASH_BEFORE=$(config_hash)
vpn-admin add-domain 'bad domain)' > /dev/null 2>&1
RC=$?
[[ $RC -eq 2 && "$(config_hash)" == "$HASH_BEFORE" ]] && t_ok "add-domain: некорректный домен отклонён, конфиг не тронут" \
    || t_fail "add-domain с некорректным доменом: код ${RC}"

vpn-admin password 'bad/pass&word' > /dev/null 2>&1
RC=$?
[[ $RC -eq 2 && "$(config_hash)" == "$HASH_BEFORE" ]] && t_ok "password: опасный пароль отклонён, конфиг не тронут" \
    || t_fail "password с опасным паролем: код ${RC}"

ORIGINAL_PASSWORD=$(get_auth_password "$CONFIG")
BACKUPS_BEFORE=$(find "$BACKUP_DIR" -maxdepth 1 -name 'config_*.yaml' 2>/dev/null | wc -l)
if vpn-admin password 'Integration_Test_42' > /dev/null 2>&1; then
    [[ "$(get_auth_password "$CONFIG")" == "Integration_Test_42" ]] && t_ok "password: пароль сменён" \
        || t_fail "password: пароль в конфиге не изменился"
else
    t_fail "password: смена корректного пароля не удалась"
fi
t_check "после смены пароля служба активна" wait_service_active
BACKUPS_AFTER=$(find "$BACKUP_DIR" -maxdepth 1 -name 'config_*.yaml' 2>/dev/null | wc -l)
(( BACKUPS_AFTER > BACKUPS_BEFORE )) && t_ok "перед изменением создан бэкап" || t_fail "бэкап не создан"
[[ "$(file_mode_owner "$CONFIG")" == "640 root:hysteria" ]] && t_ok "права конфига сохранились после правки" \
    || t_fail "права конфига изменились: $(file_mode_owner "$CONFIG")"
vpn-admin password "$ORIGINAL_PASSWORD" > /dev/null 2>&1 && t_ok "исходный пароль возвращён" || t_fail "не удалось вернуть пароль"

if [[ "$WARP_ACTIVE" == true ]]; then
    vpn-admin test-ai > "${WORK_DIR}/test-ai.log" 2>&1 && t_ok "vpn-admin test-ai" \
        || t_fail "vpn-admin test-ai: $(cat "${WORK_DIR}/test-ai.log")"
fi

# ============================================================
t_section "4. Автооткат при сломанном конфиге"
# ============================================================

HASH_BEFORE=$(config_hash)
apply_config_change "integration_rollback" break_config_for_test > /dev/null 2>&1
RC=$?
[[ $RC -ne 0 ]] && t_ok "сломанная правка не применена (код ${RC})" || t_fail "сломанная правка «прошла»"
[[ "$(config_hash)" == "$HASH_BEFORE" ]] && t_ok "конфиг восстановлен из бэкапа" || t_fail "конфиг НЕ восстановлен"
t_check "служба снова активна после отката" wait_service_active

# ============================================================
t_section "5. Реальный туннель: клиент в отдельном netns"
# ============================================================

if ! setup_netns; then
    t_fail "не удалось создать netns для клиента"
else
    t_ok "netns ${NETNS}: клиент ${CLIENT_IP} → сервер ${HOST_IP}"

    # 5.1 Ссылка port hopping + pin (hy2://...:443?...&pinSHA256=...)
    if start_client "$(link_for porthop)"; then
        TRACE=$(trace_via_client hostname)
        [[ "$(warp_state "$TRACE")" != "none" ]] && t_ok "ссылка porthop (порт 443 + pinSHA256): трафик идёт" \
            || t_fail "ссылка porthop: нет ответа через туннель"
    else
        t_fail "ссылка porthop: клиент не подключился: $(tail -n 5 "${WORK_DIR}/client.log")"
    fi

    # 5.2 Официальная ссылка: диапазон портов в адресе → клиент шлёт пакеты на
    # случайные порты 20000-50000, сервер получает их только благодаря NAT-правилу
    if start_client "$(link_for official)"; then
        TRACE=$(trace_via_client hostname)
        [[ "$(warp_state "$TRACE")" != "none" ]] && t_ok "официальная ссылка (port hopping через NAT): трафик идёт" \
            || t_fail "официальная ссылка: нет ответа через туннель"
    else
        t_fail "официальная ссылка: клиент не подключился: $(tail -n 5 "${WORK_DIR}/client.log")"
    fi

    # 5.3 Только диапазон, без 443 — однозначно проверяет NAT-редирект
    HOP_ONLY_LINK="hysteria2://$(get_auth_password "$CONFIG")@${HOST_IP}:${HOP_PORT_START}-${HOP_PORT_END}/?insecure=1&pinSHA256=${PIN}"
    if start_client "$HOP_ONLY_LINK"; then
        TRACE=$(trace_via_client hostname)
        [[ "$(warp_state "$TRACE")" != "none" ]] && t_ok "только порты ${HOP_PORT_START}-${HOP_PORT_END}: NAT-редирект работает" \
            || t_fail "только диапазон портов: нет ответа"
    else
        t_fail "только диапазон портов: клиент не подключился: $(tail -n 5 "${WORK_DIR}/client.log")"
    fi

    # 5.4 Чужой сертификат (неверный pin) — клиент обязан отказаться
    WRONG_LINK="$(link_for standard)"
    WRONG_LINK="${WRONG_LINK/pinSHA256=${PIN}/pinSHA256=${WRONG_PIN}}"
    if start_client "$WRONG_LINK"; then
        TRACE=$(trace_via_client hostname)
        [[ "$(warp_state "$TRACE")" == "none" ]] && t_ok "неверный pinSHA256: соединение отвергнуто" \
            || t_fail "неверный pinSHA256: клиент подключился к «чужому» серверу!"
    else
        t_ok "неверный pinSHA256: клиент отказался подключаться"
    fi

    # 5.5 Неверный пароль — сервер обязан отказать
    CURRENT_PASSWORD=$(get_auth_password "$CONFIG")
    BAD_AUTH_LINK="$(link_for standard)"
    BAD_AUTH_LINK="${BAD_AUTH_LINK/${CURRENT_PASSWORD}@/WrongPassword123@}"
    if start_client "$BAD_AUTH_LINK"; then
        TRACE=$(trace_via_client hostname)
        [[ "$(warp_state "$TRACE")" == "none" ]] && t_ok "неверный пароль: доступ запрещён" \
            || t_fail "неверный пароль: сервер пустил клиента!"
    else
        t_ok "неверный пароль: сервер отказал в подключении"
    fi
    stop_client

    # 5.6 WARP + sniffing: главная проверка исправления для TUN-клиентов
    if [[ "$WARP_ACTIVE" == true ]]; then
        TRACE_IP=$(getent ahostsv4 "$TRACE_HOST" | awk 'NR == 1 { print $1 }')
        if vpn-admin add-domain "$TEST_DOMAIN" > /dev/null 2>&1 && acl_has_domain "$CONFIG" "$TEST_DOMAIN"; then
            t_ok "vpn-admin add-domain ${TEST_DOMAIN}"
        else
            t_fail "vpn-admin add-domain ${TEST_DOMAIN} не сработал"
        fi
        t_check "служба активна после add-domain" wait_service_active

        if start_client "$(link_for porthop)"; then
            STATE=$(warp_state "$(trace_via_client hostname)")
            [[ "$STATE" == "on" ]] && t_ok "по имени сайта (прокси-режим): трафик через WARP" \
                || t_fail "по имени сайта: ожидали warp=on, получили ${STATE}"
            STATE=$(warp_state "$(trace_via_client ip)")
            [[ "$STATE" == "on" ]] && t_ok "только IP (как TUN-режим): sniffing направил трафик через WARP" \
                || t_fail "только IP (TUN): ожидали warp=on, получили ${STATE} — sniffing не работает"
        else
            t_fail "клиент не подключился для теста WARP"
        fi

        # Отрицательный контроль: без sniffing IP-запросы должны идти мимо WARP.
        # Это доказывает, что предыдущая проверка прошла именно благодаря sniffing.
        if apply_config_change "integration_sniff_off" disable_sniff_for_test > /dev/null 2>&1; then
            if start_client "$(link_for porthop)"; then
                STATE=$(warp_state "$(trace_via_client ip)")
                [[ "$STATE" == "off" ]] && t_ok "контроль: без sniffing IP-запрос идёт мимо WARP (как было до исправления)" \
                    || t_fail "контроль без sniffing: ожидали warp=off, получили ${STATE}"
            else
                t_fail "клиент не подключился для контроля без sniffing"
            fi
        else
            t_fail "не удалось временно выключить sniffing"
        fi

        # upgrade обязан включить выключенный sniffing обратно
        vpn-admin upgrade -y > "${WORK_DIR}/upgrade.log" 2>&1
        sniff_is_enabled "$CONFIG" && t_ok "vpn-admin upgrade снова включил sniffing" \
            || t_fail "vpn-admin upgrade не включил sniffing: $(cat "${WORK_DIR}/upgrade.log")"
        t_check "служба активна после upgrade" wait_service_active

        if vpn-admin remove-domain "$TEST_DOMAIN" > /dev/null 2>&1 && ! acl_has_domain "$CONFIG" "$TEST_DOMAIN"; then
            t_ok "vpn-admin remove-domain ${TEST_DOMAIN}"
        else
            t_fail "vpn-admin remove-domain ${TEST_DOMAIN} не сработал"
        fi
        if start_client "$(link_for porthop)"; then
            STATE=$(warp_state "$(trace_via_client hostname)")
            [[ "$STATE" == "off" ]] && t_ok "после remove-domain сайт идёт напрямую" \
                || t_fail "после remove-domain: ожидали warp=off, получили ${STATE}"
        fi
        stop_client
    else
        t_skip "WARP недоступен — проверка sniffing/ACL через туннель пропущена"
    fi
fi

# ============================================================
t_section "6. Healthcheck"
# ============================================================

/usr/local/bin/vpn-healthcheck
RC=$?
[[ $RC -eq 0 ]] && t_ok "vpn-healthcheck завершился успешно" || t_fail "vpn-healthcheck: код ${RC}"
systemctl stop "$SERVICE"
/usr/local/bin/vpn-healthcheck
t_check "vpn-healthcheck поднял остановленный Hysteria" wait_service_active

# ============================================================
t_section "7. vpn-admin upgrade старого конфига (как на живом сервере)"
# ============================================================

SAVED_CONFIG="${WORK_DIR}/config.saved.yaml"
cp -p "$CONFIG" "$SAVED_CONFIG"
legacy_config "$(get_auth_password "$CONFIG")" > "${WORK_DIR}/legacy.yaml"
cat "${WORK_DIR}/legacy.yaml" > "$CONFIG"
systemctl restart "$SERVICE"
t_check "служба работает со старым конфигом" wait_service_active

vpn-admin upgrade -y > "${WORK_DIR}/upgrade.log" 2>&1
RC=$?
[[ $RC -eq 0 ]] && t_ok "vpn-admin upgrade -y завершился успешно" || t_fail "upgrade: код ${RC}: $(cat "${WORK_DIR}/upgrade.log")"
t_check "после upgrade: sniffing включён" sniff_is_enabled "$CONFIG"
MISSING=""
for domain in "${RECOMMENDED_WARP_DOMAINS[@]}"; do
    acl_has_domain "$CONFIG" "$domain" || MISSING+=" ${domain}"
done
[[ -z "$MISSING" ]] && t_ok "после upgrade: все рекомендуемые домены на месте" || t_fail "после upgrade нет:${MISSING}"
t_check "после upgrade: YAML валиден, дублей нет" yaml_is_valid_without_duplicates
t_check "после upgrade: служба активна" wait_service_active
AGAIN=$(vpn-admin upgrade -y 2>&1)
[[ "$AGAIN" == *"уже актуален"* ]] && t_ok "повторный upgrade: изменений нет" || t_fail "повторный upgrade что-то меняет"

cat "$SAVED_CONFIG" > "$CONFIG"
systemctl restart "$SERVICE"
t_check "исходный конфиг возвращён, служба активна" wait_service_active

# ============================================================
t_section "8. Повторный запуск setup.sh (идемпотентность)"
# ============================================================

if config_has_acl "$CONFIG"; then
    vpn-admin add-domain "$CUSTOM_DOMAIN" > /dev/null 2>&1 || t_fail "не удалось добавить ${CUSTOM_DOMAIN}"
fi
PASSWORD_BEFORE=$(get_auth_password "$CONFIG")
PIN_BEFORE=$(cert_pin "$CERT_FILE")

if bash "${REPO_DIR}/setup.sh" > "${WORK_DIR}/setup-rerun.log" 2>&1; then
    t_ok "повторный setup.sh завершился успешно"
else
    t_fail "повторный setup.sh упал: $(tail -n 20 "${WORK_DIR}/setup-rerun.log")"
fi
[[ "$(get_auth_password "$CONFIG")" == "$PASSWORD_BEFORE" ]] && t_ok "пароль сохранён (клиенты не отключились)" \
    || t_fail "пароль изменился после повторного setup.sh"
[[ "$(cert_pin "$CERT_FILE")" == "$PIN_BEFORE" ]] && t_ok "сертификат сохранён (pinSHA256 в ссылках актуален)" \
    || t_fail "сертификат пересоздан — старые ссылки сломаны"
if config_has_acl "$CONFIG"; then
    acl_has_domain "$CONFIG" "$CUSTOM_DOMAIN" && t_ok "домен, добавленный вручную (${CUSTOM_DOMAIN}), сохранён" \
        || t_fail "повторный setup.sh стёр домен ${CUSTOM_DOMAIN}"
fi
BEFORE_RULES=$(grep -c -- "--dport ${HOP_PORT_START}:${HOP_PORT_END} -j REDIRECT" /etc/ufw/before.rules || true)
[[ "$BEFORE_RULES" == "1" ]] && t_ok "before.rules: NAT-правило не задублировано" || t_fail "before.rules: правил ${BEFORE_RULES}"
NAT_RULES=$(iptables -t nat -S PREROUTING | grep -c -- "--dport ${HOP_PORT_START}:${HOP_PORT_END}" || true)
[[ "$NAT_RULES" == "1" ]] && t_ok "iptables: NAT-правило не задублировано" || t_fail "iptables: правил ${NAT_RULES}"
CRON_LINES=$(crontab -l 2>/dev/null | grep -c 'vpn-healthcheck' || true)
[[ "$CRON_LINES" == "1" ]] && t_ok "cron: healthcheck не задублирован" || t_fail "cron: строк ${CRON_LINES}"
t_check "служба активна после повторной установки" wait_service_active
t_check "YAML валиден после повторной установки" yaml_is_valid_without_duplicates

# ============================================================
echo ""
echo "=== ИТОГ: пройдено ${PASSED}, провалено ${FAILURES} ==="
if (( FAILURES > 0 )); then
    exit 1
fi
exit 0
