#!/usr/bin/env bash
# ==============================================================================
#  reality-telemt — контейнеризованный double-hop:
#    OUTBOUND (за рубежом): 3x-ui (VLESS-Reality) + nginx-заглушка + HAProxy [+ telemt]
#    INBOUND  (в РФ):       HAProxy(SNI) + nginx + AmneziaWG-клиент к outbound
#
#  Стелс: пользовательский трафик — VLESS-Reality (TCP/443, мимикрия под чужой сайт),
#  Telegram — telemt (fake-TLS). 3x-ui засевается через CLI + HTTP-API (полный JSON).
#
#  СТАТУС РЕАЛИЗАЦИИ:
#    [x] Стадия 1 — OUTBOUND: 3x-ui VLESS-Reality + nginx + HAProxy + certbot
#    [ ] Стадия 2 — OUTBOUND: telemt (Telegram)              (следующий шаг)
#    [ ] Стадия 3 — INBOUND + AmneziaWG-туннель (двойной прыжок)
#
#  ОС: Ubuntu 22.04/24.04, Debian 11/12.  Запуск: bash install.sh (от root)
#  Лог: /var/log/reality_telemt.log
# ==============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Константы
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/reality_telemt.log"
STATE_DIR="/var/lib/reality-telemt"
ANSWERS_FILE="$STATE_DIR/answers.env"
SECRETS_FILE="$STATE_DIR/secrets.env"
INFO_FILE="/root/reality_telemt.txt"
CF_CREDS_FILE="/root/.secrets/cloudflare.ini"

STACK_DIR="/opt/reality-telemt"          # docker-compose стека
NGINX_DIR="$STACK_DIR/nginx"
STUB_DIR="$NGINX_DIR/site"               # легит-сайт (заглушка)
SSL_DIR="$NGINX_DIR/ssl"
NGINX_CONF="$NGINX_DIR/conf.d/default.conf"
HAPROXY_CFG="$STACK_DIR/haproxy.cfg"

XUI_IMAGE="ghcr.io/mhsanaei/3x-ui:v3.3.1"   # пиним версию: засев привязан к схеме/API
XUI_DB_DIR="$STACK_DIR/xui-db"
XUI_PANEL_PORT="2053"                    # панель: только localhost, доступ по SSH-туннелю
XUI_REALITY_PORT="2443"                  # VLESS-Reality inbound (127.0.0.1, за HAProxy)
SITE_TLS_PORT="8443"                     # nginx-TLS легит-сайта (за HAProxy)

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-reality-telemt.conf"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Логирование
# ------------------------------------------------------------------------------
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] [INFO ] $*"; }
skip() { echo "[$(ts)] [SKIP ] $*"; }
warn() { echo "[$(ts)] [WARN ] $*"; }
die()  { echo "[$(ts)] [ERROR] $*"; exit 1; }
trap 'echo "[$(ts)] [ERROR] Аварийная остановка на строке $LINENO (команда: $BASH_COMMAND). Лог: $LOG_FILE"' ERR

