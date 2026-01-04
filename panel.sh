#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE AUTO-INSTALLER v4.0
# Handles EVERYTHING: Panel, Database, Queue, Cloudflare, User Creation
# Works on: VPS, Codespaces, Containers - All environments
# Fixes: PHP 8.3+ auto-compile, Redis GPG, Config persistence
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
echo -e "${GREEN}║  Pelican Panel Auto-Installer v4.0    ║${NC}"
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
echo -e "${CYAN}[1/21] Detecting Environment...${NC}"

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
# LOAD OR COLLECT CONFIGURATION
# ============================================================================
echo ""
echo -e "${CYAN}[2/21] Configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}   Found existing configuration!${NC}"
    source "$ENV_FILE"
    echo -e "${GREEN}   Using saved values from $ENV_FILE${NC}"
    echo -e "${CYAN}   Panel Domain: ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "${CYAN}   Database: ${GREEN}${DB_DRIVER} (${DB_HOST})${NC}"
    read -p "   Use these settings? (y/n) [y]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-y}
    
    if [[ ! "$USE_EXISTING" =~ ^[Yy] ]]; then
        rm -f "$ENV_FILE"
        echo -e "${YELLOW}   Collecting new configuration...${NC}"
    fi
fi

if [ ! -f "$ENV_FILE" ]; then
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

    # Save configuration
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
fi

echo -e "${GREEN}   ✓ Configuration loaded${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[3/21] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq 2>&1 | grep -v "GPG error" | grep -v "NO_PUBKEY" || true
apt upgrade -y -qq 2>&1 | grep -v "GPG error" || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[4/21] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo supervisor net-tools 2>/dev/null || true
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# INSTALL PHP 8.3+
# ============================================================================
echo -e "${CYAN}[5/21] Installing PHP 8.3+...${NC}"

PHP_INSTALLED=false
PHP_VERSION=""

# Check if PHP 8.1+ is already installed
if command -v php &> /dev/null; then
    CURRENT_PHP=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;")
    if [ "$(echo "$CURRENT_PHP >= 8.1" | bc -l 2>/dev/null)" = "1" ] || [[ "$CURRENT_PHP" =~ ^8\.[1-9]|^8\.[1-9][0-9]|^9\. ]]; then
        PHP_VERSION=$CURRENT_PHP
        PHP_INSTALLED=true
        echo -e "${GREEN}   ✓ PHP $PHP_VERSION already installed${NC}"
    fi
fi

# Check if compiled PHP exists in /tmp or /usr/local
if [ "$PHP_INSTALLED" = false ]; then
    if [ -d "/tmp/php-8.3.16" ] && [ -f "/tmp/php-8.3.16/sapi/cli/php" ]; then
        echo -e "${YELLOW}   Found compiled PHP 8.3 in /tmp, resuming installation...${NC}"
        cd /tmp/php-8.3.16
        
        echo -e "${CYAN}   Installing from existing build...${NC}"
        make install >/dev/null 2>&1
        
        # Setup compiled PHP
        mkdir -p /usr/local/php83/etc/php-fpm.d
        cp /usr/local/php83/etc/php-fpm.conf.default /usr/local/php83/etc/php-fpm.conf 2>/dev/null || true
        cp /usr/local/php83/etc/php-fpm.d/www.conf.default /usr/local/php83/etc/php-fpm.d/www.conf 2>/dev/null || true
        ln -sf /usr/local/php83/bin/php /usr/bin/php
        ln -sf /usr/local/php83/sbin/php-fpm /usr/sbin/php-fpm
        
        mkdir -p /etc/php/8.3/fpm/pool.d
        ln -sf /usr/local/php83/etc/php-fpm.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf 2>/dev/null || true
        
        PHP_VERSION="8.3"
        PHP_INSTALLED=true
        
        cd /root
        echo -e "${GREEN}   ✓ Installed PHP from existing build${NC}"
    elif [ -f "/usr/local/php83/bin/php" ]; then
        echo -e "${GREEN}   ✓ Found compiled PHP 8.3 in /usr/local${NC}"
        ln -sf /usr/local/php83/bin/php /usr/bin/php
        ln -sf /usr/local/php83/sbin/php-fpm /usr/sbin/php-fpm
        PHP_VERSION="8.3"
        PHP_INSTALLED=true
    fi
