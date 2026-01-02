#!/bin/bash

################################################################################
# Complete Pelican Wings Installation Script
# Uses get.docker.com for reliable Docker installation
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pelican Wings Installation Script    ${NC}"
echo -e "${GREEN}  Complete Automated Setup             ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# ============================================================================
# STEP 1: Remove Old Docker Installations
# ============================================================================
echo -e "${YELLOW}[1/9] Removing old Docker/Moby installations...${NC}"

# Remove conflicting packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc \
           moby-cli moby-engine moby-containerd moby-runc moby-buildx moby-compose moby-tini; do
    apt-get remove -y $pkg 2>/dev/null || true
done

apt-get autoremove -y 2>/dev/null || true

echo -e "${GREEN}✅ Old installations removed${NC}"

# ============================================================================
# STEP 2: Install Docker (Official Method)
# ============================================================================
echo -e "${YELLOW}[2/9] Installing Docker using official script...${NC}"

# Download and run official Docker installation script
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Clean up
rm get-docker.sh

# Verify installation
if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker installation failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Docker installed successfully${NC}"
docker --version

# ============================================================================
# STEP 3: Start and Enable Docker
# ============================================================================
echo -e "${YELLOW}[3/9] Starting Docker service...${NC}"

systemctl enable docker
systemctl start docker

# Test Docker
if docker run --rm hello-world >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Docker is working correctly${NC}"
else
    echo -e "${YELLOW}⚠️  Docker test failed, but continuing...${NC}"
fi

# ============================================================================
# STEP 4: Enable Swap (if needed)
# ============================================================================
echo -e "${YELLOW}[4/9] Configuring swap...${NC}"

if [ ! -f /swapfile ]; then
    echo -e "${BLUE}Creating 2GB swap file...${NC}"
    
    # Try fallocate first, fallback to dd
    if fallocate -l 2G /swapfile 2>/dev/null; then
        echo -e "${GREEN}Swap file created with fallocate${NC}"
    else
        echo -e "${YELLOW}Using dd to create swap file...${NC}"
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Add to fstab if not already present
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    echo -e "${GREEN}✅ Swap enabled${NC}"
else
    echo -e "${GREEN}✅ Swap already configured${NC}"
fi

# Verify swap
free -h | grep -i swap

# ============================================================================
# STEP 5: Configure Kernel Modules
# ============================================================================
echo -e "${YELLOW}[5/9] Configuring kernel modules...${NC}"

# Enable necessary kernel modules
cat > /etc/modules-load.d/pelican-wings.conf <<EOF
overlay
br_netfilter
EOF

# Load modules now
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

# Configure sysctl for networking
cat > /etc/sysctl.d/99-pelican-wings.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 10
EOF

# Apply sysctl settings
sysctl --system >/dev/null 2>&1

echo -e "${GREEN}✅ Kernel modules configured${NC}"

# ============================================================================
# STEP 6: Create Pelican Directories
# ============================================================================
echo -e "${YELLOW}[6/9] Creating Pelican directories...${NC}"

mkdir -p /etc/pelican
mkdir -p /var/lib/pelican/volumes
mkdir -p /var/log/pelican
mkdir -p /var/run/wings

# Set proper permissions
chmod 755 /etc/pelican
chmod 755 /var/lib/pelican
chmod 755 /var/log/pelican

echo -e "${GREEN}✅ Directories created${NC}"

# ============================================================================
# STEP 7: Download and Install Wings Binary
# ============================================================================
echo -e "${YELLOW}[7/9] Downloading Pelican Wings...${NC}"

cd /usr/local/bin

# Download latest Wings release
if curl -L -o wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64"; then
    chmod +x wings
    echo -e "${GREEN}✅ Wings binary installed${NC}"
else
    echo -e "${RED}❌ Failed to download Wings binary${NC}"
    exit 1
fi

# Verify wings executable
if [ -f /usr/local/bin/wings ] && [ -x /usr/local/bin/wings ]; then
    echo -e "${GREEN}Wings version:${NC}"
    wings --version 2>/dev/null || echo -e "${YELLOW}Version check skipped${NC}"
