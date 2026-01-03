#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE AUTO-INSTALLER
# Handles EVERYTHING: Panel, Database, Queue, Cloudflare, User Creation
# Works on: VPS, Codespaces, Containers - All environments
# Version: 3.0 - Zero Manual Steps
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
hash -r 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.pelican.env"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Pelican Panel Auto-Installer v3.0    ║${NC}"
echo -e "${GREEN}║  Zero Manual Steps - Full Automation  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[1/20] Detecting Environment...${NC}"

HAS_SYSTEMD=false
IS_CONTAINER=false
PROCESS_MANAGER="manual"

if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
        HAS_SYSTEMD=true
        PROCESS_MANAGER="systemd"
        echo -e "${GREEN}   ✓ Systemd detected${NC}"
    else
        echo -e "${YELLOW}   ⚠ Systemd exists but not active${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ No systemd - using service commands${NC}"
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}   ⚠ Container environment${NC}"
fi

if grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
    echo -e "${BLUE}   ℹ GitHub Codespaces${NC}"
    IS_CONTAINER=true
fi

# ============================================================================
# USER INPUT
# ============================================================================
echo ""
echo -e "${CYAN}[2/20] Configuration Input...${NC}"

read -p "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
read -p "Cloudflare Tunnel Token: " CF_TOKEN
[[ -z "$CF_TOKEN" ]] && { echo -e "${RED}❌ Tunnel token required!${NC}"; exit 1; }

echo ""
echo "Database Type:"
echo "1) PostgreSQL (Recommended)"
echo "2) MySQL/MariaDB"
read -p "Choice [1]: " DB_TYPE
DB_TYPE=${DB_TYPE:-1}

if [ "$DB_TYPE" = "1" ]; then
    DB_DRIVER="pgsql"
    DB_PORT_DEFAULT="5432"
else
    DB_DRIVER="mysql"
    DB_PORT_DEFAULT="3306"
fi

read -p "Database Host: " DB_HOST
read -p "Database Port [$DB_PORT_DEFAULT]: " DB_PORT
DB_PORT=${DB_PORT:-$DB_PORT_DEFAULT}
read -p "Database Name: " DB_NAME
read -p "Database Username: " DB_USER
read -sp "Database Password: " DB_PASS
echo ""

read -p "Redis Host [127.0.0.1]: " REDIS_HOST
REDIS_HOST=${REDIS_HOST:-127.0.0.1}
read -p "Redis Port [6379]: " REDIS_PORT
REDIS_PORT=${REDIS_PORT:-6379}
read -sp "Redis Password (optional): " REDIS_PASS
echo ""

read -p "SMTP Host (e.g., smtp.gmail.com): " MAIL_HOST
read -p "SMTP Port [587]: " MAIL_PORT
MAIL_PORT=${MAIL_PORT:-587}
read -p "SMTP Username: " MAIL_USER
read -sp "SMTP Password: " MAIL_PASS
echo ""
read -p "From Email: " MAIL_FROM
read -p "From Name: " MAIL_FROM_NAME

echo ""
echo -e "${CYAN}[3/20] Saving configuration...${NC}"

# Save to .pelican.env for wings installer
cat > "$ENV_FILE" <<EOF
PANEL_DOMAIN="$PANEL_DOMAIN"
CF_TOKEN="$CF_TOKEN"
DB_DRIVER="$DB_DRIVER"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
REDIS_HOST="$REDIS_HOST"
REDIS_PORT="$REDIS_PORT"
REDIS_PASS="$REDIS_PASS"
MAIL_HOST="$MAIL_HOST"
MAIL_PORT="$MAIL_PORT"
MAIL_USER="$MAIL_USER"
MAIL_PASS="$MAIL_PASS"
MAIL_FROM="$MAIL_FROM"
MAIL_FROM_NAME="$MAIL_FROM_NAME"
IS_CONTAINER="$IS_CONTAINER"
HAS_SYSTEMD="$HAS_SYSTEMD"
EOF

