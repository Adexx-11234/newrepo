# Pelican Panel & Wings Complete Setup Guide

> **Universal Installation Guide** - Works on VPS, Dedicated Servers, GitHub Codespaces, Docker Containers, and Sandbox environments

## 📋 Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Part 1: Panel Installation](#part-1-panel-installation)
5. [Part 2: Wings Installation](#part-2-wings-installation)
6. [Part 3: Cloudflare Tunnel Setup](#part-3-cloudflare-tunnel-setup)
7. [Part 4: Creating Nodes in Panel](#part-4-creating-nodes-in-panel)
8. [Part 5: Connecting Wings to Panel](#part-5-connecting-wings-to-panel)
9. [Troubleshooting](#troubleshooting)
10. [Common Issues & Solutions](#common-issues--solutions)
11. [Uninstallation](#uninstallation)

---

## 🎯 Overview

This guide provides complete instructions for installing Pelican Panel (game server management system) with Wings (node daemon) using **Cloudflare Tunnel** for SSL termination. No need for Let's Encrypt or complex firewall configurations!

**Tested and Working On:**
- ✅ Ubuntu 20.04, 22.04, 24.04
- ✅ Debian 11, 12
- ✅ GitHub Codespaces
- ✅ Docker Containers
- ✅ Cloud VPS (AWS, DigitalOcean, Vultr, etc.)
- ✅ Bare Metal Servers

**Key Features:**
- No Let's Encrypt configuration needed
- Works in container environments (no systemd required)
- Automatic SSL via Cloudflare Tunnel
- Container-safe Docker configuration
- Handles IPv6 issues automatically

---

## 🏗️ Architecture

```
User Browser
    ↓ HTTPS (port 443)
Cloudflare Tunnel
    ↓
    ├─→ panel.example.com → localhost:8443 (Nginx + Panel)
    │                           ↓
    │                    Laravel/PHP Application
    │
    └─→ node-1.example.com → localhost:8080 (Wings)
                                ↓
                         Docker Containers
                         (Game Servers)
```

**Important Points:**
- Panel runs on **port 8443** internally
- Wings runs on **port 8080** internally
- Cloudflare Tunnel provides HTTPS on **port 443** externally
- Users always connect via port 443 (standard HTTPS)

---

## 📦 Prerequisites

### 1. Domain & DNS (Managed by Cloudflare)

You need a domain managed by Cloudflare with these subdomains:
- `panel.example.com` (for Panel)
- `node-1.example.com` (for Wings node)

### 2. Cloudflare Tunnel Token

**Steps to get your tunnel token:**

1. Go to: https://one.dash.cloudflare.com/
2. Navigate: **Zero Trust** → **Networks** → **Tunnels**
3. Click **Create a tunnel**
4. Name it (e.g., "pelican-tunnel")
5. Choose **Cloudflared**
6. Copy the tunnel token (starts with `eyJ...`)
7. **Don't configure routes yet** - we'll do that after installation

### 3. Database

Either:
- **Local:** Install PostgreSQL or MySQL/MariaDB
- **Remote:** Use a managed database service

You'll need:
- Database host
- Database port
- Database name
- Database username
- Database password

### 4. Email (SMTP)

For user notifications and password resets:
- SMTP host (e.g., smtp.gmail.com)
- SMTP port (usually 587)
- SMTP username
- SMTP password

### 5. System Requirements

**Minimum:**
- 2 CPU cores
- 2GB RAM
- 20GB disk space
- Root access

**Recommended:**
- 4 CPU cores
- 4GB RAM
- 50GB+ disk space

---

## 🎨 Part 1: Panel Installation

### Step 1: Download Installation Script

```bash
# Download the panel installation script
wget https://raw.githubusercontent.com/Adexx-11234/newrepo/panel.sh -O panel.sh

# Make it executable
chmod +x panel.sh
```

### Step 2: Run Installation

```bash
sudo ./panel.sh
```

### Step 3: Answer the Prompts

The script will ask for:

```
Panel domain: panel.example.com
Cloudflare Tunnel Token: eyJ... (paste your token)
Database type: 1 (PostgreSQL) or 2 (MySQL)
Database Host: localhost (or remote host)
Database Port: 5432 (PostgreSQL) or 3306 (MySQL)
Database Name: pelican
Database Username: pelican
Database Password: (your secure password)
Redis Host: 127.0.0.1
Redis Port: 6379
Redis Password: (leave empty or set one)
SMTP Host: smtp.gmail.com
SMTP Port: 587
SMTP Username: your@email.com
SMTP Password: (your app password)
From Email: noreply@example.com
From Name: Pelican Panel
```

### Step 4: Complete Panel Setup

After installation completes:

```bash
# Navigate to panel directory
cd /var/www/pelican

# Run database migrations
php artisan migrate --force

# Create admin user
php artisan p:user:make
```

Follow the prompts to create your admin account.

### Step 5: Configure Cloudflare Tunnel for Panel

1. Go to: https://one.dash.cloudflare.com/
2. Navigate: **Zero Trust** → **Networks** → **Tunnels**
3. Click your tunnel → **Configure**
4. Click **Public Hostnames** tab
5. Click **Add a public hostname**

**Panel Route Configuration:**
```
Subdomain: panel
Domain: example.com
Path: (leave empty)

Service:
  Type: HTTPS
  URL: localhost:8443

Additional application settings:
  ✅ No TLS Verify: ON (CRITICAL!)
```

6. Click **Save hostname**
7. Wait 30 seconds for DNS propagation
8. Access your panel: `https://panel.example.com`

---

## 🚀 Part 2: Wings Installation

### Step 1: Download Wings Installation Script

**On your Wings server** (can be same as Panel or different):

```bash
# Download the wings installation script
wget https://raw.githubusercontent.com/Adexx-11234/newrepo/wings.sh -O wings.sh

# Make it executable
chmod +x wings.sh
```

### Step 2: Run Installation

```bash
sudo ./wings.sh
```

### Step 3: Answer the Prompts

The script will ask for:

```
Node domain: node-1.example.com
Panel URL: https://panel.example.com
Panel API Token: papp_xxxxxxxxxxxx
Node ID: 1 (usually 1 for first node)
SSL Certificate Setup: 1 (Self-signed - recommended)
```

**Where to get the Panel Token:**
1. Login to your Panel: `https://panel.example.com`
2. Go to: **Admin** → **Nodes** → Click your node
3. Click **Configuration** tab
4. Look for the auto-config command - copy the token that starts with `papp_`

The script will automatically:
- ✅ Install and configure Docker
- ✅ Download Wings
- ✅ Create SSL certificates
- ✅ Run `wings configure` command
- ✅ **Automatically fix IPv6 for containers** (no manual editing!)
- ✅ Apply all necessary configuration fixes
- ✅ Create systemd service (if available)

### Step 4: Verify Configuration

---

## 🔧 Part 3: Cloudflare Tunnel Setup for Wings

### Step 1: Configure Cloudflare Tunnel Route

1. Go to: https://one.dash.cloudflare.com/
2. Navigate: **Zero Trust** → **Networks** → **Tunnels**
3. Click your tunnel → **Configure**
4. Click **Public Hostnames** tab
5. Click **Add a public hostname**

**Wings Route Configuration:**
```
Subdomain: node-1
Domain: example.com
Path: (leave empty)

Service:
  Type: HTTPS
  URL: localhost:8080

Additional application settings:
  ✅ No TLS Verify: ON (CRITICAL!)
```

6. Click **Save hostname**

### Step 2: Install Cloudflared on Wings Server

```bash
# Download cloudflared
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb

# Install
sudo dpkg -i cloudflared-linux-amd64.deb

# If dpkg fails, fix dependencies
sudo apt --fix-broken install -y
sudo dpkg -i cloudflared-linux-amd64.deb

# Install tunnel service (use YOUR token from Cloudflare dashboard)
sudo cloudflared service install YOUR_TUNNEL_TOKEN_HERE
```

### Step 3: Start Cloudflared

**With systemd:**
```bash
sudo systemctl start cloudflared
sudo systemctl enable cloudflared
sudo systemctl status cloudflared
```

**Without systemd (containers):**
```bash
sudo cloudflared tunnel run YOUR_TUNNEL_TOKEN > /var/log/cloudflared.log 2>&1 &

# Check it's running
ps aux | grep cloudflared
```

### Step 4: Test Tunnel

```bash
# Test connectivity
curl https://node-1.example.com/api/system
```

Should return: `{"error":"The required authorization heads were not present in the request."}`

This is **correct!** The auth error means Wings endpoint is reachable.

---

## 🎮 Part 4: Creating Nodes in Panel

### Step 1: Access Panel Admin

1. Login to: `https://panel.example.com`
2. Navigate to: **Admin** → **Nodes**
3. Click **Create New**

### Step 2: Node Configuration

**CRITICAL - Use These Exact Settings:**

```
Basic Details:
├─ Name: Node 1
├─ Description: Primary game server node
├─ Location: (Select or create a location)
├─ FQDN: node-1.example.com
├─ Scheme: https
├─ Behind Proxy: ✅ YES (CRITICAL!)
├─ Daemon Port: 443
└─ Memory & Disk: Set as needed

Connection:
├─ Communicate Over SSL: ✅ YES
└─ Port: 443 (NOT 8080!)

Advanced:
├─ Memory Over-Allocation: 0
├─ Disk Over-Allocation: 0
└─ Daemon Server File Directory: /var/lib/pelican/volumes
```

**Why These Settings Matter:**

| Setting | Value | Reason |
|---------|-------|--------|
| FQDN | node-1.example.com | Your Cloudflare Tunnel domain |
| Port | 443 | Cloudflare Tunnel listens on 443 |
| Behind Proxy | YES | Cloudflare terminates SSL |
| Scheme | https | External connections use HTTPS |

**Common Mistakes:**
- ❌ Port 8080 (Wings internal port - don't use!)
- ❌ Behind Proxy: NO (causes SSL errors!)
- ❌ Scheme: http (always use https!)

### Step 3: Save Node

Click **Create Node** - the node will show as **offline (red heart)** until Wings is configured.

---

## 🔗 Part 5: Connecting Wings to Panel

### Step 1: Get Auto-Configuration Command

1. In Panel, go to: **Admin** → **Nodes** → Click your node
2. Click the **Configuration** tab
3. You'll see a command like:

```bash
sudo wings configure --panel-url https://panel.example.com --token papp_xxxxxxxxxxxx --node 1
```

4. **Copy this entire command**

### Step 2: Configure Wings

**On your Wings server**, run the command you copied:

```bash
sudo wings configure --panel-url https://panel.example.com --token papp_xxxxxxxxxxxx --node 1
```

Expected output:
```
Successfully configured wings.
```

This creates `/etc/pelican/config.yml` with Panel's configuration.

### Step 3: CRITICAL - Fix IPv6 for Container Environments

**⚠️ If running in Codespaces, Docker container, or any container environment:**

```bash
# Edit the config
sudo nano /etc/pelican/config.yml
```

Find the `docker:` section and make these changes:

**BEFORE (causes crashes):**
```yaml
docker:
  network:
    IPv6: true  # ← This causes iptables errors!
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1011
```

**AFTER (works in containers):**
```yaml
docker:
  network:
    IPv6: false  # ← Changed to false
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
      # v6:  # ← Commented out or removed
      #   subnet: fdba:17c8:6c94::/64
      #   gateway: fdba:17c8:6c94::1011
```

**Save:** Ctrl+X, then Y, then Enter

### Step 4: Verify Wings Configuration

```bash
cat /etc/pelican/config.yml
```

**Key settings should be:**

```yaml
api:
  host: 0.0.0.0
  port: 8080  # Wings listens internally on 8080
  ssl:
    enabled: true
    cert: /etc/letsencrypt/live/node-1.example.com/fullchain.pem
    key: /etc/letsencrypt/live/node-1.example.com/privkey.pem

remote: https://panel.example.com

docker:
  network:
    IPv6: false  # MUST be false for containers
```

### Step 5: Start Wings

**With systemd:**
```bash
# Enable and start Wings
sudo systemctl enable --now wings

# Check status
sudo systemctl status wings

# View logs
sudo journalctl -u wings -f
```

**Without systemd (containers):**
```bash
# Start Wings in background
sudo nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &

# Check it's running
ps aux | grep wings

# View logs
tail -f /var/log/pelican/wings.log
tail -f /tmp/wings.log
```

### Step 6: Test Wings Connection

```bash
# Test local Wings API
curl -k https://localhost:8080/api/system

# Test through Cloudflare Tunnel
curl https://node-1.example.com/api/system
```

**Both should return:**
```json
{"error":"The required authorization heads were not present in the request."}
```

**This is correct!** The auth error means Wings is responding properly.

### Step 7: Verify in Panel

1. Go to Panel: **Admin** → **Nodes**
2. Your node should show a **green heart** ❤️ (healthy)
3. If red, wait 30-60 seconds and refresh
4. If still red after 2 minutes, see [Troubleshooting](#troubleshooting)

---

## 🐛 Troubleshooting

### Node Shows Red Heart (Offline)

**Check 1: Cloudflare Tunnel Running**
```bash
# Check if cloudflared is running
ps aux | grep cloudflared

# For systemd:
sudo systemctl status cloudflared

# For non-systemd, restart:
sudo cloudflared tunnel run YOUR_TOKEN > /var/log/cloudflared.log 2>&1 &
```

**Check 2: Wings Running**
```bash
# Check Wings process
ps aux | grep wings

# Check logs
tail -n 50 /var/log/pelican/wings.log

# If stopped, restart:
# With systemd:
sudo systemctl restart wings

# Without systemd:
sudo pkill wings
sudo nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
```

**Check 3: Test Connections**
```bash
# Test Wings locally
curl -k https://localhost:8080/api/system

# Test through Cloudflare
curl https://node-1.example.com/api/system
```

Both should return auth error (which is good!).

**Check 4: Panel Node Settings**
- FQDN: `node-1.example.com` ✓
- Port: `443` ✓
- Behind Proxy: `YES` ✓
- Scheme: `https` ✓

### Wings Crashes with IPv6 Error

**Error in logs:**
```
FATAL: failed to configure docker environment
iptables failed: ip6tables
modprobe: ERROR: could not insert 'ip6_tables'
```

**Solution:**
```bash
sudo nano /etc/pelican/config.yml

# Change:
IPv6: true  →  IPv6: false

# Remove v6 section

# Restart Wings
sudo systemctl restart wings  # or nohup command
```

### SSL Version Number Error

**Error:**
```
cURL error 35: SSL routines:ssl3_get_record:wrong version number
```

**This means:** Port or proxy configuration is wrong.

**Solution:**

1. **Check Cloudflare Tunnel route:**
   - URL must be `localhost:8080` (for Wings) or `localhost:8443` (for Panel)
   - "No TLS Verify" must be ON

2. **Check Panel node settings:**
   - Port must be `443` (NOT 8080)
   - Behind Proxy must be `YES`

3. **Test directly:**
   ```bash
   # Wings should respond on 8080:
   curl -k https://localhost:8080/api/system
   
   # Panel should respond on 8443:
   curl -k https://localhost:8443
   ```

### Permission Denied on Port 443

**Error:**
```
FATAL: failed to configure HTTPS server
error=listen tcp 0.0.0.0:443: bind: permission denied
```

**Problem:** Wings is trying to listen on port 443.

**Solution:**
```bash
sudo nano /etc/pelican/config.yml

# Change:
api:
  port: 8080  # NOT 443!
```

Wings should NEVER listen on 443 - Cloudflare Tunnel handles that.

### Docker Network Errors

**Error:**
```
Error response from daemon: setting default policy to DROP
```

**Solution:**

Edit Docker configuration:
```bash
sudo nano /etc/docker/daemon.json
```

```json
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
  "bip": "172.26.0.1/16"
}
```

Restart Docker:
```bash
# With systemd:
sudo systemctl restart docker

# Without systemd:
sudo pkill dockerd
sudo dockerd > /var/log/docker.log 2>&1 &
```

Restart Wings after Docker restarts.

---

## ✅ Common Issues & Solutions

### Issue 1: IPv6 Crash in Containers

**Symptoms:**
- Wings immediately crashes
- Log shows `ip6_tables` or `modprobe` errors
- Running in Codespaces/Docker

**Root Cause:** Container can't load kernel modules

**Fix:**
```yaml
# /etc/pelican/config.yml
docker:
  network:
    IPv6: false  # Change from true
    # Remove v6 section entirely
```

### Issue 2: Port Confusion

**Problem:** Many ports involved - which is which?

**Answer:**
```
Panel Internal:   8443  (Nginx)
Wings Internal:   8080  (Wings API)
External (Both):  443   (Cloudflare Tunnel)
Users Connect:    443   (Always HTTPS)
```

**In Panel node settings:**
- Port: `443` (what users/Panel connect to)
- Behind Proxy: `YES`

### Issue 3: systemd Not Available

**Symptoms:**
- `systemctl` commands fail
- Running in container/Codespaces

**Solution:** Use manual commands:

```bash
# Start Wings
sudo nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &

# Start Cloudflared
sudo cloudflared tunnel run TOKEN > /var/log/cloudflared.log 2>&1 &

# Check running
ps aux | grep wings
ps aux | grep cloudflared

# View logs
tail -f /tmp/wings.log
tail -f /var/log/cloudflared.log
```

### Issue 4: Can't Access Panel After Install

**Check 1:** Is Nginx running on 8443?
```bash
sudo netstat -tlnp | grep 8443
# Should show nginx
```

**Check 2:** Is Cloudflare Tunnel configured?
```bash
# Test direct access (should fail - no DNS)
curl -k https://localhost:8443

# Test through Cloudflare (should work)
curl https://panel.example.com
```

**Check 3:** Cloudflare Tunnel route settings:
- Service URL: `localhost:8443` (NOT 443!)
- No TLS Verify: ON

---

## 🗑️ Uninstallation

### Complete Removal

To completely remove Pelican and start fresh:

```bash
# Download uninstall script
wget https://raw.githubusercontent.com/YOUR_REPO/uninstall.sh -O uninstall.sh
chmod +x uninstall.sh

# Run uninstall
sudo ./uninstall.sh
```

The script will:
- Stop all services
- Remove Wings and Panel
- Remove Docker containers and volumes
- Remove Cloudflare Tunnel
- Ask before removing database
- Ask before removing Docker, PHP, Redis

**Warning:** This cannot be undone!

### Manual Uninstall Commands

If you prefer manual removal:

```bash
# Stop services
sudo systemctl stop wings pelican-queue cloudflared nginx
sudo pkill wings cloudflared

# Remove Wings
sudo rm -rf /etc/pelican /var/lib/pelican /var/log/pelican
sudo rm /usr/local/bin/wings

# Remove Panel
sudo rm -rf /var/www/pelican

# Remove Docker containers
docker stop $(docker ps -aq)
docker rm $(docker ps -aq)
docker volume rm $(docker volume ls -q)

# Remove Cloudflared
sudo cloudflared service uninstall
sudo apt remove -y cloudflared

# Remove configs
sudo rm /etc/nginx/sites-enabled/pelican.conf
sudo rm /etc/systemd/system/wings.service
sudo rm /etc/systemd/system/pelican-queue.service
sudo systemctl daemon-reload
```

---

## 📝 Quick Reference

### Important Ports

| Service | Internal Port | External Port | Protocol |
|---------|---------------|---------------|----------|
| Panel | 8443 | 443 | HTTPS |
| Wings | 8080 | 443 | HTTPS |
| SFTP | 2022 | 2022 | SSH |

### Key Configuration Files

```
Panel:
  /var/www/pelican/.env
  /etc/nginx/sites-available/pelican.conf
  /etc/php/8.4/fpm/pool.d/www.conf

Wings:
  /etc/pelican/config.yml
  /etc/docker/daemon.json

Services:
  /etc/systemd/system/wings.service
  /etc/systemd/system/pelican-queue.service
```

### Useful Commands

```bash
# Panel
cd /var/www/pelican
php artisan migrate
php artisan p:user:make
php artisan cache:clear
tail -f storage/logs/laravel.log

# Wings
sudo systemctl status wings
sudo journalctl -u wings -f
curl -k https://localhost:8080/api/system
tail -f /var/log/pelican/wings.log

# Cloudflared
sudo systemctl status cloudflared
ps aux | grep cloudflared
tail -f /var/log/cloudflared.log

# Docker
docker ps
docker logs CONTAINER_ID
docker network ls
```

### Testing Checklist

- [ ] Panel accessible at `https://panel.example.com`
- [ ] Can login with admin account
- [ ] Node shows green heart in Admin panel
- [ ] Wings responds: `curl -k https://localhost:8080/api/system`
- [ ] Cloudflare route works: `curl https://node-1.example.com/api/system`
- [ ] Can create a test server
- [ ] Docker containers start: `docker ps`
- [ ] No errors in logs

---

## 🎓 Understanding the Setup

### Why Port 8443 for Panel?

- Port 443 is often restricted in containers
- Port 80/443 may be used by other services
- 8443 avoids conflicts
- Cloudflare Tunnel handles external 443 → internal 8443 mapping

### Why Port 8080 for Wings?

- Standard port for Wings daemon
- Above 1024 (no root required)
- Commonly used in containerized apps
- Cloudflare Tunnel maps 443 → 8080

### Why Behind Proxy: YES?

When enabled:
- Panel trusts Cloudflare's SSL termination
- Panel uses Cloudflare's forwarded IP headers
- Prevents SSL verification errors
- Required for Cloudflare Tunnel setup

### Why IPv6: false in Containers?

Containers can't:
- Load kernel modules (ip6_tables)
- Modify iptables rules
- Configure IPv6 networking

Solution: Disable IPv6 in Wings config

---

## 🚨 Production Checklist

Before going live:

- [ ] Use strong database passwords
- [ ] Enable database backups
- [ ] Configure email (SMTP) properly
- [ ] Test server creation and deletion
- [ ] Set up monitoring (uptime checks)
- [ ] Document your admin credentials safely
- [ ] Enable 2FA for admin accounts
- [ ] Review Panel logs regularly
- [ ] Test disaster recovery (backups)
- [ ] Configure automatic updates

---

## 📚 Additional Resources

- **Pelican Panel Docs:** https://pelican.dev/docs
- **Cloudflare Tunnel Docs:** https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/
- **Wings GitHub:** https://github.com/pelican-dev/wings
- **Panel GitHub:** https://github.com/pelican-dev/panel
- **Community Discord:** Check Pelican Panel website

---

## 🎉 Success!

If everything is working:
- ✅ Panel accessible and admin user created
- ✅ Node shows green heart
- ✅ Wings responding to API calls
- ✅ Can create test servers

**You're ready to:**
1. Create game servers
2. Configure eggs (server templates)
3. Manage allocations
4. Set up backups
5. Add more nodes

Congratulations! 🎮

---

**Last Updated:** January 2026  
**Tested On:** Debian 11/12, Ubuntu 20.04/22.04/24.04, GitHub Codespaces  
**Pelican Version:** 1.0.0-beta21  
**Compatibility:** VPS, Bare Metal, Containers, Codespaces

---

## 📧 Need Help?

If you encounter issues not covered in this guide:

1. Check logs first (see Quick Reference section)
2. Review the Troubleshooting section
3. Verify all configuration settings
4. Test each component individually
5. Join Pelican community Discord

Remember: Most issues are configuration problems, not bugs!
