#!/bin/bash

################################################################################
# Pelican Wings Installation Script - UNIVERSAL VERSION
# Works on: VPS, Bare Metal, GitHub Codespaces, Docker Containers, Sandbox
# Handles: Docker, SSL, systemd/non-systemd, container limitations
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Wings Installation            ${NC}"
echo -e "${GREEN}  Universal Version (All Environments)  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

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

if pidof systemd >/dev/null 2>&1 && systemctl is-system-running &> /dev/null 2>&1; then
    HAS_SYSTEMD=true
    echo -e "${GREEN}✅ Systemd detected${NC}"
else
    echo -e "${YELLOW}⚠️  No systemd - using manual process management${NC}"
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
# USER INPUT
# ============================================================================
echo -e "${YELLOW}=== Configuration ===${NC}"
echo ""
echo -e "${BLUE}Node domain (e.g., node-1.example.com):${NC}"
read -r NODE_DOMAIN

echo ""
echo -e "${BLUE}Panel URL (e.g., https://panel.example.com):${NC}"
read -r PANEL_URL

echo ""
echo -e "${BLUE}Panel API Token (starts with papp_):${NC}"
read -r PANEL_TOKEN

echo ""
echo -e "${BLUE}Node ID (usually 1 for first node):${NC}"
read -r NODE_ID
NODE_ID=${NODE_ID:-1}

echo ""
echo -e "${YELLOW}SSL Certificate Setup:${NC}"
echo "1) Self-signed (recommended for Cloudflare Tunnel)"
echo "2) Let's Encrypt (production VPS only - requires DNS + port 80)"
echo "3) Skip SSL (use with Cloudflare Tunnel SSL termination)"
read -p "Choice [1]: " SSL_CHOICE
SSL_CHOICE=${SSL_CHOICE:-1}

if [ "$IS_CONTAINER" = true ] && [ "$SSL_CHOICE" = "2" ]; then
    echo -e "${YELLOW}⚠️  Let's Encrypt may not work in containers${NC}"
    echo -e "${YELLOW}   Recommend option 1 or 3 instead${NC}"
    read -p "Continue anyway? (yes/no): " CONTINUE
    [[ ! "$CONTINUE" =~ ^[Yy] ]] && { echo -e "${RED}Cancelled${NC}"; exit 0; }
fi

echo ""
echo -e "${YELLOW}=== Configuration Summary ===${NC}"
echo -e "Node Domain: ${GREEN}${NODE_DOMAIN}${NC}"
echo -e "Panel URL: ${GREEN}${PANEL_URL}${NC}"
echo -e "Node ID: ${GREEN}${NODE_ID}${NC}"
echo -e "SSL: ${GREEN}Option ${SSL_CHOICE}${NC}"
echo ""
echo -e "${YELLOW}Continue with installation? (yes/no):${NC}"
read -r CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy] ]] && { echo -e "${RED}Cancelled${NC}"; exit 0; }

# ============================================================================
# STEP 1: System Preparation
# ============================================================================
echo ""
echo -e "${YELLOW}[1/10] Preparing system...${NC}"

apt-get update -qq
apt-get install -y curl wget sudo ca-certificates gnupg openssl

echo -e "${GREEN}✅ System prepared${NC}"

# ============================================================================
# STEP 2: Remove Old Docker
# ============================================================================
echo -e "${YELLOW}[2/10] Cleaning old Docker installations...${NC}"

for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done

apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}✅ Cleanup complete${NC}"

# ============================================================================
# STEP 3: Install Docker
# ============================================================================
echo -e "${YELLOW}[3/10] Installing Docker...${NC}"

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker installation failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Docker installed${NC}"
docker --version

# ============================================================================
# STEP 4: Configure Docker
# ============================================================================
echo -e "${YELLOW}[4/10] Configuring Docker...${NC}"

