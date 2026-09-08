#!/bin/bash
# ============================================================
# 🚀 VPN Server Quick Setup (Enterprise Edition)
# Полная автоматическая установка Hysteria2 VPN за 2 минуты:
# - BBR + FQ сетевой тюнинг ядра (максимальная скорость, мин. задержки)
# - UDP буферы 8MB (защита от потери пакетов)
# - Cloudflare WARP SOCKS5 (обход детектов ChatGPT, Claude, Netflix, Google)
# - Port Hopping 20000-50000 (защита от глушилок провайдеров)
# - UFW + Fail2ban + Healthcheck мониторинг
# - 100% совместимость с ботами на одном VPS (изолированный SOCKS5)
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
WARP_SOCKS_PORT=40000

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}🚀 VPN Server Quick Setup (Enterprise Edition)${NC}       ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${DIM}Hysteria2 + BBR + WARP SOCKS5 + Port Hopping${NC}         ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Проверяем что скрипт запущен от root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Запусти от root (sudo bash setup.sh)!${NC}"
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
echo -e "${YELLOW}[1/8]${NC} Обновление системы..."
apt-get update -qq > /dev/null 2>&1
apt-get upgrade -y -qq > /dev/null 2>&1
echo -e "  ${GREEN}✅ Система обновлена${NC}"

# ============================================================
# Шаг 2: Установка необходимых пакетов
# ============================================================
echo -e "${YELLOW}[2/8]${NC} Установка базовых утилит..."
apt-get install -y -qq curl ufw fail2ban openssl unattended-upgrades iptables lsb-release gpg > /dev/null 2>&1

dpkg-reconfigure -f noninteractive unattended-upgrades > /dev/null 2>&1
echo -e "  ${GREEN}✅ curl, ufw, fail2ban, iptables, auto-updates${NC}"

# ============================================================
# Шаг 3: Тюнинг сетевого стека ядра Linux (BBR + FQ + UDP 8MB)
# ============================================================
echo -e "${YELLOW}[3/8]${NC} Настройка BBR и UDP буферов ядра Linux..."

cat > /etc/sysctl.d/99-hysteria.conf << 'EOF'
# Алгоритм контроля перегрузок Google BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Увеличение буферов приёма и отправки UDP до 8MB (убирает дропы пакетов)
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# Быстрая очистка закрытых соединений
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
EOF

sysctl --system > /dev/null 2>&1
echo -e "  ${GREEN}✅ Google BBR + FQ + 8MB UDP буферы активированы${NC}"

# ============================================================
# Шаг 4: Установка и настройка Cloudflare WARP (SOCKS5 Mode)
# ============================================================
echo -e "${YELLOW}[4/8]${NC} Установка Cloudflare WARP (обход антифрода ChatGPT/AI)..."

# Добавляем официальный репозиторий Cloudflare
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /etc/apt/keyrings/cloudflare-warp.gpg 2>/dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null

apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq cloudflare-warp > /dev/null 2>&1

# Регистрируем WARP и переводим строго в SOCKS5 proxy режим
# (Внимание: режим proxy не трогает системный шлюз, поэтому SSH и Telegram-бот не пострадают!)
warp-cli --accept-tos registration new > /dev/null 2>&1 || true
warp-cli --accept-tos mode proxy > /dev/null 2>&1 || true
warp-cli --accept-tos proxy port ${WARP_SOCKS_PORT} > /dev/null 2>&1 || true
warp-cli --accept-tos connect > /dev/null 2>&1 || true

systemctl enable warp-svc > /dev/null 2>&1
echo -e "  ${GREEN}✅ Cloudflare WARP запущен на 127.0.0.1:${WARP_SOCKS_PORT} (SOCKS5)${NC}"

# ============================================================
# Шаг 5: Установка Hysteria2
# ============================================================
echo -e "${YELLOW}[5/8]${NC} Установка Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
echo -e "  ${GREEN}✅ Hysteria2 установлен${NC}"

# ============================================================
# Шаг 6: Генерация сертификата и умного конфига с ACL
# ============================================================
echo -e "${YELLOW}[6/8]${NC} Настройка конфига Hysteria2 с Smart Outbound ACL..."

mkdir -p /etc/hysteria
openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key 2>/dev/null
openssl req -new -x509 -days 3650 -key /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt -subj "/CN=bing.com" 2>/dev/null

VPN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
SERVER_IP=$(curl -s -4 --connect-timeout 10 ifconfig.me || curl -s -4 icanhazip.com)

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

outbounds:
  - name: warp_proxy
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_SOCKS_PORT}

acl:
  inline:
    # --- Сервисы с жестким антифродом идут через чистый пул Cloudflare ---
    - warp_proxy(geosite:openai)
    - warp_proxy(geosite:anthropic)
    - warp_proxy(geosite:google)
    - warp_proxy(geosite:netflix)
    - warp_proxy(geosite:spotify)
    - warp_proxy(suffix:openai.com)
    - warp_proxy(suffix:chatgpt.com)
    - warp_proxy(suffix:oaistatic.com)
    - warp_proxy(suffix:oaiusercontent.com)
    - warp_proxy(suffix:anthropic.com)
    - warp_proxy(suffix:claude.ai)

    # --- Весь остальной трафик (YouTube, соцсети, файлы) летит напрямую ---
    - direct(all)