# ------------------------------------------------------------------------------
# Хелперы (проверены в amnezia-install)
# ------------------------------------------------------------------------------
apt_install() {
    local missing=() p
    for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [[ ${#missing[@]} -eq 0 ]]; then skip "Пакеты уже установлены: $*"; return 0; fi
    log "Устанавливаю: ${missing[*]}"; apt-get install -y "${missing[@]}"
}

# Записать файл из stdin, только если содержимое изменилось. 0=записан, 1=актуален.
deploy_file() {
    local dest="$1" mode="${2:-644}" tmp; tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
    mkdir -p "$(dirname "$dest")"; mv "$tmp" "$dest"; chmod "$mode" "$dest"; return 0
}

# Развернуть легит-сайт (index.html) в каталог $1. 0=изменился.
deploy_stub() {
    local dir="$1"; mkdir -p "$dir"
    deploy_file "$dir/index.html" 644 <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Northwind Studio — Digital Product Design</title>
<style>
  :root{--bg:#0f1115;--panel:#161922;--ink:#eef1f6;--muted:#9aa3b2;--line:#262b36;--brand:#5b8def;--brand-2:#7c5cff}
  *{box-sizing:border-box}html,body{margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
  .wrap{max-width:1080px;margin:0 auto;padding:0 24px}
  header{display:flex;align-items:center;justify-content:space-between;padding:22px 0;border-bottom:1px solid var(--line)}
  .brand{display:flex;align-items:center;gap:12px;font-weight:600}
  nav a{color:var(--muted);margin-left:26px;font-size:15px;text-decoration:none}
  .hero{padding:96px 0 80px;text-align:center}
  .eyebrow{display:inline-block;color:var(--brand);font-size:13px;font-weight:600;letter-spacing:1.4px;text-transform:uppercase;margin-bottom:18px}
  .hero h1{font-size:52px;line-height:1.1;margin:0 0 20px;font-weight:700;letter-spacing:-.5px}
  .hero h1 span{background:linear-gradient(90deg,var(--brand),var(--brand-2));-webkit-background-clip:text;background-clip:text;color:transparent}
  .hero p{font-size:19px;color:var(--muted);max-width:620px;margin:0 auto 34px}
  .btn{padding:13px 26px;border-radius:11px;font-weight:600;font-size:15px;text-decoration:none;color:#fff;background:linear-gradient(90deg,var(--brand),var(--brand-2))}
  .grid{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;padding:24px 0 96px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:28px}
  .card h3{margin:0 0 8px;font-size:18px}.card p{margin:0;color:var(--muted);font-size:15px}
  footer{border-top:1px solid var(--line);padding:30px 0;display:flex;justify-content:space-between;color:var(--muted);font-size:14px}
  @media(max-width:780px){.hero h1{font-size:38px}.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand">
      <svg width="28" height="28" viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg"><rect width="28" height="28" rx="8" fill="url(#g)"/><path d="M8 19V9l6 7 6-7v10" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><defs><linearGradient id="g" x1="0" y1="0" x2="28" y2="28"><stop stop-color="#5b8def"/><stop offset="1" stop-color="#7c5cff"/></linearGradient></defs></svg>
      <span>Northwind Studio</span>
    </div>
    <nav><a href="#work">Work</a><a href="#services">Services</a></nav>
  </header>
  <section class="hero">
    <span class="eyebrow">Independent Design &amp; Engineering</span>
    <h1>We build <span>calm, careful</span><br>digital products.</h1>
    <p>Northwind is a small studio partnering with founders and teams to design, prototype and ship software that feels effortless to use.</p>
    <a href="#contact" class="btn">Start a project</a>
  </section>
  <section class="grid">
    <div class="card"><h3>Product Design</h3><p>Research, interface design and design systems that scale with your team.</p></div>
    <div class="card"><h3>Web Engineering</h3><p>Fast, accessible and maintainable front-ends built on modern tooling.</p></div>
    <div class="card"><h3>Strategy</h3><p>From positioning to roadmap, we help you decide what to build next.</p></div>
  </section>
  <footer><span>&copy; Northwind Studio</span><span>hello@northwind.studio</span></footer>
</div>
</body>
</html>
EOF
}

# ------------------------------------------------------------------------------
# Проверки окружения
# ------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
[[ -f /etc/os-release ]] || die "Нет /etc/os-release — неподдерживаемая ОС"
. /etc/os-release
OS_ID="${ID:-}"
case "$OS_ID" in ubuntu|debian) ;; *) die "Только Ubuntu/Debian (обнаружено: ${PRETTY_NAME:-$OS_ID})" ;; esac

log "=============================================================="
log "reality-telemt на ${PRETTY_NAME}"
log "=============================================================="

# ==============================================================================
# ШАГ 0. Вопросы
# ==============================================================================
if [[ -f "$ANSWERS_FILE" ]]; then . "$ANSWERS_FILE"; log "Подставлены ответы прошлого запуска"; fi

DEF_ROLE="${ROLE:-outbound}"
DEF_USER="${NEW_USER:-vpnadmin}"
DEF_HOST="${SERVER_HOST:-}"
DEF_REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

echo ""
echo "================  reality-telemt  ================"
echo ""
echo "Роль сервера:"
echo "  1) outbound — за рубежом (3x-ui VLESS-Reality + telemt). Точка выхода."
echo "  2) inbound  — в РФ (HAProxy + nginx + AmneziaWG-клиент). Точка входа."
[[ "$DEF_ROLE" == "inbound" ]] && DR=2 || DR=1
while true; do
    read -rp "Вариант [1/2] [$DR]: " RN; RN="${RN:-$DR}"
    case "$RN" in 1) ROLE=outbound; break ;; 2) ROLE=inbound; break ;; *) echo "  1 или 2." ;; esac
done
log "Роль: $ROLE"

while true; do
    read -rp "Имя нового пользователя (вместо root) [$DEF_USER]: " NEW_USER; NEW_USER="${NEW_USER:-$DEF_USER}"
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    echo "  Допустимы строчные буквы, цифры, '-', '_'."
done

while true; do
    if [[ -n "$DEF_HOST" ]]; then read -rp "Публичный IP/домен ЭТОГО сервера [$DEF_HOST]: " SERVER_HOST; SERVER_HOST="${SERVER_HOST:-$DEF_HOST}"
    else read -rp "Публичный IP/домен ЭТОГО сервера: " SERVER_HOST; fi
    [[ -n "$SERVER_HOST" ]] && break; echo "  Не может быть пустым."
done

# TLS-сертификат для легит-сайта (Reality своего cert не требует)
echo ""
echo "TLS для легит-сайта (Reality cert не нужен):"
echo "  1) Самоподписанный   2) Let's Encrypt (HTTP-01)   3) Let's Encrypt (Cloudflare DNS-01)"
DEF_CERT="${CERT_MODE:-1}"
while true; do read -rp "Вариант [1/2/3] [$DEF_CERT]: " CERT_MODE; CERT_MODE="${CERT_MODE:-$DEF_CERT}"
    case "$CERT_MODE" in 1|2|3) break ;; *) echo "  1, 2 или 3." ;; esac; done
LE_EMAIL="${LE_EMAIL:-}"; CF_TOKEN=""
if [[ "$CERT_MODE" != "1" ]]; then
    if [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]]; then warn "LE не выдаёт cert на IP — самоподписанный."; CERT_MODE=1
    else DEF_EMAIL="${LE_EMAIL:-admin@$SERVER_HOST}"; read -rp "E-mail Let's Encrypt [$DEF_EMAIL]: " LE_EMAIL; LE_EMAIL="${LE_EMAIL:-$DEF_EMAIL}"; fi
