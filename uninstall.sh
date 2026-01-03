#!/bin/bash

################################################################################
# Complete Pelican Panel & Wings Uninstall Script
# Removes ALL traces of Panel, Wings, and Cloudflare Tunnel
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}  Pelican Complete Uninstall           ${NC}"
echo -e "${RED}  This will remove EVERYTHING!          ${NC}"
echo -e "${RED}========================================${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

echo -e "${YELLOW}This will permanently delete:${NC}"
echo "  - Pelican Panel (all data)"
echo "  - Wings daemon (all servers)"
echo "  - Cloudflare Tunnel"
echo "  - All databases and configurations"
echo "  - All Docker containers and volumes"
echo ""
echo -e "${RED}THIS CANNOT BE UNDONE!${NC}"
echo ""
read -p "Type 'DELETE EVERYTHING' to confirm: " CONFIRM

if [ "$CONFIRM" != "DELETE EVERYTHING" ]; then
    echo -e "${GREEN}Cancelled. Nothing was deleted.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Starting complete removal...${NC}"
echo ""

# ============================================================================
# STOP ALL SERVICES
# ============================================================================
echo -e "${YELLOW}[1/12] Stopping all services...${NC}"

# Stop systemd services
systemctl stop wings 2>/dev/null || true
systemctl stop pelican-queue 2>/dev/null || true
systemctl stop cloudflared 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop php8.4-fpm 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true

# Kill any running processes
pkill -9 wings 2>/dev/null || true
pkill -9 cloudflared 2>/dev/null || true
pkill -9 nginx 2>/dev/null || true

# Stop supervisor if running
supervisorctl stop pelican-queue 2>/dev/null || true

echo -e "${GREEN}✅ Services stopped${NC}"

# ============================================================================
# REMOVE WINGS
# ============================================================================
echo -e "${YELLOW}[2/12] Removing Wings...${NC}"

# Stop and remove Wings service
systemctl disable wings 2>/dev/null || true
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload 2>/dev/null || true

# Remove Wings binary
rm -f /usr/local/bin/wings

# Remove Wings data and config
rm -rf /etc/pelican
rm -rf /var/lib/pelican
rm -rf /var/log/pelican
rm -rf /var/run/wings
rm -rf /tmp/pelican
rm -f /tmp/wings.log

# Remove Wings Docker network
docker network rm pelican_nw 2>/dev/null || true
docker network rm pterodactyl_nw 2>/dev/null || true

echo -e "${GREEN}✅ Wings removed${NC}"

# ============================================================================
# REMOVE ALL DOCKER CONTAINERS & VOLUMES
# ============================================================================
echo -e "${YELLOW}[3/12] Removing all Docker containers and volumes...${NC}"

# Stop all containers
docker stop $(docker ps -aq) 2>/dev/null || true

# Remove all containers
docker rm -f $(docker ps -aq) 2>/dev/null || true

# Remove all volumes
docker volume rm $(docker volume ls -q) 2>/dev/null || true

# Remove all networks (except defaults)
docker network prune -f 2>/dev/null || true

# Remove all images (optional - uncomment if you want to remove Docker images too)
# docker rmi -f $(docker images -aq) 2>/dev/null || true

echo -e "${GREEN}✅ Docker containers and volumes removed${NC}"

# ============================================================================
# REMOVE PANEL
# ============================================================================
echo -e "${YELLOW}[4/12] Removing Panel...${NC}"

# Stop and remove Panel queue service
systemctl disable pelican-queue 2>/dev/null || true
rm -f /etc/systemd/system/pelican-queue.service
systemctl daemon-reload 2>/dev/null || true

# Remove supervisor config
rm -f /etc/supervisor/conf.d/pelican-queue.conf
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

# Remove Panel files
rm -rf /var/www/pelican

# Remove cron jobs
crontab -u www-data -r 2>/dev/null || true

echo -e "${GREEN}✅ Panel removed${NC}"

# ============================================================================
# REMOVE NGINX CONFIGURATION
# ============================================================================
echo -e "${YELLOW}[5/12] Removing Nginx configuration...${NC}"

rm -f /etc/nginx/sites-enabled/pelican.conf
rm -f /etc/nginx/sites-available/pelican.conf
rm -f /etc/ssl/pelican/cert.pem
rm -f /etc/ssl/pelican/key.pem
rmdir /etc/ssl/pelican 2>/dev/null || true

# Restore default site if it exists
if [ -f /etc/nginx/sites-available/default ]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
fi

# Test and reload Nginx
nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || true

echo -e "${GREEN}✅ Nginx configuration removed${NC}"

# ============================================================================
# REMOVE CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${YELLOW}[6/12] Removing Cloudflare Tunnel...${NC}"

# Uninstall Cloudflare service
cloudflared service uninstall 2>/dev/null || true