EOF

echo -e "  ${GREEN}✅ Конфиг создан: Bing-маскировка + Smart ACL${NC}"

# ============================================================
# Шаг 7: Настройка Port Hopping и Файрвола UFW
# ============================================================
echo -e "${YELLOW}[7/8]${NC} Настройка файрвола и Port Hopping (20000-50000 UDP)..."

# Добавляем NAT-редирект портов в /etc/ufw/before.rules, если его еще нет
if ! grep -q "20000:50000" /etc/ufw/before.rules 2>/dev/null; then
    sed -i '1i *nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443\nCOMMIT\n' /etc/ufw/before.rules
fi

ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

ufw allow 22/tcp > /dev/null 2>&1
ufw allow 443/udp > /dev/null 2>&1
ufw allow 20000:50000/udp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1

echo -e "  ${GREEN}✅ Файрвол настроен: SSH (22) + Hysteria (443) + Port Hopping (20000-50000)${NC}"

# ============================================================
# Шаг 8: Мониторинг, автоперезапуск и установка vpn-admin
# ============================================================
echo -e "${YELLOW}[8/8]${NC} Настройка мониторинга и панели управления..."

mkdir -p /etc/systemd/system/hysteria-server.service.d/
cat > /etc/systemd/system/hysteria-server.service.d/restart.conf << EOF
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload

cat > /usr/local/bin/vpn-healthcheck << 'EOF'
#!/bin/bash
# Проверка Hysteria2
if ! systemctl is-active --quiet hysteria-server; then
  systemctl restart hysteria-server
  echo "$(date): Hysteria2 restarted" >> /var/log/vpn-healthcheck.log
fi

# Проверка Cloudflare WARP
if ! systemctl is-active --quiet warp-svc; then
  systemctl restart warp-svc
  sleep 2
  warp-cli --accept-tos connect > /dev/null 2>&1 || true
  echo "$(date): WARP restarted" >> /var/log/vpn-healthcheck.log
fi
EOF
chmod +x /usr/local/bin/vpn-healthcheck

(crontab -l 2>/dev/null | grep -v vpn-healthcheck; echo "*/5 * * * * /usr/local/bin/vpn-healthcheck") | crontab -

# Скачиваем обновленный vpn-admin
curl -fsSL "$VPN_ADMIN_URL" -o /usr/local/bin/vpn-admin 2>/dev/null || true
if [[ -f /usr/local/bin/vpn-admin ]]; then
    chmod +x /usr/local/bin/vpn-admin
    sed -i 's/\r$//' /usr/local/bin/vpn-admin
fi

systemctl enable hysteria-server > /dev/null 2>&1
systemctl restart hysteria-server

echo -e "  ${GREEN}✅ Сервисы запущены и добавлены в автозагрузку${NC}"

# ============================================================
# Финал: Вывод ссылок и параметров
# ============================================================
LINK_STANDARD="hy2://${VPN_PASSWORD}@${SERVER_IP}:443?insecure=1&alpn=h3#Hysteria2"
LINK_PORTHOP="hy2://${VPN_PASSWORD}@${SERVER_IP}:443?insecure=1&alpn=h3&mport=443,20000-50000#Hysteria2-PortHop"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ УСТАНОВКА ENTERPRISE VPN ЗАВЕРШЕНА!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}IP сервера:${NC}      ${SERVER_IP}"
echo -e "  ${BOLD}Пароль VPN:${NC}      ${VPN_PASSWORD}"
echo -e "  ${BOLD}TCP BBR:${NC}         ${GREEN}Активен (fq + bbr)${NC}"
echo -e "  ${BOLD}WARP SOCKS5:${NC}     ${GREEN}Активен (127.0.0.1:${WARP_SOCKS_PORT})${NC}"
echo -e "  ${BOLD}Port Hopping:${NC}    ${GREEN}20000-50000 UDP${NC}"
echo ""
echo -e "  ${BOLD}1. Ссылка со скачущими портами (Рекомендуется для РФ):${NC}"
echo -e "  ${CYAN}${LINK_PORTHOP}${NC}"
echo ""
echo -e "  ${BOLD}2. Стандартная ссылка (порт 443):${NC}"
echo -e "  ${DIM}${LINK_STANDARD}${NC}"
echo ""
echo -e "  ${DIM}Скопируй ссылку в NekoBox / v2rayN / Hiddify / Streisand / Shadowrocket${NC}"
echo ""
echo -e "  ${BOLD}Управление:${NC}"
echo -e "  ${DIM}vpn-admin${NC}          — интерактивное меню"
echo -e "  ${DIM}vpn-admin status${NC}   — статус сервисов и WARP"
echo -e "  ${DIM}vpn-admin test-ai${NC}  — проверить доступность ChatGPT/AI"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