else
    echo -e "${RED}❌ Wings binary is not executable${NC}"
    exit 1
fi

# ============================================================================
# STEP 8: Create Wings Systemd Service
# ============================================================================
echo -e "${YELLOW}[8/9] Creating Wings systemd service...${NC}"

cat > /etc/systemd/system/wings.service <<'WINGSEOF'
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
WINGSEOF

# Reload systemd
systemctl daemon-reload

echo -e "${GREEN}✅ Wings service created${NC}"

# ============================================================================
# STEP 9: Install Certbot (Optional SSL Setup)
# ============================================================================
echo -e "${YELLOW}[9/9] Installing Certbot for SSL certificates...${NC}"

if ! command -v certbot &> /dev/null; then
    apt-get update
    apt-get install -y certbot
    echo -e "${GREEN}✅ Certbot installed${NC}"
else
    echo -e "${GREEN}✅ Certbot already installed${NC}"
fi

# ============================================================================
# Final Summary
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Wings Installation Complete!        ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}CRITICAL NEXT STEPS:${NC}"
echo ""

echo -e "${GREEN}1. Create Wings Configuration File:${NC}"
echo -e "   ${BLUE}nano /etc/pelican/config.yml${NC}"
echo -e "   ${YELLOW}Get this from your Pelican Panel:${NC}"
echo -e "   ${YELLOW}Panel → Nodes → [Your Node] → Configuration${NC}"
echo ""

echo -e "${GREEN}2. Setup SSL Certificates:${NC}"
echo ""
echo -e "   ${YELLOW}Option A - Self-Signed (Testing Only):${NC}"
echo -e "   ${BLUE}NODE_DOMAIN=\"your-node-domain.com\"${NC}"
echo -e "   ${BLUE}mkdir -p /etc/letsencrypt/live/\$NODE_DOMAIN${NC}"
echo -e "   ${BLUE}openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\${NC}"
echo -e "   ${BLUE}  -keyout /etc/letsencrypt/live/\$NODE_DOMAIN/privkey.pem \\${NC}"
echo -e "   ${BLUE}  -out /etc/letsencrypt/live/\$NODE_DOMAIN/fullchain.pem \\${NC}"
echo -e "   ${BLUE}  -subj \"/CN=\$NODE_DOMAIN\"${NC}"
echo ""
echo -e "   ${YELLOW}Option B - Let's Encrypt (Production):${NC}"
echo -e "   ${BLUE}certbot certonly --standalone -d your-node-domain.com${NC}"
echo ""

echo -e "${GREEN}3. Start Wings:${NC}"
echo -e "   ${BLUE}systemctl enable --now wings${NC}"
echo ""

echo -e "${GREEN}4. Monitor Wings:${NC}"
echo -e "   ${BLUE}systemctl status wings${NC}"
echo -e "   ${BLUE}journalctl -u wings -f${NC}"
echo ""

echo -e "${GREEN}5. Verify Docker:${NC}"
echo -e "   ${BLUE}docker ps${NC}"
echo -e "   ${BLUE}docker images${NC}"
echo ""

echo -e "${YELLOW}Current System Status:${NC}"
echo ""

echo -e "${BLUE}Docker:${NC}"
docker --version
systemctl is-active docker >/dev/null 2>&1 && echo -e "  ${GREEN}● Active${NC}" || echo -e "  ${RED}● Inactive${NC}"

echo ""
echo -e "${BLUE}Swap:${NC}"
free -h | grep Swap

echo ""
echo -e "${BLUE}Disk Space:${NC}"
df -h /var/lib/pelican | tail -1

echo ""
echo -e "${BLUE}Directories Created:${NC}"
ls -la /etc/pelican 2>/dev/null || echo "  /etc/pelican"
ls -la /var/lib/pelican 2>/dev/null | head -3 || echo "  /var/lib/pelican"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Don't forget to:${NC}"
echo -e "  1. Configure ${BLUE}/etc/pelican/config.yml${NC}"
echo -e "  2. Setup SSL certificates for your node domain"
echo -e "  3. Start Wings with: ${BLUE}systemctl enable --now wings${NC}"
echo ""