# Remove Cloudflared binary
apt remove -y cloudflared 2>/dev/null || true
rm -f /usr/bin/cloudflared
rm -f /usr/local/bin/cloudflared

# Remove Cloudflare config
rm -rf /root/.cloudflared
rm -rf /etc/cloudflared

echo -e "${GREEN}✅ Cloudflare Tunnel removed${NC}"

# ============================================================================
# CLEAN UP DATABASES (Optional)
# ============================================================================
echo -e "${YELLOW}[7/12] Database cleanup...${NC}"
echo -e "${BLUE}Do you want to drop the Pelican database? (yes/no):${NC}"
read -r DROP_DB

if [[ "$DROP_DB" =~ ^[Yy] ]]; then
    echo -e "${BLUE}Enter database name:${NC}"
    read -r DB_NAME
    
    echo -e "${BLUE}Database type (postgres/mysql):${NC}"
    read -r DB_TYPE
    
    if [ "$DB_TYPE" = "postgres" ]; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null || echo -e "${YELLOW}Could not drop PostgreSQL database${NC}"
        sudo -u postgres psql -c "DROP USER IF EXISTS pelican;" 2>/dev/null || true
    else
        mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null || echo -e "${YELLOW}Could not drop MySQL database${NC}"
        mysql -e "DROP USER IF EXISTS 'pelican'@'localhost';" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✅ Database dropped${NC}"
else
    echo -e "${YELLOW}⚠️  Database preserved${NC}"
fi

# ============================================================================
# REMOVE PHP 8.4 (Optional)
# ============================================================================
echo -e "${YELLOW}[8/12] PHP cleanup...${NC}"
echo -e "${BLUE}Do you want to remove PHP 8.4? (yes/no):${NC}"
read -r REMOVE_PHP

if [[ "$REMOVE_PHP" =~ ^[Yy] ]]; then
    apt remove -y php8.4* 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    echo -e "${GREEN}✅ PHP 8.4 removed${NC}"
else
    echo -e "${YELLOW}⚠️  PHP 8.4 preserved${NC}"
fi

# ============================================================================
# REMOVE REDIS (Optional)
# ============================================================================
echo -e "${YELLOW}[9/12] Redis cleanup...${NC}"
echo -e "${BLUE}Do you want to remove Redis? (yes/no):${NC}"
read -r REMOVE_REDIS

if [[ "$REMOVE_REDIS" =~ ^[Yy] ]]; then
    systemctl stop redis-server 2>/dev/null || true
    systemctl disable redis-server 2>/dev/null || true
    apt remove -y redis-server 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    rm -rf /var/lib/redis
    echo -e "${GREEN}✅ Redis removed${NC}"
else
    echo -e "${YELLOW}⚠️  Redis preserved${NC}"
fi

# ============================================================================
# REMOVE DOCKER (Optional)
# ============================================================================
echo -e "${YELLOW}[10/12] Docker cleanup...${NC}"
echo -e "${BLUE}Do you want to remove Docker? (yes/no):${NC}"
read -r REMOVE_DOCKER

if [[ "$REMOVE_DOCKER" =~ ^[Yy] ]]; then
    apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    rm -rf /var/lib/docker
    rm -rf /etc/docker
    echo -e "${GREEN}✅ Docker removed${NC}"
else
    echo -e "${YELLOW}⚠️  Docker preserved${NC}"
fi

# ============================================================================
# CLEAN UP LOGS
# ============================================================================
echo -e "${YELLOW}[11/12] Cleaning up logs...${NC}"

rm -f /var/log/nginx/pelican.*
rm -f /var/log/pelican-queue*.log
rm -rf /var/log/pelican

echo -e "${GREEN}✅ Logs cleaned${NC}"

# ============================================================================
# CLEAN UP SYSTEMD
# ============================================================================
echo -e "${YELLOW}[12/12] Final cleanup...${NC}"

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# Remove any leftover files
rm -f /etc/cron.d/certbot-renew
rm -f /etc/apt/sources.list.d/redis.list
rm -rf /usr/share/keyrings/redis-archive-keyring.gpg

echo -e "${GREEN}✅ Final cleanup complete${NC}"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Uninstall Complete!                   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}What was removed:${NC}"
echo "  ✓ Wings daemon and all game servers"
echo "  ✓ Pelican Panel"
echo "  ✓ Cloudflare Tunnel"
echo "  ✓ Nginx configuration"
echo "  ✓ All Docker containers and volumes"
echo "  ✓ All logs and temporary files"
echo ""
echo -e "${YELLOW}What was preserved (if you chose to keep):${NC}"
echo "  - Database"
echo "  - PHP 8.4"
echo "  - Redis"
echo "  - Docker"
echo "  - Nginx (but without Pelican config)"
echo ""
echo -e "${BLUE}System is now clean and ready for a fresh installation!${NC}"
echo ""
echo -e "${GREEN}To reinstall, run the installation scripts again.${NC}"
echo ""
