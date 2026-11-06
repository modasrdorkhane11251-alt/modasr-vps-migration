#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DRY_RUN="${MIGRATE_DRY_RUN:-0}"
if [[ "$DRY_RUN" == "1" ]]; then
  LOG_FILE="${MIGRATE_DRY_RUN_LOG:-/tmp/modasr-migrate-dry.log}"
else
  LOG_FILE="/var/log/modasr-migrate.log"
fi
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[FAILED] Migration stopped at line $LINENO. Review $LOG_FILE" >&2' ERR

if [[ "$(id -u)" -ne 0 && "$DRY_RUN" != "1" ]]; then
  echo "Run as root on the NEW Ubuntu 24.04 server."
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

say() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
require_command() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
read_domain() {
  local value
  while true; do
    read -rp "$1" value
    if valid_domain "$value"; then printf '%s' "$value"; return; fi
    echo "Invalid domain. Enter a hostname such as example.com"
  done
}
read_secret() { read -rsp "$1" "$2"; printf '\n'; }
run() { if [[ "$DRY_RUN" == "1" ]]; then say "DRY: $*"; else eval "$*"; fi; }

say "MODASR migration starts. Secrets are never printed or logged."
read -rp "Source VPS IPv4: " SOURCE_HOST
read -rp "Source SSH username [root]: " SOURCE_USER
SOURCE_USER="${SOURCE_USER:-root}"
read_secret "Source SSH password (hidden): " SOURCE_PASSWORD
SITE_DOMAIN="$(read_domain 'Website domain (for shop and n8n): ')"
PANEL_DOMAIN="$(read_domain 'Bot/panel domain: ')"
read -rp "SSL email (optional): " SSL_EMAIL
read -rp "Telegram owner numeric ID: " ADMIN_TELEGRAM_ID
read -rp "Bale owner ID (optional): " ADMIN_BALE_ID
read -rp "Rubika owner ID (optional): " ADMIN_RUBIKA_ID
read -rp "Soroush owner ID (optional): " ADMIN_SOROUSH_ID
read_secret "Telegram bot token (hidden): " TELEGRAM_TOKEN
read_secret "Bale bot token (hidden): " BALE_TOKEN
read_secret "Rubika bot token (hidden): " RUBIKA_TOKEN
read_secret "Soroush Plus bot token (hidden): " SOROUSH_TOKEN
read -rp "Start production services after migration? [y/N]: " START_NOW
START_NOW="${START_NOW:-N}"
read_secret "New MySQL root password (blank = generate): " NEW_DB_ROOT_PASSWORD
if [[ -z "$NEW_DB_ROOT_PASSWORD" ]]; then
  NEW_DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  say "DRY RUN: source=$SOURCE_HOST user=$SOURCE_USER website=$SITE_DOMAIN panel=$PANEL_DOMAIN start=$START_NOW"
  say "No downloads, package installation, database writes, DNS changes or service changes would run."
  exit 0
fi

require_command apt-get
require_command curl
require_command openssl
require_command rsync
require_command sshpass
require_command php
require_command docker
require_command python3

export SSHPASS="$SOURCE_PASSWORD"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no)
SOURCE_SSH="$SOURCE_USER@$SOURCE_HOST"

say "Checking source VPS access"
sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" 'echo SOURCE_CONNECTION_OK'

say "Validating bot tokens with getMe"
validate_token() {
  local platform="$1" token="$2" url
  case "$platform" in
    telegram) url="https://api.telegram.org/bot${token}/getMe" ;;
    bale) url="https://tapi.bale.ai/bot${token}/getMe" ;;
    splus) url="https://api.splus.ir/bot${token}/getMe" ;;
    rubika) url="https://botapi.rubika.ir/v3/${token}/getMe" ;;
  esac
  local response
  response="$(curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' -d '{}' "$url")"
  if [[ "$platform" == "rubika" ]]; then
    grep -q '"status"[[:space:]]*:[[:space:]]*"OK"' <<<"$response"
  else
    grep -q '"ok"[[:space:]]*:[[:space:]]*true' <<<"$response"
  fi
}
validate_token telegram "$TELEGRAM_TOKEN"
validate_token bale "$BALE_TOKEN"
validate_token rubika "$RUBIKA_TOKEN"
validate_token splus "$SOROUSH_TOKEN"
say "All four platform tokens validated"

say "Installing required packages"
apt-get update
apt-get install -y apache2 php libapache2-mod-php php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip \
  nodejs npm docker.io docker-compose-v2 certbot python3-certbot-apache rsync sshpass curl jq openssl unzip dnsutils
