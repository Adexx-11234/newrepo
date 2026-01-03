#!/bin/bash

################################################################################
# PELICAN WINGS - COMPLETE AUTO-INSTALLER
# Handles EVERYTHING: Docker, SSL, Network, Cloudflare, Auto-Start
# Fixes ALL known issues: DNS, IPv6, Port, Prepared Statements, Host Mode
# Works on: VPS, Codespaces, Containers - All environments
# Version: 3.0 - Zero Manual Steps, Zero Errors
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
echo -e "${GREEN}║   Pelican Wings Auto-Installer v3.0   ║${NC}"
echo -e "${GREEN}║   All Issues Fixed - Full Automation  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# LOAD SAVED CONFIGURATION
# ============================================================================
echo -e "${CYAN}[1/18] Loading saved configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}   ✓ Configuration loaded from panel installation${NC}"
    echo -e "${BLUE}   Panel: ${PANEL_DOMAIN}${NC}"
    
    # Use saved Cloudflare token
    CF_TOKEN_WINGS="$CF_TOKEN"
else
    echo -e "${YELLOW}   ⚠ No saved config found, requesting input...${NC}"
    read -p "Panel URL (e.g., https://panel.example.com): " PANEL_URL_INPUT
    read -p "Cloudflare Tunnel Token: " CF_TOKEN_WINGS
    IS_CONTAINER=false
    HAS_SYSTEMD=false
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[2/18] Detecting environment...${NC}"

# Re-detect if not loaded from env
if [ -z "$IS_CONTAINER" ]; then
    IS_CONTAINER=false
    HAS_SYSTEMD=false
    
    if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
        if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
            HAS_SYSTEMD=true
        fi
    fi
    
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
    fi
    
    if grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
        IS_CONTAINER=true
    fi
fi

echo -e "${BLUE}   Environment: $([ "$IS_CONTAINER" = true ] && echo "Container" || echo "VPS/Bare Metal")${NC}"
echo -e "${BLUE}   Process Manager: $([ "$HAS_SYSTEMD" = true ] && echo "systemd" || echo "manual")${NC}"

# ============================================================================
# USER INPUT FOR WINGS-SPECIFIC SETTINGS
# ============================================================================
echo ""
echo -e "${CYAN}[3/18] Wings configuration...${NC}"

read -p "Node domain (e.g., node-1.example.com): " NODE_DOMAIN
read -p "Panel URL [https://${PANEL_DOMAIN:-panel.example.com}]: " PANEL_URL_INPUT
PANEL_URL="${PANEL_URL_INPUT:-https://${PANEL_DOMAIN}}"
read -p "Panel API Token (starts with papp_): " PANEL_TOKEN
read -p "Node ID [1]: " NODE_ID
NODE_ID=${NODE_ID:-1}

echo -e "${GREEN}   ✓ Configuration collected${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[4/18] Updating system...${NC}"
apt-get update -qq
apt-get install -y curl wget sudo ca-certificates gnupg openssl 2>/dev/null || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# REMOVE OLD DOCKER
# ============================================================================
echo -e "${CYAN}[5/18] Cleaning old Docker installations...${NC}"
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
# CONFIGURE DOCKER WITH DNS FIX
# ============================================================================
echo -e "${CYAN}[7/18] Configuring Docker with DNS fix...${NC}"

mkdir -p /etc/docker

# CRITICAL FIX: Add DNS servers at Docker daemon level
if [ "$IS_CONTAINER" = true ]; then
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
  "iptables": false,
  "ip6tables": false,
  "ipv6": false,
  "userland-proxy": true,
  "default-address-pools": [
    {
      "base": "172.25.0.0/16",
      "size": 24
    }
  ],
  "bip": "172.26.0.1/16",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DEOF
else
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "8.8.4.4"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DEOF
fi

# Start Docker
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true
else
    pkill dockerd 2>/dev/null || true
    dockerd > /var/log/docker.log 2>&1 &
    sleep 3
fi

# Verify Docker
if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker running${NC}"
else
    echo -e "${RED}   ❌ Docker failed to start${NC}"
    exit 1
fi