mkdir -p /etc/docker

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${BLUE}Applying container-specific Docker config...${NC}"
    cat > /etc/docker/daemon.json <<EOF
{
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
EOF
else
    echo -e "${BLUE}Applying standard Docker config...${NC}"
    cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
fi

# Start Docker
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker
else
    pkill dockerd 2>/dev/null || true
    dockerd > /var/log/docker.log 2>&1 &
    sleep 3
fi

# Verify Docker
if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Docker configured and running${NC}"
else
    echo -e "${RED}❌ Docker failed to start!${NC}"
    exit 1
fi

# ============================================================================
# STEP 5: Kernel Configuration
# ============================================================================
echo -e "${YELLOW}[5/10] Configuring kernel...${NC}"

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

    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}✅ Kernel configured${NC}"
else
    echo -e "${YELLOW}⚠️  Skipping kernel modules (container environment)${NC}"
fi

# ============================================================================
# STEP 6: Swap Configuration
# ============================================================================
echo -e "${YELLOW}[6/10] Configuring swap...${NC}"

if [ "$IS_CONTAINER" = false ]; then
    if [ ! -f /swapfile ]; then
        if fallocate -l 2G /swapfile 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            
            if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            
            echo -e "${GREEN}✅ Swap enabled${NC}"
        else
            echo -e "${YELLOW}⚠️  Swap creation failed, continuing...${NC}"
        fi
    else
        echo -e "${GREEN}✅ Swap already exists${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Skipping swap (container environment)${NC}"
fi

# ============================================================================
# STEP 7: Create Directories
# ============================================================================
echo -e "${YELLOW}[7/10] Creating directories...${NC}"

mkdir -p /etc/pelican
mkdir -p /var/lib/pelican/volumes
mkdir -p /var/lib/pelican/archives
mkdir -p /var/lib/pelican/backups
mkdir -p /var/log/pelican
mkdir -p /var/run/wings
mkdir -p /tmp/pelican

chmod 755 /etc/pelican /var/lib/pelican /var/log/pelican

echo -e "${GREEN}✅ Directories created${NC}"

# ============================================================================
# STEP 8: Download Wings
# ============================================================================
echo -e "${YELLOW}[8/10] Downloading Wings...${NC}"

cd /usr/local/bin
curl -L -o wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64"
chmod +x wings

if [ ! -x /usr/local/bin/wings ]; then
    echo -e "${RED}❌ Wings download failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Wings installed${NC}"
wings --version 2>/dev/null || echo -e "${BLUE}Version: latest${NC}"

# ============================================================================
# STEP 9: SSL Certificates
# ============================================================================
echo -e "${YELLOW}[9/10] Setting up SSL certificates...${NC}"

mkdir -p /etc/letsencrypt/live/${NODE_DOMAIN}

if [ "$SSL_CHOICE" = "1" ]; then
    echo -e "${BLUE}Creating self-signed certificate...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
      -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
      -subj "/CN=${NODE_DOMAIN}" 2>/dev/null
    echo -e "${GREEN}✅ Self-signed certificate created${NC}"
    
elif [ "$SSL_CHOICE" = "2" ]; then
    echo -e "${BLUE}Installing Certbot...${NC}"
    apt-get update -qq
    apt-get install -y certbot
    
    echo -e "${BLUE}Obtaining Let's Encrypt certificate...${NC}"
    
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl stop nginx 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
    fi
    
    if certbot certonly --standalone --non-interactive --agree-tos \
        --email admin@${NODE_DOMAIN} -d ${NODE_DOMAIN}; then
        echo -e "${GREEN}✅ Let's Encrypt certificate obtained${NC}"
        
        if [ "$HAS_SYSTEMD" = true ]; then
            cat > /etc/cron.d/certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --deploy-hook "pkill -HUP wings"
EOF
            echo -e "${GREEN}✅ Auto-renewal configured${NC}"
        fi
    else
        echo -e "${RED}❌ Let's Encrypt failed! Creating self-signed fallback...${NC}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
          -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
          -subj "/CN=${NODE_DOMAIN}" 2>/dev/null
    fi
    
