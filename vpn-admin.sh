#!/bin/bash
# ============================================================
# 🛡️ VPN Admin Panel — интерактивное управление Hysteria2 VPN
# GitHub: https://github.com/Fulsepredict/Admin_vpn
# ============================================================

# === Цвета для терминала ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# === Конфигурация (пути к файлам Hysteria2) ===
CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server"
BACKUP_DIR="/root/vpn-backups"
LOG_FILE="/var/log/vpn-admin.log"

# ============================================================
# Вспомогательные функции
# ============================================================

# Красивый заголовок секции
header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Статусная строка: зелёная если ОК, красная если нет
status_line() {
    local label="$1"
    local value="$2"
    local color="${3:-$NC}"
    printf "  ${DIM}%-20s${NC} ${color}%s${NC}\n" "$label" "$value"
}

# Пауза перед возвратом в меню
pause() {
    echo ""
    echo -e "${DIM}  Нажми Enter чтобы вернуться в меню...${NC}"
    read -r
}

# Записать действие в лог
log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Получить текущий пароль из конфига
get_password() {
    grep 'password:' "$CONFIG" | tail -1 | awk '{print $2}'
}

# Получить внешний IPv4 адрес сервера
get_ip() {
    curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null
}

# ============================================================
# Пункты меню
# ============================================================

# 1. Статус сервера — показывает состояние и ресурсы
show_status() {
    header "📊 Статус сервера"

    # Проверяем запущен ли сервис Hysteria2
    if systemctl is-active --quiet "$SERVICE"; then
        status_line "Hysteria2:" "● РАБОТАЕТ" "$GREEN"
    else
        status_line "Hysteria2:" "● ОСТАНОВЛЕН" "$RED"
    fi

    # Время работы сервера с последней перезагрузки
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null || uptime)
    status_line "Аптайм:" "$uptime_info"

    # Использование оперативной памяти
    local mem_used mem_total
    mem_used=$(free -h | awk '/Mem:/ {print $3}')
    mem_total=$(free -h | awk '/Mem:/ {print $2}')
    status_line "RAM:" "${mem_used} / ${mem_total}"

    # Использование диска
    local disk_info
    disk_info=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
    status_line "Диск:" "$disk_info"

    # Нагрузка на процессор (средняя за 1/5/15 минут)
    local load
    load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    status_line "Нагрузка CPU:" "$load"

    # Текущие подключения к VPN (по количеству UDP-соединений)
    local connections
    connections=$(ss -up | grep -c hysteria 2>/dev/null || echo "0")
    status_line "Подключения:" "$connections"

    # Внешний IP-адрес сервера
    local ip
    ip=$(get_ip)
    status_line "IP:" "${ip:-не определён}"

    # Сколько заблокировано ботов файрволом fail2ban
    local banned
    banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
    status_line "Забанено IP:" "${banned:-fail2ban не найден}"

    pause
}

# 2. Просмотр логов — показывает последние записи журнала
show_logs() {
    header "📋 Логи Hysteria2"
    echo ""
    echo -e "  ${DIM}Сколько строк показать? (по умолчанию 30):${NC}"
    read -r lines
    lines=${lines:-30}
    echo ""

    # journalctl — системная утилита для чтения логов сервиса
    journalctl -u "$SERVICE" --no-pager -n "$lines" --output=short-iso
    pause
}

