# reality-telemt

Контейнеризованный **double-hop** для РФ: пользовательский трафик — **VLESS-Reality**
(3x-ui, TCP/443, мимикрия под чужой сайт), Telegram — **telemt** (fake-TLS). Всё в Docker.
3x-ui поднимается **уже настроенным** (засев через CLI + HTTP-API, без возни с UI).

Это «макс-стелс» вариант. Простой AmneziaWG-вариант — в репозитории
[amnezia-install](https://github.com/ComradDart/amnezia-install).

## Архитектура

```
[USER в РФ] ─VLESS-Reality(443,SNI=чужой сайт)→ [INBOUND РФ]            [OUTBOUND за рубежом]
                                                 HAProxy :443 (SNI)      raw AmneziaWG (awg0, host)
                                                  ├ SNI=маска ─awg─→ 3x-ui VLESS-Reality (выход)
                                                  ├ SNI=telemt ─awg─→ telemt (Telegram)
                                                  └ иначе ──────────→ nginx (легит-сайт)
```

- VLESS-Reality **терминируется на outbound**; inbound лишь HAProxy-форвардит сырой TCP по
  туннелю → 3x-ui остаётся простым (один инбаунд), без кастомной маршрутизации в xray.
- Межсерверный туннель — **raw AmneziaWG p2p на хосте** (проверенный механизм).
- HAProxy SNI-роутер на 443 (Reality и telemt fake-TLS на одном порту уживаются только так).

## Статус

| Стадия | Что | Статус |
|---|---|---|
| 1 | OUTBOUND: 3x-ui VLESS-Reality + nginx + HAProxy + certbot | ✅ готово |
| 2 | OUTBOUND: telemt (Telegram) | ✅ готово (опц.) |
| 3 | OUTBOUND: AmneziaWG-фолбэк (wg-easy, опц.) | ✅ готово (опц.) |
| 4 | INBOUND: HAProxy-релей на 443 (двойной прыжок) | ⏳ следующий шаг |

Весь OUTBOUND тестируется на **одном** зарубежном сервере (прямое подключение VLESS-Reality /
Telegram / AWG). INBOUND (двойной прыжок) — когда поднимешь второй сервер.

**Каналы (по приоритету):** VLESS-Reality — основной; AmneziaWG — запасной (переключение делает
клиент, напр. Hiddify/sing-box urltest); telemt — для Telegram.

## Запуск

> ⚠️ Это отдельный стек. **Не запускайте на сервере, где уже крутится amnezia-install**
> (конфликт за порт 443). Нужен чистый VPS (или снапшот).

```bash
curl -fsSLO https://raw.githubusercontent.com/ComradDart/reality-telemt/main/install.sh
bash install.sh
```
(роль `outbound`; маску Reality — чужой CDN-домен, по умолчанию `www.microsoft.com`)

Скрипт интерактивный — не запускайте через `curl | bash` (нужен ввод ответов).

## Доступ к панели 3x-ui

Панель слушает только `127.0.0.1:2053` (наружу закрыта ufw). Доступ — по SSH-туннелю:

```bash
ssh -L 2053:127.0.0.1:2053 <user>@<server>
# затем открыть http://127.0.0.1:2053
```

Логин/пароль и готовая VLESS-Reality ссылка печатаются в конце установки и сохраняются
в `/root/reality_telemt.txt`.

## Требования

- Чистый VPS: Ubuntu 22.04/24.04 или Debian 11/12, root.
- Для Let's Encrypt — домен на сервер (или Cloudflare API-токен для DNS-01). Reality своего
  сертификата не требует — cert нужен только легит-сайту-заглушке.
