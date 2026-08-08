#!/bin/bash
# ============================================================
# 🚀 VPN Server Quick Setup
# Полная автоматическая установка Hysteria2 VPN за 2 минуты
# GitHub: https://github.com/Fulsepredict/Admin_vpn
# ============================================================

set -e

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# === Конфигурация ===
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
VPN_ADMIN_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}🚀 VPN Server Quick Setup${NC}               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${DIM}Hysteria2 + Firewall + Monitoring${NC}       ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# --- Проверяем что скрипт запущен от root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Запусти от root!${NC}"
    exit 1
fi

# --- Проверяем ОС ---
if ! command -v apt &> /dev/null; then
    echo -e "${RED}❌ Поддерживается только Ubuntu/Debian${NC}"
    exit 1
fi

# ============================================================
# Шаг 1: Обновление системы
# ============================================================
echo -e "${YELLOW}[1/7]${NC} Обновление системы..."
apt-get update -qq > /dev/null 2>&1
apt-get upgrade -y -qq > /dev/null 2>&1
echo -e "  ${GREEN}✅ Система обновлена${NC}"

# ============================================================
# Шаг 2: Установка необходимых пакетов
# ============================================================
echo -e "${YELLOW}[2/7]${NC} Установка пакетов..."
apt-get install -y -qq curl ufw fail2ban openssl unattended-upgrades > /dev/null 2>&1

# Включаем автоматические обновления безопасности
dpkg-reconfigure -f noninteractive unattended-upgrades > /dev/null 2>&1
echo -e "  ${GREEN}✅ curl, ufw, fail2ban, auto-updates${NC}"

# ============================================================
# Шаг 3: Установка Hysteria2
# ============================================================
echo -e "${YELLOW}[3/7]${NC} Установка Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
echo -e "  ${GREEN}✅ Hysteria2 установлен${NC}"

# ============================================================
# Шаг 4: Генерация сертификата и конфига
# ============================================================
echo -e "${YELLOW}[4/7]${NC} Настройка конфига..."

# Генерируем самоподписанный TLS-сертификат (для шифрования)
mkdir -p /etc/hysteria
openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key 2>/dev/null
openssl req -new -x509 -days 3650 -key /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt -subj "/CN=bing.com" 2>/dev/null

# Генерируем случайный пароль для VPN (24 символа, без спецсимволов)
VPN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

# Получаем внешний IPv4 адрес сервера
SERVER_IP=$(curl -s -4 --connect-timeout 10 ifconfig.me)

# Создаём конфигурацию Hysteria2
cat > "$HYSTERIA_CONFIG" << EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${VPN_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF

echo -e "  ${GREEN}✅ Сертификат + конфиг созданы${NC}"

# ============================================================
# Шаг 5: Настройка файрвола
# ============================================================
echo -e "${YELLOW}[5/7]${NC} Настройка файрвола..."

# Сбрасываем правила и ставим политику "запрещать всё входящее"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# Открываем только необходимые порты:
# 22/tcp — SSH (для управления сервером)
# 443/udp — Hysteria2 VPN
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 443/udp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
echo -e "  ${GREEN}✅ Файрвол: SSH + Hysteria2${NC}"

# ============================================================
# Шаг 6: Мониторинг и автоперезапуск
# ============================================================
echo -e "${YELLOW}[6/7]${NC} Настройка мониторинга..."

# Автоматический перезапуск Hysteria2 через systemd
mkdir -p /etc/systemd/system/hysteria-server.service.d/
cat > /etc/systemd/system/hysteria-server.service.d/restart.conf << EOF
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload

# Скрипт проверки здоровья — cron запускает каждые 5 минут
cat > /usr/local/bin/vpn-healthcheck << 'EOF'
#!/bin/bash
if ! systemctl is-active --quiet hysteria-server; then
  systemctl restart hysteria-server
  echo "$(date): restarted" >> /var/log/vpn-healthcheck.log
fi
EOF
chmod +x /usr/local/bin/vpn-healthcheck

# Добавляем в cron (каждые 5 минут проверяет, жив ли VPN)
(crontab -l 2>/dev/null | grep -v vpn-healthcheck; echo "*/5 * * * * /usr/local/bin/vpn-healthcheck") | crontab -

echo -e "  ${GREEN}✅ Автоперезапуск + healthcheck${NC}"

# ============================================================
# Шаг 7: Установка vpn-admin и запуск
# ============================================================
echo -e "${YELLOW}[7/7]${NC} Установка VPN Admin Panel..."

# Скачиваем vpn-admin из GitHub
curl -fsSL "$VPN_ADMIN_URL" -o /usr/local/bin/vpn-admin
chmod +x /usr/local/bin/vpn-admin
sed -i 's/\r$//' /usr/local/bin/vpn-admin

# Запускаем Hysteria2
systemctl enable hysteria-server > /dev/null 2>&1
systemctl start hysteria-server
echo -e "  ${GREEN}✅ vpn-admin установлен, Hysteria2 запущен${NC}"

# ============================================================
# Готово! Выводим результат
# ============================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}IP сервера:${NC}  ${SERVER_IP}"
echo -e "  ${BOLD}Пароль VPN:${NC}  ${VPN_PASSWORD}"
echo ""
echo -e "  ${BOLD}Ссылка для клиента:${NC}"
echo -e "  ${CYAN}hy2://${VPN_PASSWORD}@${SERVER_IP}:443?insecure=1&alpn=h3#Hysteria2${NC}"
echo ""
echo -e "  ${DIM}Скопируй ссылку в NekoBox / Hiddify / Shadowrocket${NC}"
echo ""
echo -e "  ${BOLD}Управление:${NC}"
echo -e "  ${DIM}vpn-admin${NC}          — интерактивное меню"
echo -e "  ${DIM}vpn-admin status${NC}   — быстрый статус"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