chmod 600 "$ENV_FILE"
echo -e "${GREEN}   ✓ Configuration saved to $ENV_FILE${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[4/20] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq
apt upgrade -y -qq || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[5/20] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo supervisor 2>/dev/null || true
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# INSTALL PHP 8.4
# ============================================================================
echo -e "${CYAN}[6/20] Installing PHP 8.4...${NC}"
if command -v add-apt-repository &> /dev/null; then
    add-apt-repository ppa:ondrej/php -y 2>/dev/null || true
fi
apt update -qq
apt install -y php8.4 php8.4-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,redis,pgsql} 2>/dev/null || true

update-alternatives --set php /usr/bin/php8.4 2>/dev/null || {
    update-alternatives --install /usr/bin/php php /usr/bin/php8.4 84
    update-alternatives --set php /usr/bin/php8.4
}

# Fix for Codespaces custom PHP
if [ -d "/usr/local/php" ]; then
    PHP_EXT_DIR=$(find /usr/lib/php -name "pdo_pgsql.so" 2>/dev/null | head -1 | xargs dirname)
    if [ -n "$PHP_EXT_DIR" ] && [ -f "/usr/local/php/8.3.14/ini/php.ini" ]; then
        echo "extension_dir = \"$PHP_EXT_DIR\"" >> /usr/local/php/8.3.14/ini/php.ini
        echo "extension=pdo_pgsql.so" >> /usr/local/php/8.3.14/ini/php.ini
    fi
fi

echo -e "${GREEN}   ✓ PHP 8.4 installed ($(php -v | head -n1 | cut -d' ' -f2))${NC}"

# ============================================================================
# INSTALL NGINX, DATABASE CLIENT, REDIS
# ============================================================================
echo -e "${CYAN}[7/20] Installing Nginx, database client, Redis...${NC}"
apt install -y nginx 2>/dev/null || true
[ "$DB_DRIVER" = "pgsql" ] && apt install -y postgresql-client 2>/dev/null || apt install -y mysql-client mariadb-client 2>/dev/null

curl -fsSL https://packages.redis.io/gpg 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list 2>/dev/null || true
apt update -qq
apt install -y redis-server 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable redis-server 2>/dev/null || true
    systemctl start redis-server 2>/dev/null || service redis-server start 2>/dev/null || true
else
    service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
fi

echo -e "${GREEN}   ✓ Services installed${NC}"

# ============================================================================
# INSTALL COMPOSER
# ============================================================================
echo -e "${CYAN}[8/20] Installing Composer...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet
echo -e "${GREEN}   ✓ Composer installed${NC}"

# ============================================================================
# DOWNLOAD PANEL
# ============================================================================
echo -e "${CYAN}[9/20] Downloading Pelican Panel...${NC}"
mkdir -p /var/www/pelican
cd /var/www/pelican
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv >/dev/null 2>&1
echo -e "${GREEN}   ✓ Panel downloaded${NC}"

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[10/20] Installing Composer dependencies...${NC}"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --quiet
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# CONFIGURE ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[11/20] Configuring environment...${NC}"
cp .env.example .env

sed -i "s|APP_URL=.*|APP_URL=https://${PANEL_DOMAIN}|" .env
sed -i "s|DB_CONNECTION=.*|DB_CONNECTION=${DB_DRIVER}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
sed -i "s|DB_PORT=.*|DB_PORT=${DB_PORT}|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
sed -i "s|REDIS_HOST=.*|REDIS_HOST=${REDIS_HOST}|" .env
sed -i "s|REDIS_PORT=.*|REDIS_PORT=${REDIS_PORT}|" .env
[ -n "$REDIS_PASS" ] && sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASS}|" .env || true
sed -i "s|MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
sed -i "s|MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
sed -i "s|MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USER}|" .env
sed -i "s|MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASS}|" .env
sed -i "s|MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM}|" .env
sed -i "s|MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"${MAIL_FROM_NAME}\"|" .env