fi
if [[ "$CERT_MODE" == "3" && ! -s "$CF_CREDS_FILE" ]]; then
    echo "  Токен Cloudflare: My Profile -> API Tokens -> \"Edit zone DNS\"."
    while true; do read -rsp "  API-токен Cloudflare (скрыт): " CF_TOKEN; echo ""; [[ -n "$CF_TOKEN" ]] && break; echo "  Пусто."; done
fi

# Reality: маскировочный (чужой) домен
if [[ "$ROLE" == "outbound" ]]; then
    echo ""
    echo "Reality маскируется под чужой сайт (его SNI шлёт клиент; должен быть доступен"
    echo "с этого сервера, поддерживать TLS1.3+H2 и НЕ быть заблокирован в РФ)."
    read -rp "Маска Reality (dest/serverName) [$DEF_REALITY_SNI]: " REALITY_SNI; REALITY_SNI="${REALITY_SNI:-$DEF_REALITY_SNI}"
fi

deploy_file "$ANSWERS_FILE" 600 <<EOF >/dev/null || true
ROLE="$ROLE"
NEW_USER="$NEW_USER"
SERVER_HOST="$SERVER_HOST"
CERT_MODE="$CERT_MODE"
LE_EMAIL="$LE_EMAIL"
REALITY_SNI="${REALITY_SNI:-$DEF_REALITY_SNI}"
EOF
log "Параметры: роль=$ROLE, адрес=$SERVER_HOST, cert=режим$CERT_MODE, reality=${REALITY_SNI:-—}"

