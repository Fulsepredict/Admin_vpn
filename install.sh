#!/bin/bash
# ============================================================
# 🛡️ VPN Admin — установщик
# Скачивает vpn-admin.sh и устанавливает как системную команду
# ============================================================

set -e

REPO_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"
INSTALL_PATH="/usr/local/bin/vpn-admin"

echo "🛡️ Установка VPN Admin Panel..."
echo ""

# Скачиваем скрипт из GitHub
curl -fsSL "$REPO_URL" -o "$INSTALL_PATH"

# Делаем исполняемым
chmod +x "$INSTALL_PATH"

# Убираем Windows-переносы строк (на всякий случай)
sed -i 's/\r$//' "$INSTALL_PATH"

echo "✅ Установлено: $INSTALL_PATH"
echo ""
echo "Использование:"
echo "  vpn-admin          — интерактивное меню"
echo "  vpn-admin status   — быстрый статус"
echo "  vpn-admin link     — показать ссылку"
echo ""
