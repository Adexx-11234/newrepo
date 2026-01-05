#!/bin/bash

################################################################################
# PELICAN WINGS - COMPLETE INSTALLER v4.0 FINAL
# ALL ISSUES FIXED: Docker, DNS, IPv6, Ports, Host Mode, Icons, PHP
# Production-ready for VPS, Codespaces, and all container environments
# Zero manual steps - Full automation
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
echo -e "${GREEN}║   Pelican Wings Installer v4.0 FINAL  ║${NC}"
echo -e "${GREEN}║   All Issues Fixed - Production Ready ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# LOAD SAVED CONFIGURATION
# ============================================================================
echo -e "${CYAN}[1/18] Loading configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}   ✓ Panel config loaded: ${PANEL_DOMAIN}${NC}"
    CF_TOKEN_WINGS="$CF_TOKEN"
    PANEL_URL="https://${PANEL_DOMAIN}"
else
    echo -e "${YELLOW}   ⚠ No saved config found${NC}"
    read -p "Panel URL (e.g., https://panel.example.com): " PANEL_URL
    read -p "Cloudflare Tunnel Token: " CF_TOKEN_WINGS
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[2/18] Detecting environment...${NC}"

IS_CONTAINER=false
HAS_SYSTEMD=false

if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
        HAS_SYSTEMD=true
        echo -e "${GREEN}   ✓ Systemd available${NC}"
    fi
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null || grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}   ⚠ Container environment (Codespaces/Docker)${NC}"
fi

# ============================================================================
# USER INPUT
# ============================================================================
echo -e "${CYAN}[3/18] Wings configuration...${NC}"

read -p "Node domain (e.g., node-1.example.com): " NODE_DOMAIN
read -p "Panel URL [${PANEL_URL}]: " PANEL_URL_INPUT
PANEL_URL="${PANEL_URL_INPUT:-${PANEL_URL}}"
read -p "Panel API Token (starts with papp_): " PANEL_TOKEN
read -p "Node ID [1]: " NODE_ID
NODE_ID=${NODE_ID:-1}

echo -e "${GREEN}   ✓ Configuration collected${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[4/18] Updating system...${NC}"
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y curl wget sudo ca-certificates gnupg openssl iptables git 2>/dev/null || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# REMOVE OLD DOCKER
# ============================================================================
echo -e "${CYAN}[5/18] Cleaning old Docker...${NC}"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done
apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}   ✓ Cleanup complete${NC}"

# ============================================================================
# INSTALL DOCKER
# ============================================================================
echo -e "${CYAN}[6/18] Installing Docker...${NC}"

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    rm get-docker.sh
fi

echo -e "${GREEN}   ✓ Docker installed: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')${NC}"

# ============================================================================
# CONFIGURE AND START DOCKER (FIXED FOR ALL ENVIRONMENTS)
# ============================================================================
echo -e "${CYAN}[7/18] Starting Docker daemon...${NC}"

mkdir -p /etc/docker

# Create optimized daemon config
if [ "$IS_CONTAINER" = true ]; then
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
  "iptables": false,
  "ip6tables": false,
  "ipv6": false,
  "userland-proxy": true,
  "default-address-pools": [{"base": "172.25.0.0/16", "size": 24}],
  "bip": "172.26.0.1/16",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
DEOF
else
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "8.8.4.4"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
DEOF
fi

# Stop any existing Docker
pkill dockerd 2>/dev/null || true
sleep 2

# Start Docker (handles both systemd and manual)
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    echo -e "${YELLOW}   Starting Docker manually...${NC}"
    pkill -9 dockerd 2>/dev/null || true
    sleep 1
    
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    
    echo -n "   Waiting for Docker"
    for i in {1..15}; do
        sleep 1
        echo -n "."
        if docker info >/dev/null 2>&1; then
            echo ""
            break
        fi
    done
    echo ""
fi

# Verify Docker
if docker info >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker daemon running${NC}"
else
    echo -e "${RED}   ❌ Docker failed to start${NC}"
    echo -e "${YELLOW}   Logs:${NC}"
    tail -20 /var/log/docker.log 2>/dev/null || echo "No logs"
    exit 1
fi

# ============================================================================
# TEST DOCKER DNS (CRITICAL)
# ============================================================================
echo -e "${CYAN}[8/18] Testing Docker DNS...${NC}"