# ==============================================================================
# ШАГ 1. Базовые пакеты
# ==============================================================================
log "--- Шаг 1: базовые пакеты ---"
apt-get update
apt_install curl ca-certificates gnupg openssl sudo ufw fail2ban jq

# ==============================================================================
# ШАГ 2. Пользователь вместо root
# ==============================================================================
log "--- Шаг 2: пользователь $NEW_USER ---"
if id -u "$NEW_USER" >/dev/null 2>&1; then skip "Пользователь существует"; else log "Создаю $NEW_USER"; useradd -m -s /bin/bash "$NEW_USER"; fi
id -nG "$NEW_USER" | grep -qw sudo || { log "В группу sudo"; usermod -aG sudo "$NEW_USER"; }
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6); KEYS_PRESENT=0
if [[ -s "$USER_HOME/.ssh/authorized_keys" ]]; then KEYS_PRESENT=1; skip "authorized_keys уже есть"
elif [[ -s /root/.ssh/authorized_keys ]]; then
    log "Копирую ключи root -> $NEW_USER"; mkdir -p "$USER_HOME/.ssh"
    cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
    chmod 700 "$USER_HOME/.ssh"; chmod 600 "$USER_HOME/.ssh/authorized_keys"; chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"; KEYS_PRESENT=1
else warn "Ключей нет — вход по паролю останется включён"; fi
PASS_STATUS=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' || true)
if [[ "$PASS_STATUS" == "P" ]]; then skip "Пароль уже задан"; else
    log "Задайте пароль для $NEW_USER (нужен для sudo)"; until passwd "$NEW_USER"; do warn "Повторите"; done; fi

# ==============================================================================
# ШАГ 3. SSH hardening
# ==============================================================================
log "--- Шаг 3: SSH hardening ---"
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true); SSH_PORT="${SSH_PORT:-22}"
log "Порт SSH: $SSH_PORT"
if (( KEYS_PRESENT )); then PASSWORD_AUTH="no"; else PASSWORD_AUTH="yes"; warn "Вход по паролю НЕ отключён (нет ключей)"; fi
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
if deploy_file "$SSHD_DROPIN" 600 <<EOF
# reality-telemt — не редактировать вручную
PermitRootLogin no
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
then
    sshd -t || die "Ошибка sshd_config — проверьте $SSHD_DROPIN"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
    log "SSH: root запрещён, пароль=$PASSWORD_AUTH"
    warn "НЕ закрывайте сессию! Проверьте вход: ssh $NEW_USER@$SERVER_HOST"
else skip "sshd_config актуален"; fi

# ==============================================================================
# ШАГ 4. ufw
# ==============================================================================
log "--- Шаг 4: ufw ---"
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" >/dev/null && log "ufw: $SSH_PORT/tcp"
ufw allow 80/tcp  >/dev/null && log "ufw: 80/tcp"
ufw allow 443/tcp >/dev/null && log "ufw: 443/tcp"
# панель 3x-ui (2053) НЕ открываем наружу — доступ по SSH-туннелю
ufw status | grep -q "Status: active" && skip "ufw активен" || { log "Включаю ufw"; ufw --force enable; }

# ==============================================================================
# ШАГ 5. fail2ban
# ==============================================================================
log "--- Шаг 5: fail2ban ---"
apt_install python3-systemd
F2B_CHANGED=0
deploy_file /etc/fail2ban/jail.local 644 <<EOF && F2B_CHANGED=1
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
port = $SSH_PORT
EOF
systemctl enable fail2ban >/dev/null 2>&1
if (( F2B_CHANGED )) || ! systemctl is-active --quiet fail2ban; then log "Перезапуск fail2ban"; systemctl restart fail2ban; else skip "fail2ban ок"; fi

