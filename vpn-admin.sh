#!/bin/bash
# ============================================================
# 🛡️ VPN Admin Panel (Enterprise Edition)
# Интерактивная консольная панель управления Hysteria2 VPN
# Поддержка: BBR, Cloudflare WARP SOCKS5, Port Hopping, Тест ИИ
# GitHub: https://github.com/Fulsepredict/Admin_vpn
# ============================================================

set -e

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# === Пути и константы ===
CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server"
WARP_SERVICE="warp-svc"
WARP_PORT=40000
BACKUP_DIR="/etc/hysteria/backups"
LOG_FILE="/var/log/vpn-admin.log"

# ============================================================
# Вспомогательные функции
# ============================================================

log_action() {
    local action="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $action" >> "$LOG_FILE" 2>/dev/null || true
}

header() {
    clear
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

pause() {
    echo ""
    echo -ne "  ${DIM}Нажми Enter чтобы продолжить...${NC}"
    read -r
}

get_ip() {
    local ip
    ip=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || \
         curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null || \
         curl -s -4 --connect-timeout 5 api.ipify.org 2>/dev/null || \
         hostname -I | awk '{print $1}')
    echo "$ip" | tr -d ' \r\n'
}

get_password() {
    if [[ -f "$CONFIG" ]]; then
        grep "password:" "$CONFIG" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'"
    else
        echo "НЕТ_КОНФИГА"
    fi
}

status_line() {
    local label="$1"
    local value="$2"
    printf "  %-24s %b\n" "$label" "$value"
}

# ============================================================
# Команды меню
# ============================================================

# 1. Статус сервера
show_status() {
    header "📊 Статус Hysteria 2 VPN"

    # Статус службы Hysteria
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        local pid
        pid=$(systemctl show --property MainPID --value "$SERVICE" 2>/dev/null || echo "N/A")
        status_line "Hysteria 2:" "${GREEN}● РАБОТАЕТ${NC} (PID: ${pid})"
    else
        status_line "Hysteria 2:" "${RED}● ОСТАНОВЛЕН${NC}"
    fi

    # Статус Cloudflare WARP
    if systemctl is-active --quiet "$WARP_SERVICE" 2>/dev/null; then
        if curl -s -x socks5h://127.0.0.1:${WARP_PORT} --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
            status_line "Cloudflare WARP:" "${GREEN}● АКТИВЕН${NC} (SOCKS5 127.0.0.1:${WARP_PORT}, warp=on)"
        else
            status_line "Cloudflare WARP:" "${YELLOW}● ЗАПУЩЕН${NC} (проверяется соединение...)"
        fi
    else
        status_line "Cloudflare WARP:" "${YELLOW}○ НЕ ИСПОЛЬЗУЕТСЯ${NC} (прямое подключение)"
    fi

    # Статус BBR
    local bbr_status
    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$bbr_status" == "bbr" ]]; then
        status_line "Google BBR:" "${GREEN}● ВКЛЮЧЕН${NC} (быстрый стек TCP/UDP)"
    else
        status_line "Google BBR:" "${YELLOW}● ${bbr_status}${NC}"
    fi

    # Статус Port Hopping
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "20000:50000"; then
        status_line "Port Hopping:" "${GREEN}● АКТИВЕН${NC} (20000-50000 UDP -> 443)"
    else
        status_line "Port Hopping:" "${YELLOW}● НЕ НАСТРОЕН${NC}"
    fi

    echo ""
    # Системные ресурсы
    local cpu_usage
    cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4}' || echo "0")
    status_line "Загрузка CPU:" "${cpu_usage}%"

    local mem_total mem_used
    mem_total=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "N/A")
    mem_used=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3}' || echo "N/A")
    status_line "Оперативная память:" "${mem_used} / ${mem_total}"

    local disk_used disk_total disk_pct
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")
    disk_total=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")
    disk_pct=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "N/A")
    status_line "Диск (/):" "${disk_used} / ${disk_total} (${disk_pct})"

    # Активные подключения Hysteria (UDP 443)
    local conns
    conns=$(ss -u -a '( dport = :443 or sport = :443 )' 2>/dev/null | grep -v "State" | wc -l || echo "0")
    status_line "Подключения UDP:" "${CYAN}${conns}${NC}"

    pause
}