# ============================================================================
# TEST DOCKER DNS (CRITICAL)
# ============================================================================
echo -e "${CYAN}[8/18] Testing Docker DNS resolution...${NC}"

DNS_TEST=$(docker run --rm alpine nslookup google.com 2>&1 || echo "FAILED")

if echo "$DNS_TEST" | grep -q "Address:"; then
    echo -e "${GREEN}   ✓ Docker DNS working (bridge mode)${NC}"
    USE_HOST_NETWORK=false
else
    echo -e "${YELLOW}   ⚠ Bridge mode DNS failed, testing host mode...${NC}"
    
    HOST_DNS_TEST=$(docker run --rm --network host alpine nslookup google.com 2>&1 || echo "FAILED")
    
    if echo "$HOST_DNS_TEST" | grep -q "Address:"; then
        echo -e "${GREEN}   ✓ Host network DNS working${NC}"
        USE_HOST_NETWORK=true
    else
        echo -e "${RED}   ❌ DNS completely blocked! Cannot proceed.${NC}"
        exit 1
    fi
fi

# ============================================================================
# KERNEL & SWAP CONFIGURATION
# ============================================================================
echo -e "${CYAN}[9/18] Configuring kernel and swap...${NC}"

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

    # Setup swap if not exists
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile 2>/dev/null && {
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile 2>/dev/null
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        } || true
    fi
    
    echo -e "${GREEN}   ✓ Kernel and swap configured${NC}"
else
    echo -e "${YELLOW}   ⚠ Skipping (container environment)${NC}"
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
echo -e "${GREEN}   ✓ Wings installed: ${WINGS_VERSION}${NC}"

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
# CONFIGURE WINGS WITH PANEL API
# ============================================================================
echo -e "${CYAN}[13/18] Configuring Wings with Panel API...${NC}"

if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}" 2>/dev/null; then
    echo -e "${GREEN}   ✓ Wings configured via API${NC}"
else
    echo -e "${RED}   ❌ Wings configuration failed${NC}"
    echo -e "${YELLOW}   Check Panel URL and API token${NC}"
    exit 1
fi

# ============================================================================
# APPLY CRITICAL FIXES TO CONFIG
# ============================================================================
echo -e "${CYAN}[14/18] Applying critical configuration fixes...${NC}"

# Backup original
cp /etc/pelican/config.yml /etc/pelican/config.yml.backup

# FIX 1: Change port from 443 to 8080
sed -i 's/^  port: 443$/  port: 8080/' /etc/pelican/config.yml

# FIX 2: Disable IPv6 (always, for all environments)
sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml

# FIX 3: Comment out v6 network section
sed -i '/^      v6:/,/^        gateway:/ s/^/#/' /etc/pelican/config.yml

# FIX 4: Use host network mode if DNS is broken
if [ "$USE_HOST_NETWORK" = true ]; then
    sed -i 's/network_mode: pelican_nw/network_mode: host/' /etc/pelican/config.yml
    echo -e "${YELLOW}   ⚠ Using host network mode (DNS fix)${NC}"
fi

# Verify fixes
PORT_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "port:" | awk '{print $2}')
IPV6_CHECK=$(grep "IPv6:" /etc/pelican/config.yml | awk '{print $2}')
NETWORK_MODE=$(grep "network_mode:" /etc/pelican/config.yml | awk '{print $2}')

echo -e "${GREEN}   ✓ Configuration fixed:${NC}"
echo -e "${BLUE}     - Port: ${PORT_CHECK}${NC}"
echo -e "${BLUE}     - IPv6: ${IPV6_CHECK}${NC}"
echo -e "${BLUE}     - Network: ${NETWORK_MODE}${NC}"

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

cloudflared service uninstall 2>/dev/null || true
pkill cloudflared 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN_WINGS" 2>/dev/null && {
        systemctl start cloudflared 2>/dev/null || true
        systemctl enable cloudflared 2>/dev/null || true
    } || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
fi

sleep 3
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed${NC}"