# ==============================================================================
# ШАГ 6. Docker
# ==============================================================================
log "--- Шаг 6: Docker ---"
if command -v docker >/dev/null 2>&1; then skip "Docker есть: $(docker --version)"; else log "Ставлю Docker"; curl -fsSL https://get.docker.com | sh; fi
docker compose version >/dev/null 2>&1 || { log "Доставляю docker-compose-plugin"; apt_install docker-compose-plugin; }
systemctl enable --now docker >/dev/null 2>&1
log "Docker готов"

# ==============================================================================
# ШАГ 7. Секреты
# ==============================================================================
log "--- Шаг 7: секреты ---"
[[ -f "$SECRETS_FILE" ]] && { . "$SECRETS_FILE"; skip "Секреты прошлого запуска"; }
XUI_ADMIN_USER="${XUI_ADMIN_USER:-admin}"
XUI_ADMIN_PASS="${XUI_ADMIN_PASS:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)}"
VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
REALITY_SHORTID="${REALITY_SHORTID:-$(openssl rand -hex 8)}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
deploy_file "$SECRETS_FILE" 600 <<EOF >/dev/null || true
XUI_ADMIN_USER="$XUI_ADMIN_USER"
XUI_ADMIN_PASS="$XUI_ADMIN_PASS"
VLESS_UUID="$VLESS_UUID"
REALITY_SHORTID="$REALITY_SHORTID"
REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
EOF

# ==============================================================================
# Сертификат для nginx-сайта (общая функция)
# ==============================================================================
LE_LIVE="/etc/letsencrypt/live/$SERVER_HOST"
gen_selfsigned() {
    mkdir -p "$SSL_DIR"
    [[ -s "$SSL_DIR/selfsigned.crt" && -s "$SSL_DIR/selfsigned.key" ]] && return 0
    log "Самоподписанный cert для $SERVER_HOST"
    local san; [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]] && san="IP:$SERVER_HOST" || san="DNS:$SERVER_HOST"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$SSL_DIR/selfsigned.key" -out "$SSL_DIR/selfsigned.crt" \
        -subj "/CN=$SERVER_HOST" -addext "subjectAltName=$san"
    chmod 600 "$SSL_DIR/selfsigned.key"
}

if [[ "$ROLE" != "outbound" ]]; then
    echo ""
    warn "Роль inbound и AmneziaWG-туннель будут добавлены на Стадии 3."
    warn "Сейчас реализован только OUTBOUND (3x-ui VLESS-Reality). Запустите с ролью outbound."
    exit 0
fi

# ##############################################################################
# OUTBOUND — Стадия 1: 3x-ui (VLESS-Reality) + nginx + HAProxy
# ##############################################################################
log "--- Стадия 1 (outbound): 3x-ui + nginx + HAProxy ---"

mkdir -p "$STACK_DIR" "$NGINX_DIR/conf.d" "$STUB_DIR" "$SSL_DIR" "$XUI_DB_DIR"
chmod 700 "$STACK_DIR"

deploy_stub "$STUB_DIR" >/dev/null || true
gen_selfsigned

# Выбор cert для nginx
CERT_CRT="$SSL_DIR/selfsigned.crt"; CERT_KEY="$SSL_DIR/selfsigned.key"; CERT_DESC="самоподписанный"
if [[ "$CERT_MODE" != "1" && -s "$LE_LIVE/fullchain.pem" ]]; then
    CERT_CRT="$LE_LIVE/fullchain.pem"; CERT_KEY="$LE_LIVE/privkey.pem"; CERT_DESC="Let's Encrypt"
fi

