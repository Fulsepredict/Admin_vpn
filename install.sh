#!/bin/bash
# ============================================================
# 🛡️ VPN Admin — установщик / обновлятор панели управления
# Скачивает vpn-admin.sh, проверяет его и делает доступной команду 'vpn-admin'.
# Для уже работающих серверов после обновления выполни: vpn-admin upgrade
# ============================================================

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"
INSTALL_PATH="/usr/local/bin/vpn-admin"

if [[ $EUID -ne 0 ]]; then
    echo "❌ Запусти от root: sudo bash install.sh" >&2
    exit 1
fi

echo "🛡️ Установка VPN Admin Panel (Enterprise Edition)..."
echo ""

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

if ! curl -fsSL --connect-timeout 15 "$REPO_URL" -o "$TMP_FILE"; then
    echo "❌ Не удалось скачать ${REPO_URL}" >&2
    exit 1
fi

# Убираем Windows-переводы строк и проверяем, что файл — целый bash-скрипт.
# Почему: обрыв загрузки или страница ошибки вместо скрипта не должны
# заменить рабочую панель на сломанную.
sed -i 's/\r$//' "$TMP_FILE"
if [[ "$(head -n 1 "$TMP_FILE")" != "#!/bin/bash" ]] || ! bash -n "$TMP_FILE"; then
    echo "❌ Скачанный файл повреждён — установка отменена" >&2
    exit 1
fi

install -m 755 -o root -g root "$TMP_FILE" "$INSTALL_PATH"

# Обновляем healthcheck (новая версия проверяет, что WARP реально работает)
"$INSTALL_PATH" install-healthcheck || echo "⚠ Не удалось обновить healthcheck"

echo ""
echo "✅ Успешно установлено: $INSTALL_PATH"
echo ""
echo "Использование:"
echo "  vpn-admin            — интерактивное меню"
echo "  vpn-admin status     — статус сервера, WARP и sniffing"
echo "  vpn-admin upgrade    — включить sniffing и добавить новые домены (для старых серверов)"
echo "  vpn-admin test-ai    — тест ChatGPT/Claude/Instagram через WARP"
echo "  vpn-admin link       — ссылки для подключения"
echo ""