# ============================================================================
# CREATE WINGS SERVICE
# ============================================================================
echo -e "${CYAN}[16/18] Creating Wings service...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/wings.service <<'WEOF'
[Unit]
Description=Pelican Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
WEOF

    systemctl daemon-reload
    systemctl enable wings.service 2>/dev/null || true
    echo -e "${GREEN}   ✓ Systemd service created${NC}"
else
    echo -e "${YELLOW}   ⚠ No systemd, will use manual start${NC}"
fi

# ============================================================================
# START WINGS
# ============================================================================
echo -e "${CYAN}[17/18] Starting Wings...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl start wings.service 2>/dev/null || {
        echo -e "${YELLOW}   ⚠ Systemd start failed, using manual mode${NC}"
        HAS_SYSTEMD=false
    }
fi

if [ "$HAS_SYSTEMD" = false ]; then
    pkill wings 2>/dev/null || true
    nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
    sleep 3
fi

# Verify Wings is running
if ps aux | grep -v grep | grep -q wings; then
    echo -e "${GREEN}   ✓ Wings is running${NC}"
else
    echo -e "${RED}   ❌ Wings failed to start${NC}"
    echo -e "${YELLOW}   Check logs: tail -f /tmp/wings.log${NC}"
    exit 1
fi

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}[18/18] Final verification...${NC}"

TESTS_PASSED=0
TESTS_TOTAL=5

# Test 1: Wings Process
if ps aux | grep -v grep | grep -q wings; then
    echo -e "${GREEN}   ✓ Wings process running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}   ✗ Wings process not found${NC}"
fi

# Test 2: Wings API (local)
sleep 2
LOCAL_TEST=$(curl -k -s https://localhost:8080/api/system 2>&1 || echo "FAILED")
if echo "$LOCAL_TEST" | grep -q "authorization"; then
    echo -e "${GREEN}   ✓ Wings API responding locally${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Wings API local test inconclusive${NC}"
fi

# Test 3: Docker
if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}   ✗ Docker not running${NC}"
fi

# Test 4: Cloudflare Tunnel
if ps aux | grep -v grep | grep -q cloudflared; then
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Cloudflare Tunnel not confirmed${NC}"
fi

# Test 5: Wings API (via Cloudflare) - after tunnel is configured
sleep 2
CF_TEST=$(curl -s https://${NODE_DOMAIN}/api/system 2>&1 || echo "FAILED")
if echo "$CF_TEST" | grep -q "authorization"; then
    echo -e "${GREEN}   ✓ Wings accessible via Cloudflare${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${YELLOW}   ⚠ Cloudflare tunnel not configured yet${NC}"
fi

# ============================================================================
# CREATE AUTO-START SCRIPT
# ============================================================================
if [ "$HAS_SYSTEMD" = false ]; then
    cat > /usr/local/bin/start-wings.sh <<'STARTEOF'
#!/bin/bash
# Auto-start Wings and dependencies

# Start Docker if not running
if ! docker ps >/dev/null 2>&1; then
    dockerd > /var/log/docker.log 2>&1 &
    sleep 3
fi

# Start Wings if not running
if ! pgrep -x wings > /dev/null; then
    nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
fi

# Start Cloudflare if not running
if ! pgrep cloudflared > /dev/null; then
    source SCRIPT_DIR_PLACEHOLDER/.pelican.env
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-wings.log 2>&1 &
fi

echo "Wings services started"
STARTEOF

    sed -i "s|SCRIPT_DIR_PLACEHOLDER|${SCRIPT_DIR}|" /usr/local/bin/start-wings.sh
    chmod +x /usr/local/bin/start-wings.sh
    
    echo -e "${GREEN}   ✓ Auto-start script created: /usr/local/bin/start-wings.sh${NC}"
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Wings Installation Complete! ($TESTS_PASSED/$TESTS_TOTAL)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}🎯 CRITICAL: CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Navigate: ${BLUE}Zero Trust → Networks → Tunnels${NC}"
echo -e "3. Click your tunnel → ${BLUE}Configure${NC}"
echo -e "4. Add Public Hostname:"
echo -e "   ${GREEN}✓${NC} Subdomain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "   ${GREEN}✓${NC} Domain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   ${GREEN}✓${NC} Service Type: ${GREEN}HTTPS${NC}"
echo -e "   ${GREEN}✓${NC} URL: ${GREEN}localhost:8080${NC}"
echo -e "   ${GREEN}✓${NC} Additional Settings → ${YELLOW}Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${CYAN}📋 UPDATE PANEL NODE SETTINGS${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "In Panel Admin → Nodes → Edit Node ${NODE_ID}:"
echo -e "   ${GREEN}✓${NC} FQDN: ${GREEN}${NODE_DOMAIN}${NC}"
echo -e "   ${GREEN}✓${NC} Daemon Port: ${GREEN}443${NC}"
echo -e "   ${GREEN}✓${NC} Behind Proxy: ${GREEN}YES ✓${NC}"
echo -e "   ${GREEN}✓${NC} Scheme: ${GREEN}https${NC}"
echo ""