else
    echo -e "${YELLOW}SSL skipped - using Cloudflare Tunnel SSL termination${NC}"
    echo -e "${BLUE}Creating placeholder certificates...${NC}"
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
      -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
      -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
      -subj "/CN=${NODE_DOMAIN}" 2>/dev/null
    echo -e "${GREEN}✅ Placeholder certificates created${NC}"
fi

# ============================================================================
# STEP 10: Configure Wings Automatically
# ============================================================================
echo -e "${YELLOW}[10/11] Configuring Wings with Panel...${NC}"

# Run wings configure command
echo -e "${BLUE}Running: wings configure --panel-url ${PANEL_URL} --token [HIDDEN] --node ${NODE_ID}${NC}"

if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}"; then
    echo -e "${GREEN}✅ Wings configured successfully${NC}"
else
    echo -e "${RED}❌ Wings configuration failed!${NC}"
    echo -e "${YELLOW}Please check your Panel URL and token${NC}"
    exit 1
fi

# ============================================================================
# STEP 11: Auto-Fix Configuration for Containers
# ============================================================================
echo -e "${YELLOW}[11/11] Applying environment-specific fixes...${NC}"

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${BLUE}Applying container-specific configuration fixes...${NC}"
    
    # Backup original config
    cp /etc/pelican/config.yml /etc/pelican/config.yml.backup
    
    # Fix IPv6 setting
    sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml
    
    # Comment out v6 section
    sed -i '/^[[:space:]]*v6:/,/^[[:space:]]*gateway:.*$/s/^/#/' /etc/pelican/config.yml
    
    echo -e "${GREEN}✅ Container-specific fixes applied${NC}"
    echo -e "${BLUE}   - IPv6 disabled${NC}"
    echo -e "${BLUE}   - v6 network section commented out${NC}"
    echo -e "${YELLOW}   - Original config backed up to: /etc/pelican/config.yml.backup${NC}"
else
    echo -e "${GREEN}✅ No environment-specific fixes needed${NC}"
fi

# Verify critical settings
echo -e "${BLUE}Verifying configuration...${NC}"

if grep -q "IPv6: false" /etc/pelican/config.yml || [ "$IS_CONTAINER" = false ]; then
    echo -e "${GREEN}✅ IPv6 configuration correct${NC}"
else
    echo -e "${RED}⚠️  IPv6 setting may need manual verification${NC}"
fi

if grep -q "port: 8080" /etc/pelican/config.yml; then
    echo -e "${GREEN}✅ Port configuration correct (8080)${NC}"
else
    echo -e "${YELLOW}⚠️  Port setting may need verification${NC}"
fi

echo -e "${GREEN}✅ Configuration complete!${NC}"

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Wings Installation Complete!          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}CRITICAL NEXT STEPS:${NC}"
echo ""

echo -e "${GREEN}1. Create Wings Service (if systemd available):${NC}"
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
    echo -e "${GREEN}   ✅ Wings systemd service created${NC}"
else
    echo -e "${YELLOW}   ⚠️  Systemd not available - use manual commands below${NC}"
fi
echo ""

echo -e "${GREEN}2. Configure Cloudflare Tunnel:${NC}"
echo -e "   Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "   Navigate: ${BLUE}Zero Trust → Networks → Tunnels → Configure${NC}"
echo -e "   Add Public Hostname:"
echo -e "   - Subdomain: ${BLUE}node-1${NC} (or your node name)"
echo -e "   - Domain: ${BLUE}your-domain.com${NC}"
echo -e "   - Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${BLUE}localhost:8080${NC}"
echo -e "   - ${YELLOW}Enable 'No TLS Verify' in Additional settings${NC}"
echo ""
echo -e "   ${GREEN}Install Cloudflared on this server:${NC}"
echo -e "   ${BLUE}wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb${NC}"
echo -e "   ${BLUE}sudo dpkg -i cloudflared-linux-amd64.deb${NC}"
echo -e "   ${BLUE}sudo cloudflared service install YOUR_TUNNEL_TOKEN${NC}"
if [ "$HAS_SYSTEMD" = true ]; then
    echo -e "   ${BLUE}sudo systemctl start cloudflared${NC}"
