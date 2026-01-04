#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT
# For GitHub Codespaces - Starts everything after sleep/restart
# Run this manually or add to .bashrc for automatic startup
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Pelican Services Restart Tool     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.pelican.env"

# Load config if exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

SERVICES_STARTED=0

# ============================================================================
# 1. START DOCKER
# ============================================================================
echo -e "${CYAN}[1/6] Starting Docker...${NC}"

if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Docker not running, starting...${NC}"
    pkill dockerd 2>/dev/null || true
    sleep 1
    dockerd > /var/log/docker.log 2>&1 &
    
    # Wait for Docker to be ready (max 15 seconds)
    for i in {1..15}; do
        if docker ps >/dev/null 2>&1; then
            echo -e "${GREEN}   ✓ Docker started${NC}"
            ((SERVICES_STARTED++))
            break
        fi
        sleep 1
    done
    
    if ! docker ps >/dev/null 2>&1; then
        echo -e "${RED}   ✗ Docker failed to start${NC}"
    fi
fi

# ============================================================================
# 2. START REDIS
# ============================================================================
echo -e "${CYAN}[2/6] Starting Redis...${NC}"

if pgrep redis-server >/dev/null; then
    echo -e "${GREEN}   ✓ Redis already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Redis not running, starting...${NC}"
    service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
    sleep 1
    
    if pgrep redis-server >/dev/null; then
        echo -e "${GREEN}   ✓ Redis started${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${YELLOW}   ⚠ Redis start inconclusive${NC}"
    fi
fi

# ============================================================================
# 3. START PHP-FPM
# ============================================================================
echo -e "${CYAN}[3/6] Starting PHP-FPM...${NC}"

if pgrep php-fpm >/dev/null; then
    echo -e "${GREEN}   ✓ PHP-FPM already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ PHP-FPM not running, starting...${NC}"
    service php8.4-fpm start 2>/dev/null || /usr/sbin/php-fpm8.4 -D 2>/dev/null || true
    sleep 1
    
    if pgrep php-fpm >/dev/null; then
        echo -e "${GREEN}   ✓ PHP-FPM started${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ PHP-FPM failed to start${NC}"
    fi
fi

# ============================================================================
# 4. START NGINX
# ============================================================================
echo -e "${CYAN}[4/6] Starting Nginx...${NC}"

if pgrep nginx >/dev/null; then
    echo -e "${GREEN}   ✓ Nginx already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Nginx not running, starting...${NC}"
    service nginx start 2>/dev/null || nginx 2>/dev/null || true
    sleep 1
    
    if pgrep nginx >/dev/null; then
        echo -e "${GREEN}   ✓ Nginx started${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Nginx failed to start${NC}"
    fi
fi

# ============================================================================
# 5. START PANEL QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[5/6] Starting Panel Queue Worker...${NC}"

if pgrep -f "queue:work" >/dev/null; then
    echo -e "${GREEN}   ✓ Queue worker already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Queue worker not running, starting...${NC}"
    
    if [ -d "/var/www/pelican" ]; then
        cd /var/www/pelican
        pkill -f "queue:work" 2>/dev/null || true
        nohup sudo -u www-data php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
        sleep 2
        
        if pgrep -f "queue:work" >/dev/null; then
            echo -e "${GREEN}   ✓ Queue worker started${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ Queue worker failed to start${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠ Panel not installed, skipping${NC}"
    fi
fi

# ============================================================================
# 6. START WINGS & CLOUDFLARE TUNNELS
# ============================================================================
echo -e "${CYAN}[6/6] Starting Wings & Cloudflare Tunnels...${NC}"

# Start Wings
if pgrep -x wings >/dev/null; then
    echo -e "${GREEN}   ✓ Wings already running${NC}"
    ((SERVICES_STARTED++))
else
    if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
        echo -e "${YELLOW}   ⚠ Wings not running, starting...${NC}"
        pkill wings 2>/dev/null || true
        nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
        sleep 2
        
        if pgrep -x wings >/dev/null; then
            echo -e "${GREEN}   ✓ Wings started${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ Wings failed to start${NC}"
            echo -e "${YELLOW}   Check: tail -f /tmp/wings.log${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠ Wings not installed, skipping${NC}"
    fi
fi

# Start Cloudflare Tunnels
echo ""
echo -e "${CYAN}   Starting Cloudflare Tunnels...${NC}"

TUNNELS_STARTED=0

# Panel Tunnel
if pgrep -f "cloudflared.*tunnel.*run" | grep -v "wings" >/dev/null; then
    echo -e "${GREEN}   ✓ Panel tunnel already running${NC}"
    ((TUNNELS_STARTED++))
