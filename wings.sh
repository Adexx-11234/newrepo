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
# STEP 10: Create Wings Service
# ============================================================================
echo -e "${YELLOW}[10/10] Setting up Wings service...${NC}"

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
    echo -e "${GREEN}✅ Wings systemd service created${NC}"
else
    echo -e "${YELLOW}⚠️  No systemd - you'll use manual start commands${NC}"
fi

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

echo -e "${GREEN}1. Get Configuration from Panel:${NC}"
echo -e "   - Login to your Pelican Panel"
echo -e "   - Go to: ${BLUE}Admin → Nodes → [Your Node]${NC}"
echo -e "   - Click ${BLUE}Configuration${NC} tab"
echo -e "   - Copy the auto-configuration command"
echo ""

echo -e "${GREEN}2. Configure Wings:${NC}"
echo -e "   ${BLUE}sudo wings configure --panel-url https://YOUR_PANEL_URL --token YOUR_TOKEN --node 1${NC}"
echo ""

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${RED}⚠️  CRITICAL FOR CONTAINERS (Codespaces/Docker/Sandbox):${NC}"
    echo -e "${YELLOW}After running the configure command above, you MUST edit the config:${NC}"
    echo -e "   ${BLUE}sudo nano /etc/pelican/config.yml${NC}"
    echo ""
    echo -e "${YELLOW}Find and change these settings:${NC}"
    echo -e "   ${RED}IPv6: true${NC}  ${GREEN}→${NC}  ${GREEN}IPv6: false${NC}"
    echo ""
    echo -e "${YELLOW}Remove or comment out the entire v6 section:${NC}"
    echo -e "   ${RED}v6:${NC}"
    echo -e "   ${RED}  subnet: fdba:17c8:6c94::/64${NC}"
    echo -e "   ${RED}  gateway: fdba:17c8:6c94::1011${NC}"
    echo ""
    echo -e "${YELLOW}Change to:${NC}"
    echo -e "   ${GREEN}# v6:${NC}"
    echo -e "   ${GREEN}#   subnet: fdba:17c8:6c94::/64${NC}"
    echo -e "   ${GREEN}#   gateway: fdba:17c8:6c94::1011${NC}"
    echo ""
fi

echo -e "${GREEN}3. Configure Cloudflare Tunnel:${NC}"
echo -e "   Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "   Navigate: ${BLUE}Zero Trust → Networks → Tunnels → Configure${NC}"
echo -e "   Add Public Hostname:"
echo -e "   - Subdomain: ${BLUE}node-1${NC} (or your node name)"
echo -e "   - Domain: ${BLUE}your-domain.com${NC}"
echo -e "   - Type: ${BLUE}HTTPS${NC}"
echo -e "   - URL: ${BLUE}localhost:8080${NC}"
echo -e "   - ${YELLOW}Enable 'No TLS Verify' in Additional settings${NC}"
echo ""
echo -e "   ${GREEN}Install Cloudflared on this