else
    echo -e "   ${BLUE}sudo cloudflared tunnel run YOUR_TUNNEL_TOKEN &${NC}"
fi
echo ""

echo -e "${GREEN}3. Update Panel Node Settings:${NC}"
echo -e "   In Panel: Admin → Nodes → Edit your node"
echo -e "   - FQDN: ${BLUE}${NODE_DOMAIN}${NC}"
echo -e "   - Daemon Port: ${BLUE}443${NC}"
echo -e "   - Behind Proxy: ${BLUE}YES${NC}"
echo -e "   - Scheme: ${BLUE}https${NC}"
echo ""

echo -e "${GREEN}4. Start Wings:${NC}"
if [ "$HAS_SYSTEMD" = true ]; then
    echo -e "   ${BLUE}sudo systemctl enable --now wings${NC}"
    echo ""
    echo -e "${GREEN}5. Monitor Wings:${NC}"
    echo -e "   ${BLUE}sudo systemctl status wings${NC}"
    echo -e "   ${BLUE}sudo journalctl -u wings -f${NC}"
else
    echo -e "   ${BLUE}sudo nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &${NC}"
    echo ""
    echo -e "${GREEN}5. Monitor Wings:${NC}"
    echo -e "   ${BLUE}ps aux | grep wings${NC}"
    echo -e "   ${BLUE}tail -f /var/log/pelican/wings.log${NC}"
    echo -e "   ${BLUE}tail -f /tmp/wings.log${NC}"
fi
echo ""

echo -e "${GREEN}6. Test Connection:${NC}"
echo -e "   ${BLUE}curl -k https://localhost:8080/api/system${NC}"
echo -e "   ${BLUE}curl https://${NODE_DOMAIN}/api/system${NC}"
echo -e "   ${YELLOW}Both should return: \"error\":\"The required authorization heads...\"${NC}"
echo -e "   ${GREEN}(This auth error is expected and means Wings is working!)${NC}"
echo ""

echo -e "${YELLOW}Environment Summary:${NC}"
echo ""
echo -e "${BLUE}Environment Type:${NC}"
[ "$IS_CONTAINER" = true ] && echo -e "  ${YELLOW}Container (requires IPv6: false in config)${NC}" || echo -e "  ${GREEN}VM/Bare Metal${NC}"
echo ""
echo -e "${BLUE}Process Manager:${NC}"
[ "$HAS_SYSTEMD" = true ] && echo -e "  ${GREEN}systemd${NC}" || echo -e "  ${YELLOW}manual (use nohup)${NC}"
echo ""
echo -e "${BLUE}Docker:${NC} $(docker --version 2>/dev/null || echo 'Not found')"
docker ps >/dev/null 2>&1 && echo -e "  ${GREEN}● Running${NC}" || echo -e "  ${RED}● Stopped${NC}"
echo ""
echo -e "${BLUE}SSL Certificates:${NC}"
ls -lh /etc/letsencrypt/live/${NODE_DOMAIN}/ 2>/dev/null || echo "  Not configured"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${GREEN}✅ Container environment detected and configured automatically${NC}"
    echo -e "${GREEN}   - IPv6 disabled${NC}"
    echo -e "${GREEN}   - Docker network optimized${NC}"
    echo -e "${GREEN}   - Configuration backup saved${NC}"
    echo ""
fi

echo -e "${BLUE}Next Steps:${NC}"
echo -e "  1. Install Cloudflare Tunnel (see instructions above)"
echo -e "  2. Update Panel node settings"
echo -e "  3. Start Wings"
echo -e "  4. Check node health in Panel (should show green heart)"
echo ""
