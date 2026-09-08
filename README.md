# 🛡️ Admin_vpn (Enterprise Edition)

> Автоматический развёртыватель и панель управления сверхбыстрым VPN на базе **Hysteria 2**, **Google BBR**, **Cloudflare WARP (SOCKS5)** и **Port Hopping**.

---

## ⚡ Особенности Enterprise Edition

* 🚀 **Максимальная скорость:** Протокол Hysteria 2 на базе кастомного QUIC (UDP) + алгоритм **Google BBR** и сетевой планировщик **FQ**.
* 📦 **Никаких потерь пакетов:** Буферы ядра Linux для UDP увеличены до **8 MB** (`rmem_max` / `wmem_max`).
* 🤖 **Обход антифрода ИИ (Zero-Detect):** Встроенная маршрутизация через локальный Cloudflare WARP SOCKS5 (`127.0.0.1:40000`). Сервисы **ChatGPT, Claude, Netflix, Google (без ReCaptcha)** видят чистые домашние IP Cloudflare.
* 🔀 **Port Hopping (20000–50000 UDP):** Клиент динамически меняет порты подключения. Провайдеры и мобильные операторы (МТС, Теле2, Мегафон) не могут замедлить или заглушить сессию.
* 🎭 **Маскировка Bing:** Полная имитация легитимного TLS-трафика на `bing.com`.
* 🤖 **100% совместимость с Telegram-ботами на одном сервере:** WARP работает изолированно в режиме SOCKS5 proxy, не подменяя сетевой шлюз сервера. SSH и боты в Docker/Long Polling не испытывают помех.
* 🛡️ **Безопасность «из коробки»:** Автонастройка UFW, Fail2ban для защиты SSH от брутфорса, cron-healthcheck каждые 5 минут.

---

## 🚀 Быстрая установка за 2 минуты

На чистом сервере **Ubuntu 20.04 / 22.04 / 24.04** или **Debian 11 / 12** выполни одну команду:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/setup.sh)
```

Скрипт автоматически всё установит, настроит ядро, поднимет WARP, сгенерирует ключи и выдаст две ссылки для подключения.

---

## 📱 Подключение на устройствах

Используй любую из полученных ссылок:
1. **Рекомендуемая (со скачущими портами):** `hy2://...&mport=443,20000-50000#Hysteria2-PortHop`
2. **Стандартная (порт 443):** `hy2://...#Hysteria2`

### Рекомендуемые клиенты:
* **Android:** [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid), [Hiddify](https://github.com/hiddify/hiddify-next)
* **iOS:** [Streisand](https://apps.apple.com/app/streisand/id6450534064), [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)
* **Windows:** [NekoBox for Windows](https://github.com/MatsuriDayo/nekoray), [Hiddify](https://github.com/hiddify/hiddify-next), [v2rayN](https://github.com/2dust/v2rayN)
* **macOS:** [Hiddify](https://github.com/hiddify/hiddify-next), [Streisand](https://apps.apple.com/app/streisand/id6450534064)

---

## 🖥️ Интерактивная панель `vpn-admin`

Запуск интерактивного меню:
```bash
vpn-admin
```

### Быстрые команды:
```bash
vpn-admin status     # Статус Hysteria2, BBR, WARP и системных ресурсов
vpn-admin test-ai    # Проверка доступности ChatGPT и Claude через WARP
vpn-admin link       # Вывести актуальные ссылки для клиентов
vpn-admin password   # Быстрая смена пароля
vpn-admin logs       # Просмотр логов в реальном времени
vpn-admin restart    # Мягкий перезапуск Hysteria2 и WARP
vpn-admin backup     # Создание бэкапа конфигурации с датой
vpn-admin update     # Обновление Hysteria2 до последней версии
```

---

## 📂 Структура проекта

```text
Admin_vpn/
├── setup.sh         # Главный автоматический установщик
├── vpn-admin.sh     # Консольная панель управления
├── install.sh       # Быстрый апдейтер для vpn-admin
└── README.md        # Документация
```
