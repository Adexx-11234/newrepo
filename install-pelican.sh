#!/bin/bash

################################################################################
# Pelican Panel Complete Installation Script
# For Debian/Ubuntu with Cloudflare Tunnel & PostgreSQL
# Includes all fixes from our session
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Panel Installation Script    ${NC}"
echo -e "${GREEN}  With PostgreSQL & Cloudflare Tunnel  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Get Cloudflare Tunnel Token
echo -e "${YELLOW}Enter your Cloudflare Tunnel Token:${NC}"
read -r CF_TOKEN

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}Cloudflare token is required!${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Starting installation...${NC}"
echo ""

# ============================================================================
# STEP 1: Update System
# ============================================================================
echo -e "${YELLOW}[1/16] Updating system...${NC}"
apt update && apt upgrade -y

# ============================================================================
# STEP 2: Install Dependencies
# ============================================================================
echo -e "${YELLOW}[2/16] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget git tar unzip telnet

# ============================================================================
# STEP 3: Add PHP 8.4 Repository (Debian/Ubuntu)
# ============================================================================
echo -e "${YELLOW}[3/16] Adding PHP 8.4 repository...${NC}"

# Detect OS
if [ -f /etc/debian_version ]; then
    # Debian
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
elif [ -f /etc/lsb-release ]; then
    # Ubuntu
    add-apt-repository ppa:ondrej/php -y
fi

# Remove any conflicting old PHP repositories
rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list 2>/dev/null || true

apt update

# ============================================================================
# STEP 4: Install PHP 8.4 with ALL Required Extensions
# ============================================================================
echo -e "${YELLOW}[4/16] Installing PHP 8.4...${NC}"
apt install -y php8.4 php8.4-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,dom,redis,pgsql}

# Set PHP 8.4 as default
update-alternatives --set php /usr/bin/php8.4 || true

# ============================================================================
# STEP 5: Install Nginx
# ============================================================================
echo -e "${YELLOW}[5/16] Installing Nginx...${NC}"
apt install -y nginx

# ============================================================================
# STEP 6: Install PostgreSQL Client
# ============================================================================
echo -e "${YELLOW}[6/16] Installing PostgreSQL client...${NC}"
apt install -y postgresql-client

# ============================================================================
# STEP 7: Install Redis
# ============================================================================
echo -e "${YELLOW}[7/16] Installing Redis...${NC}"
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
apt update
apt install -y redis-server
systemctl enable --now redis-server

# ============================================================================
# STEP 8: Install Composer
# ============================================================================
echo -e "${YELLOW}[8/16] Installing Composer...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ============================================================================
# STEP 9: Download Pelican Panel
# ============================================================================
echo -e "${YELLOW}[9/16] Downloading Pelican Panel...${NC}"
mkdir -p /var/www/pelican
cd /var/www/pelican
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv

# ============================================================================
# STEP 10: Install Composer Dependencies
# ============================================================================
echo -e "${YELLOW}[10/16] Installing Composer dependencies...${NC}"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# ============================================================================
# STEP 11: Setup Environment
# ============================================================================
echo -e "${YELLOW}[11/16] Setting up environment...${NC}"
cp .env.example .env
php artisan key:generate --force

# Display APP_KEY for backup
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}IMPORTANT: BACKUP YOUR APP_KEY!${NC}"
echo -e "${GREEN}========================================${NC}"
grep "APP_KEY=" .env
echo -e "${GREEN}========================================${NC}"
echo ""
sleep 3

# ============================================================================
# STEP 12: Set Permissions
# ============================================================================
echo -e "${YELLOW}[12/16] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/
chown -R www-data:www-data /var/www/pelican

# ============================================================================
# STEP 13: Configure Nginx with HTTPS
# ============================================================================
echo -e "${YELLOW}[13/16] Configuring Nginx...${NC}"

# Generate self-signed SSL certificate
mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=panel.nexusbot.qzz.io" 2>/dev/null

