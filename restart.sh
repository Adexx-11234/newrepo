#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT v2.0 - FIXED
# For GitHub Codespaces - Starts everything after sleep/restart
# FIXED: Proper PHP-FPM detection and startup
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

# Force system PHP path
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

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
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    
    # Wait for Docker (max 15 seconds)
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

if redis-cli ping >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Redis already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Redis not running, starting...${NC}"
    
    # Try service command first
    service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
    sleep 2
    
    if redis-cli ping >/dev/null 2>&1; then
        echo -e "${GREEN}   ✓ Redis started${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Redis failed to start${NC}"
    fi
fi

# ============================================================================
# 3. START PHP-FPM (FIXED)
# ============================================================================
echo -e "${CYAN}[3/6] Starting PHP-FPM...${NC}"

# Detect PHP version
PHP_VERSION=""
for ver in 8.3 8.4 8.2; do
    if [ -f "/usr/sbin/php-fpm${ver}" ] || [ -f "/usr/sbin/php-fpm" ]; then
        PHP_VERSION=$ver
        break
    fi
done

if [ -z "$PHP_VERSION" ]; then
    echo -e "${RED}   ✗ PHP-FPM not found${NC}"
else
    # Check if already running on port 9000
    if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
        echo -e "${GREEN}   ✓ PHP-FPM already running (port 9000)${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${YELLOW}   ⚠ PHP-FPM not running, starting...${NC}"
        
        # Kill any stuck PHP-FPM processes
        pkill -9 php-fpm 2>/dev/null || true
        sleep 1
        
        # Try different start methods
        if service php${PHP_VERSION}-fpm start 2>/dev/null; then
            echo -e "${GREEN}   ✓ Started via service command${NC}"
        elif /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null; then
            echo -e "${GREEN}   ✓ Started via direct binary${NC}"
        elif php-fpm${PHP_VERSION} 2>/dev/null; then
            echo -e "${GREEN}   ✓ Started via PATH binary${NC}"
        else
            echo -e "${RED}   ✗ All start methods failed${NC}"
        fi
        
        sleep 2
        
        # Verify it started
        if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
            echo -e "${GREEN}   ✓ PHP-FPM is now listening on port 9000${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ PHP-FPM failed to start on port 9000${NC}"
            echo -e "${YELLOW}   Troubleshooting:${NC}"
            echo -e "${YELLOW}   Check config: /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf${NC}"
            echo -e "${YELLOW}   Should have: listen = 127.0.0.1:9000${NC}"
        fi
    fi
fi

# ============================================================================
# 4. START NGINX
# ============================================================================
echo -e "${CYAN}[4/6] Starting Nginx...${NC}"