systemctl enable --now docker apache2
if ! node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 20 ? 0 : 1)" >/dev/null 2>&1; then
  say "Installing Node.js 20 from the official NodeSource repository"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
if [[ -f /var/www/modasr-site/package-lock.json ]]; then
  (cd /var/www/modasr-site && npm ci --omit=dev)
fi
if ! id modasrstaging >/dev/null 2>&1; then
  useradd --system --home /nonexistent --shell /usr/sbin/nologin modasrstaging
fi

sync_tree() {
  local remote="$1" destination="$2"
  mkdir -p "$destination"
  sshpass -e rsync -az -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:$remote/" "$destination/"
}

say "Copying current application files from the source VPS"
sync_tree /var/www/html/mirzaprobotconfig /var/www/html/mirzaprobotconfig
sync_tree /var/www/modasr-site /var/www/modasr-site
sync_tree /var/www/modasr-hosting-full /var/www/modasr-hosting-full
sync_tree /var/www/modasr-hosting-factory /var/www/modasr-hosting-factory
sync_tree /var/www/modasr-hosting-staging /var/www/modasr-hosting-staging
sync_tree /var/www/modasr-hosting-tenants /var/www/modasr-hosting-tenants
sync_tree /var/www/modasr-private /var/www/modasr-private
sync_tree /var/www/modasr-auth-staging /var/www/modasr-auth-staging

mkdir -p /usr/local/sbin /etc/systemd/system /etc/apache2/sites-available /etc/sudoers.d
sshpass -e rsync -az --include='modasr-*' --exclude='*' -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:/usr/local/sbin/" /usr/local/sbin/
sshpass -e rsync -az --include='modasr*.service' --exclude='*' -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:/etc/systemd/system/" /etc/systemd/system/
sshpass -e rsync -az --include='bot.modasr.site*' --include='modasr.site*' --include='shop.modasr.site*' --include='n8n.modasr.site*' --exclude='*' -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:/etc/apache2/sites-available/" /etc/apache2/sites-available/
sshpass -e rsync -az --include='modasr*' --exclude='*' -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:/etc/sudoers.d/" /etc/sudoers.d/

say "Dumping every source database, including users and grants"
MIGRATION_DB_DIR="/var/backups/modasr-migration"
mkdir -p "$MIGRATION_DB_DIR"
sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" "docker exec modasr-hosting-mysql sh -c 'mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --all-databases --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4' | gzip -1" > "$MIGRATION_DB_DIR/all-databases.sql.gz"
gzip -t "$MIGRATION_DB_DIR/all-databases.sql.gz"

say "Starting MySQL and restoring databases"
if ! docker inspect modasr-hosting-mysql >/dev/null 2>&1; then
  docker volume create modasr_mysql_data >/dev/null
  docker run -d --name modasr-hosting-mysql --restart unless-stopped \
    -p 127.0.0.1:3307:3306 \
    -e MYSQL_ROOT_PASSWORD="$NEW_DB_ROOT_PASSWORD" \
    -v modasr_mysql_data:/var/lib/mysql \
    mysql:8.0
fi
for attempt in {1..45}; do
  if docker exec modasr-hosting-mysql sh -c 'mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" ping' >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$attempt" == "45" ]]; then echo "MySQL did not become ready"; exit 1; fi
done
zcat "$MIGRATION_DB_DIR/all-databases.sql.gz" | docker exec -i modasr-hosting-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
docker exec modasr-hosting-mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;\""

say "Restoring n8n and its persistent data"
N8N_ENCRYPTION_KEY="$(sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" 'docker exec n8n printenv N8N_ENCRYPTION_KEY' || true)"
N8N_SOURCE_VOLUME="$(sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" "docker inspect n8n --format '{{range .Mounts}}{{.Source}}{{end}}'" | head -n 1)"
if [[ -n "$N8N_SOURCE_VOLUME" ]]; then
  docker volume create n8n_data >/dev/null
  mkdir -p /var/lib/docker/volumes/n8n_data/_data
  sshpass -e rsync -az -e "ssh ${SSH_OPTS[*]}" "$SOURCE_SSH:$N8N_SOURCE_VOLUME/" /var/lib/docker/volumes/n8n_data/_data/
fi
if ! docker inspect n8n >/dev/null 2>&1; then
  N8N_ENV=()
  if [[ -n "$N8N_ENCRYPTION_KEY" ]]; then N8N_ENV=(-e "N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY"); fi
  docker run -d --name n8n --restart unless-stopped -p 127.0.0.1:5678:5678 "${N8N_ENV[@]}" -v n8n_data:/home/node/.n8n n8nio/n8n:latest
