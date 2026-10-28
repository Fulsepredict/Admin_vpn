# 🛡️ Admin_vpn (Enterprise Edition)

[![CI](https://github.com/Fulsepredict/Admin_vpn/actions/workflows/ci.yml/badge.svg)](https://github.com/Fulsepredict/Admin_vpn/actions/workflows/ci.yml)

> Установщик и консольная панель управления VPN на базе **Hysteria 2** с **Google BBR**, **5G/LTE QUIC тюнингом**, **Cloudflare WARP (SOCKS5)**, **Smart ACL + sniffing** и **Port Hopping**.

---

## ⚡ Что умеет

* 🚀 **Скорость и стабильность на 5G/LTE:** Hysteria 2 (QUIC поверх UDP) + принудительный адаптивный **BBR** (`ignoreClientBandwidth: true`, чтобы мобильные клиенты не включали агрессивный `Brutal`) + защита от потери крупных пакетов на сотовых вышках (`disablePathMTUDiscovery: true`) + буферы UDP **8 MB** и оптимизация `nf_conntrack`.
* 🌐 **Smart ACL через Cloudflare WARP + анти-QUIC:** трафик к Instagram/Meta, Threads, ChatGPT, Claude, Google/Gemini/Antigravity и стримингам выходит через Cloudflare WARP (`127.0.0.1:40000`), а внешний `UDP 443` блокируется (`reject(all, udp/443)`), чтобы браузеры и приложения мгновенно переходили на стабильный `TCP 443`.
* 🇺🇸 **Режим `google-mode` для серверов в США/Европе:** если ваш VPS уже находится в США, команда `vpn-admin google-mode direct` переключает всю экосистему Google, Gemini и Antigravity (`antigravity.google`, `cloudcode-pa.googleapis.com`, `pki.goog`) на чистый прямой IPv4 вашего сервера (`mode: 46` без утечки IPv6).
* 🇷🇺 **Обход VPN для Сбербанка, Яндекса и Госуслуг (`vpn-admin ru-bypass`):** готовые инструкции в 1 клик и списки доменов для раздельного туннелирования российских сервисов напрямую мимо VPN.
* 🧲 **Sniffing (`rewriteDomain: true`, работает и в TUN-режиме):** сервер сам определяет имя сайта по TLS SNI / HTTP Host / QUIC и передаёт распознанный домен в исходящий прокси.
* 🔀 **Port Hopping (UDP 20000–50000) + `sni=bing.com`:** клиент периодически меняет порт подключения и передаёт корректный SNI для прохождения мобильных ТСПУ.
* 🔒 **Закреплённый сертификат (pinSHA256):** ссылки содержат отпечаток сертификата сервера, поэтому клиент не подключится к подставному серверу, даже при `insecure=1`.
* 🛡️ **Аккуратная безопасность:** UFW **без сброса** существующих правил (порт SSH определяется автоматически), Fail2ban, ключ и конфиг закрыты правами `640`, автообновления безопасности.
* ♻️ **Безопасные изменения:** любая правка конфига из `vpn-admin` делается с бэкапом; если Hysteria не запустилась — автоматический откат.
* 🩺 **Бережный Healthcheck каждые 5 минут:** проверяет `warp=on` с 3 повторными попытками, чтобы единичный сетевой лаг не перезапускал `warp-svc` и не обрывал живые сессии.

> [!IMPORTANT]
> **Честно о WARP и Google.** Бесплатный WARP даёт общий IP Cloudflare вместо IP хостинга. Однако если ваш сервер физически расположен в **США**, родной IPv4 вашего VPS для входа в аккаунты Google и **Antigravity IDE** значительно чище общего пула WARP (который Google нередко помечает как спам или РФ). Для американских серверов рекомендуется выполнить: `vpn-admin google-mode direct`.

---

## 🚀 Установка на новый сервер

Поддерживается **Ubuntu 22.04 / 24.04** и **Debian 12** (автоматически проверяется в CI на Ubuntu 24.04). Запускать от `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/setup.sh)
```

Скрипт поставит пакеты, настроит ядро, поднимет WARP, Hysteria 2, файрвол, healthcheck и выведет ссылки для подключения. Лог установки: `/var/log/vpn-setup.log`.

Повторный запуск безопасен: **пароль, сертификат и домены, добавленные вручную, сохраняются**, правила файрвола не дублируются.

---

## ♻️ Обновление уже работающего сервера

Если сервер ставился старой версией скрипта, выполни две команды:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/install.sh)
vpn-admin upgrade -y
```

1. `install.sh` обновляет панель `vpn-admin` и бережный healthcheck.
2. `vpn-admin upgrade` включает **5G QUIC тюнинг**, **sniffing (`rewriteDomain: true`)**, **блокировку внешнего UDP 443**, приоритет **IPv4**, добавляет все домены **Google / Antigravity** и убирает дубли в ACL. Перед изменением делается бэкап, при сбое — автооткат. Пароль и сертификат **не меняются**.
3. Если сервер находится в США — переключи Google/Antigravity на прямой IPv4 сервера:
   ```bash
   vpn-admin google-mode direct
   ```

Проверить результат: `vpn-admin test-ai` и получить обновлённые ссылки (с `sni=bing.com`): `vpn-admin link`.

---

## 📱 Подключение на устройствах и обход для банков РФ

`vpn-admin link` показывает 4 ссылки:

| № | Ссылка | Когда использовать |
|---|--------|--------------------|
| 1 | `hy2://…&sni=bing.com&pinSHA256=…&mport=443,20000-50000#Hysteria2-PortHop` | **Рекомендуемая для Wi-Fi и ПК.** Port hopping + SNI + закреплённый сертификат |
| 2 | `hy2://…:443?…&sni=bing.com&pinSHA256=…#Hysteria2` | **Только порт 443 (лучше для мобильных сетей 4G/5G РФ**, если оператор режет высокие UDP-порты) |
| 3 | `hy2://…&sni=bing.com&mport=…#Hysteria2-PortHop-NoPin` | Если клиент не подключается по ссылкам 1–2 (не понимает `pinSHA256`) |
| 4 | `hysteria2://…@IP:443,20000-50000/?…&sni=bing.com…` | Официальный формат Hysteria: диапазон портов прямо в адресе |

### 🇷🇺 Как пустить Сбербанк, Яндекс и Госуслуги мимо VPN (`vpn-admin ru-bypass`)
Чтобы российские банки и сервисы видели ваш настоящий российский IP и открывались мгновенно:
* **Hiddify:** Настройки (⚙️) → Регион (Region) → выбери **Россия (`ru`)**.
* **v2rayN (v7+):** Настройки → Региональные пресеты (Regional presets) → **Россия (Russia)**.
* **NekoBox / Streisand / Shadowrocket:** добавь в правила маршрутизации `Direct` (Напрямую) для `geosite:ru`, `geoip:ru` и доменов `.ru`, `.su`, `.xn--p1ai`. Полный список доменов выводит команда `vpn-admin ru-bypass`.

---

## 🖥️ Панель `vpn-admin`

Интерактивное меню:

```bash
vpn-admin
```

Все команды (подходят и для скриптов):

```bash
vpn-admin status                  # Hysteria, WARP, 5G QUIC, sniffing, режим Google, BBR
vpn-admin link                    # ссылки для клиентов (с sni=bing.com и pinSHA256)
vpn-admin test-ai                 # проверить ChatGPT / Claude / Instagram / Antigravity
vpn-admin google-mode [direct|warp] # пустить Google/Antigravity напрямую (для VPS в США) или через WARP
vpn-admin ru-bypass               # инструкция обхода VPN для Сбербанка, Яндекса и Госуслуг
vpn-admin password [НОВЫЙ]        # сменить пароль (8–64 символа: A-Z a-z 0-9 _ -)
vpn-admin domains                 # какие домены идут через WARP
vpn-admin add-domain tiktok.com   # отправить домен (и все поддомены) через WARP
vpn-admin remove-domain tiktok.com
vpn-admin upgrade [-y]            # 5G QUIC + sniffing + домены Antigravity + чистка дублей
vpn-admin logs                    # последние строки журнала Hysteria
vpn-admin restart                 # перезапустить Hysteria и WARP
vpn-admin toggle                  # остановить / запустить Hysteria
vpn-admin backup                  # бэкап конфига (хранятся последние 30)
vpn-admin update                  # обновить Hysteria 2
vpn-admin self-update             # обновить саму панель с GitHub
vpn-admin install-healthcheck     # переустановить healthcheck
vpn-admin info                    # ОС, ядро, IP, UFW, Fail2ban
vpn-admin migrate                 # как переехать на новый сервер
```

Логи: действия панели — `/var/log/vpn-admin.log`, healthcheck — `/var/log/vpn-healthcheck.log`, бэкапы — `/etc/hysteria/backups/`.

---

## 🔥 Файрвол

* Если UFW уже был включён, его правила **не сбрасываются** — добавляются только правила для SSH, Hysteria и port hopping.
* Порт SSH определяется автоматически (текущая сессия, `sshd -T`, `ss`), поэтому SSH на нестандартном порту не отрежется.
* Если UFW был выключен, после установки входящие соединения запрещены по умолчанию. Скрипт предупредит о сервисах, которые слушают другие TCP-порты (например, вебхуки ботов). Открыть порт: `ufw allow ПОРТ/tcp`.

---

## 🧪 Тесты

* `tests/test_audit.py` — юнит-тесты: вызывают настоящие функции скриптов на временных файлах (генерация конфига и ссылок, 5G QUIC тюнинг, переключение `google-mode`, валидация ввода, правки ACL, upgrade старого конфига, отсутствие опасных команд). Запуск: `python3 tests/test_audit.py` (нужны bash, PyYAML, shellcheck).
* `tests/integration.sh` — интеграционный тест в GitHub Actions на чистой Ubuntu: полная установка, команды `vpn-admin`, автооткат, реальный туннель с port hopping и pinSHA256 (клиент в отдельном network namespace), WARP + sniffing в режиме «только IP» (как TUN), healthcheck, upgrade старого конфига и повторный запуск `setup.sh`.

---

## 📂 Структура проекта

```text
Admin_vpn/
├── setup.sh                  # установщик сервера
├── vpn-admin.sh              # консольная панель управления
├── install.sh                # установка / обновление vpn-admin на готовом сервере
├── tests/
│   ├── test_audit.py         # юнит-тесты
│   └── integration.sh        # интеграционный тест (GitHub Actions)
├── .github/workflows/ci.yml  # автоматическая проверка каждого изменения
└── README.md
```
