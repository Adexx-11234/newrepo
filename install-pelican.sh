#!/bin/bash

################################################################################
# Pelican Panel Interactive Installation Script - CONTAINER-SAFE VERSION
# For Debian/Ubuntu with Cloudflare Tunnel & PostgreSQL
# Handles dpkg cross-device link errors in containerized environments
################################################################################

set -e

# Force system binaries to be used (important for Codespaces/container environments)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
hash -r 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Panel Installation Script    ${NC}"
echo -e "${GREEN}  Container-Safe Version                ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# GET ALL USER INFORMATION
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
echo "1) PostgreSQL (Recommended for production)"
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

echo -e "${BLUE}Database Host (e.g., localhost or remote host):${NC}"
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
# STEP 1: Update System with dpkg fix
# ============================================================================
echo -e "${YELLOW}[1/17] Updating system...${NC}"

# Configure dpkg to handle cross-device link errors (common in containers)
cat > /etc/dpkg/dpkg.cfg.d/docker <<'DPKGEOF'
# Handle cross-device link errors in containerized environments
force-unsafe-io
DPKGEOF

# Try normal update first
if ! apt update && apt upgrade -y; then
    echo -e "${YELLOW}Normal upgrade failed, attempting to fix dpkg issues...${NC}"
    
    # Fix broken packages
    dpkg --configure -a 2>/dev/null || true
    apt --fix-broken install -y 2>/dev/null || true
    
    # If git update is stuck, force reinstall
    if dpkg -l | grep -q "^iF.*git"; then
        echo -e "${YELLOW}Forcing git reinstallation...${NC}"
        apt remove --purge -y git 2>/dev/null || true
        apt install -y git
    fi
    
    # Try upgrade again
    apt update
    apt upgrade -y || {
        echo -e "${YELLOW}Some packages failed to upgrade, continuing anyway...${NC}"
    }
fi

# ============================================================================
# STEP 2: Install Dependencies
# ============================================================================
echo -e "${YELLOW}[2/17] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip cron 2>/dev/null || {
    echo -e "${YELLOW}Some dependencies failed, trying individually...${NC}"
    for pkg in software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release wget tar unzip cron; do
        apt install -y "$pkg" 2>/dev/null || echo -e "${YELLOW}Warning: $pkg installation failed${NC}"
    done
}

# Install git separately if needed
if ! command -v git &> /dev/null; then
    echo -e "${YELLOW}Installing git separately...${NC}"
    apt install -y --reinstall git 2>/dev/null || {
        echo -e "${YELLOW}Git installation had issues, but may still work${NC}"
    }
fi

# ============================================================================
# STEP 3: Add PHP 8.4 Repository
# ============================================================================
echo -e "${YELLOW}[3/17] Adding PHP 8.4 repository...${NC}"

# Remove any existing PHP repositories to avoid conflicts
rm -f /etc/apt/sources.list.d/php*.list 2>/dev/null || true
rm -f /etc/apt/trusted.gpg.d/php*.gpg 2>/dev/null || true
rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list 2>/dev/null || true

# Detect OS
if [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    DISTRO=$(lsb_release -sc)
    
    # Prefer ondrej PPA for Ubuntu (more reliable)
    if command -v add-apt-repository &> /dev/null && [ -f /etc/lsb-release ]; then
        echo "Using ondrej PPA method (recommended for Ubuntu)..."
        add-apt-repository ppa:ondrej/php -y
    else
        # Manual setup for Debian or Ubuntu without add-apt-repository
        echo "Using manual repository setup..."
        
        # Download and install GPG key using the modern method
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
        
        # Add repository with proper keyring signing
        echo "deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ $DISTRO main" | tee /etc/apt/sources.list.d/php.list
    fi
    
    apt update
else
    echo -e "${RED}Unsupported OS. Please install PHP 8.4 manually.${NC}"
    exit 1
fi

# Verify the repository was added successfully
if apt-cache policy php8.4-cli 2>/dev/null | grep -qE "(packages.sury.org|ondrej|ppa.launchpadcontent.com)"; then
    echo -e "${GREEN}✅ PHP 8.4 repository added successfully${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: Could not verify PHP repository. Continuing anyway...${NC}"
fi

# ============================================================================
# STEP 4: Install PHP 8.4 with ALL Required Extensions
# ============================================================================
echo -e "${YELLOW}[4/17] Installing PHP 8.4 with all required extensions...${NC}"

# Install PHP 8.4 and ALL required extensions
apt install -y php8.4 php8.4-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,redis,pgsql} || {
    echo -e "${YELLOW}Batch install failed, installing packages individually...${NC}"
    apt install -y php8.4
    for ext in cli gd mysql mbstring bcmath xml fpm curl zip intl sqlite3 redis pgsql; do
        apt install -y "php8.4-${ext}" 2>/dev/null || echo -e "${YELLOW}Warning: php8.4-${ext} installation had issues${NC}"
    done
}

