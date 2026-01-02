#!/bin/bash

################################################################################
# Pelican Panel Permissions Fix & Optimization Script
# Run this FIRST before installing Wings
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Panel Fix Script             ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Verify Pelican directory exists
if [ ! -d "/var/www/pelican" ]; then
    echo -e "${RED}Error: /var/www/pelican directory not found!${NC}"
    echo -e "${YELLOW}Please install Pelican Panel first.${NC}"
    exit 1
fi

cd /var/www/pelican

# ============================================================================
# STEP 1: Fix File Permissions
# ============================================================================
echo -e "${YELLOW}[1/7] Fixing file ownership and permissions...${NC}"

# Set ownership to www-data
chown -R www-data:www-data /var/www/pelican

# Set base permissions
chmod -R 755 /var/www/pelican

# Set write permissions for storage and cache
chmod -R 775 storage bootstrap/cache

# Ensure www-data owns these critical directories
chown -R www-data:www-data storage bootstrap/cache

echo -e "${GREEN}✅ Permissions fixed${NC}"

# ============================================================================
# STEP 2: Clear All Caches (as www-data user)
# ============================================================================
echo -e "${YELLOW}[2/7] Clearing all caches...${NC}"

sudo -u www-data php artisan cache:clear
sudo -u www-data php artisan config:clear
sudo -u www-data php artisan route:clear
sudo -u www-data php artisan view:clear

echo -e "${GREEN}✅ Caches cleared${NC}"

# ============================================================================
# STEP 3: Verify Database Connection
# ============================================================================
echo -e "${YELLOW}[3/7] Verifying database connection...${NC}"

if sudo -u www-data php artisan migrate:status >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Database connected${NC}"
else
    echo -e "${RED}❌ Database connection failed${NC}"
    echo -e "${YELLOW}Please check your .env database settings${NC}"
fi

# ============================================================================
# STEP 4: Optimize Application
# ============================================================================
echo -e "${YELLOW}[4/7] Optimizing application...${NC}"

sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache

echo -e "${GREEN}✅ Application optimized${NC}"

# ============================================================================
# STEP 5: Verify PHP Extensions
# ============================================================================
echo -e "${YELLOW}[5/7] Verifying PHP extensions...${NC}"

REQUIRED_EXTS=("intl" "zip" "bcmath" "mbstring" "xml" "curl" "gd" "redis" "pgsql" "dom")
MISSING_EXTS=()

for ext in "${REQUIRED_EXTS[@]}"; do
    if php -m | grep -qi "^${ext}$"; then
        echo -e "  ${GREEN}✓${NC} ${ext}"
    else
        echo -e "  ${RED}✗${NC} ${ext} (MISSING)"
        MISSING_EXTS+=("$ext")
    fi
done

if [ ${#MISSING_EXTS[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Missing extensions detected, but continuing...${NC}"
else
    echo -e "${GREEN}✅ All PHP extensions present${NC}"
fi

# ============================================================================
# STEP 6: Check Services Status
# ============================================================================
echo -e "${YELLOW}[6/7] Checking services...${NC}"

check_service() {
    if systemctl is-active --quiet "$1"; then
        echo -e "  ${GREEN}● $1 - Running${NC}"
    else
        echo -e "  ${RED}● $1 - Not running${NC}"
        echo -e "    ${YELLOW}Attempting to start...${NC}"
        systemctl restart "$1" 2>/dev/null || echo -e "    ${RED}Failed to start${NC}"
    fi
}

check_service "nginx"
check_service "php8.4-fpm"
check_service "redis-server"
check_service "pelican-queue"

echo -e "${GREEN}✅ Services checked${NC}"

# ============================================================================
# STEP 7: Restart All Services
# ============================================================================
echo -e "${YELLOW}[7/7] Restarting services...${NC}"

systemctl restart php8.4-fpm
systemctl restart nginx
systemctl restart pelican-queue 2>/dev/null || echo -e "${YELLOW}Note: pelican-queue service not found${NC}"

echo -e "${GREEN}✅ Services restarted${NC}"

# ============================================================================
# Final Verification
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Fix Complete!                        ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Test panel access
echo -e "${YELLOW}Testing panel...${NC}"
PANEL_URL=$(grep "APP_URL=" .env | cut -d'=' -f2)

if [ -n "$PANEL_URL" ]; then
    echo -e "${BLUE}Panel URL: ${PANEL_URL}${NC}"
    echo -e "${GREEN}Try accessing your panel now!${NC}"
else
    echo -e "${YELLOW}Could not determine panel URL from .env${NC}"
fi

echo ""
echo -e "${YELLOW}Service Status:${NC}"
systemctl status nginx --no-pager -l | head -3
systemctl status php8.4-fpm --no-pager -l | head -3
systemctl status redis-server --no-pager -l | head -3

echo ""
echo -e "${GREEN}Storage Permissions:${NC}"
ls -la storage/ | head -5

echo ""
echo -e "${GREEN}All fixes applied!${NC}"
echo -e "${YELLOW}If you still see errors, check logs:${NC}"
echo -e "  ${BLUE}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  ${BLUE}tail -f storage/logs/laravel.log${NC}"
echo ""