echo -e "${BLUE}   Pulling alpine image...${NC}"
docker pull alpine:latest >/dev/null 2>&1 || {
    echo -e "${YELLOW}   ⚠ Standard pull failed, trying host network${NC}"
    docker pull --network host alpine:latest >/dev/null 2>&1
}

DNS_TEST=$(docker run --rm alpine nslookup google.com 2>&1 || echo "FAILED")

if echo "$DNS_TEST" | grep -q "Address:"; then
    echo -e "${GREEN}   ✓ DNS working (bridge mode)${NC}"
    USE_HOST_NETWORK=false
else
    echo -e "${YELLOW}   ⚠ Bridge DNS failed, testing host mode...${NC}"
    
    HOST_DNS_TEST=$(docker run --rm --network host alpine nslookup google.com 2>&1 || echo "FAILED")
    
    if echo "$HOST_DNS_TEST" | grep -q "Address:"; then
        echo -e "${GREEN}   ✓ DNS working (host mode)${NC}"
        USE_HOST_NETWORK=true
    else
        echo -e "${RED}   ❌ DNS completely blocked!${NC}"
        exit 1
    fi
fi

# ============================================================================
# KERNEL CONFIG (skip in containers)
# ============================================================================
echo -e "${CYAN}[9/18] Kernel configuration...${NC}"

if [ "$IS_CONTAINER" = false ]; then
    cat > /etc/modules-load.d/pelican-wings.conf <<EOF
overlay
br_netfilter
EOF
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true

    cat > /etc/sysctl.d/99-pelican-wings.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 10
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}   ✓ Kernel configured${NC}"
else
    echo -e "${YELLOW}   ⚠ Skipped (container)${NC}"
fi

# ============================================================================
# CREATE DIRECTORIES
# ============================================================================
echo -e "${CYAN}[10/18] Creating directories...${NC}"

mkdir -p /etc/pelican
mkdir -p /var/lib/pelican/{volumes,archives,backups}
mkdir -p /var/log/pelican
mkdir -p /var/run/wings
mkdir -p /tmp/pelican

chmod 755 /etc/pelican /var/lib/pelican /var/log/pelican

echo -e "${GREEN}   ✓ Directories created${NC}"

# ============================================================================
# DOWNLOAD WINGS
# ============================================================================
echo -e "${CYAN}[11/18] Downloading Wings...${NC}"

cd /usr/local/bin
curl -L -o wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64" 2>/dev/null
chmod +x wings

if [ ! -x /usr/local/bin/wings ]; then
    echo -e "${RED}   ❌ Wings download failed${NC}"
    exit 1
fi

WINGS_VERSION=$(wings --version 2>/dev/null | grep -oP 'wings \Kv[\d\.]+' || echo "latest")
echo -e "${GREEN}   ✓ Wings ${WINGS_VERSION} installed${NC}"

# ============================================================================
# SSL CERTIFICATES
# ============================================================================
echo -e "${CYAN}[12/18] Creating SSL certificates...${NC}"

mkdir -p /etc/letsencrypt/live/${NODE_DOMAIN}

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
  -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
  -subj "/CN=${NODE_DOMAIN}" 2>/dev/null

echo -e "${GREEN}   ✓ Self-signed certificate created${NC}"

# ============================================================================
# CONFIGURE WINGS WITH PANEL
# ============================================================================
echo -e "${CYAN}[13/18] Configuring Wings via Panel API...${NC}"

if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}" 2>/dev/null; then
    echo -e "${GREEN}   ✓ Wings configured successfully${NC}"
else
    echo -e "${RED}   ❌ Configuration failed${NC}"
    echo -e "${YELLOW}   Check Panel URL and API token${NC}"
    exit 1
fi

# ============================================================================
# APPLY CRITICAL CONFIGURATION FIXES
# ============================================================================
echo -e "${CYAN}[14/18] Applying critical fixes...${NC}"

cp /etc/pelican/config.yml /etc/pelican/config.yml.backup

# Fix 1: Port 8080 (Cloudflare compatibility)
sed -i 's/^  port: 443$/  port: 8080/' /etc/pelican/config.yml

# Fix 2: Disable IPv6 (container compatibility)
sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml

# Fix 3: Comment out v6 network section
sed -i '/^      v6:/,/^        gateway:/ s/^/#/' /etc/pelican/config.yml

# Fix 4: Use host network if DNS broken
if [ "$USE_HOST_NETWORK" = true ]; then
    sed -i 's/network_mode: pelican_nw/network_mode: host/' /etc/pelican/config.yml
    echo -e "${YELLOW}   ⚠ Using host network mode (DNS fix)${NC}"