# Force PHP 8.4 as the default CLI version
update-alternatives --set php /usr/bin/php8.4 2>/dev/null || true

# If update-alternatives fails, manually set it
if ! command -v php &> /dev/null || ! php -v | grep -q "8.4"; then
    echo -e "${YELLOW}Forcing PHP 8.4 activation...${NC}"
    update-alternatives --install /usr/bin/php php /usr/bin/php8.4 84
    update-alternatives --set php /usr/bin/php8.4
fi

# ============================================================================
# STEP 5: Verify PHP 8.4 Installation
# ============================================================================
echo -e "${YELLOW}[5/17] Verifying PHP 8.4 installation...${NC}"

# Check PHP version
PHP_VERSION=$(php -v | head -n 1)
echo -e "${BLUE}Active PHP Version: ${PHP_VERSION}${NC}"

if ! echo "$PHP_VERSION" | grep -q "8.4"; then
    echo -e "${RED}❌ ERROR: PHP 8.4 is not active!${NC}"
    echo -e "${RED}Current version: ${PHP_VERSION}${NC}"
    echo -e "${YELLOW}Please fix PHP version manually and re-run the script.${NC}"
    exit 1
fi

# Check required extensions
echo -e "${BLUE}Checking required PHP extensions...${NC}"
REQUIRED_EXTS=("intl" "zip" "sodium" "bcmath" "mbstring" "xml" "curl" "gd" "pgsql" "redis" "sqlite3" "dom")
MISSING_EXTS=()

for ext in "${REQUIRED_EXTS[@]}"; do
    if php -m | grep -qi "^${ext}$"; then
        echo -e "  ${GREEN}✓${NC} ${ext}"
    else
        echo -e "  ${RED}✗${NC} ${ext} (MISSING)"
        MISSING_EXTS+=("$ext")
    fi
done

# Special check for MySQL (mysqli/mysqlnd)
if php -m | grep -qiE "^(mysqli|mysqlnd)$"; then
    echo -e "  ${GREEN}✓${NC} mysqli/mysqlnd (MySQL support)"
else
    echo -e "  ${RED}✗${NC} mysqli (MISSING)"
    MISSING_EXTS+=("mysql")
fi