# 3. Смена пароля — генерирует новый пароль и перезапускает VPN
change_password() {
    header "🔑 Смена пароля VPN"

    local old_pass
    old_pass=$(get_password)
    echo -e "  Текущий пароль: ${DIM}${old_pass}${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ После смены пароля все клиенты отключатся!${NC}"
    echo -e "  ${YELLOW}  Нужно будет обновить ссылку на всех устройствах.${NC}"
    echo ""
    echo -e "  Продолжить? ${BOLD}(y/n)${NC}: "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${DIM}Отменено.${NC}"
        pause
        return
    fi

    # Генерация нового случайного пароля:
    # openssl rand -base64 24 → случайные байты → base64
    # tr -d '/+=' → убираем спецсимволы (чтобы не ломать URL)
    # head -c 24 → берём первые 24 символа
    local new_pass
    new_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

    # Подставляем новый пароль в конфиг через sed
    sed -i "s|password:.*|password: ${new_pass}|" "$CONFIG"

    # Перезапускаем сервис чтобы применить изменения
    systemctl restart "$SERVICE"

    local ip
    ip=$(get_ip)
    local link="hy2://${new_pass}@${ip}:443?insecure=1&alpn=h3#Hysteria2"

    echo ""
    echo -e "  ${GREEN}✅ Пароль изменён!${NC}"
    echo ""
    echo -e "  ${BOLD}Новая ссылка:${NC}"
    echo -e "  ${CYAN}${link}${NC}"
    echo ""
    echo -e "  ${DIM}Скопируй ссылку и обнови на всех устройствах!${NC}"

    log_action "PASSWORD_CHANGED"
    pause
}

# 4. Показать ссылку — выводит текущую ссылку для подключения
show_link() {
    header "🔗 Ссылка для подключения"

    local pass ip link
    pass=$(get_password)
    ip=$(get_ip)
    link="hy2://${pass}@${ip}:443?insecure=1&alpn=h3#Hysteria2"

    echo ""
    echo -e "  ${BOLD}Ссылка:${NC}"
    echo -e "  ${CYAN}${link}${NC}"
    echo ""
    echo -e "  ${DIM}Скопируй и вставь в NekoBox / Hiddify / Shadowrocket${NC}"
    pause
}

# 5. Перезапуск сервера — мягкая перезагрузка Hysteria2
restart_server() {
    header "🔄 Перезапуск Hysteria2"

    systemctl restart "$SERVICE"

    # Ждём секунду и проверяем, запустился ли сервис
    sleep 1
    if systemctl is-active --quiet "$SERVICE"; then
        echo -e "  ${GREEN}✅ Hysteria2 перезапущен успешно${NC}"
    else
        echo -e "  ${RED}❌ Ошибка! Hysteria2 не запустился${NC}"
        echo -e "  ${DIM}Проверь логи (пункт 2)${NC}"
    fi

    log_action "SERVER_RESTARTED"
    pause
}

# 6. Остановить / Запустить — переключатель
toggle_server() {
    header "⏯️ Остановка / Запуск"

    if systemctl is-active --quiet "$SERVICE"; then
        echo -e "  Сервер ${GREEN}работает${NC}. Остановить? ${BOLD}(y/n)${NC}: "
        read -r confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            systemctl stop "$SERVICE"
            echo -e "  ${RED}⏹ Остановлен${NC}"
            log_action "SERVER_STOPPED"
        fi
    else
        echo -e "  Сервер ${RED}остановлен${NC}. Запустить? ${BOLD}(y/n)${NC}: "
        read -r confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            systemctl start "$SERVICE"
            echo -e "  ${GREEN}▶ Запущен${NC}"
            log_action "SERVER_STARTED"
        fi
    fi
    pause
}

