#!/bin/bash

################################################################################
# Pelican Panel Interactive Installation Script - UNIVERSAL VERSION
# For Debian/Ubuntu - Works on VPS, Codespaces, Docker, Sandbox
# Uses port 8443 for Nginx (compatible with all environments)
################################################################################

set -e

# Force system binaries to be used
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
hash -r 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Panel Installation Script    ${NC}"
echo -e "${GREEN}  Universal Version (All Environments) ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${YELLOW}=== Detecting Environment ===${NC}"

HAS_SYSTEMD=false
IS_CONTAINER=false

if pidof systemd >/dev/null 2>&1; then
    HAS_SYSTEMD=true
    echo -e "${GREEN}✅ Systemd detected${NC}"
else
    echo -e "${YELLOW}⚠️  No systemd - using alternative process management${NC}"
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}⚠️  Container environment detected${NC}"
fi

if [ -f /proc/sys/kernel/osrelease ]; then
    if grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
        echo -e "${BLUE}ℹ️  GitHub Codespaces detected${NC}"
        IS_CONTAINER=true
    fi
fi

echo ""

# ============================================================================
# GET USER INFORMATION
# ============================================================================
echo -e "${YELLOW}=== Configuration Setup ===${NC}"
echo ""

# Domain/Subdomain
echo -e "${BLUE}Enter your panel domain (e.g., panel.example.com):${NC}"
read -r PANEL_DOMAIN

# Cloudflare Tunnel Token
echo -e "${BLUE}Enter your Cloudflare Tunnel Token:${NC}"
read -r CF_TOKEN

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}Cloudflare token is required!${NC}"
    exit 1
fi

# Database Configuration
echo ""
echo -e "${YELLOW}=== Database Configuration ===${NC}"
echo -e "${BLUE}Choose database type:${NC}"
echo "1) PostgreSQL (Recommended)"
echo "2) MySQL/MariaDB"
read -r DB_TYPE

if [ "$DB_TYPE" = "1" ]; then
    DB_DRIVER="pgsql"
    DB_PORT_DEFAULT="5432"
    echo -e "${GREEN}Using PostgreSQL${NC}"
else
    DB_DRIVER="mysql"
    DB_PORT_DEFAULT="3306"
    echo -e "${GREEN}Using MySQL${NC}"
fi

echo -e "${BLUE}Database Host (e.g., localhost):${NC}"
read -r DB_HOST

echo -e "${BLUE}Database Port [${DB_PORT_DEFAULT}]:${NC}"
read -r DB_PORT
DB_PORT=${DB_PORT:-$DB_PORT_DEFAULT}

echo -e "${BLUE}Database Name:${NC}"
read -r DB_NAME

echo -e "${BLUE}Database Username:${NC}"
read -r DB_USER

echo -e "${BLUE}Database Password:${NC}"
read -rs DB_PASS
echo ""

# Redis Configuration
echo ""
echo -e "${YELLOW}=== Redis Configuration ===${NC}"
echo -e "${BLUE}Redis Host [127.0.0.1]:${NC}"
read -r REDIS_HOST
REDIS_HOST=${REDIS_HOST:-127.0.0.1}

echo -e "${BLUE}Redis Port [6379]:${NC}"
read -r REDIS_PORT
REDIS_PORT=${REDIS_PORT:-6379}

echo -e "${BLUE}Redis Password (leave empty if none):${NC}"
read -rs REDIS_PASS
echo ""

# Email Configuration
echo ""
echo -e "${YELLOW}=== Email Configuration ===${NC}"
echo -e "${BLUE}SMTP Host (e.g., smtp.gmail.com):${NC}"
read -r MAIL_HOST

echo -e "${BLUE}SMTP Port [587]:${NC}"
read -r MAIL_PORT
MAIL_PORT=${MAIL_PORT:-587}

echo -e "${BLUE}SMTP Username:${NC}"
read -r MAIL_USER

echo -e "${BLUE}SMTP Password:${NC}"
read -rs MAIL_PASS
echo ""

echo -e "${BLUE}From Email Address:${NC}"
read -r MAIL_FROM

echo -e "${BLUE}From Name:${NC}"
read -r MAIL_FROM_NAME

# Confirm Settings
echo ""
echo -e "${YELLOW}=== Configuration Summary ===${NC}"
echo -e "Panel Domain: ${GREEN}${PANEL_DOMAIN}${NC}"
echo -e "Panel Port: ${GREEN}8443 (Nginx)${NC}"
echo -e "Database: ${GREEN}${DB_DRIVER}${NC} at ${GREEN}${DB_HOST}:${DB_PORT}${NC}"
echo -e "Database Name: ${GREEN}${DB_NAME}${NC}"
echo -e "Redis: ${GREEN}${REDIS_HOST}:${REDIS_PORT}${NC}"
echo -e "SMTP: ${GREEN}${MAIL_HOST}:${MAIL_PORT}${NC}"
echo ""
echo -e "${YELLOW}Continue with installation? (yes/no):${NC}"
read -r CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Starting installation...${NC}"
echo ""