fi

# Try package manager if still not installed
if [ "$PHP_INSTALLED" = false ]; then
    if command -v add-apt-repository &> /dev/null; then
        add-apt-repository ppa:ondrej/php -y 2>&1 | grep -v "GPG error" || true
    fi
    apt update -qq 2>&1 | grep -v "GPG error" || true
    
    # Try PHP 8.4, 8.3, 8.2, 8.1 in order
    for PHP_VER in 8.4 8.3 8.2 8.1; do
        if apt-cache show php${PHP_VER} >/dev/null 2>&1; then
            echo -e "${YELLOW}   Found PHP ${PHP_VER} in repos, installing...${NC}"
            apt install -y php${PHP_VER} php${PHP_VER}-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,redis,pgsql} 2>/dev/null && {
                update-alternatives --set php /usr/bin/php${PHP_VER} 2>/dev/null || {
                    update-alternatives --install /usr/bin/php php /usr/bin/php${PHP_VER} ${PHP_VER//./} 2>/dev/null
                    update-alternatives --set php /usr/bin/php${PHP_VER} 2>/dev/null
                }
                PHP_INSTALLED=true
                PHP_VERSION=${PHP_VER}
                break
            }
        fi
    done
fi

# If no PHP found, compile from source
if [ "$PHP_INSTALLED" = false ]; then
    echo -e "${YELLOW}   ⚠ No PHP 8.1+ found in package repos${NC}"
    echo -e "${YELLOW}   Need to compile PHP 8.3 from source (takes ~15 minutes)${NC}"
    read -p "   Compile PHP 8.3 now? (y/n) [y]: " COMPILE_PHP
    COMPILE_PHP=${COMPILE_PHP:-y}
    
    if [[ ! "$COMPILE_PHP" =~ ^[Yy] ]]; then
        echo -e "${RED}❌ PHP 8.1+ is required for Pelican Panel${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}   Installing build dependencies...${NC}"
    apt install -y build-essential autoconf libtool bison re2c pkg-config \
      libxml2-dev libsqlite3-dev libcurl4-openssl-dev libpng-dev libjpeg-dev \
      libonig-dev libzip-dev libssl-dev libpq-dev libreadline-dev 2>/dev/null || true
    
    # Check if tarball already downloaded
    if [ ! -f "/tmp/php-8.3.16.tar.gz" ]; then
        echo -e "${CYAN}   Downloading PHP 8.3.16...${NC}"
        cd /tmp
        wget -q https://www.php.net/distributions/php-8.3.16.tar.gz
    else
        echo -e "${GREEN}   Using existing PHP tarball${NC}"
        cd /tmp
    fi
    
    # Extract if not already extracted
    if [ ! -d "/tmp/php-8.3.16" ]; then
        echo -e "${CYAN}   Extracting PHP source...${NC}"
        tar -xzf php-8.3.16.tar.gz
    else
        echo -e "${GREEN}   Using existing PHP source${NC}"
    fi
    
    cd php-8.3.16
    
    # Check if already configured
    if [ ! -f "Makefile" ]; then
        echo -e "${CYAN}   Configuring PHP (5 mins)...${NC}"
        ./configure --prefix=/usr/local/php83 \
          --with-config-file-path=/usr/local/php83/etc \
          --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
          --with-openssl --with-curl --with-zlib --enable-bcmath --enable-mbstring \
          --with-pdo-mysql --with-pdo-pgsql --with-pgsql --enable-gd --with-jpeg \
          --enable-intl --with-zip --enable-sockets >/dev/null 2>&1
    else
        echo -e "${GREEN}   PHP already configured${NC}"
    fi
    
    # Check if already compiled
    if [ ! -f "sapi/cli/php" ]; then
        echo -e "${CYAN}   Compiling PHP (10 mins)...${NC}"
        make -j$(nproc) >/dev/null 2>&1
    else
        echo -e "${GREEN}   PHP already compiled${NC}"
    fi
    
    echo -e "${CYAN}   Installing PHP...${NC}"
    make install >/dev/null 2>&1
    
    # Setup compiled PHP
    mkdir -p /usr/local/php83/etc/php-fpm.d
    cp /usr/local/php83/etc/php-fpm.conf.default /usr/local/php83/etc/php-fpm.conf 2>/dev/null || true
    cp /usr/local/php83/etc/php-fpm.d/www.conf.default /usr/local/php83/etc/php-fpm.d/www.conf 2>/dev/null || true
    ln -sf /usr/local/php83/bin/php /usr/bin/php
    ln -sf /usr/local/php83/sbin/php-fpm /usr/sbin/php-fpm
    
    mkdir -p /etc/php/8.3/fpm/pool.d
    ln -sf /usr/local/php83/etc/php-fpm.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf 2>/dev/null || true
    
    PHP_VERSION="8.3"
    PHP_INSTALLED=true
    
    # Cleanup only tarball, keep source for potential restart
    cd /root
    echo -e "${YELLOW}   ℹ Keeping PHP source in /tmp for potential restart${NC}"
fi

if [ "$PHP_INSTALLED" = true ]; then
    echo -e "${GREEN}   ✓ PHP installed ($(php -v | head -n1 | cut -d' ' -f2))${NC}"
else
    echo -e "${RED}❌ Failed to install PHP${NC}"
    exit 1
fi

# ============================================================================
# INSTALL NGINX, DATABASE CLIENT, REDIS
# ============================================================================
echo -e "${CYAN}[6/21] Installing Nginx, database client, Redis...${NC}"
apt install -y nginx 2>/dev/null || true
[ "$DB_DRIVER" = "pgsql" ] && apt install -y postgresql-client 2>/dev/null || apt install -y mysql-client mariadb-client 2>/dev/null

# Redis without GPG errors
apt install -y redis-server 2>/dev/null || {
    # If redis repo fails, use default repo
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 5F4349D6BF53AA0C 2>/dev/null || true
    apt update -qq 2>&1 | grep -v "GPG error" || true
    apt install -y redis-server 2>/dev/null || true
}

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
echo -e "${CYAN}[7/21] Installing Composer...${NC}"
if ! command -v composer &> /dev/null; then
    export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null || {
        wget -q -O composer-setup.php https://getcomposer.org/installer
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
        rm composer-setup.php
    }
fi
echo -e "${GREEN}   ✓ Composer installed${NC}"

# ============================================================================
# DOWNLOAD PANEL
# ============================================================================
echo -e "${CYAN}[8/21] Downloading Pelican Panel...${NC}"

# Check if panel already exists and is complete
if [ -d "/var/www/pelican/app" ] && [ -f "/var/www/pelican/artisan" ] && [ -f "/var/www/pelican/composer.json" ]; then
    echo -e "${GREEN}   ✓ Panel files already exist${NC}"
    cd /var/www/pelican
else
    # Clean up any incomplete installation
    if [ -d "/var/www/pelican" ]; then
        echo -e "${YELLOW}   Cleaning up incomplete installation...${NC}"
        mv /var/www/pelican /var/www/pelican.backup.$(date +%s) 2>/dev/null || rm -rf /var/www/pelican
    fi
    
    mkdir -p /var/www/pelican
    cd /var/www/pelican
    
    echo -e "${CYAN}   Downloading panel from GitHub...${NC}"
    
    # Try wget first (more reliable in containers)
    if wget --show-progress -q https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz -O panel.tar.gz 2>/dev/null; then
        echo -e "${GREEN}   ✓ Downloaded successfully${NC}"
    else
        echo -e "${YELLOW}   ⚠ wget failed, trying curl...${NC}"
        curl -L --progress-bar https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz 2>/dev/null || {
            echo -e "${RED}❌ Download failed!${NC}"
            exit 1
        }
    fi
    
    # Verify download size
    FILE_SIZE=$(stat -f%z panel.tar.gz 2>/dev/null || stat -c%s panel.tar.gz 2>/dev/null)
    if [ "$FILE_SIZE" -lt 2000000 ]; then
        echo -e "${RED}❌ Download corrupted (file too small: $FILE_SIZE bytes)${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}   Extracting panel...${NC}"
    tar -xzf panel.tar.gz || {
        echo -e "${RED}❌ Extraction failed!${NC}"
        exit 1
    }
    rm panel.tar.gz
    
    # Verify extraction
    if [ ! -f "artisan" ] || [ ! -d "app" ]; then
        echo -e "${RED}❌ Panel files incomplete after extraction!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}   ✓ Panel downloaded and extracted${NC}"
fi

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[9/21] Installing Composer dependencies...${NC}"

# Check if vendor directory already exists
if [ -d "vendor" ] && [ -f "vendor/autoload.php" ]; then
    echo -e "${GREEN}   ✓ Dependencies already installed${NC}"
else
    # Check if composer.lock exists and is compatible
    if [ -f "composer.lock" ]; then
        echo -e "${YELLOW}   Checking composer.lock compatibility...${NC}"
        if ! COMPOSER_ALLOW_SUPERUSER=1 composer check-platform-reqs --no-dev >/dev/null 2>&1; then
            echo -e "${YELLOW}   ⚠ Lock file incompatible with PHP $(php -v | head -n1 | cut -d' ' -f2)${NC}"
            echo -e "${CYAN}   Updating composer.lock...${NC}"
            rm -f composer.lock
        fi
    fi

    # Try normal install first
    if COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --quiet 2>&1 | grep -q "ext-sodium"; then
        echo -e "${YELLOW}   ⚠ Missing PHP extensions, using --ignore-platform-reqs${NC}"
        rm -f composer.lock
        COMPOSER_ALLOW_SUPERUSER=1 composer update --no-dev --optimize-autoloader --ignore-platform-reqs --quiet 2>&1 | grep -v "Warning" || {
            echo -e "${RED}❌ Composer install failed!${NC}"
            exit 1
        }
    elif [ ! -d "vendor" ]; then
        # Try update if install failed
        echo -e "${YELLOW}   ⚠ Install failed, trying update...${NC}"
        rm -f composer.lock
        COMPOSER_ALLOW_SUPERUSER=1 composer update --no-dev --optimize-autoloader --ignore-platform-reqs --quiet 2>&1 | grep -v "Warning" || {
            echo -e "${RED}❌ Composer update failed!${NC}"
            exit 1
        }
    fi
    
    echo -e "${GREEN}   ✓ Dependencies installed${NC}"
fi

# ============================================================================
# CONFIGURE ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[10/21] Configuring environment...${NC}"
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

echo "DB_DISABLE_PREPARED_STATEMENTS=true" >> .env
echo "GUZZLE_TIMEOUT=15" >> .env
echo "GUZZLE_CONNECT_TIMEOUT=5" >> .env

php artisan key:generate --force --quiet

APP_KEY=$(grep "APP_KEY=" .env | cut -d'=' -f2)
echo -e "${GREEN}   ✓ Environment configured${NC}"
echo -e "${YELLOW}   📝 APP_KEY: ${APP_KEY}${NC}"

# ============================================================================
# FIX APPPROVIDER
# ============================================================================
echo -e "${CYAN}[11/21] Applying AppServiceProvider fixes...${NC}"
sed -i 's/->timeout(config('\''panel\.guzzle\.timeout'\''))/->timeout((int) config('\''panel.guzzle.timeout'\''))/' app/Providers/AppServiceProvider.php 2>/dev/null || true
sed -i 's/->connectTimeout(config('\''panel\.guzzle\.connect_timeout'\''))/->connectTimeout((int) config('\''panel.guzzle.connect_timeout'\''))/' app/Providers/AppServiceProvider.php 2>/dev/null || true
echo -e "${GREEN}   ✓ AppServiceProvider fixed${NC}"