if [ ${#MISSING_EXTS[@]} -gt 0 ]; then
    echo -e "${RED}❌ ERROR: Missing required PHP extensions: ${MISSING_EXTS[*]}${NC}"
    echo -e "${YELLOW}Attempting to install missing extensions...${NC}"
    
    for ext in "${MISSING_EXTS[@]}"; do
        apt install -y "php8.4-${ext}" 2>/dev/null || echo -e "${YELLOW}Note: php8.4-${ext} may not exist as a separate package${NC}"
    done
    
    echo -e "${YELLOW}Verifying extensions after installation attempt...${NC}"
    
    # Re-check critical extensions
    STILL_MISSING=()
    for ext in "${MISSING_EXTS[@]}"; do
        if ! php -m | grep -qi "^${ext}$"; then
            STILL_MISSING+=("$ext")
        fi
    done
    
    if [ ${#STILL_MISSING[@]} -gt 0 ]; then
        echo -e "${RED}❌ Still missing: ${STILL_MISSING[*]}${NC}"
        echo -e "${YELLOW}However, if mysqli/mysqlnd are present, MySQL support is available.${NC}"
        echo -e "${YELLOW}Continuing with installation...${NC}"
    fi
fi

echo -e "${GREEN}✅ PHP extensions check complete!${NC}"

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

# Start Redis
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl enable --now redis-server
else
    service redis-server start 2>/dev/null || /etc/init.d/redis-server start 2>/dev/null || true
fi

# ============================================================================
# STEP 9: Install Composer
# ============================================================================
echo -e "${YELLOW}[9/17] Installing Composer...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ============================================================================
# STEP 10: Download Pelican Panel
# ============================================================================
echo -e "${YELLOW}[10/17] Downloading Pelican Panel...${NC}"
mkdir -p /var/www/pelican
cd /var/www/pelican
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv

# ============================================================================
# STEP 11: Install Composer Dependencies
# ============================================================================
echo -e "${YELLOW}[11/17] Installing Composer dependencies...${NC}"
echo -e "${BLUE}PHP version being used by Composer:${NC}"
php -v | head -n 1

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# ============================================================================
# STEP 12: Setup Environment
# ============================================================================
echo -e "${YELLOW}[12/17] Setting up environment...${NC}"
cp .env.example .env

# Configure .env file with user inputs
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
echo -e "${GREEN}IMPORTANT: BACKUP YOUR APP_KEY!${NC}"
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
# STEP 14: Configure Nginx
# ============================================================================
echo -e "${YELLOW}[14/17] Configuring Nginx...${NC}"

mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<NGINXEOF
server_tokens off;

server {
    listen 443 ssl http2;
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
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
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

# Check if systemd is available
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl restart nginx
else
    echo -e "${YELLOW}Using service command instead of systemctl${NC}"
    service nginx restart || /etc/init.d/nginx restart
fi

# ============================================================================
# STEP 15: Setup Queue Worker
# ============================================================================
echo -e "${YELLOW}[15/17] Setting up queue worker...${NC}"

# Check if systemd is available
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
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

    systemctl enable --now pelican-queue.service
    echo -e "${GREEN}Queue worker service created and started${NC}"
else
    echo -e "${YELLOW}Systemd not available - creating supervisor config instead${NC}"
    
    # Install supervisor if not present
    if ! command -v supervisorctl &> /dev/null; then
        apt install -y supervisor
    fi
    
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

    # Start supervisor
    service supervisor start 2>/dev/null || /etc/init.d/supervisor start 2>/dev/null || true
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
    supervisorctl start pelican-queue 2>/dev/null || true
    echo -e "${GREEN}Queue worker configured with supervisor${NC}"
fi

# ============================================================================
# STEP 16: Setup Cron
# ============================================================================
echo -e "${YELLOW}[16/17] Setting up cron...${NC}"

# Ensure cron is installed and running
if ! command -v crontab &> /dev/null; then
    echo -e "${YELLOW}Installing cron...${NC}"
    apt install -y cron
fi

# Start cron service
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl enable --now cron
else
    service cron start 2>/dev/null || /etc/init.d/cron start 2>/dev/null || true
fi

# Add cron job
(crontab -l -u www-data 2>/dev/null; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -
echo -e "${GREEN}Cron job added for www-data user${NC}"

# ============================================================================
# STEP 17: Install Cloudflare Tunnel
# ============================================================================
echo -e "${YELLOW}[17/17] Installing Cloudflare Tunnel...${NC}"

wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
    echo -e "${YELLOW}dpkg had issues, trying to fix...${NC}"
    apt --fix-broken install -y
    dpkg -i cloudflared-linux-amd64.deb
}
rm cloudflared-linux-amd64.deb

cloudflared service uninstall 2>/dev/null || true
cloudflared service install "$CF_TOKEN"

if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl start cloudflared
    systemctl enable cloudflared
else
    service cloudflared start 2>/dev/null || true
fi

# ============================================================================
# Enable all services
# ============================================================================
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl enable nginx php8.4-fpm redis-server 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo ""
echo -e "${GREEN}1. Configure Cloudflare Tunnel:${NC}"
echo -e "   Go to: https://one.dash.cloudflare.com/"
echo -e "   Networks → Tunnels → Configure → Public Hostname"
echo ""
echo -e "   ${YELLOW}Add this route:${NC}"
echo -e "   - Subdomain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${BLUE}$(echo ${PANEL_DOMAIN} | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${BLUE}localhost:443${NC}"
echo -e "   - Additional Settings → ${BLUE}No TLS Verify: ON${NC}"
echo ""
echo -e "${GREEN}2. Run Database Migrations:${NC}"
echo -e "   ${BLUE}cd /var/www/pelican${NC}"
echo -e "   ${BLUE}php artisan migrate --force${NC}"
echo ""
echo -e "${GREEN}3. Create Admin User:${NC}"
echo -e "   ${BLUE}php artisan p:user:make${NC}"
echo ""
echo -e "${GREEN}4. Access Your Panel:${NC}"
echo -e "   ${BLUE}https://${PANEL_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Services Status:${NC}"
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null 2>&1; then
    systemctl status nginx --no-pager -l | head -3 || true
    systemctl status php8.4-fpm --no-pager -l | head -3 || true
    systemctl status redis-server --no-pager -l | head -3 || true
    systemctl status pelican-queue --no-pager -l | head -3 || true
    systemctl status cloudflared --no-pager -l | head -3 || true
else
    echo -e "${YELLOW}Systemd not available - services started with init scripts${NC}"
fi
echo ""
echo -e "${GREEN}All done!${NC}"
echo ""