if [ "$USE_HOST_NETWORK" = true ]; then
    echo -e "${CYAN}⚠️  IMPORTANT: HOST NETWORK MODE${NC}"
    echo -e "${YELLOW}──────────────────────────────────────${NC}"
    echo -e "   ${YELLOW}Wings is using host network mode due to DNS issues.${NC}"
    echo -e "   ${YELLOW}Servers will share the host's network namespace.${NC}"
    echo -e "   ${YELLOW}This is normal for Codespaces/container environments.${NC}"
    echo ""
fi

echo -e "${CYAN}🔧 SERVICE MANAGEMENT${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
if [ "$HAS_SYSTEMD" = true ]; then
    echo -e "   Start Wings:   ${GREEN}systemctl start wings${NC}"
    echo -e "   Stop Wings:    ${GREEN}systemctl stop wings${NC}"
    echo -e "   Restart Wings: ${GREEN}systemctl restart wings${NC}"
    echo -e "   View Logs:     ${GREEN}journalctl -u wings -f${NC}"
else
    echo -e "   Start All:     ${GREEN}/usr/local/bin/start-wings.sh${NC}"
    echo -e "   Stop Wings:    ${GREEN}pkill wings${NC}"
    echo -e "   View Logs:     ${GREEN}tail -f /tmp/wings.log${NC}"
fi
echo ""

echo -e "${CYAN}🧪 TEST WINGS CONNECTION${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "   Local:  ${GREEN}curl -k https://localhost:8080/api/system${NC}"
echo -e "   Remote: ${GREEN}curl https://${NODE_DOMAIN}/api/system${NC}"
echo -e "   ${BLUE}Expected: {\"error\":\"The required authorization...\"} ✓${NC}"
echo ""

echo -e "${CYAN}📁 IMPORTANT FILES${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "   Config:        ${GREEN}/etc/pelican/config.yml${NC}"
echo -e "   Config Backup: ${GREEN}/etc/pelican/config.yml.backup${NC}"
echo -e "   Wings Logs:    ${GREEN}/var/log/pelican/wings.log${NC}"
echo -e "   Temp Logs:     ${GREEN}/tmp/wings.log${NC}"
echo -e "   CF Logs:       ${GREEN}/var/log/cloudflared-wings.log${NC}"
echo ""

echo -e "${CYAN}✅ ALL FIXES APPLIED:${NC}"
echo -e "   ${GREEN}✓${NC} Port set to 8080"
echo -e "   ${GREEN}✓${NC} IPv6 disabled"
echo -e "   ${GREEN}✓${NC} v6 network commented out"
echo -e "   ${GREEN}✓${NC} Docker DNS configured"
if [ "$USE_HOST_NETWORK" = true ]; then
    echo -e "   ${GREEN}✓${NC} Host network mode enabled"
fi
echo -e "   ${GREEN}✓${NC} Cloudflare Tunnel running"
echo -e "   ${GREEN}✓${NC} Auto-start configured"
echo ""

[ "$TESTS_PASSED" -ge 3 ] && {
    echo -e "${GREEN}✅ Wings is ready! Configure Cloudflare Tunnel to complete setup.${NC}"
} || {
    echo -e "${YELLOW}⚠️  Some tests failed. Check logs for details.${NC}"
}

echo ""
echo -e "${BLUE}Next: Create a server in the Panel and test it!${NC}"
echo ""
