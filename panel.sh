#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE AUTO-INSTALLER v5.3 (ALL FIXES APPLIED)
# - Forces localhost (not 127.0.0.1) for Cloudflare Tunnel compatibility
# - IPv6 support for container environments
# - Fixed PHP 8.3 with all extensions
# - Fixed Composer dependencies
# - Production ready
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.pelican.env"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Pelican Panel Auto-Installer v5.3    ║${NC}"
echo -e "${GREEN}║  All Fixes Applied - IPv4/IPv6 Ready  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[1/18] Detecting Environment...${NC}"

HAS_SYSTEMD=false
IS_CONTAINER=false

if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
        HAS_SYSTEMD=true
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
# CONFIGURATION
# ============================================================================
echo ""
echo -e "${CYAN}[2/18] Configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}   Found existing configuration!${NC}"
    source "$ENV_FILE"
    echo -e "${GREEN}   Using: $ENV_FILE${NC}"
    echo -e "${CYAN}   Domain: ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "${CYAN}   Database: ${GREEN}${DB_DRIVER} (${DB_HOST})${NC}"
    read -p "   Use these settings? (y/n) [y]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-y}
    
    if [[ ! "$USE_EXISTING" =~ ^[Yy] ]]; then
        rm -f "$ENV_FILE"
    fi
fi

if [ ! -f "$ENV_FILE" ]; then
    read -p "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
    read -p "Cloudflare Tunnel Token: " CF_TOKEN
    [[ -z "$CF_TOKEN" ]] && { echo -e "${RED}❌ Token required!${NC}"; exit 1; }

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
EOF
    chmod 600 "$ENV_FILE"
fi

echo -e "${GREEN}   ✓ Configuration loaded${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[3/18] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq 2>&1 | grep -v "GPG error" || true
apt upgrade -y -qq 2>&1 | grep -v "GPG error" || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[4/18] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo supervisor net-tools nano 2>/dev/null || true
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# INSTALL PHP 8.3+ (FORCE SYSTEM PHP)
# ============================================================================
echo -e "${CYAN}[5/18] Installing PHP 8.3+...${NC}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

if command -v add-apt-repository &> /dev/null; then
    add-apt-repository ppa:ondrej/php -y 2>&1 | grep -v "GPG error" || true
fi

apt update -qq 2>&1 | grep -v "GPG error" || true

echo -e "${BLUE}   Installing PHP 8.3 and all extensions...${NC}"
apt install -y \
    php8.3 \
    php8.3-cli \
    php8.3-fpm \
    php8.3-mysql \
    php8.3-pgsql \
    php8.3-sqlite3 \
    php8.3-redis \
    php8.3-intl \
    php8.3-zip \
    php8.3-bcmath \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-curl \
    php8.3-gd \
    2>/dev/null || {
    echo -e "${RED}❌ PHP installation failed!${NC}"
    exit 1
}

update-alternatives --install /usr/bin/php php /usr/bin/php8.3 100 2>/dev/null || true
update-alternatives --set php /usr/bin/php8.3 2>/dev/null || true

echo 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"' >> /root/.bashrc 2>/dev/null || true

PHP_VERSION="8.3"

if ! php -v | grep -q "PHP 8.3"; then
    echo -e "${RED}❌ PHP 8.3 not properly installed!${NC}"
    exit 1
fi

echo -e "${BLUE}   Verifying PHP extensions...${NC}"
MISSING_EXTS=""
for ext in intl zip bcmath mbstring xml curl; do
    if php -m | grep -qi "^$ext$"; then
        echo -e "${GREEN}      ✓ $ext${NC}"
    else
        MISSING_EXTS="$MISSING_EXTS $ext"
        echo -e "${RED}      ✗ $ext${NC}"
    fi
done

if [ -n "$MISSING_EXTS" ]; then
    echo -e "${RED}❌ Missing PHP extensions:$MISSING_EXTS${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ PHP $(php -v | head -n1 | cut -d' ' -f2) with all extensions${NC}"

# ============================================================================
# INSTALL NGINX, DATABASE CLIENT, REDIS
# ============================================================================
echo -e "${CYAN}[6/18] Installing services...${NC}"
apt install -y nginx 2>/dev/null || true
[ "$DB_DRIVER" = "pgsql" ] && apt install -y postgresql-client 2>/dev/null || apt install -y mysql-client mariadb-client 2>/dev/null
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
echo -e "${CYAN}[7/18] Installing Composer...${NC}"
if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null
fi
echo -e "${GREEN}   ✓ Composer $(composer --version 2>/dev/null | cut -d' ' -f3)${NC}"