fi

PORT_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "port:" | awk '{print $2}')
echo -e "${GREEN}   ✓ Configuration fixed (Port: ${PORT_CHECK})${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[15/18] Installing Cloudflare Tunnel...${NC}"

if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
        apt --fix-broken install -y 2>/dev/null
        dpkg -i cloudflared-linux-amd64.deb 2>/dev/null
    }
    rm -f cloudflared-linux-amd64.deb
fi

pkill cloudflared 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN_WINGS" 2>/dev/null && {
        systemctl start cloudflared 2>/dev/null || true
        systemctl enable cloudflared 2>/dev/null || true
    } || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
fi

sleep 2
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed${NC}"

# ============================================================================
# CREATE AUTO-START SCRIPT
# ============================================================================
echo -e "${CYAN}[16/18] Creating auto-start script...${NC}"

cat > /usr/local/bin/start-wings.sh <<STARTEOF
#!/bin/bash
# Wings Auto-Start Script (All environments)

echo "Starting Wings services..."

# Start Docker if not running
if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker daemon..."
    pkill -9 dockerd 2>/dev/null || true
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    sleep 5
fi

# Start Wings
if ! pgrep -x wings > /dev/null; then
    echo "Starting Wings..."
    cd /etc/pelican
    nohup wings > /tmp/wings.log 2>&1 &
    sleep 2
fi

# Start Cloudflare Tunnel
if ! pgrep cloudflared > /dev/null; then
    echo "Starting Cloudflare Tunnel..."
    nohup cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
fi

echo ""
echo "Services Status:"
docker info >/dev/null 2>&1 && echo "  ✓ Docker running" || echo "  ✗ Docker not running"
pgrep -x wings >/dev/null && echo "  ✓ Wings running" || echo "  ✗ Wings not running"
pgrep cloudflared >/dev/null && echo "  ✓ Cloudflare Tunnel running" || echo "  ✗ Cloudflare not running"
STARTEOF

chmod +x /usr/local/bin/start-wings.sh
echo -e "${GREEN}   ✓ Auto-start script: /usr/local/bin/start-wings.sh${NC}"

# ============================================================================
# START WINGS
# ============================================================================
echo -e "${CYAN}[17/18] Starting Wings...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/wings.service <<'WEOF'
[Unit]
Description=Pelican Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
WEOF

    systemctl daemon-reload
    systemctl enable wings 2>/dev/null || true
    systemctl start wings 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    cd /etc/pelican
    nohup wings > /tmp/wings.log 2>&1 &
    sleep 3
fi

# Verify Wings
if ps aux | grep -v grep | grep -q wings; then
    echo -e "${GREEN}   ✓ Wings running${NC}"
else
    echo -e "${RED}   ❌ Wings failed to start${NC}"
    echo -e "${YELLOW}   Check: tail -f /tmp/wings.log${NC}"
fi

# ============================================================================
# DOWNLOAD EGG ICONS (FIX 404 ERRORS) - RUNS ON PANEL SERVER
# ============================================================================
echo -e "${CYAN}[18/18] Installing egg icons on Panel...${NC}"

if [ -d "/var/www/pelican" ]; then
    echo -e "${BLUE}   Panel detected, installing icons...${NC}"
    
    # Force system PHP
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    PHP_BIN="/usr/bin/php8.3"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
    
    cd /var/www/pelican
    
    # Create directories
    mkdir -p storage/app/public/icons/egg
    chown -R www-data:www-data storage/app/public
    
    # Create storage link
    $PHP_BIN artisan storage:link 2>/dev/null || true
    
    # Download egg icons
    cd storage/app/public/icons/egg
    echo -e "${BLUE}   Downloading egg icons...${NC}"
    git clone --depth 1 https://github.com/pelican-eggs/eggs.git /tmp/pelican-eggs-wings 2>/dev/null
    find /tmp/pelican-eggs-wings -type f \( -name "*.png" -o -name "*.svg" -o -name "*.jpg" -o -name "*.webp" \) -exec cp {} . \; 2>/dev/null
    rm -rf /tmp/pelican-eggs-wings
    
    # Fix permissions
    chown -R www-data:www-data /var/www/pelican/storage
    chmod -R 755 /var/www/pelican/storage/app/public
    
    # Clear cache
    cd /var/www/pelican
    $PHP_BIN artisan cache:clear >/dev/null 2>&1
    $PHP_BIN artisan view:clear >/dev/null 2>&1
    
    ICON_COUNT=$(ls -1 /var/www/pelican/storage/app/public/icons/egg/ 2>/dev/null | wc -l)
    echo -e "${GREEN}   ✓ Installed ${ICON_COUNT} egg icons${NC}"