# ============================================================================
# STEP 1: Update System
# ============================================================================
echo -e "${YELLOW}[1/17] Updating system...${NC}"

# Configure dpkg for container environments
mkdir -p /etc/dpkg/dpkg.cfg.d
cat > /etc/dpkg/dpkg.cfg.d/docker <<'DPKGEOF'
force-unsafe-io
DPKGEOF

apt update
apt upgrade -y || echo -e "${YELLOW}Some packages failed to upgrade, continuing...${NC}"

# ============================================================================
# STEP 2: Install Dependencies
# ============================================================================
echo -e "${YELLOW}[2/17] Installing dependencies...${NC}"

apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo 2>/dev/null || {
    for pkg in software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release wget tar unzip git cron sudo; do
        apt install -y "$pkg" 2>/dev/null || echo -e "${YELLOW}Warning: $pkg may have issues${NC}"
    done
}

# ============================================================================
# STEP 3: Add PHP 8.4 Repository
# ============================================================================
echo -e "${YELLOW}[3/17] Adding PHP 8.4 repository...${NC}"

rm -f /etc/apt/sources.list.d/php*.list 2>/dev/null || true
rm -f /etc/apt/trusted.gpg.d/php*.gpg 2>/dev/null || true

DISTRO=$(lsb_release -sc)

if command -v add-apt-repository &> /dev/null && [ -f /etc/lsb-release ]; then
    add-apt-repository ppa:ondrej/php -y
else
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ $DISTRO main" | tee /etc/apt/sources.list.d/php.list
fi

apt update

# ============================================================================
# STEP 4: Install PHP 8.4
# ============================================================================
echo -e "${YELLOW}[4/17] Installing PHP 8.4...${NC}"

apt install -y php8.4 php8.4-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,redis,pgsql} || {
    apt install -y php8.4
    for ext in cli gd mysql mbstring bcmath xml fpm curl zip intl sqlite3 redis pgsql; do
        apt install -y "php8.4-${ext}" 2>/dev/null || true
    done
}

update-alternatives --set php /usr/bin/php8.4 2>/dev/null || {
    update-alternatives --install /usr/bin/php php /usr/bin/php8.4 84
    update-alternatives --set php /usr/bin/php8.4
}

# ============================================================================
# STEP 5: Verify PHP 8.4
# ============================================================================
echo -e "${YELLOW}[5/17] Verifying PHP 8.4...${NC}"

PHP_VERSION=$(php -v | head -n 1)
echo -e "${BLUE}Active PHP: ${PHP_VERSION}${NC}"

if ! echo "$PHP_VERSION" | grep -q "8.4"; then
    echo -e "${RED}❌ PHP 8.4 not active!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ PHP 8.4 verified${NC}"

# ============================================================================
# STEP 6: Install Nginx
# ============================================================================
echo -e "${YELLOW}[6/17] Installing Nginx...${NC}"
apt install -y nginx

# ============================================================================
# STEP 7: Install Database Client
# ============================================================================
echo -e "${YELLOW}[7/17] Installing database client...${NC}"
if [ "$DB_DRIVER" = "pgsql" ]; then
    apt install -y postgresql-client
else
    apt install -y mysql-client || apt install -y mariadb-client
fi

# ============================================================================
# STEP 8: Install Redis
# ============================================================================
echo -e "${YELLOW}[8/17] Installing Redis...${NC}"

curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
apt update
apt install -y redis-server

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable --now redis-server
else
    service redis-server start 2>/dev/null || redis-server --daemonize yes
fi

# ============================================================================
# STEP 9: Install Composer
# ============================================================================
echo -e "${YELLOW}[9/17] Installing Composer...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ============================================================================
# STEP 10: Download Panel
# ============================================================================
echo -e "${YELLOW}[10/17] Downloading Pelican Panel...${NC}"
mkdir -p /var/www/pelican
cd /var/www/pelican
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv

# ============================================================================
# STEP 11: Install Composer Dependencies
# ============================================================================
echo -e "${YELLOW}[11/17] Installing Composer dependencies...${NC}"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# ============================================================================
# STEP 12: Setup Environment
# ============================================================================
echo -e "${YELLOW}[12/17] Configuring environment...${NC}"
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

if [ -n "$REDIS_PASS" ]; then
    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASS}|" .env
fi

sed -i "s|MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
sed -i "s|MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
sed -i "s|MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USER}|" .env
sed -i "s|MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASS}|" .env
sed -i "s|MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM}|" .env
sed -i "s|MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"${MAIL_FROM_NAME}\"|" .env