# --- nginx: :80 (ACME) + 127.0.0.1:SITE_TLS_PORT (TLS легит-сайт за HAProxy) ---
render_nginx() {
    deploy_file "$NGINX_CONF" 644 <<EOF
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ { root /var/www/site; default_type "text/plain"; try_files \$uri =404; }
    location / { root /var/www/site; index index.html; try_files \$uri \$uri/ =404; }
}
server {
    listen 127.0.0.1:$SITE_TLS_PORT ssl default_server;
    server_name _;
    server_tokens off;
    ssl_certificate     $CERT_CRT;
    ssl_certificate_key $CERT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { root /var/www/site; index index.html; try_files \$uri \$uri/ =404; }
}
EOF
}
render_nginx >/dev/null || true

# --- HAProxy :443 SNI: Reality-маска -> 3x-ui; иначе -> легит-сайт ---
deploy_file "$HAPROXY_CFG" 644 <<EOF >/dev/null || true
global
    log stdout format raw local0
    maxconn 10000
defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout check   5s
frontend fe_443
    bind 0.0.0.0:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl sni_reality req.ssl_sni -i $REALITY_SNI
    use_backend be_xui if sni_reality
    default_backend be_site
backend be_xui
    server xui 127.0.0.1:$XUI_REALITY_PORT check
backend be_site
    server site 127.0.0.1:$SITE_TLS_PORT check
EOF

# --- docker-compose: 3x-ui + nginx + haproxy (все host-net) ---
deploy_file "$STACK_DIR/docker-compose.yml" 600 <<EOF >/dev/null || true
services:
  3x-ui:
    image: $XUI_IMAGE
    container_name: 3x-ui
    hostname: 3x-ui
    network_mode: host
    volumes:
      - ./xui-db:/etc/x-ui
      - /etc/letsencrypt:/etc/letsencrypt:ro
    environment:
      - XRAY_VMESS_AEAD_FORCED=false
    restart: unless-stopped
  nginx:
    image: nginx:stable
    container_name: rt-nginx
    network_mode: host
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/site:/var/www/site:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    restart: unless-stopped
  haproxy:
    image: haproxy:lts-alpine
    container_name: rt-haproxy
    user: "root"
    network_mode: host
    depends_on: [3x-ui, nginx]
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: unless-stopped
EOF

# Освобождаем 80/443 от системного nginx, если был
if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "Останавливаю системный nginx (порты займут контейнеры)"; systemctl disable --now nginx 2>/dev/null || true
fi

log "Поднимаю стек (docker compose up -d) — первый запуск тянет образ 3x-ui"
(cd "$STACK_DIR" && docker compose up -d)

# --- Панель 3x-ui: логин/пароль/порт/корень через CLI (без HTTP/CSRF) ---
log "Жду контейнер 3x-ui ..."
for _ in $(seq 1 30); do [[ "$(docker inspect -f '{{.State.Running}}' 3x-ui 2>/dev/null || echo false)" == "true" ]] && break; sleep 2; done
if docker exec 3x-ui /app/x-ui setting -username "$XUI_ADMIN_USER" -password "$XUI_ADMIN_PASS" \
        -port "$XUI_PANEL_PORT" -webBasePath / >/dev/null 2>&1; then
    log "Панель: логин/пароль/порт/корень заданы через CLI"
    (cd "$STACK_DIR" && docker compose restart 3x-ui) >/dev/null 2>&1 || true
else
    warn "x-ui setting не сработал — панель пока admin/admin, поправьте вручную"
fi