if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}   ✓ Nginx already running (port 8443)${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   ⚠ Nginx not running, starting...${NC}"
    
    # Kill any stuck processes
    pkill nginx 2>/dev/null || true
    sleep 1
    
    # Test nginx config first
    nginx -t 2>/dev/null
    
    # Start nginx
    service nginx start 2>/dev/null || nginx 2>/dev/null || true
    sleep 2
    
    if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
        echo -e "${GREEN}   ✓ Nginx started (port 8443)${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Nginx failed to start${NC}"
        echo -e "${YELLOW}   Check: tail -f /var/log/nginx/error.log${NC}"
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
        
        # Kill any stuck workers
        pkill -f "queue:work" 2>/dev/null || true
        sleep 1
        
        # Use system PHP
        PHP_BIN="/usr/bin/php8.3"
        [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
        
        nohup sudo -u www-data $PHP_BIN artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
        sleep 2
        
        if pgrep -f "queue:work" >/dev/null; then
            echo -e "${GREEN}   ✓ Queue worker started${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ Queue worker failed to start${NC}"
            echo -e "${YELLOW}   Check: tail -f /var/log/pelican-queue.log${NC}"
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
else
    if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
        echo -e "${YELLOW}   ⚠ Wings not running, starting...${NC}"
        pkill wings 2>/dev/null || true
        cd /etc/pelican
        nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
        sleep 3
        
        if pgrep -x wings >/dev/null; then
            echo -e "${GREEN}   ✓ Wings started${NC}"
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

# Kill old tunnels
pkill cloudflared 2>/dev/null || true
sleep 2

# Panel Tunnel
if [ -n "$CF_TOKEN" ]; then
    echo -e "${YELLOW}   Starting Panel tunnel...${NC}"
    nohup cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
    sleep 2
    echo -e "${GREEN}   ✓ Panel tunnel started${NC}"
fi

# Wings Tunnel (if separate token exists)
# Add logic here if you have a separate CF_TOKEN_WINGS

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
if redis-cli ping >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis:        Running${NC}"
else
    echo -e "${RED}✗ Redis:        Not Running${NC}"
fi

# PHP-FPM
if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
    PHP_PID=$(netstat -tulpn 2>/dev/null | grep ":9000" | awk '{print $7}' | cut -d'/' -f1)
    echo -e "${GREEN}✓ PHP-FPM:      Running (port 9000, PID: $PHP_PID)${NC}"
else
    echo -e "${RED}✗ PHP-FPM:      Not Running on port 9000${NC}"
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

# Test Panel (local)
if [ -d "/var/www/pelican" ]; then
    PANEL_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:8443/ 2>/dev/null || echo "000")
    if [ "$PANEL_TEST" = "200" ] || [ "$PANEL_TEST" = "302" ]; then
        echo -e "${GREEN}✓ Panel Local:  HTTP $PANEL_TEST${NC}"
    else
        echo -e "${RED}✗ Panel Local:  HTTP $PANEL_TEST (Should be 200 or 302)${NC}"
    fi
    
    # Test via Cloudflare (if domain set)
    if [ -n "$PANEL_DOMAIN" ]; then
        sleep 2
        PANEL_CF_TEST=$(curl -s -o /dev/null -w "%{http_code}" https://${PANEL_DOMAIN}/ 2>/dev/null || echo "000")
        if [ "$PANEL_CF_TEST" = "200" ] || [ "$PANEL_CF_TEST" = "302" ]; then
            echo -e "${GREEN}✓ Panel Remote: HTTP $PANEL_CF_TEST${NC}"
        else
            echo -e "${RED}✗ Panel Remote: HTTP $PANEL_CF_TEST${NC}"
        fi
    fi
fi

# Test Wings
if [ -f "/usr/local/bin/wings" ]; then
    WINGS_TEST=$(curl -k -s https://localhost:8080/api/system 2>&1 || echo "FAILED")
    if echo "$WINGS_TEST" | grep -q "authorization"; then
        echo -e "${GREEN}✓ Wings Local:  Responding${NC}"
    else
        echo -e "${YELLOW}⚠ Wings Local:  Not responding${NC}"
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

# Check critical services
CRITICAL_OK=0
docker ps >/dev/null 2>&1 && ((CRITICAL_OK++))
redis-cli ping >/dev/null 2>&1 && ((CRITICAL_OK++))
netstat -tulpn 2>/dev/null | grep -q ":9000" && ((CRITICAL_OK++))
netstat -tulpn 2>/dev/null | grep -q ":8443" && ((CRITICAL_OK++))
pgrep -f "queue:work" >/dev/null && ((CRITICAL_OK++))

if [ "$CRITICAL_OK" -ge 5 ]; then
    echo -e "${GREEN}✅ All critical services are running!${NC}"
    echo ""
    if [ -n "$PANEL_DOMAIN" ]; then
        echo -e "${CYAN}Panel URL:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
    fi
    if [ -n "$NODE_DOMAIN" ]; then
        echo -e "${CYAN}Wings URL:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
    fi
else
    echo -e "${RED}❌ Some critical services failed to start ($CRITICAL_OK/5)${NC}"
    echo ""
    echo -e "${CYAN}Most Common Issues:${NC}"
    
    # Check PHP-FPM specifically
    if ! netstat -tulpn 2>/dev/null | grep -q ":9000"; then
        echo -e "${RED}  ✗ PHP-FPM not on port 9000${NC}"
        echo -e "${YELLOW}    Fix: Edit /etc/php/8.3/fpm/pool.d/www.conf${NC}"
        echo -e "${YELLOW}    Change: listen = 127.0.0.1:9000${NC}"
        echo -e "${YELLOW}    Then run: service php8.3-fpm restart${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Troubleshooting Commands:${NC}"
    echo -e "  • Panel logs:  ${BLUE}tail -f /var/log/nginx/pelican.app-error.log${NC}"
    echo -e "  • PHP-FPM:     ${BLUE}tail -f /var/log/php8.3-fpm.log${NC}"
    echo -e "  • Queue:       ${BLUE}tail -f /var/log/pelican-queue.log${NC}"
    echo -e "  • Wings:       ${BLUE}tail -f /tmp/wings.log${NC}"
    echo -e "  • Check ports: ${BLUE}netstat -tulpn | grep -E '9000|8443|8080'${NC}"
fi

echo ""
echo -e "${CYAN}📝 Useful Commands:${NC}"
echo -e "  • Restart everything:   ${GREEN}sudo $0${NC}"
echo -e "  • Check all services:   ${GREEN}ps aux | grep -E 'wings|php-fpm|nginx|redis|queue:work'${NC}"
echo -e "  • Fix PHP-FPM config:   ${GREEN}nano /etc/php/8.3/fpm/pool.d/www.conf${NC}"
echo -e "  • Restart PHP-FPM:      ${GREEN}service php8.3-fpm restart${NC}"
echo ""