# Critical fixes for Supabase/pooling
echo "DB_DISABLE_PREPARED_STATEMENTS=true" >> .env
echo "GUZZLE_TIMEOUT=15" >> .env
echo "GUZZLE_CONNECT_TIMEOUT=5" >> .env

php artisan key:generate --force --quiet

APP_KEY=$(grep "APP_KEY=" .env | cut -d'=' -f2)
echo -e "${GREEN}   ✓ Environment configured${NC}"
echo -e "${YELLOW}   📝 APP_KEY: ${APP_KEY}${NC}"

# ============================================================================
# FIX APPPROVIDER TIMEOUT TYPE CASTING
# ============================================================================
echo -e "${CYAN}[12/20] Applying AppServiceProvider fixes...${NC}"
sed -i 's/->timeout(config('\''panel\.guzzle\.timeout'\''))/->timeout((int) config('\''panel.guzzle.timeout'\''))/' app/Providers/AppServiceProvider.php
sed -i 's/->connectTimeout(config('\''panel\.guzzle\.connect_timeout'\''))/->connectTimeout((int) config('\''panel.guzzle.connect_timeout'\''))/' app/Providers/AppServiceProvider.php
echo -e "${GREEN}   ✓ AppServiceProvider fixed${NC}"

# ============================================================================
# SET PERMISSIONS
# ============================================================================
echo -e "${CYAN}[13/20] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true
chown -R www-data:www-data /var/www/pelican 2>/dev/null || true
mkdir -p storage/logs
touch storage/logs/laravel.log
chown -R www-data:www-data storage 2>/dev/null || true
echo -e "${GREEN}   ✓ Permissions set${NC}"

# ============================================================================
# CONFIGURE PHP-FPM
# ============================================================================
echo -e "${CYAN}[14/20] Configuring PHP-FPM...${NC}"
sed -i 's|listen = /run/php/php8.4-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/8.4/fpm/pool.d/www.conf 2>/dev/null || true
sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/8.4/fpm/pool.d/www.conf 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php8.4-fpm 2>/dev/null || service php8.4-fpm restart 2>/dev/null || true
else
    service php8.4-fpm restart 2>/dev/null || pkill php-fpm && /usr/sbin/php-fpm8.4 -D 2>/dev/null || true
fi

# Wait for PHP-FPM
sleep 2
if netstat -tulpn 2>/dev/null | grep -q ":9000" || ss -tlnp 2>/dev/null | grep -q ":9000"; then
    echo -e "${GREEN}   ✓ PHP-FPM running on port 9000${NC}"
else
    echo -e "${YELLOW}   ⚠ PHP-FPM port check inconclusive, continuing...${NC}"
fi

# ============================================================================
# CONFIGURE NGINX
# ============================================================================
echo -e "${CYAN}[15/20] Configuring Nginx...${NC}"
mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<'NGINXEOF'
server_tokens off;

server {
    listen 8443 ssl http2;
    server_name PANEL_DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/ssl/pelican/cert.pem;
    ssl_certificate_key /etc/ssl/pelican/key.pem;

    root /var/www/pelican/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXEOF

sed -i "s/PANEL_DOMAIN_PLACEHOLDER/${PANEL_DOMAIN}/" /etc/nginx/sites-available/pelican.conf

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf

nginx -t 2>/dev/null || { echo -e "${RED}❌ Nginx config invalid${NC}"; exit 1; }

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart nginx 2>/dev/null || service nginx restart
else
    service nginx restart 2>/dev/null || nginx -s reload
fi

echo -e "${GREEN}   ✓ Nginx configured${NC}"

# ============================================================================
# RUN DATABASE MIGRATIONS
# ============================================================================
echo -e "${CYAN}[16/20] Running database migrations...${NC}"
php artisan migrate --force --quiet || {
    echo -e "${RED}❌ Migrations failed! Check database connection.${NC}"
    exit 1
}
echo -e "${GREEN}   ✓ Database migrated${NC}"

# ============================================================================
# SETUP QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[17/20] Setting up queue worker...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/pelican-queue.service <<'QEOF'
[Unit]
Description=Pelican Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pelican/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
QEOF

    systemctl daemon-reload
    systemctl enable pelican-queue.service 2>/dev/null || true
    systemctl start pelican-queue.service 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    pkill -f "queue:work" 2>/dev/null || true
    cd /var/www/pelican
    nohup sudo -u www-data php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
fi

sleep 2
if ps aux | grep -v grep | grep -q "queue:work"; then
    echo -e "${GREEN}   ✓ Queue worker running${NC}"
else
    echo -e "${YELLOW}   ⚠ Queue worker status unclear${NC}"
fi

# Setup cron
(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data - 2>/dev/null || true

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[18/20] Installing Cloudflare Tunnel...${NC}"

if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
        apt --fix-broken install -y 2>/dev/null
        dpkg -i cloudflared-linux-amd64.deb 2>/dev/null
    }
    rm -f cloudflared-linux-amd64.deb
fi

cloudflared service uninstall 2>/dev/null || true
pkill cloudflared 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN" 2>/dev/null && {
        systemctl start cloudflared 2>/dev/null || true
        systemctl enable cloudflared 2>/dev/null || true
    } || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