fi

say "Updating domains, tokens and owner IDs"
# Domain updates are deliberately scoped to known config files, not the whole filesystem.
for file in /etc/apache2/sites-available/bot.modasr.site*.conf; do
  [[ -f "$file" ]] && sed -i "s#bot.modasr.site#${PANEL_DOMAIN}#g" "$file"
done
for file in /etc/apache2/sites-available/modasr.site*.conf; do
  [[ -f "$file" ]] && sed -i "s#modasr.site#${SITE_DOMAIN}#g" "$file"
done
for file in /etc/apache2/sites-available/shop.modasr.site*.conf; do
  [[ -f "$file" ]] && sed -i "s#shop.modasr.site#shop.${SITE_DOMAIN}#g" "$file"
done
for file in /etc/apache2/sites-available/n8n.modasr.site*.conf; do
  [[ -f "$file" ]] && sed -i "s#n8n.modasr.site#n8n.${SITE_DOMAIN}#g" "$file"
done
sed -i "s#bot.modasr.site#${PANEL_DOMAIN}#g" /var/www/html/mirzaprobotconfig/config.php
sed -i "s#^\$APIKEY = .*#\$APIKEY = '${TELEGRAM_TOKEN}';#" /var/www/html/mirzaprobotconfig/config.php
sed -i "s#'bale' => '[^']*'#'bale' => '${BALE_TOKEN}'#g" /var/www/html/mirzaprobotconfig/config.php
sed -i "s#'rubika' => '[^']*'#'rubika' => '${RUBIKA_TOKEN}'#g" /var/www/html/mirzaprobotconfig/config.php
sed -i "s#'splus' => '[^']*'#'splus' => '${SOROUSH_TOKEN}'#g" /var/www/html/mirzaprobotconfig/config.php

set_env_value() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}
set_env_value /var/www/modasr-site/.env BOT_API_BASE "https://${PANEL_DOMAIN}"
set_env_value /var/www/modasr-hosting-staging/.env TELEGRAM_TOKEN "$TELEGRAM_TOKEN"
set_env_value /var/www/modasr-hosting-staging/.env MODASR_OWNER_TELEGRAM_ID "$ADMIN_TELEGRAM_ID"
if [[ -n "$ADMIN_BALE_ID" ]]; then set_env_value /var/www/modasr-hosting-staging/.env MODASR_OWNER_BALE_ID "$ADMIN_BALE_ID"; fi
if [[ -n "$ADMIN_RUBIKA_ID" ]]; then set_env_value /var/www/modasr-hosting-staging/.env MODASR_OWNER_RUBIKA_ID "$ADMIN_RUBIKA_ID"; fi
if [[ -n "$ADMIN_SOROUSH_ID" ]]; then set_env_value /var/www/modasr-hosting-staging/.env MODASR_OWNER_SOROUSH_ID "$ADMIN_SOROUSH_ID"; fi

docker exec modasr-hosting-mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"UPDATE admin SET id_admin='${ADMIN_TELEGRAM_ID}'\""

chown -R www-data:www-data /var/www/html/mirzaprobotconfig /var/www/modasr-site /var/www/modasr-auth-staging
chown -R root:modasrstaging /var/www/modasr-hosting-full /var/www/modasr-hosting-factory /var/www/modasr-hosting-staging /var/www/modasr-hosting-tenants /var/www/modasr-private
find /var/www/modasr-hosting-tenants -type d -exec chmod 0770 {} +
find /var/www/modasr-hosting-tenants -name '.env' -type f -exec chmod 0600 {} +

say "Checking PHP syntax"
php -l /var/www/html/mirzaprobotconfig/config.php
php -l /var/www/html/mirzaprobotconfig/index.php
php -l /var/www/html/mirzaprobotconfig/function.php