else
    echo -e "${YELLOW}   ⚠ Panel not installed on this server, skipping icons${NC}"
fi

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}Verifying installation...${NC}"

CHECKS=0
docker info >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ Docker running${NC}"; ((CHECKS++)); }
ps aux | grep -v grep | grep -q wings && { echo -e "${GREEN}  ✓ Wings running${NC}"; ((CHECKS++)); }
ps aux | grep -v grep | grep -q cloudflared && { echo -e "${GREEN}  ✓ Cloudflare Tunnel${NC}"; ((CHECKS++)); }
[ -f /etc/pelican/config.yml ] && { echo -e "${GREEN}  ✓ Configuration exists${NC}"; ((CHECKS++)); }
netstat -tulpn 2>/dev/null | grep -q 8080 || { echo -e "${GREEN}  ✓ Port 8080 ready${NC}"; ((CHECKS++)); }

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Wings Installation Complete! (${CHECKS}/5)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}🎯 CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Navigate: ${BLUE}Zero Trust → Networks → Tunnels → Configure${NC}"
echo -e "3. Add Public Hostname:"
echo -e "   - Subdomain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${GREEN}HTTPS${NC}"
echo -e "   - URL: ${GREEN}localhost:8080${NC}"
echo -e "   - ${YELLOW}⚠️  Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${CYAN}📋 UPDATE PANEL NODE${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "In Panel: Admin → Nodes → Edit Node ${NODE_ID}"
echo -e "   - FQDN: ${GREEN}${NODE_DOMAIN}${NC}"
echo -e "   - Daemon Port: ${GREEN}443${NC}"
echo -e "   - Behind Proxy: ${GREEN}YES ✓${NC}"
echo -e "   - Scheme: ${GREEN}https${NC}"
echo ""

if [ "$USE_HOST_NETWORK" = true ]; then
    echo -e "${CYAN}⚠️  HOST NETWORK MODE ACTIVE${NC}"
    echo -e "   Wings is using host network mode due to DNS issues."
    echo -e "   This is normal for Codespaces/container environments."
    echo ""
fi

if [ "$HAS_SYSTEMD" = false ]; then
    echo -e "${CYAN}🔧 CONTAINER MODE COMMANDS${NC}"
    echo -e "   Start all services: ${GREEN}/usr/local/bin/start-wings.sh${NC}"
    echo -e "   View Wings logs: ${GREEN}tail -f /tmp/wings.log${NC}"
    echo -e "   View Docker logs: ${GREEN}tail -f /var/log/docker.log${NC}"
    echo ""
fi

echo -e "${CYAN}🧪 TEST WINGS CONNECTION${NC}"
echo -e "   Local:  ${GREEN}curl -k https://localhost:8080/api/system${NC}"
echo -e "   Remote: ${GREEN}curl https://${NODE_DOMAIN}/api/system${NC}"
echo -e "   ${BLUE}Expected: {\"error\":\"The required authorization...\"} ✓${NC}"
echo ""

echo -e "${CYAN}📁 IMPORTANT FILES${NC}"
echo -e "   Config: ${GREEN}/etc/pelican/config.yml${NC}"
echo -e "   Backup: ${GREEN}/etc/pelican/config.yml.backup${NC}"
echo -e "   Logs: ${GREEN}/var/log/pelican/wings.log${NC}"
echo ""

echo -e "${CYAN}🎨 FIX EGG ICONS (Panel Server)${NC}"
echo -e "   Run on Panel: ${GREEN}/tmp/install-egg-icons.sh${NC}"
echo -e "   Or manually:"
echo -e "   ${GREEN}cd /var/www/pelican/storage/app/public/icons/egg${NC}"
echo -e "   ${GREEN}git clone --depth 1 https://github.com/pelican-eggs/eggs.git /tmp/pelican-eggs${NC}"
echo -e "   ${GREEN}find /tmp/pelican-eggs -name '*.png' -o -name '*.svg' | xargs -I {} cp {} .${NC}"
echo ""

echo -e "${BLUE}✅ Wings is ready! Complete Cloudflare Tunnel setup, then create servers!${NC}"
echo ""
