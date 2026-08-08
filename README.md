# 🛡️ VPN Admin Panel

Интерактивная панель управления Hysteria2 VPN сервером прямо из терминала.

![Bash](https://img.shields.io/badge/Bash-5.0+-green?logo=gnu-bash)
![Hysteria2](https://img.shields.io/badge/Hysteria2-v2.x-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Возможности

- 📊 **Статус** — состояние сервера, RAM, диск, подключения
- 📋 **Логи** — просмотр журнала Hysteria2
- 🔑 **Смена пароля** — генерация нового пароля + ссылки
- 🔗 **Ссылка** — показать текущую ссылку для клиента
- 🔄 **Перезапуск** — мягкая перезагрузка VPN
- ⏯️ **Стоп / Старт** — остановка и запуск сервиса
- ⬆️ **Обновление** — обновление Hysteria2 до последней версии
- 💾 **Бэкап** — сохранение конфигурации с датой
- 🖥️ **Система** — информация об ОС, файрволе, fail2ban

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/install.sh)
```

## Использование

### Интерактивный режим (меню)
```bash
vpn-admin
```

### Быстрые команды
```bash
vpn-admin status     # Статус сервера
vpn-admin logs       # Логи
vpn-admin password   # Сменить пароль
vpn-admin link       # Показать ссылку
vpn-admin restart    # Перезапуск
vpn-admin update     # Обновить Hysteria2
vpn-admin backup     # Бэкап конфига
vpn-admin info       # Информация о системе
```

## Требования

- Ubuntu 20.04+ / Debian 11+
- Hysteria2 установлен и настроен
- Запуск от `root`

## Структура

```
Admin_vpn/
├── vpn-admin.sh    # Основной скрипт
├── install.sh      # Установщик
└── README.md       # Документация
```
