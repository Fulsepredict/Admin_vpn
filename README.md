# 🛡️ Admin_vpn (Enterprise Edition)

[![CI](https://github.com/Fulsepredict/Admin_vpn/actions/workflows/ci.yml/badge.svg)](https://github.com/Fulsepredict/Admin_vpn/actions/workflows/ci.yml)

> Установщик и консольная панель управления VPN на базе **Hysteria 2** с **Google BBR**, **Cloudflare WARP (SOCKS5)**, **Smart ACL + sniffing** и **Port Hopping**.

---

## ⚡ Что умеет

* 🚀 **Скорость:** Hysteria 2 (QUIC поверх UDP) + **BBR** и планировщик **FQ**; буферы UDP увеличены до **8 MB**.
* 🌐 **Smart ACL через Cloudflare WARP:** трафик к Instagram/Meta, Threads, ChatGPT, Claude, Google/Gemini и стримингам выходит в интернет с IP-адреса Cloudflare WARP, а не с IP дата-центра хостинга. Остальной трафик (YouTube и т.д.) идёт напрямую — так быстрее.
* 🧲 **Sniffing (работает и в TUN-режиме):** сервер сам определяет имя сайта по TLS SNI / HTTP Host / QUIC. Без этого клиенты в TUN-режиме (NekoRay/NekoBox, Hiddify, v2rayN с «VPN-режимом») присылают только IP-адрес, правила ACL не срабатывают, и сайты «видят» IP хостинга (например, Gemini отвечает *User location is not supported*).
* 🔀 **Port Hopping (UDP 20000–50000):** клиент периодически меняет порт подключения — это усложняет замедление и блокировку по одному порту.
* 🔒 **Закреплённый сертификат (pinSHA256):** ссылки содержат отпечаток сертификата сервера, поэтому клиент не подключится к подставному серверу, даже при `insecure=1`.
* 🎭 **Маскировка:** без пароля сервер отвечает как прокси к `bing.com`.
* 🛡️ **Аккуратная безопасность:** UFW **без сброса** существующих правил (порт SSH определяется автоматически, правила ботов и других сервисов сохраняются), Fail2ban, ключ и конфиг закрыты правами `640`, автообновления безопасности.
* ♻️ **Безопасные изменения:** любая правка конфига из `vpn-admin` делается с бэкапом; если Hysteria не запустилась — автоматический откат.
* 🩺 **Healthcheck каждые 5 минут:** проверяет не только службы, но и что туннель WARP реально работает (`warp=on`), и сам переподключает его.
* 🤖 **Совместимость с ботами на том же сервере:** WARP работает только как локальный SOCKS5 (`127.0.0.1:40000`) и не меняет маршруты сервера.

> [!IMPORTANT]
> **Честно о WARP.** WARP даёт IP-адрес Cloudflare вместо IP хостинга — это заметно снижает подозрительность для антифрод-систем, но это **не** «резидентный» и не личный IP: одни и те же адреса WARP используют многие люди. Никакой VPN не гарантирует отсутствие банов, теневых банов или капчи — на это влияют и поведение аккаунта, и отпечаток устройства. Для прогрева и мультиаккаунтинга соблюдай лимиты действий и не держи много аккаунтов на одном выходном IP.

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
vpn-admin upgrade
```

1. `install.sh` обновляет панель `vpn-admin` и healthcheck (VPN при этом не перезапускается).
2. `vpn-admin upgrade` показывает, что изменится, и после подтверждения: включает **sniffing**, добавляет недостающие рекомендуемые домены, убирает дубли в ACL. Перед изменением делается бэкап, при сбое — автооткат. Пароль и ссылки клиентов **не меняются**.

Проверить результат: `vpn-admin test-ai`.

---

## 📱 Подключение на устройствах

`vpn-admin link` показывает 4 ссылки:

| № | Ссылка | Когда использовать |
|---|--------|--------------------|
| 1 | `hy2://…&pinSHA256=…&mport=443,20000-50000#Hysteria2-PortHop` | **Рекомендуемая.** Port hopping + закреплённый сертификат (NekoBox, Hiddify, v2rayN) |
| 2 | `hy2://…:443?…&pinSHA256=…#Hysteria2` | Только порт 443 |
| 3 | `hy2://…&mport=…#Hysteria2-PortHop-NoPin` | Если клиент не подключается по ссылкам 1–2 (не понимает `pinSHA256`) |
| 4 | `hysteria2://…@IP:443,20000-50000/?…` | Официальный формат Hysteria: диапазон портов прямо в адресе (официальный клиент `hysteria`) |

### Рекомендуемые клиенты
* **Android:** [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid), [Hiddify](https://github.com/hiddify/hiddify-app)
* **iOS:** [Streisand](https://apps.apple.com/app/streisand/id6450534064), [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)
* **Windows:** [v2rayN](https://github.com/2dust/v2rayN), [Hiddify](https://github.com/hiddify/hiddify-app), [NekoRay](https://github.com/MatsuriDayo/nekoray) (проект архивирован с декабря 2024 — работает, но обновлений больше не будет)
* **macOS:** [Hiddify](https://github.com/hiddify/hiddify-app), [Streisand](https://apps.apple.com/app/streisand/id6450534064)

> [!TIP]
> Благодаря sniffing можно спокойно включать **TUN-режим** в клиенте — ACL и WARP работают так же, как в режиме системного прокси.

---

## 🖥️ Панель `vpn-admin`

Интерактивное меню:

```bash
vpn-admin
```

Все команды (подходят и для скриптов):

```bash
vpn-admin status                  # Hysteria, WARP (warp=on?), sniffing, ACL, BBR, port hopping
vpn-admin link                    # ссылки для клиентов
vpn-admin test-ai                 # проверить ChatGPT / Claude / Instagram / Gemini через WARP
vpn-admin password [НОВЫЙ]        # сменить пароль (8–64 символа: A-Z a-z 0-9 _ -)
vpn-admin domains                 # какие домены идут через WARP
vpn-admin add-domain tiktok.com   # отправить домен (и все поддомены) через WARP
vpn-admin remove-domain tiktok.com
vpn-admin upgrade [-y]            # sniffing + рекомендуемые домены + чистка дублей
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

* `tests/test_audit.py` — юнит-тесты: вызывают настоящие функции скриптов на временных файлах (генерация конфига и ссылок, валидация ввода, правки ACL, upgrade старого конфига, отсутствие опасных команд). Запуск: `python3 tests/test_audit.py` (нужны bash, PyYAML, shellcheck).
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