# Create Nginx config
cat > /etc/nginx/sites-available/pelican.conf <<'NGINXEOF'
server_tokens off;

server {
    listen 443 ssl http2;
    server_name _;

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
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
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

# Enable Nginx site
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
nginx -t
systemctl restart nginx

# ============================================================================
# STEP 14: Setup Queue Worker
# ============================================================================
echo -e "${YELLOW}[14/16] Setting up queue worker...${NC}"

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

# ============================================================================
# STEP 15: Setup Cron
# ============================================================================
echo -e "${YELLOW}[15/16] Setting up cron...${NC}"
(crontab -l -u www-data 2>/dev/null; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -

# ============================================================================
# STEP 16: Install Cloudflare Tunnel
# ============================================================================
echo -e "${YELLOW}[16/16] Installing Cloudflare Tunnel...${NC}"

# Download cloudflared
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb
rm cloudflared-linux-amd64.deb

# Uninstall any existing service
cloudflared service uninstall 2>/dev/null || true

# Install with token
cloudflared service install "$CF_TOKEN"

# Start service
systemctl start cloudflared
systemctl enable cloudflared

# ============================================================================
# Enable all services on boot
# ============================================================================
systemctl enable nginx php8.4-fpm redis-server pelican-queue cloudflared

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT INFORMATION:${NC}"
echo ""
echo -e "${GREEN}1. APP_KEY Location:${NC} /var/www/pelican/.env"
echo -e "   ${RED}BACKUP THIS KEY NOW!${NC}"
echo ""
echo -e "${GREEN}2. Complete installation at:${NC}"
echo -e "   ${BLUE}https://panel.nexusbot.qzz.io/installer${NC}"
echo ""
echo -e "${GREEN}3. Cloudflare Tunnel Configuration:${NC}"
echo -e "   Go to: https://one.dash.cloudflare.com/"
echo -e "   Networks → Tunnels → Configure → Public Hostname"
echo ""
echo -e "   ${YELLOW}Add this route:${NC}"
echo -e "   - Subdomain: ${BLUE}panel${NC}"
echo -e "   - Domain: ${BLUE}nexusbot.qzz.io${NC}"
echo -e "   - Service Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${BLUE}localhost:443${NC}"
echo -e "   - Additional Settings → ${BLUE}No TLS Verify: ON${NC}"
echo ""
echo -e "${GREEN}4. Database Setup:${NC}"
echo -e "   Use your Supabase PostgreSQL database:"
echo -e "   - Driver: ${BLUE}PostgreSQL${NC}"
echo -e "   - Host: ${BLUE}aws-0-us-west-2.pooler.supabase.com${NC}"
echo -e "   - Port: ${BLUE}5432${NC} (NOT 6543!)"
echo -e "   - Database: ${BLUE}postgres${NC}"
echo ""
echo -e "${GREEN}5. Cache/Queue/Session:${NC}"
echo -e "   Use ${BLUE}Redis${NC} for all three:"
echo -e "   - Host: ${BLUE}127.0.0.1${NC}"
echo -e "   - Port: ${BLUE}6379${NC}"
echo -e "   - Password: ${BLUE}(leave empty)${NC}"
echo ""
echo -e "${GREEN}6. After web installation, create admin user:${NC}"
echo -e "   ${BLUE}cd /var/www/pelican${NC}"
echo -e "   ${BLUE}sudo php artisan migrate --force${NC}"
echo -e "   ${BLUE}sudo php artisan p:user:make${NC}"
echo ""
echo -e "${YELLOW}Services Status:${NC}"
systemctl status nginx --no-pager -l | head -3
systemctl status php8.4-fpm --no-pager -l | head -3
systemctl status redis-server --no-pager -l | head -3
systemctl status pelican-queue --no-pager -l | head -3
systemctl status cloudflared --no-pager -l | head -3
echo ""
echo -e "${GREEN}All done! Visit the installer to complete setup.${NC}"
echo ""