# 7. Обновить Hysteria2 — скачивает последнюю версию
update_hysteria() {
    header "⬆️ Обновление Hysteria2"

    echo -e "  ${DIM}Текущая версия:${NC}"
    # Получаем текущую версию Hysteria2
    hysteria version 2>/dev/null || echo "  не определена"
    echo ""
    echo -e "  Начать обновление? ${BOLD}(y/n)${NC}: "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${DIM}Отменено.${NC}"
        pause
        return
    fi

    echo -e "  ${YELLOW}Скачиваю последнюю версию...${NC}"

    # Официальный установщик Hysteria2
    bash <(curl -fsSL https://get.hy2.sh/) 2>&1

    systemctl restart "$SERVICE"
    echo ""
    echo -e "  ${GREEN}✅ Обновлено и перезапущено!${NC}"

    log_action "HYSTERIA_UPDATED"
    pause
}

# 8. Бэкап конфига — сохраняет копию с датой
backup_config() {
    header "💾 Бэкап конфигурации"

    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/config_${timestamp}.yaml"

    cp "$CONFIG" "$backup_file"

    echo -e "  ${GREEN}✅ Бэкап сохранён:${NC}"
    echo -e "  ${CYAN}${backup_file}${NC}"
    echo ""

    # Показываем все существующие бэкапы
    echo -e "  ${BOLD}Все бэкапы:${NC}"
    ls -lh "$BACKUP_DIR"/*.yaml 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'

    log_action "BACKUP_CREATED: ${backup_file}"
    pause
}

# 9. Информация о системе — подробная сводка
system_info() {
    header "🖥️ Информация о системе"

    status_line "ОС:" "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    status_line "Ядро:" "$(uname -r)"
    status_line "Hostname:" "$(hostname)"
    status_line "IPv4:" "$(get_ip)"
    status_line "IPv6:" "$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | head -1)"
    echo ""

    echo -e "  ${BOLD}Файрвол (UFW):${NC}"
    ufw status | grep -v "^$" | head -10 | while read -r line; do
        echo "    $line"
    done
    echo ""

    echo -e "  ${BOLD}Fail2ban:${NC}"
    fail2ban-client status sshd 2>/dev/null | while read -r line; do
        echo "    $line"
    done

    pause
}

# ============================================================
# Главное меню
# ============================================================

# Проверяем, что скрипт запущен от имени root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запусти от root (sudo vpn-admin)${NC}"
    exit 1
fi

# Если передан аргумент — выполняем команду напрямую (без меню)
# Это нужно для быстрых команд типа: vpn-admin status
if [[ -n "$1" ]]; then
    case "$1" in
        status)   show_status ;;
        logs)     show_logs ;;
        password) change_password ;;
        link)     show_link ;;
        restart)  restart_server ;;
        toggle)   toggle_server ;;
        update)   update_hysteria ;;
        backup)   backup_config ;;
        info)     system_info ;;
        *)        echo "Использование: vpn-admin {status|logs|password|link|restart|toggle|update|backup|info}" ;;
    esac
    exit 0
fi

# Главный цикл меню — показываем, пока пользователь не выберет "Выход"
while true; do
    clear

    # Определяем статус сервиса для отображения в заголовке
    if systemctl is-active --quiet "$SERVICE"; then
        local_status="${GREEN}● РАБОТАЕТ${NC}"
    else
        local_status="${RED}● ОСТАНОВЛЕН${NC}"
    fi

    # Рисуем меню
    echo ""
    echo -e "${CYAN}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║${NC}  ${BOLD}🛡️  VPN Admin Panel${NC}               ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}  ${DIM}Hysteria2 Management${NC}    ${local_status}  ${CYAN}║${NC}"
    echo -e "${CYAN}  ╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}  ║${NC}                                      ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}1${NC} │ 📊  Статус сервера            ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}2${NC} │ 📋  Логи                      ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}3${NC} │ 🔑  Сменить пароль            ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}4${NC} │ 🔗  Показать ссылку           ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}5${NC} │ 🔄  Перезапуск                ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}6${NC} │ ⏯️   Стоп / Старт              ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}7${NC} │ ⬆️   Обновить Hysteria2        ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}8${NC} │ 💾  Бэкап конфига             ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${BOLD}9${NC} │ 🖥️   Инфо о системе            ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}                                      ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}   ${RED}0${NC} │ 🚪  Выход                     ${CYAN}║${NC}"
    echo -e "${CYAN}  ║${NC}                                      ${CYAN}║${NC}"
    echo -e "${CYAN}  ╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "  ${BOLD}Выбери пункт [0-9]: ${NC}"
    read -r choice

    case "$choice" in
        1) show_status ;;
        2) show_logs ;;
        3) change_password ;;
        4) show_link ;;
        5) restart_server ;;
        6) toggle_server ;;
        7) update_hysteria ;;
        8) backup_config ;;
        9) system_info ;;
        0) echo -e "\n  ${DIM}👋 До встречи!${NC}\n"; exit 0 ;;
        *) echo -e "\n  ${RED}Неверный выбор. Попробуй ещё раз.${NC}"; sleep 1 ;;
    esac
done