php artisan key:generate --force

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}BACKUP YOUR APP_KEY!${NC}"
echo -e "${GREEN}========================================${NC}"
grep "APP_KEY=" .env
echo -e "${GREEN}========================================${NC}"
echo ""
sleep 3

# ============================================================================
# STEP 13: Set Permissions
# ============================================================================
echo -e "${YELLOW}[13/17] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/
chown -R www-data:www-data /var/www/pelican

# ============================================================================
# STEP 14: Configure PHP-FPM for Port 9000 (Container-Safe)
# ============================================================================
echo -e "${YELLOW}[14/17] Configuring PHP-FPM...${NC}"

# Change PHP-FPM to use TCP instead of socket (more reliable in containers)
sed -i 's|listen = /run/php/php8.4-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/8.4/fpm/pool.d/www.conf
sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/8.4/fpm/pool.d/www.conf

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php8.4-fpm
else
    service php8.4-fpm restart 2>/dev/null || php-fpm8.4 -D
fi

# ============================================================================
# STEP 15: Configure Nginx on Port 8443
# ============================================================================
echo -e "${YELLOW}[15/17] Configuring Nginx on port 8443...${NC}"

mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<NGINXEOF
server_tokens off;

server {
    listen 8443 ssl http2;
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

nginx -t

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart nginx
else
    service nginx restart 2>/dev/null || nginx -s reload
fi

# ============================================================================
# STEP 16: Setup Queue Worker
# ============================================================================
echo -e "${YELLOW}[16/17] Setting up queue worker...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/pelican-queue.service <<'QUEUEEOF'
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
QUEUEEOF

    systemctl daemon-reload
    systemctl enable --now pelican-queue.service
else
    # Install supervisor
    apt install -y supervisor 2>/dev/null || true
    
    # Create supervisor config
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/conf.d/pelican-queue.conf <<'QUEUEEOF'
[program:pelican-queue]
command=/usr/bin/php /var/www/pelican/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
directory=/var/www/pelican
user=www-data
autostart=true
autorestart=true
stdout_logfile=/var/log/pelican-queue.log
stderr_logfile=/var/log/pelican-queue-error.log
QUEUEEOF

    # Try to start supervisor
    service supervisor restart 2>/dev/null || supervisord 2>/dev/null || {
        echo -e "${YELLOW}Warning: Supervisor may not be running. Queue will need manual start.${NC}"
    }
    
    # Try to update supervisor
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
    supervisorctl start pelican-queue 2>/dev/null || true
fi

# Setup Cron
if ! command -v crontab &> /dev/null; then
    apt install -y cron
fi

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable --now cron 2>/dev/null || service cron start 2>/dev/null || true
else
    service cron start 2>/dev/null || cron 2>/dev/null || true
fi

(crontab -l -u www-data 2>/dev/null; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -

echo -e "${GREEN}✅ Queue worker configured${NC}"

# ============================================================================
# STEP 17: Install Cloudflare Tunnel
# ============================================================================
echo -e "${YELLOW}[17/17] Installing Cloudflare Tunnel...${NC}"

wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
    apt --fix-broken install -y
    dpkg -i cloudflared-linux-amd64.deb
}
rm cloudflared-linux-amd64.deb

cloudflared service uninstall 2>/dev/null || true
cloudflared service install "$CF_TOKEN"

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl start cloudflared
    systemctl enable cloudflared
else
    cloudflared tunnel run "$CF_TOKEN" > /var/log/cloudflared.log 2>&1 &
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!                ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo ""
echo -e "${GREEN}1. Configure Cloudflare Tunnel Route:${NC}"
echo -e "   Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "   Navigate: Zero Trust → Networks → Tunnels → Configure"
echo ""
echo -e "   ${YELLOW}Add Public Hostname:${NC}"
echo -e "   - Subdomain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${BLUE}localhost:8443${NC}"
echo -e "   - Additional Settings → ${BLUE}No TLS Verify: ON${NC}"
echo ""
echo -e "${GREEN}2. Run Database Migrations:${NC}"
echo -e "   ${BLUE}cd /var/www/pelican${NC}"
echo -e "   ${BLUE}php artisan migrate --force${NC}"
echo ""
echo -e "${GREEN}3. Create Admin User:${NC}"
echo -e "   ${BLUE}php artisan p:user:make${NC}"
echo ""
echo -e "${GREEN}4. Access Panel:${NC}"
echo -e "   ${BLUE}https://${PANEL_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo -e "  - Panel runs on port ${BLUE}8443${NC} locally"
echo -e "  - Cloudflare Tunnel maps 443 → 8443"
echo -e "  - Users access via HTTPS on port 443"
echo ""
echo -e "${GREEN}All done!${NC}"
echo ""
