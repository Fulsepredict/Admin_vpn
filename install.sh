#!/bin/bash
# ============================================================
# 🛡️ VPN Admin — быстрый установщик панели управления
# Скачивает vpn-admin.sh и делает доступной команду 'vpn-admin'
# ============================================================

set -e

REPO_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"
INSTALL_PATH="/usr/local/bin/vpn-admin"

echo "🛡️ Установка VPN Admin Panel (Enterprise Edition)..."
echo ""

curl -fsSL "$REPO_URL" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
sed -i 's/\r$//' "$INSTALL_PATH"

echo "✅ Успешно установлено: $INSTALL_PATH"
echo ""
echo "Использование:"
echo "  vpn-admin          — интерактивное меню"
echo "  vpn-admin status   — быстрый статус сервера, BBR и WARP"
echo "  vpn-admin test-ai  — тест обхода блокировок ChatGPT/Claude"
echo "  vpn-admin link     — ссылки для подключения (Port Hopping)"
echo ""