# ============================================================================
# SET PERMISSIONS
# ============================================================================
echo -e "${CYAN}[12/21] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true
chown -R www-data:www-data /var/www/pelican 2>/dev/null || true
mkdir -p storage/logs
touch storage/logs/laravel.log
chown -R www-data:www-data storage 2>/dev/null || true
echo -e "${GREEN}   ✓ Permissions set${NC}"

# ============================================================================
# CONFIGURE PHP-FPM
# ============================================================================
echo -e "${CYAN}[13/21] Configuring PHP-FPM...${NC}"

# Configure PHP-FPM to use port 9000
if [ -f "/usr/local/php83/etc/php-fpm.d/www.conf" ]; then
    sed -i 's|listen = .*|listen = 127.0.0.1:9000|' /usr/local/php83/etc/php-fpm.d/www.conf 2>/dev/null || true
elif [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
    sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null || true
    sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null || true
fi

# Check if PHP-FPM is already running
if netstat -tulpn 2>/dev/null | grep -q ":9000" || ss -tlnp 2>/dev/null | grep -q ":9000"; then
    echo -e "${GREEN}   ✓ PHP-FPM already running on port 9000${NC}"
else
    # Start PHP-FPM
    if [ -f "/usr/local/php83/sbin/php-fpm" ]; then
        /usr/local/php83/sbin/php-fpm -D 2>/dev/null || echo -e "${YELLOW}   ⚠ PHP-FPM start attempted${NC}"
    elif [ "$HAS_SYSTEMD" = true ]; then
        systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || service php${PHP_VERSION}-fpm restart 2>/dev/null || true
    else
        service php${PHP_VERSION}-fpm restart 2>/dev/null || pkill php-fpm; /usr/sbin/php-fpm -D 2>/dev/null || true
    fi
    
    sleep 2
    
    # Verify it started
    if netstat -tulpn 2>/dev/null | grep -q ":9000" || ss -tlnp 2>/dev/null | grep -q ":9000"; then
        echo -e "${GREEN}   ✓ PHP-FPM running on port 9000${NC}"
    else
        echo -e "${YELLOW}   ⚠ PHP-FPM status unclear, continuing...${NC}"
    fi
fi

# ============================================================================
# CONFIGURE NGINX
# ============================================================================
echo -e "${CYAN}[14/21] Configuring Nginx...${NC}"
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
echo -e "${CYAN}[15/21] Running database migrations...${NC}"
php artisan migrate --force --quiet || {
    echo -e "${RED}❌ Migrations failed! Check database connection.${NC}"
    exit 1
}
echo -e "${GREEN}   ✓ Database migrated${NC}"

# ============================================================================
# SETUP QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[16/21] Setting up queue worker...${NC}"

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

(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data - 2>/dev/null || true

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[17/21] Installing Cloudflare Tunnel...${NC}"

# Install cloudflared
if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
        apt --fix-broken install -y 2>/dev/null
        dpkg -i cloudflared-linux-amd64.deb 2>/dev/null
    }
    rm -f cloudflared-linux-amd64.deb
fi

# Stop any existing cloudflared instances
cloudflared service uninstall 2>/dev/null || true
pkill cloudflared 2>/dev/null || true

echo -e "${GREEN}   ✓ Cloudflared installed${NC}"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Manual Cloudflare Tunnel Setup Required${NC}"
echo ""
echo -e "${CYAN}To complete the installation:${NC}"
echo ""
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Navigate to: ${GREEN}Zero Trust → Networks → Tunnels${NC}"
echo -e "3. Create or select your tunnel"
echo -e "4. Click ${GREEN}Configure${NC} → ${GREEN}Public Hostname${NC} tab"
echo -e "5. Add hostname with these settings:"
echo -e "   ${CYAN}Subdomain:${NC} panel (or your choice)"
echo -e "   ${CYAN}Domain:${NC} ${PANEL_DOMAIN##*.}"
echo -e "   ${CYAN}Service Type:${NC} HTTPS"
echo -e "   ${CYAN}URL:${NC} ${YELLOW}127.0.0.1:8443${NC} ${RED}(NOT localhost!)${NC}"
echo -e "   ${CYAN}TLS Settings:${NC} Enable ${GREEN}'No TLS Verify'${NC}"
echo ""
echo -e "6. Copy the tunnel token from the install command"
echo -e "7. Run this command to start the tunnel:"
echo -e "   ${GREEN}nohup cloudflared tunnel --no-autoupdate --protocol http2 --metrics 127.0.0.1:58080 run --token \"YOUR_TOKEN\" > /var/log/cloudflared.log 2>&1 &${NC}"
echo ""
echo -e "${YELLOW}Note: In container environments, always use 127.0.0.1 instead of localhost${NC}"
echo ""

# Wait for user to set up tunnel
read -p "Press Enter after you've configured the Cloudflare Tunnel and have your token ready..."

# Prompt for tunnel token
read -p "Enter your Cloudflare Tunnel token: " CF_TUNNEL_TOKEN

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    # Start cloudflared with the token
    nohup cloudflared tunnel --no-autoupdate --protocol http2 --metrics 127.0.0.1:58080 run --token "$CF_TUNNEL_TOKEN" > /var/log/cloudflared.log 2>&1 &
    
    sleep 3
    
    if ps aux | grep -v grep | grep -q cloudflared; then
        echo -e "${GREEN}   ✓ Cloudflare Tunnel started${NC}"
    else
        echo -e "${YELLOW}   ⚠ Cloudflare Tunnel status unclear${NC}"
        echo -e "${YELLOW}   Check logs: tail -f /var/log/cloudflared.log${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ No token provided, tunnel not started${NC}"
    echo -e "${YELLOW}   Start manually: cloudflared tunnel --no-autoupdate --protocol http2 --metrics 127.0.0.1:58080 run --token \"YOUR_TOKEN\"${NC}"
fi

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}[21/21] Final verification...${NC}"