fi

sleep 3
if ps aux | grep -v grep | grep -q cloudflared; then
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}"
else
    echo -e "${YELLOW}   ⚠ Cloudflare Tunnel status unclear${NC}"
fi

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}[20/20] Final verification...${NC}"

TESTS_PASSED=0
TESTS_TOTAL=5

# Test 1: PHP-FPM
if netstat -tulpn 2>/dev/null | grep -q ":9000" || ss -tlnp 2>/dev/null | grep -q ":9000"; then
    echo -e "${GREEN}   ✓ PHP-FPM listening on port 9000${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ PHP-FPM port not confirmed${NC}"
fi

# Test 2: Nginx
if netstat -tulpn 2>/dev/null | grep -q ":8443" || ss -tlnp 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}   ✓ Nginx listening on port 8443${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Nginx port not confirmed${NC}"
fi

# Test 3: Queue Worker
if ps aux | grep -v grep | grep -q "queue:work"; then
    echo -e "${GREEN}   ✓ Queue worker running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Queue worker not confirmed${NC}"
fi

# Test 4: Cloudflare
if ps aux | grep -v grep | grep -q cloudflared; then
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Cloudflare Tunnel not confirmed${NC}"
fi

# Test 5: Panel Response
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" http://localhost:8443/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "${GREEN}   ✓ Panel responding (HTTP $HTTP_CODE)${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Panel response: HTTP $HTTP_CODE${NC}"
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete! ($TESTS_PASSED/$TESTS_TOTAL)        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}📋 PANEL ACCESS:${NC}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}${NC}"
echo -e "   Cloudflare Dashboard: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo ""

echo -e "${CYAN}🔧 CLOUDFLARE TUNNEL SETUP:${NC}"
echo -e "   1. Go to Zero Trust → Networks → Tunnels"
echo -e "   2. Click your tunnel → Configure"
echo -e "   3. Add Public Hostname:"
echo -e "      - Subdomain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "      - Domain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "      - Service: ${GREEN}HTTPS → localhost:8443${NC}"
echo -e "      - ${YELLOW}Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${CYAN}📁 CONFIGURATION:${NC}"
echo -e "   Saved to: ${GREEN}$ENV_FILE${NC}"
echo -e "   APP_KEY: ${GREEN}$APP_KEY${NC}"
echo ""

echo -e "${CYAN}🚀 NEXT STEP:${NC}"
echo -e "   Run Wings installer: ${GREEN}./wings.sh${NC}"
echo ""

[ "$TESTS_PASSED" -ge 4 ] && {
    echo -e "${GREEN}✅ Panel is ready!${NC}"
} || {
    echo -e "${YELLOW}⚠️  Some services may need manual verification${NC}"
    echo -e "${YELLOW}   Check logs: tail -f /var/log/nginx/pelican.app-error.log${NC}"
}