# 2. Логи
show_logs() {
    header "📋 Логи Hysteria 2"
    echo -e "  ${DIM}(показываются последние 40 строк, 'q' для выхода)${NC}\n"
    journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null || echo "Логи недоступны"
    pause
}

# 3. Смена пароля (с сохранением отступа YAML!)
change_password() {
    header "🔑 Смена пароля VPN"

    local old_pass
    old_pass=$(get_password)
    echo -e "  Текущий пароль: ${DIM}${old_pass}${NC}\n"

    echo -ne "  Сгенерировать случайный надёжный пароль? ${BOLD}(y/n)${NC}: "
    read -r gen_auto

    local new_pass=""
    if [[ "$gen_auto" == "y" || "$gen_auto" == "Y" ]]; then
        new_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
    else
        echo -ne "  Введи новый пароль (минимум 8 символов): "
        read -r new_pass
        if [[ ${#new_pass} -lt 8 ]]; then
            echo -e "\n  ${RED}❌ Пароль слишком короткий!${NC}"
            pause
            return
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    cp "$CONFIG" "${BACKUP_DIR}/config_before_pwd_$(date +%s).yaml"

    # Сохраняем ровно 2 пробела отступа в YAML!
    sed -i "s/^[[:space:]]*password:.*/  password: ${new_pass}/" "$CONFIG"

    systemctl restart "$SERVICE" 2>/dev/null || true

    echo ""
    echo -e "  ${GREEN}✅ Пароль успешно изменён!${NC}"
    echo -e "  Новый пароль: ${BOLD}${new_pass}${NC}"

    log_action "PASSWORD_CHANGED"
    pause
}

# 4. Показать ссылки
show_link() {
    header "🔗 Ссылки для подключения"

    local ip pass
    ip=$(get_ip)
    pass=$(get_password)

    local link_hop="hy2://${pass}@${ip}:443?insecure=1&alpn=h3&mport=443,20000-50000#Hysteria2-PortHop"
    local link_std="hy2://${pass}@${ip}:443?insecure=1&alpn=h3#Hysteria2"

    echo -e "  ${BOLD}1. Рекомендуемая ссылка (со скачущими портами, обход глушилок):${NC}"
    echo -e "  ${CYAN}${link_hop}${NC}\n"

    echo -e "  ${BOLD}2. Стандартная ссылка (порт 443):${NC}"
    echo -e "  ${DIM}${link_std}${NC}\n"

    echo -e "  ${DIM}Клиенты: NekoBox, Hiddify, v2rayN, Streisand, Shadowrocket${NC}"
    pause
}

# 5. Тест обхода антифрода (ChatGPT / Claude / WARP)
test_ai() {
    header "🧪 Тест обхода антифрода (ChatGPT / Claude)"

    echo -e "  ${YELLOW}Проверяем статус Cloudflare WARP SOCKS5...${NC}"
    local warp_trace
    warp_trace=$(curl -s -x socks5h://127.0.0.1:${WARP_PORT} --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)

    if echo "$warp_trace" | grep -q "warp=on"; then
        local warp_ip warp_loc
        warp_ip=$(echo "$warp_trace" | grep "^ip=" | cut -d= -f2)
        warp_loc=$(echo "$warp_trace" | grep "^loc=" | cut -d= -f2)
        echo -e "  ${GREEN}✅ Cloudflare WARP работает идеально!${NC}"
        echo -e "  Выходной IP для ИИ: ${CYAN}${warp_ip}${NC} (Страна: ${warp_loc})\n"

        echo -e "  ${YELLOW}Проверяем доступность доменов OpenAI & Claude через WARP...${NC}"
        local chatgpt_code
        chatgpt_code=$(curl -s -o /dev/null -w "%{http_code}" -x socks5h://127.0.0.1:${WARP_PORT} --connect-timeout 6 https://chatgpt.com 2>/dev/null || echo "000")
        if [[ "$chatgpt_code" == "200" || "$chatgpt_code" == "301" || "$chatgpt_code" == "302" || "$chatgpt_code" == "403" ]]; then
            echo -e "  ChatGPT (chatgpt.com):   ${GREEN}✅ Доступен (HTTP $chatgpt_code)${NC}"
        else
            echo -e "  ChatGPT (chatgpt.com):   ${YELLOW}⚠ Ответ: HTTP $chatgpt_code${NC}"
        fi

        local claude_code
        claude_code=$(curl -s -o /dev/null -w "%{http_code}" -x socks5h://127.0.0.1:${WARP_PORT} --connect-timeout 6 https://claude.ai 2>/dev/null || echo "000")
        if [[ "$claude_code" == "200" || "$claude_code" == "301" || "$claude_code" == "302" ]]; then
            echo -e "  Claude  (claude.ai):     ${GREEN}✅ Доступен (HTTP $claude_code)${NC}"
        else
            echo -e "  Claude  (claude.ai):     ${YELLOW}⚠ Ответ: HTTP $claude_code${NC}"
        fi
    else
        echo -e "  ${YELLOW}○ Cloudflare WARP не активен на 127.0.0.1:${WARP_PORT}.${NC}"
        echo -e "  Все запросы идут напрямую через основной IP сервера.\n"
        
        echo -e "  ${YELLOW}Проверяем прямой доступ к ChatGPT...${NC}"
        local direct_code
        direct_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://chatgpt.com 2>/dev/null || echo "000")
        echo -e "  Прямой ответ ChatGPT: HTTP ${direct_code}"
    fi

    pause
}

# 6. Перезапуск
restart_server() {
    header "🔄 Перезапуск VPN и WARP"
    echo -e "  ${YELLOW}Перезапуск Hysteria 2...${NC}"
    systemctl restart "$SERVICE" 2>/dev/null || true
    echo -e "  ${YELLOW}Перезапуск Cloudflare WARP...${NC}"
    systemctl restart "$WARP_SERVICE" 2>/dev/null || true
    echo ""
    echo -e "  ${GREEN}✅ Все сервисы успешно перезапущены!${NC}"
    log_action "SERVICES_RESTARTED"
    pause
}

# 7. Стоп / Старт
toggle_server() {
    header "⏯️ Стоп / Старт Hysteria 2"
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo -ne "  Остановить VPN? ${BOLD}(y/n)${NC}: "
        read -r conf
        if [[ "$conf" == "y" || "$conf" == "Y" ]]; then
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
    echo -e "  ${DIM}Текущая версия:${NC}"
    hysteria version 2>/dev/null || echo "  не определена"
    echo ""
    echo -ne "  Начать обновление до последней версии? ${BOLD}(y/n)${NC}: "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${DIM}Отменено.${NC}"
        pause
        return
    fi

    echo -e "\n  ${YELLOW}Скачиваю последнюю версию...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/) 2>&1
    systemctl restart "$SERVICE" 2>/dev/null || true
    echo ""
    echo -e "  ${GREEN}✅ Hysteria 2 обновлена и перезапущена!${NC}"
    log_action "HYSTERIA_UPDATED"
    pause
}

# 9. Бэкап
backup_config() {
    header "💾 Бэкап конфигурации"
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/config_$(date +%Y%m%d_%H%M%S).yaml"
    cp "$CONFIG" "$backup_file" 2>/dev/null || true

    echo -e "  ${GREEN}✅ Бэкап сохранён:${NC}"
    echo -e "  ${CYAN}${backup_file}${NC}\n"
    echo -e "  ${BOLD}Список всех бэкапов:${NC}"
    ls -lh "$BACKUP_DIR"/*.yaml 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
    log_action "BACKUP_CREATED: ${backup_file}"
    pause
}

# 10. Системная информация
system_info() {
    header "🖥️ Информация о системе"
    status_line "ОС:" "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    status_line "Ядро Linux:" "$(uname -r)"
    status_line "TCP Congestion:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
    status_line "IPv4:" "$(get_ip)"
    status_line "IPv6:" "$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | head -1 || echo 'нет')"
    echo ""
    echo -e "  ${BOLD}Файрвол (UFW):${NC}"
    ufw status 2>/dev/null | grep -v "^$" | head -12 | while read -r line; do
        echo "    $line"
    done
    echo ""
    echo -e "  ${BOLD}Fail2ban:${NC}"
    fail2ban-client status sshd 2>/dev/null | while read -r line; do
        echo "    $line"
    done
    pause
}

# 11. Миграция
migration() {
    header "🚚 Миграция / Смена IP"
    local ip
    ip=$(get_ip)
    echo -e "  ${BOLD}Текущий IP:${NC} ${CYAN}${ip}${NC}\n"
    echo -e "  ${BOLD}Как развернуть чистый Enterprise VPN на новом сервере:${NC}\n"
    echo -e "  ${DIM}1.${NC} Купи новый VPS (Ubuntu 20.04 / 22.04 / 24.04)"
    echo -e "  ${DIM}2.${NC} Подключись по SSH"
    echo -e "  ${DIM}3.${NC} Вставь одну команду:\n"
    echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/setup.sh)${NC}\n"
    echo -e "  ${DIM}4.${NC} Скопируй полученную ссылку в клиент — и всё летает!"
    pause
}

# ============================================================
# Главный цикл
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запусти от root (sudo vpn-admin)${NC}"
    exit 1
fi

if [[ -n "$1" ]]; then
    case "$1" in
        status)    show_status ;;
        logs)      show_logs ;;
        password)  change_password ;;
        link)      show_link ;;
        test-ai)   test_ai ;;
        restart)   restart_server ;;
        toggle)    toggle_server ;;
        update)    update_hysteria ;;
        backup)    backup_config ;;
        info)      system_info ;;
        migrate)   migration ;;
        *)         echo "Использование: vpn-admin {status|logs|password|link|test-ai|restart|toggle|update|backup|info|migrate}" ;;
    esac
    exit 0
fi

while true; do
    clear
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        local_status="${GREEN}● РАБОТАЕТ${NC}"
    else
        local_status="${RED}● ОСТАНОВЛЕН${NC}"
    fi

    echo ""
    echo -e "${CYAN}  ╔═════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║${NC}  ${BOLD}🛡️  VPN Admin Panel (Enterprise)${NC}        ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}  ${DIM}Hysteria2 + WARP + BBR${NC}        ${local_status}  ${CYAN}║${NC}"
    echo -e "${CYAN}  ╠═════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}  ║${NC}                                             ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}1${NC} │ 📊  Статус сервера и WARP          ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}2${NC} │ 📋  Логи Hysteria 2                ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}3${NC} │ 🔑  Сменить пароль                 ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}4${NC} │ 🔗  Показать ссылки (Port Hopping) ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}5${NC} │ 🧪  Тест обхода антифрода (ИИ)     ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}6${NC} │ 🔄  Перезапуск сервисов            ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}7${NC} │ ⏯️   Стоп / Старт                   ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}8${NC} │ ⬆️   Обновить Hysteria 2            ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}9${NC} │ 💾  Бэкап конфига                  ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}  ${BOLD}10${NC} │ 🖥️   Инфо о системе и BBR           ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}  ${BOLD}11${NC} │ 🚚  Миграция / Справка             ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}                                             ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${RED}0${NC} │ 🚪  Выход                          ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}                                             ${CYAN}║${NC}"
    echo -e "${CYAN}  ╚═════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "  ${BOLD}Выбери пункт [0-11]: ${NC}"
    read -r choice

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
        0) echo -e "\n  ${DIM}👋 До встречи!${NC}\n"; exit 0 ;;
        *) echo -e "\n  ${RED}Неверный выбор. Попробуй ещё раз.${NC}"; sleep 1 ;;
    esac
done