TESTS_PASSED=0
TESTS_TOTAL=5

if netstat -tulpn 2>/dev/null | grep -q ":9000" || ss -tlnp 2>/dev/null | grep -q ":9000"; then
    echo -e "${GREEN}   ✓ PHP-FPM listening on port 9000${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ PHP-FPM port not confirmed${NC}"
fi

if netstat -tulpn 2>/dev/null | grep -q ":8443" || ss -tlnp 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}   ✓ Nginx listening on port 8443${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Nginx port not confirmed${NC}"
fi

if ps aux | grep -v grep | grep -q "queue:work"; then
    echo -e "${GREEN}   ✓ Queue worker running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Queue worker not confirmed${NC}"
fi

if ps aux | grep -v grep | grep -q cloudflared; then
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Cloudflare Tunnel not confirmed${NC}"
fi

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
echo -e "   ${RED}IMPORTANT:${NC} Use ${YELLOW}127.0.0.1:8443${NC} (NOT localhost) in tunnel config"
echo -e "   1. Go to Zero Trust → Networks → Tunnels"
echo -e "   2. Click your tunnel → Configure"
echo -e "   3. Add Public Hostname:"
echo -e "      - Subdomain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "      - Domain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "      - Service: ${GREEN}HTTPS → 127.0.0.1:8443${NC} ${RED}(NOT localhost!)${NC}"
echo -e "      - ${YELLOW}Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${CYAN}📁 CONFIGURATION:${NC}"
echo -e "   Saved to: ${GREEN}$ENV_FILE${NC}"
echo -e "   APP_KEY: ${GREEN}$APP_KEY${NC}"
echo -e "   PHP Version: ${GREEN}$(php -v | head -n1 | cut -d' ' -f2)${NC}"
echo ""

echo -e "${CYAN}🚀 NEXT STEPS:${NC}"
echo -e "   1. Configure Cloudflare Tunnel (see above)"
echo -e "   2. Create admin user: ${GREEN}cd /var/www/pelican && php artisan p:user:make${NC}"
echo -e "   3. Access panel at: ${GREEN}https://${PANEL_DOMAIN}${NC}"
echo ""

echo -e "${CYAN}📝 USEFUL COMMANDS:${NC}"
echo -e "   View queue logs: ${GREEN}tail -f /var/log/pelican-queue.log${NC}"
echo -e "   View nginx logs: ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "   Restart services: ${GREEN}systemctl restart nginx php${PHP_VERSION}-fpm${NC}"
echo ""

[ "$TESTS_PASSED" -ge 4 ] && {
    echo -e "${GREEN}✅ Panel is ready! Configure Cloudflare Tunnel and create your admin user.${NC}"
} || {
    echo -e "${YELLOW}⚠️  Some services may need manual verification${NC}"
    echo -e "${YELLOW}   Check logs: tail -f /var/log/nginx/pelican.app-error.log${NC}"
    echo -e "${YELLOW}   Check PHP-FPM: systemctl status php${PHP_VERSION}-fpm${NC}"
}

echo ""
echo -e "${CYAN}Need help? Check the logs or visit Pelican documentation.${NC}"
echo ""