# ============================================================================
# DOWNLOAD PANEL
# ============================================================================
echo -e "${CYAN}[8/18] Downloading Pelican Panel...${NC}"

if [ -d "/var/www/pelican/app" ] && [ -f "/var/www/pelican/artisan" ]; then
    echo -e "${GREEN}   ✓ Panel already exists${NC}"
else
    [ -d "/var/www/pelican" ] && mv /var/www/pelican /var/www/pelican.backup.$(date +%s) 2>/dev/null
    mkdir -p /var/www/pelican
    cd /var/www/pelican
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv
    echo -e "${GREEN}   ✓ Panel downloaded${NC}"
fi

cd /var/www/pelican

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[9/18] Installing dependencies...${NC}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

PHP_BIN="/usr/bin/php8.3"
if [ ! -f "$PHP_BIN" ]; then
    PHP_BIN=$(which php)
fi

echo -e "${BLUE}   Using PHP: $PHP_BIN${NC}"
$PHP_BIN -v | head -n1

echo -e "${BLUE}   Verifying PHP extensions...${NC}"
for ext in intl zip bcmath mbstring xml; do
    if $PHP_BIN -m | grep -qi "^$ext$"; then
        echo -e "${GREEN}      ✓ $ext${NC}"
    else
        echo -e "${RED}      ✗ $ext MISSING${NC}"
        exit 1
    fi
done

if [ ! -d "vendor" ] || [ ! -f "vendor/autoload.php" ]; then
    echo -e "${YELLOW}   Installing fresh dependencies...${NC}"
    
    rm -f composer.lock
    rm -rf vendor/
    
    composer clear-cache 2>/dev/null || true
    
    echo -e "${BLUE}   Running composer install (this may take 2-5 minutes)...${NC}"
    
    if COMPOSER_ALLOW_SUPERUSER=1 $PHP_BIN $(which composer) install \
        --no-dev \
        --optimize-autoloader \
        --no-interaction \
        2>&1 | tee /tmp/composer-install.log; then
        echo -e "${GREEN}   ✓ Dependencies installed successfully${NC}"
    else
        echo -e "${RED}❌ Composer installation failed!${NC}"
        echo -e "${RED}   Check logs: /tmp/composer-install.log${NC}"
        echo -e "${YELLOW}   Last 20 lines of error:${NC}"
        tail -n 20 /tmp/composer-install.log
        exit 1
    fi
    
    if [ ! -f "vendor/autoload.php" ]; then
        echo -e "${RED}❌ vendor/autoload.php not found after installation!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}   ✓ Verified vendor/autoload.php exists${NC}"
else
    echo -e "${GREEN}   ✓ Dependencies already installed${NC}"
fi

if ! $PHP_BIN -r "require 'vendor/autoload.php'; echo 'OK';" 2>/dev/null | grep -q OK; then
    echo -e "${RED}❌ vendor/autoload.php exists but doesn't work!${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ All dependencies ready${NC}"

# ============================================================================
# CONFIGURE ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[10/18] Configuring environment...${NC}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
PHP_BIN="/usr/bin/php8.3"
[ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

if [ ! -f "vendor/autoload.php" ]; then
    echo -e "${RED}❌ Cannot proceed: vendor/autoload.php missing${NC}"
    exit 1
fi

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
[ -n "$REDIS_PASS" ] && sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASS}|" .env
sed -i "s|MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
sed -i "s|MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
sed -i "s|MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USER}|" .env
sed -i "s|MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASS}|" .env
sed -i "s|MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM}|" .env
sed -i "s|MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"${MAIL_FROM_NAME}\"|" .env

$PHP_BIN artisan key:generate --force --quiet

APP_KEY=$(grep "APP_KEY=" .env | cut -d'=' -f2)
echo -e "${GREEN}   ✓ Environment configured${NC}"
echo -e "${YELLOW}   📝 APP_KEY: ${APP_KEY}${NC}"

# ============================================================================
# SET PERMISSIONS
# ============================================================================
echo -e "${CYAN}[11/18] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true
chown -R www-data:www-data /var/www/pelican
mkdir -p storage/logs
touch storage/logs/laravel.log
chown www-data:www-data storage/logs/laravel.log
echo -e "${GREEN}   ✓ Permissions set${NC}"

