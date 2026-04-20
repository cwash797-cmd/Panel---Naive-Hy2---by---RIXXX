# Panel Naive + Hysteria2 by RIXXX

> Веб-панель для быстрой установки и управления **NaiveProxy** и **Hysteria2** на одном VPS — в **2 клика**

---

## 🚀 Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/install.sh)
```

После установки панель будет доступна:
```
http://YOUR_SERVER_IP:3000
```

**Логин по умолчанию:** `admin` / `admin` — **смените сразу!**

---

## 💡 Идея проекта

На одном сервере поднимаются **оба протокола одновременно**:

| Протокол    | Транспорт | Порт       | Назначение                                              |
|-------------|-----------|------------|---------------------------------------------------------|
| NaiveProxy  | TCP       | 443        | Маскировка под HTTPS, HTTP/2 forward-proxy (Caddy)      |
| Hysteria2   | UDP       | 443        | Высокоскоростной QUIC-прокси с собственным congestion   |

**Оба работают на одном порту 443** (TCP + UDP — разные сокеты, конфликта нет). Hysteria2 использует **сертификат Caddy** — один домен, один сертификат, два протокола. Для внешнего наблюдателя сервер выглядит как обычный сайт на HTTPS с поддержкой HTTP/3.

---

## 📋 Требования к серверу

- **ОС:** Ubuntu 22.04 / 24.04 или Debian 11 / 12
- **Архитектура:** `amd64`, `arm64`, `armv7` (автоопределение)
- **Домен:** A-запись с IP сервера (например `vpn.yourdomain.com`)
- **Порты:** 22, 80, 443 (TCP + UDP), 3000
- **RAM:** минимум 1 GB (для сборки Caddy)

---

## 🎛️ Возможности панели

| Функция | Описание |
|---------|----------|
| 🟢 **Установка в 2 клика** | Выбери стек (Naive / Hy2 / Оба) → домен + email → готово |
| 👥 **Раздельные пользователи** | Отдельные списки для NaiveProxy и Hysteria2 |
| 📊 **Умный дашборд** | Статус обоих сервисов, счётчик пользователей, IP, домен |
| 🔗 **Ссылки подключения** | Готовые `naive+https://...` и `hysteria2://...` ссылки |
| 🔄 **Управление сервисами** | Старт / стоп / рестарт Caddy и Hysteria по отдельности |
| ⚡ **Сетевой тюнинг** | Применение BBR + UDP-буферов одной кнопкой |
| 🔒 **Смена пароля панели** | Хешированное хранение bcrypt |

---

## 🔌 Клиенты для подключения

### NaiveProxy
| Платформа | Приложение |
|-----------|-----------|
| iOS       | [Karing](https://apps.apple.com/app/karing/id6472431552) |
| Android   | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) / Karing |
| Windows   | Karing / [NekoRay](https://github.com/MatsuriDayo/nekoray/releases) / [v2rayN](https://github.com/2dust/v2rayN/releases) |

### Hysteria2
| Платформа | Приложение |
|-----------|-----------|
| iOS       | [Karing](https://apps.apple.com/app/karing/id6472431552) / Shadowrocket |
| Android   | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) / Karing |
| Windows   | [Nekoray](https://github.com/MatsuriDayo/nekoray/releases) / v2rayN / [Hiddify](https://github.com/hiddify/hiddify-app/releases) |
| macOS     | Karing / Hiddify |
| Linux     | [hysteria CLI](https://github.com/apernet/hysteria/releases) |

**Формат ссылок:**
```
naive+https://LOGIN:PASSWORD@your.domain.com:443
hysteria2://PASSWORD@your.domain.com:443?sni=your.domain.com
```

---

## ⚙️ Управление

```bash
# Панель
pm2 status
pm2 logs panel-naive-hy2
pm2 restart panel-naive-hy2

# NaiveProxy (Caddy)
systemctl status caddy
systemctl restart caddy
journalctl -u caddy -f

# Hysteria2
systemctl status hysteria-server
systemctl restart hysteria-server
journalctl -u hysteria-server -f
```

---

## 🔐 Безопасность

- Пароли пользователей панели хранятся как **bcrypt-хеш**
- Пароли прокси-пользователей шифруются при сохранении на диск (AES-256-GCM)
- CORS ограничен `localhost:3000`
- Session secret генерируется при первом запуске
- UFW включается автоматически, лишние порты закрыты

---

## 🔧 Диагностика проблем

В панели есть страница **«Диагностика»** (в боковом меню) — там можно:
- Посмотреть логи Caddy и Hysteria2 без SSH
- Проверить кто слушает порт 443/TCP и 443/UDP
- Прочитать частые причины почему Hy2 не запускается

Если что-то не так — заходите туда первым делом.

---

## 📜 История изменений

### v1.2 — Исправление параллельной работы Naive + Hy2
- 🐞 **Hy2 не запускался когда был Naive**: Caddy по умолчанию занимал UDP/443 для HTTP/3 (QUIC), не давая Hy2 биндиться. Теперь при установке обоих протоколов в `Caddyfile` добавляется `servers { protocols h1 h2 }` — HTTP/3 в Caddy отключён, UDP/443 свободен для Hy2.
- 🆕 **Страница «Диагностика»** в панели — логи + проверка портов
- 🆕 Скрипт `install_hysteria.sh` теперь сам патчит уже установленный Caddyfile при доустановке Hy2 поверх Naive
- 🆕 Финальные проверки в `install.sh`: панель отвечает на `:3000`, nginx слушает `:8080`
- 🆕 Systemd-fallback если PM2 не запустил панель
- 🐞 `writeCaddyfile` в backend теперь сохраняет директиву отключения HTTP/3 при добавлении/удалении Naive-юзеров

### v1.1 — Параллельный запуск Naive + Hy2 (4 фикса)
- Hysteria2 теперь стартует после Caddy (`After=caddy.service`)
- Чтение существующего `/etc/hysteria/config.yaml` при изменении пользователей (раньше затирал TLS-секцию)
- Поиск Caddy-сертификата в обоих возможных путях
- Валидный JSON `config.json` (heredoc + переменные)

### v1.0 — Первый релиз
- Multi-arch Go (amd64 / arm64 / armv6l)
- 2-кликовая установка обоих протоколов
- Единая панель для Naive + Hy2
- BBR + UDP-тюнинг

---

*by RIXXX — мультипротокольная прокси-панель с удобным интерфейсом*