say "Enabling Apache sites and modules"
a2enmod ssl proxy proxy_http proxy_ssl rewrite headers
for file in /etc/apache2/sites-available/*.conf; do
  [[ -f "$file" ]] && a2ensite "$(basename "$file")"
done
apache2ctl configtest
systemctl reload apache2

PUBLIC_IP="$(curl -fsS --max-time 20 https://api.ipify.org || true)"
DNS_READY=0
if [[ -n "$PUBLIC_IP" ]]; then
  DNS_READY=1
  for host in "$SITE_DOMAIN" "$PANEL_DOMAIN" "shop.${SITE_DOMAIN}" "n8n.${SITE_DOMAIN}"; do
    if ! dig +short A "$host" | grep -Fxq "$PUBLIC_IP"; then DNS_READY=0; fi
  done
fi

if [[ "$DNS_READY" == "1" ]]; then
  say "DNS matches this server. Issuing or renewing TLS certificates"
  if [[ -n "$SSL_EMAIL" ]]; then
    certbot --apache --non-interactive --agree-tos --email "$SSL_EMAIL" -d "$SITE_DOMAIN" -d "$PANEL_DOMAIN" -d "shop.${SITE_DOMAIN}" -d "n8n.${SITE_DOMAIN}"
  else
    certbot --apache --non-interactive --agree-tos --register-unsafely-without-email -d "$SITE_DOMAIN" -d "$PANEL_DOMAIN" -d "shop.${SITE_DOMAIN}" -d "n8n.${SITE_DOMAIN}"
  fi
else
  say "DNS is not pointing to this server yet; certbot and production start are paused"
  START_NOW="N"
fi

if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
  say "Stopping services on the old server before starting the new services"
  sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" 'systemctl stop modasr-site modasr-hosting-staging modasr-hosting-full-php modasr-hosting-tenant-1.service modasr-hosting-tenant-2.service; docker stop n8n || true'

  systemctl daemon-reload
  systemctl enable --now modasr-site modasr-hosting-staging modasr-hosting-full-php
  for unit in /etc/systemd/system/modasr-hosting-tenant-*.service; do
    [[ -f "$unit" ]] && systemctl enable --now "$(basename "$unit")"
  done
  docker start n8n || true
  systemctl reload apache2

  say "Updating Telegram, Bale and Soroush webhooks to the new panel domain"
  TELEGRAM_WEBHOOK="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getWebhookInfo" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["url"])')"
  if [[ -n "$TELEGRAM_WEBHOOK" ]]; then
    NEW_WEBHOOK="$(python3 -c "from urllib.parse import urlsplit,urlunsplit;u=urlsplit('${TELEGRAM_WEBHOOK}');print(urlunsplit((u.scheme,'${PANEL_DOMAIN}',u.path,u.query,u.fragment))")"
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook" --data-urlencode "url=${NEW_WEBHOOK}" --data-urlencode "drop_pending_updates=false"
    curl -fsS -X POST "https://tapi.bale.ai/bot${BALE_TOKEN}/setWebhook" --data-urlencode "url=${NEW_WEBHOOK}" --data-urlencode "drop_pending_updates=false"
    curl -fsS -X POST "https://api.splus.ir/bot${SOROUSH_TOKEN}/setWebhook" --data-urlencode "url=${NEW_WEBHOOK}" --data-urlencode "drop_pending_updates=false"
  fi
  say "Updating Rubika endpoints"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"type\":\"ReceiveUpdate\",\"url\":\"https://${PANEL_DOMAIN}/index.php\"}" "https://botapi.rubika.ir/v3/${RUBIKA_TOKEN}/updateBotEndpoints" || true
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"type\":\"ReceiveInlineMessage\",\"url\":\"https://${PANEL_DOMAIN}/index.php\"}" "https://botapi.rubika.ir/v3/${RUBIKA_TOKEN}/updateBotEndpoints" || true

  say "Running the production health check"
  if ! curl -fsS --max-time 25 "https://${PANEL_DOMAIN}/api/storefront_catalog" | grep -q '"status"[[:space:]]*:[[:space:]]*true'; then
    say "Health check failed; restoring the old services"
    systemctl stop modasr-site modasr-hosting-staging modasr-hosting-full-php || true
    for unit in /etc/systemd/system/modasr-hosting-tenant-*.service; do systemctl stop "$(basename "$unit")" || true; done
    docker stop n8n || true
    sshpass -e ssh "${SSH_OPTS[@]}" "$SOURCE_SSH" 'systemctl start modasr-site modasr-hosting-staging modasr-hosting-full-php modasr-hosting-tenant-1.service modasr-hosting-tenant-2.service; docker start n8n || true'
    exit 1
  fi
  say "Migration completed successfully. The new website, panel and bots are running."
else
  say "Files and databases are restored. Production services were not started because DNS/start approval is pending."
  say "After DNS is ready, run this script again and choose Start production services."
fi

unset SSHPASS SOURCE_PASSWORD TELEGRAM_TOKEN BALE_TOKEN RUBIKA_TOKEN SOROUSH_TOKEN NEW_DB_ROOT_PASSWORD N8N_ENCRYPTION_KEY