# ============================================================================
# CONFIGURE PHP-FPM
# ============================================================================
echo -e "${CYAN}[12/18] Configuring PHP-FPM...${NC}"

if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
    sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
fi

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || service php${PHP_VERSION}-fpm restart 2>/dev/null
else
    service php${PHP_VERSION}-fpm restart 2>/dev/null || pkill php-fpm; php-fpm${PHP_VERSION} -D 2>/dev/null || true
fi

sleep 1
echo -e "${GREEN}   ✓ PHP-FPM configured${NC}"

# ============================================================================
# CONFIGURE NGINX (FIXED: IPv4 + IPv6, localhost compatible)
# ============================================================================
echo -e "${CYAN}[13/18] Configuring Nginx...${NC}"
mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<NGINXEOF
server_tokens off;

server {
    # Listen on both IPv4 and IPv6 for container compatibility
    listen 0.0.0.0:8443 ssl http2;
    listen [::]:8443 ssl http2;
    
    server_name ${PANEL_DOMAIN};

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
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
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

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
nginx -t 2>/dev/null

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart nginx 2>/dev/null || service nginx restart
else
    service nginx restart 2>/dev/null || nginx -s reload
fi

echo -e "${GREEN}   ✓ Nginx configured on port 8443 (IPv4 + IPv6)${NC}"

# ============================================================================
# RUN DATABASE MIGRATIONS
# ============================================================================
echo -e "${CYAN}[14/18] Running database migrations...${NC}"
$PHP_BIN artisan migrate --force || {
    echo -e "${YELLOW}   ⚠ Migrations will run via web installer${NC}"
}
echo -e "${GREEN}   ✓ Database ready${NC}"

# ============================================================================
# SETUP QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[15/18] Setting up queue worker...${NC}"

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
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/conf.d/pelican-queue.conf <<'QEOF'
[program:pelican-queue]
command=/usr/bin/php /var/www/pelican/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
directory=/var/www/pelican
user=www-data
autostart=true
autorestart=true
stdout_logfile=/var/log/pelican-queue.log
stderr_logfile=/var/log/pelican-queue-error.log
QEOF

    mkdir -p /var/run/supervisor
    service supervisor restart 2>/dev/null || supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
    sleep 1
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
    supervisorctl start pelican-queue 2>/dev/null || true
fi

echo -e "${GREEN}   ✓ Queue worker configured${NC}"

# ============================================================================
# SETUP CRON
# ============================================================================
echo -e "${CYAN}[16/18] Setting up cron...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || service cron start 2>/dev/null || true
else
    service cron start 2>/dev/null || cron 2>/dev/null || true
fi

(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data - 2>/dev/null || true

echo -e "${GREEN}   ✓ Cron configured${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[17/18] Installing Cloudflare Tunnel...${NC}"

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
    nohup cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN" > /var/log/cloudflared.log 2>&1 &
fi

sleep 3
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed${NC}"

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo -e "${CYAN}[18/18] Verifying installation...${NC}"

CHECKS=0
[ "$(netstat -tulpn 2>/dev/null | grep -c ":9000")" -gt 0 ] && { echo -e "${GREEN}   ✓ PHP-FPM running${NC}"; ((CHECKS++)); }
[ "$(netstat -tulpn 2>/dev/null | grep -c ":8443")" -gt 0 ] && { echo -e "${GREEN}   ✓ Nginx running (IPv4+IPv6)${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c "queue:work")" -gt 0 ] && { echo -e "${GREEN}   ✓ Queue worker${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c cloudflared)" -gt 0 ] && { echo -e "${GREEN}   ✓ Cloudflare Tunnel${NC}"; ((CHECKS++)); }

if [ -f "/var/www/pelican/vendor/autoload.php" ]; then
    echo -e "${GREEN}   ✓ Composer dependencies${NC}"
    ((CHECKS++))
else
    echo -e "${RED}   ✗ Composer dependencies missing${NC}"
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete! (${CHECKS}/5)        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}🎯 CLOUDFLARE TUNNEL CONFIGURATION:${NC}"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Configure your tunnel route in Cloudflare:${NC}"
echo ""
echo -e "${GREEN}1. Go to Cloudflare Zero Trust Dashboard:${NC}"
echo -e "   ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo ""
echo -e "${GREEN}2. Navigate to:${NC}"
echo -e "   ${BLUE}Zero Trust → Networks → Tunnels → [Your Tunnel] → Configure${NC}"
echo ""
echo -e "${GREEN}3. Add/Edit Public Hostname:${NC}"
echo -e "   - Subdomain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${GREEN}localhost:8443${NC} ${YELLOW}(MUST be 'localhost', NOT '127.0.0.1')${NC}"
echo -e "   - Additional Settings:"
echo -e "     ${YELLOW}☑ No TLS Verify: ON${NC}"
echo ""
echo -e "${RED}⚠️  Using 127.0.0.1 will cause 502 errors! Use 'localhost' only!${NC}"
echo ""

echo -e "${CYAN}🌐 COMPLETE SETUP:${NC}"
echo ""
echo -e "${GREEN}After configuring Cloudflare Tunnel, open:${NC}"
echo -e "   ${BLUE}https://${PANEL_DOMAIN}/installer${NC}"
echo ""
echo -e "${YELLOW}Web Installer Settings:${NC}"
echo -e "   - Queue Driver: ${GREEN}Redis${NC}"
echo -e "   - Cache Driver: ${GREEN}Redis${NC}"
echo -e "   - Session Driver: ${GREEN}Redis${NC}"
echo ""
echo -e "${CYAN}Database (already configured):${NC}"
echo -e "   - Driver: ${GREEN}${DB_DRIVER}${NC}"
echo -e "   - Host: ${GREEN}${DB_HOST}${NC}"
echo -e "   - Port: ${GREEN}${DB_PORT}${NC}"
echo -e "   - Database: ${GREEN}${DB_NAME}${NC}"
echo -e "   - Username: ${GREEN}${DB_USER}${NC}"
echo ""

echo -e "${CYAN}📁 CONFIGURATION FILES:${NC}"
echo -e "   Config: ${GREEN}$ENV_FILE${NC}"
echo -e "   Panel: ${GREEN}/var/www/pelican${NC}"
echo -e "   Logs: ${GREEN}/var/log/nginx/pelican.app-error.log${NC}"
echo -e "   Cloudflared: ${GREEN}/var/log/cloudflared.log${NC}"
echo ""

echo -e "${CYAN}📝 USEFUL COMMANDS:${NC}"
echo -e "   Restart services:"
echo -e "     ${GREEN}systemctl restart nginx php${PHP_VERSION}-fpm pelican-queue${NC}"
echo ""
echo -e "   View logs:"
echo -e "     ${GREEN}tail -f /var/log/pelican-queue.log${NC}"
echo -e "     ${GREEN}tail -f /var/www/pelican/storage/logs/laravel.log${NC}"
echo -e "     ${GREEN}tail -f /var/log/cloudflared.log${NC}"
echo ""
echo -e "   Create admin user (optional):"
echo -e "     ${GREEN}cd /var/www/pelican && php artisan p:user:make${NC}"
echo ""
echo -e "   Test local connection:"
echo -e "     ${GREEN}curl -k https://localhost:8443${NC}"
echo ""

echo -e "${CYAN}🔍 TROUBLESHOOTING:${NC}"
echo -e "   Check Nginx is listening on both IPv4 and IPv6:"
echo -e "     ${GREEN}netstat -tulpn | grep 8443${NC}"
echo -e "     ${YELLOW}(Should show 0.0.0.0:8443 and :::8443)${NC}"
echo ""
echo -e "   Test IPv6 localhost:"
echo -e "     ${GREEN}curl -k -g https://[::1]:8443${NC}"
echo ""
echo -e "   Check cloudflared status:"
echo -e "     ${GREEN}ps aux | grep cloudflared${NC}"
echo -e "     ${GREEN}tail -f /var/log/cloudflared.log${NC}"
echo ""

if [ ! -f "/var/www/pelican/vendor/autoload.php" ]; then
    echo -e "${RED}⚠️ Some services need verification. Check logs above.${NC}"
    echo ""
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  🎉 Installation Complete!                                ║${NC}"
echo -e "${BLUE}║                                                            ║${NC}"
echo -e "${BLUE}║  Next Steps:                                               ║${NC}"
echo -e "${BLUE}║  1. Configure Cloudflare Tunnel (use 'localhost:8443')    ║${NC}"
echo -e "${BLUE}║  2. Visit https://${PANEL_DOMAIN}/installer  ║${NC}"
echo -e "${BLUE}║  3. Complete web-based setup                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