# --- Reality-ключи (x25519) через xray в контейнере ---
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    log "Генерирую Reality-ключи (x25519)"
    XOUT=$(docker exec 3x-ui sh -c '
        for b in /app/bin/xray-linux-amd64 /app/bin/xray-linux-arm64 /app/bin/xray /usr/bin/xray "$(command -v xray 2>/dev/null)"; do
            [ -x "$b" ] && { "$b" x25519; exit 0; }
        done; exit 1' 2>/dev/null || true)
    REALITY_PRIVATE_KEY=$(echo "$XOUT" | awk -F': *' '/[Pp]rivate/{print $2}' | tr -d ' \r' | head -1)
    REALITY_PUBLIC_KEY=$(echo "$XOUT"  | awk -F': *' '/[Pp]ublic/{print $2}'  | tr -d ' \r' | head -1)
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Не удалось сгенерировать Reality-ключи (xray x25519). Лог: docker logs 3x-ui"
    deploy_file "$SECRETS_FILE" 600 <<EOF >/dev/null || true
XUI_ADMIN_USER="$XUI_ADMIN_USER"
XUI_ADMIN_PASS="$XUI_ADMIN_PASS"
VLESS_UUID="$VLESS_UUID"
REALITY_SHORTID="$REALITY_SHORTID"
REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
EOF
    log "Reality-ключи сгенерированы"
fi

# --- Засев VLESS-Reality инбаунда через HTTP-API 3x-ui ---
PANEL="http://127.0.0.1:$XUI_PANEL_PORT"
log "Жду ответа панели ($PANEL) ..."
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 3 "$PANEL" 2>/dev/null && break; sleep 2; done

xui_csrf() { curl -s -b "$1" -c "$1" --max-time 5 "$PANEL/csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null; }

seed_inbound() {
    local jar=/tmp/rt-xui.cookie t1 t2 payload result; rm -f "$jar"
    t1=$(xui_csrf "$jar"); [[ -n "$t1" ]] || return 1
    curl -s -b "$jar" -c "$jar" --max-time 5 -X POST "$PANEL/login" -H "X-CSRF-Token: $t1" \
        --data-urlencode "username=$XUI_ADMIN_USER" --data-urlencode "password=$XUI_ADMIN_PASS" -o /dev/null 2>/dev/null || return 1
    t2=$(xui_csrf "$jar"); [[ -n "$t2" ]] || t2="$t1"
    # идемпотентность: не дублировать инбаунд на нашем порту
    if curl -s -b "$jar" --max-time 8 "$PANEL/panel/api/inbounds/list" 2>/dev/null \
         | jq -e --argjson p "$XUI_REALITY_PORT" '.obj[]?|select(.port==$p)' >/dev/null 2>&1; then
        rm -f "$jar"; skip "Инбаунд на порту $XUI_REALITY_PORT уже есть"; return 0
    fi
    local settings stream
    settings=$(jq -cn --arg id "$VLESS_UUID" '{clients:[{id:$id,flow:"xtls-rprx-vision",email:"user1",enable:true}],decryption:"none"}')
    stream=$(jq -cn --arg dest "$REALITY_SNI:443" --arg sni "$REALITY_SNI" --arg priv "$REALITY_PRIVATE_KEY" \
                    --arg pub "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORTID" \
        '{network:"tcp",security:"reality",realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$sni],privateKey:$priv,shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",spiderX:"/"}}}')
    payload=$(jq -cn --arg remark "VLESS-Reality" --argjson port "$XUI_REALITY_PORT" \
                     --arg settings "$settings" --arg stream "$stream" \
        '{enable:true,remark:$remark,listen:"127.0.0.1",port:$port,protocol:"vless",expiryTime:0,settings:$settings,streamSettings:$stream,sniffing:"{\"enabled\":false}",tag:("inbound-reality-"+($port|tostring))}')
    result=$(curl -s -b "$jar" --max-time 8 -X POST "$PANEL/panel/api/inbounds/add" \
        -H "X-CSRF-Token: $t2" -H "Content-Type: application/json" -d "$payload" 2>/dev/null || echo '{"success":false}')
    rm -f "$jar"
    echo "$result" | jq -e '.success==true' >/dev/null 2>&1 && { log "VLESS-Reality инбаунд добавлен (порт $XUI_REALITY_PORT)"; return 0; }
    warn "Ответ API: $(echo "$result" | tr -d '\n' | head -c 300)"; return 1
}
seed_inbound || warn "Инбаунд не добавлен автоматически — добавьте вручную в панели (см. лог)."

# --- certbot для легит-сайта (если LE) ---
rt_nginx_reload() { docker exec rt-nginx nginx -t && docker exec rt-nginx nginx -s reload; }
if [[ "$CERT_MODE" != "1" && ! -s "$LE_LIVE/fullchain.pem" ]]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    deploy_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 755 <<'EOF' >/dev/null || true
#!/bin/sh
docker exec rt-nginx nginx -s reload
EOF
    if [[ "$CERT_MODE" == "2" ]]; then
        apt_install certbot
        certbot certonly --webroot -w "$STUB_DIR" -d "$SERVER_HOST" --non-interactive --agree-tos -m "$LE_EMAIL" \
            || warn "LE (HTTP-01) не удалось — остаюсь на самоподписанном."
    else
        apt_install certbot python3-certbot-dns-cloudflare
        mkdir -p "$(dirname "$CF_CREDS_FILE")"; chmod 700 "$(dirname "$CF_CREDS_FILE")"
        [[ -n "$CF_TOKEN" ]] && { printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_CREDS_FILE"; chmod 600 "$CF_CREDS_FILE"; }
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS_FILE" \
            --dns-cloudflare-propagation-seconds 30 -d "$SERVER_HOST" --non-interactive --agree-tos -m "$LE_EMAIL" \
            || warn "LE (DNS-01) не удалось — остаюсь на самоподписанном."
    fi
    if [[ -s "$LE_LIVE/fullchain.pem" ]]; then
        CERT_CRT="$LE_LIVE/fullchain.pem"; CERT_KEY="$LE_LIVE/privkey.pem"; CERT_DESC="Let's Encrypt"
        render_nginx >/dev/null || true; rt_nginx_reload || true; log "nginx переключён на Let's Encrypt"
    fi
fi

# --- Клиентская VLESS-Reality ссылка (на Стадии 1 — напрямую к этому серверу) ---
VLESS_LINK="vless://${VLESS_UUID}@${SERVER_HOST}:443?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI}&sid=${REALITY_SHORTID}&flow=xtls-rprx-vision#${SERVER_HOST}-reality"

deploy_file "$INFO_FILE" 600 <<EOF >/dev/null || true
============================================================
 reality-telemt — OUTBOUND (Стадия 1)
============================================================
 Панель 3x-ui:   http://127.0.0.1:$XUI_PANEL_PORT  (только локально!)
   доступ:       ssh -L $XUI_PANEL_PORT:127.0.0.1:$XUI_PANEL_PORT $NEW_USER@$SERVER_HOST
                 затем открыть http://127.0.0.1:$XUI_PANEL_PORT
   логин/пароль: $XUI_ADMIN_USER / $XUI_ADMIN_PASS
 Легит-сайт TLS: $CERT_DESC
 SSH:            $NEW_USER@$SERVER_HOST (root по SSH запрещён, порт $SSH_PORT/tcp)

 VLESS-Reality (на Стадии 1 — прямое подключение к этому серверу):
 $VLESS_LINK

 Маска Reality: $REALITY_SNI   UUID: $VLESS_UUID
 (двойной прыжок и telemt — Стадии 2-3)
============================================================
EOF

echo ""
echo "=============================================================="
echo "  OUTBOUND (Стадия 1) ГОТОВ"
echo "=============================================================="
echo ""
echo "  Панель 3x-ui:  http://127.0.0.1:$XUI_PANEL_PORT  (по SSH-туннелю)"
echo "    ssh -L $XUI_PANEL_PORT:127.0.0.1:$XUI_PANEL_PORT $NEW_USER@$SERVER_HOST"
echo "    логин/пароль: $XUI_ADMIN_USER / $XUI_ADMIN_PASS"
echo ""
echo "  VLESS-Reality ссылка (импортируйте в клиент):"
echo "    $VLESS_LINK"
echo ""
echo "  Памятка: $INFO_FILE   Лог: $LOG_FILE"
echo "  ВАЖНО: проверьте вход в новом окне (ssh $NEW_USER@$SERVER_HOST) — root по SSH закрыт."
echo ""
log "Стадия 1 завершена"