else
    if [ -n "$CF_TOKEN" ]; then
        echo -e "${YELLOW}   ⚠ Panel tunnel not running, starting...${NC}"
        nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
        sleep 2
        echo -e "${GREEN}   ✓ Panel tunnel started${NC}"
        ((TUNNELS_STARTED++))
    else
        echo -e "${YELLOW}   ⚠ No CF_TOKEN found, skipping panel tunnel${NC}"
    fi
fi

# Wings Tunnel (if different from panel)
# Check if there's a separate wings tunnel running
if pgrep -f "cloudflared.*wings" >/dev/null; then
    echo -e "${GREEN}   ✓ Wings tunnel already running${NC}"
    ((TUNNELS_STARTED++))
fi

# ============================================================================
# VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          Services Status Check         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Docker
if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker:       Running${NC}"
else
    echo -e "${RED}✗ Docker:       Not Running${NC}"
fi

# Redis
if pgrep redis-server >/dev/null; then
    echo -e "${GREEN}✓ Redis:        Running${NC}"
else
    echo -e "${RED}✗ Redis:        Not Running${NC}"
fi

# PHP-FPM
if pgrep php-fpm >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":9000"; then
    echo -e "${GREEN}✓ PHP-FPM:      Running (port 9000)${NC}"
else
    echo -e "${RED}✗ PHP-FPM:      Not Running${NC}"
fi

# Nginx
if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}✓ Nginx:        Running (port 8443)${NC}"
else
    echo -e "${RED}✗ Nginx:        Not Running${NC}"
fi

# Queue Worker
if pgrep -f "queue:work" >/dev/null; then
    echo -e "${GREEN}✓ Queue Worker: Running${NC}"
else
    echo -e "${RED}✗ Queue Worker: Not Running${NC}"
fi

# Wings
if pgrep -x wings >/dev/null; then
    echo -e "${GREEN}✓ Wings:        Running${NC}"
else
    echo -e "${YELLOW}⚠ Wings:        Not Running (may not be installed)${NC}"
fi

# Cloudflare
CF_COUNT=$(pgrep -f cloudflared | wc -l)
if [ "$CF_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Cloudflare:   Running (${CF_COUNT} tunnel(s))${NC}"
else
    echo -e "${YELLOW}⚠ Cloudflare:   Not Running${NC}"
fi

# ============================================================================
# QUICK TESTS
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           Quick Health Check           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Test Panel
if [ -d "/var/www/pelican" ]; then
    PANEL_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" http://localhost:8443/ 2>/dev/null || echo "000")
    if [ "$PANEL_TEST" = "200" ] || [ "$PANEL_TEST" = "302" ]; then
        echo -e "${GREEN}✓ Panel:        Responding (HTTP $PANEL_TEST)${NC}"
    else
        echo -e "${YELLOW}⚠ Panel:        HTTP $PANEL_TEST${NC}"
    fi
fi

# Test Wings
if [ -f "/usr/local/bin/wings" ]; then
    WINGS_TEST=$(curl -k -s https://localhost:8080/api/system 2>&1 || echo "FAILED")
    if echo "$WINGS_TEST" | grep -q "authorization"; then
        echo -e "${GREEN}✓ Wings API:    Responding${NC}"
    else
        echo -e "${YELLOW}⚠ Wings API:    Not responding${NC}"
    fi
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Summary                   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

if [ "$SERVICES_STARTED" -ge 5 ]; then
    echo -e "${GREEN}✅ All critical services are running!${NC}"
    echo ""
    if [ -n "$PANEL_DOMAIN" ]; then
        echo -e "${CYAN}Panel URL:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
    fi
    if [ -n "$NODE_DOMAIN" ]; then
        echo -e "${CYAN}Wings URL:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Some services failed to start${NC}"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo -e "  • Check logs: ${BLUE}tail -f /var/log/nginx/pelican.app-error.log${NC}"
    echo -e "  • Check queue: ${BLUE}tail -f /var/log/pelican-queue.log${NC}"
    echo -e "  • Check Wings: ${BLUE}tail -f /tmp/wings.log${NC}"
fi

echo ""
echo -e "${CYAN}📝 Useful Commands:${NC}"
echo -e "  • Restart everything: ${GREEN}sudo ./restart.sh${NC}"
echo -e "  • Check services:     ${GREEN}ps aux | grep -E 'wings|php-fpm|nginx|redis|queue:work'${NC}"
echo -e "  • Panel logs:         ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  • Wings logs:         ${GREEN}tail -f /tmp/wings.log${NC}"
echo ""
