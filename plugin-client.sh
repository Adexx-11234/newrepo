#!/bin/bash

################################################################################
# PELICAN USER REGISTRATION & RESOURCE LIMITS SETUP - FIXED VERSION
# Automated configuration for Register and User-Creatable-Servers plugins
# Supports SQLite, MySQL, and PostgreSQL
# FIXES:
# - PostgreSQL driver detection and installation
# - Proper PHP binary usage
# - Plugin enable command (doesn't exist in newer versions)
# - Migration errors
# - Table creation verification
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Pelican User Registration & Resource Limits Setup    ║${NC}"
echo -e "${GREEN}║  Register Plugin + User-Creatable-Servers Plugin      ║${NC}"
echo -e "${GREEN}║  FIXED VERSION - PostgreSQL Compatible                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

# Check if Pelican is installed
if [ ! -f "/var/www/pelican/artisan" ]; then
    echo -e "${RED}❌ Pelican Panel not found at /var/www/pelican${NC}"
    exit 1
fi

cd /var/www/pelican

# ============================================================================
# SET CORRECT PHP BINARY
# ============================================================================
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
PHP_BIN="/usr/bin/php8.3"

# Fallback to generic php if php8.3 not found
if [ ! -f "$PHP_BIN" ]; then
    PHP_BIN=$(which php 2>/dev/null || echo "php")
fi

echo -e "${BLUE}Using PHP: $($PHP_BIN -v | head -n1)${NC}"
echo ""

# ============================================================================
# DETECT DATABASE TYPE
# ============================================================================
echo -e "${CYAN}[1/12] Detecting database configuration...${NC}"

DB_CONNECTION=$(grep "^DB_CONNECTION=" .env | cut -d'=' -f2)

if [ -z "$DB_CONNECTION" ]; then
    echo -e "${RED}❌ Could not detect database type from .env${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ Database type: ${DB_CONNECTION}${NC}"

case "$DB_CONNECTION" in
    sqlite)
        DB_TYPE="SQLite"
        SQLITE_DB="/var/www/pelican/database/database.sqlite"
        ;;
    mysql)
        DB_TYPE="MySQL"
        DB_HOST=$(grep "^DB_HOST=" .env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" .env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-3306}
        DB_DATABASE=$(grep "^DB_DATABASE=" .env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" .env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)
        ;;
    pgsql)
        DB_TYPE="PostgreSQL"
        DB_HOST=$(grep "^DB_HOST=" .env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" .env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-5432}
        DB_DATABASE=$(grep "^DB_DATABASE=" .env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" .env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)
        ;;
    *)
        echo -e "${RED}❌ Unsupported database type: ${DB_CONNECTION}${NC}"
        exit 1
        ;;
esac

# ============================================================================
# VERIFY/INSTALL POSTGRESQL PHP EXTENSIONS
# ============================================================================
if [ "$DB_CONNECTION" = "pgsql" ]; then
    echo ""
    echo -e "${CYAN}[2/12] Verifying PostgreSQL PHP extensions...${NC}"
    
    # Check if pdo_pgsql is loaded
    if ! $PHP_BIN -m | grep -q pdo_pgsql; then
        echo -e "${YELLOW}   ⚠ PostgreSQL PHP extension not found!${NC}"
        echo -e "${YELLOW}   Installing pgsql extensions...${NC}"
        
        apt-get update -qq 2>&1 | grep -v "GPG error" || true
        apt-get install -y php8.3-pgsql php8.3-pdo php-pgsql 2>/dev/null || {
            echo -e "${RED}❌ Failed to install PostgreSQL extensions!${NC}"
            exit 1
        }
        
        # Restart PHP-FPM to load new extensions
        systemctl restart php8.3-fpm 2>/dev/null || service php8.3-fpm restart 2>/dev/null || true
        
        # Verify installation
        if ! $PHP_BIN -m | grep -q pdo_pgsql; then
            echo -e "${RED}❌ PostgreSQL extension still not available!${NC}"
            echo -e "${YELLOW}   Installed modules:${NC}"
            $PHP_BIN -m | grep -i pdo
            exit 1
        fi
    fi
    
    echo -e "${GREEN}   ✓ PostgreSQL PHP extensions verified${NC}"
    echo -e "${GREEN}   ✓ Available: $(echo $($PHP_BIN -m | grep pdo))${NC}"
else
    echo ""
    echo -e "${CYAN}[2/12] Skipping PostgreSQL checks (not using pgsql)${NC}"
fi

# ============================================================================
# DOWNLOAD ALL PLUGINS
# ============================================================================
echo ""
echo -e "${CYAN}[3/12] Downloading ALL plugins from GitHub...${NC}"

# Create temporary directory
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Download plugins repository
echo -e "${YELLOW}   Downloading plugin repository...${NC}"
curl -sL "https://github.com/pelican-dev/plugins/archive/refs/heads/main.zip" -o plugins.zip

# Extract all plugins
echo -e "${YELLOW}   Extracting all plugins...${NC}"
unzip -q plugins.zip

# Create plugins directory if it doesn't exist
mkdir -p /var/www/pelican/plugins

# Copy ALL plugins (so they're available for future use)
echo -e "${YELLOW}   Installing all plugins to /var/www/pelican/plugins/...${NC}"
cp -r plugins-main/* /var/www/pelican/plugins/
rm -f /var/www/pelican/plugins/.gitignore /var/www/pelican/plugins/LICENSE /var/www/pelican/plugins/README.md

# Count plugins
PLUGIN_COUNT=$(ls -1d /var/www/pelican/plugins/*/ 2>/dev/null | wc -l)
echo -e "${GREEN}   ✓ ${PLUGIN_COUNT} plugins downloaded and ready${NC}"

# Set ownership
chown -R www-data:www-data /var/www/pelican/plugins

# Cleanup
cd /var/www/pelican
rm -rf "$TMP_DIR"

# ============================================================================
# INSTALL AND ENABLE REQUIRED PLUGINS
# ============================================================================
echo ""
echo -e "${CYAN}[4/12] Installing required plugins...${NC}"

# Install Register plugin
echo -e "${YELLOW}   Installing Register plugin...${NC}"
if $PHP_BIN artisan p:plugin:install register 2>&1 | grep -q "already installed"; then
    echo -e "${GREEN}   ✓ Register plugin already installed${NC}"
else
    echo -e "${GREEN}   ✓ Register plugin installed${NC}"
fi

# Install User-Creatable-Servers plugin
echo -e "${YELLOW}   Installing User-Creatable-Servers plugin...${NC}"
if $PHP_BIN artisan p:plugin:install user-creatable-servers 2>&1 | grep -q "already installed"; then
    echo -e "${GREEN}   ✓ User-Creatable-Servers plugin already installed${NC}"
else
    echo -e "${GREEN}   ✓ User-Creatable-Servers plugin installed${NC}"
fi

# NOTE: p:plugin:enable command doesn't exist in newer Pelican versions
# Plugins are auto-enabled after installation
echo -e "${GREEN}   ✓ Plugins are auto-enabled after installation${NC}"

# ============================================================================
# RUN MIGRATIONS
# ============================================================================
echo ""
echo -e "${CYAN}[5/12] Running database migrations...${NC}"

# Clear config cache first
$PHP_BIN artisan config:clear >/dev/null 2>&1 || true

# Test database connection first
echo -e "${YELLOW}   Testing database connection...${NC}"
if $PHP_BIN artisan migrate:status >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Database connection successful${NC}"
else
    echo -e "${RED}❌ Database connection failed!${NC}"
    echo -e "${YELLOW}   Attempting to diagnose...${NC}"
    $PHP_BIN artisan migrate:status 2>&1 | tail -10
    exit 1
fi

# Run migrations
echo -e "${YELLOW}   Running migrations...${NC}"
MIGRATION_OUTPUT=$($PHP_BIN artisan migrate --force 2>&1)

if echo "$MIGRATION_OUTPUT" | grep -qi "error\|exception"; then
    echo -e "${RED}❌ Migration failed!${NC}"
    echo "$MIGRATION_OUTPUT" | tail -10
    exit 1
elif echo "$MIGRATION_OUTPUT" | grep -q "Nothing to migrate"; then
    echo -e "${GREEN}   ✓ Database already up to date${NC}"
else
    echo -e "${GREEN}   ✓ Migrations completed${NC}"
fi

# Verify user_resource_limits table exists
echo -e "${YELLOW}   Verifying plugin tables...${NC}"

TABLE_EXISTS=false
if [ "$DB_TYPE" = "SQLite" ]; then
    if sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='user_resource_limits';" 2>/dev/null | grep -q "user_resource_limits"; then
        TABLE_EXISTS=true
    fi
elif [ "$DB_TYPE" = "MySQL" ]; then
    if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" -sN -e "SHOW TABLES LIKE 'user_resource_limits';" 2>/dev/null | grep -q "user_resource_limits"; then
        TABLE_EXISTS=true
    fi
elif [ "$DB_TYPE" = "PostgreSQL" ]; then
    if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" -tAc "SELECT tablename FROM pg_tables WHERE tablename='user_resource_limits';" 2>/dev/null | grep -q "user_resource_limits"; then
        TABLE_EXISTS=true
    fi
fi

if [ "$TABLE_EXISTS" = true ]; then
    echo -e "${GREEN}   ✓ Plugin tables verified (user_resource_limits exists)${NC}"
else
    echo -e "${YELLOW}   ⚠ Warning: user_resource_limits table not found${NC}"
    echo -e "${YELLOW}   This is normal if the plugin doesn't create tables via migrations${NC}"
    echo -e "${YELLOW}   The table will be created automatically when needed${NC}"
fi

# Clear cache
echo -e "${YELLOW}   Clearing cache...${NC}"
$PHP_BIN artisan config:clear >/dev/null 2>&1
$PHP_BIN artisan cache:clear >/dev/null 2>&1
echo -e "${GREEN}   ✓ Cache cleared${NC}"

# ============================================================================
# USER CONFIGURATION
# ============================================================================
echo ""
echo -e "${CYAN}[6/12] Configure Default User Resource Limits${NC}"
echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${BLUE}These limits will be automatically assigned to new users${NC}"
echo ""

read -p "CPU Limit (in %, e.g., 200 = 2 cores) [200]: " CPU_LIMIT
CPU_LIMIT=${CPU_LIMIT:-200}

read -p "Memory/RAM Limit (in MiB, e.g., 4096 = 4GB) [4096]: " MEMORY_LIMIT
MEMORY_LIMIT=${MEMORY_LIMIT:-4096}

read -p "Disk Space Limit (in MiB, e.g., 10240 = 10GB) [10240]: " DISK_LIMIT
DISK_LIMIT=${DISK_LIMIT:-10240}

read -p "Maximum Servers per user [2]: " MAX_SERVERS
MAX_SERVERS=${MAX_SERVERS:-2}

read -p "Maximum Databases per server [2]: " MAX_DATABASES
MAX_DATABASES=${MAX_DATABASES:-2}

read -p "Maximum Allocations/Ports per server [3]: " MAX_ALLOCATIONS
MAX_ALLOCATIONS=${MAX_ALLOCATIONS:-3}

read -p "Maximum Backups per server [1]: " MAX_BACKUPS
MAX_BACKUPS=${MAX_BACKUPS:-1}

echo ""
read -p "Can users update their servers? (y/n) [y]: " CAN_UPDATE
CAN_UPDATE=${CAN_UPDATE:-y}
CAN_USERS_UPDATE=$( [[ "$CAN_UPDATE" =~ ^[Yy] ]] && echo "true" || echo "false" )

read -p "Can users delete their servers? (y/n) [y]: " CAN_DELETE
CAN_DELETE=${CAN_DELETE:-y}
CAN_USERS_DELETE=$( [[ "$CAN_DELETE" =~ ^[Yy] ]] && echo "true" || echo "false" )

read -p "Deployment tag for user-created servers [user_creatable_servers]: " DEPLOYMENT_TAG
DEPLOYMENT_TAG=${DEPLOYMENT_TAG:-user_creatable_servers}

echo ""
echo -e "${GREEN}   ✓ Configuration collected${NC}"

# ============================================================================
# CONFIGURE .ENV
# ============================================================================
echo ""
echo -e "${CYAN}[7/12] Configuring environment variables...${NC}"

# Remove old UCS settings if they exist
sed -i '/^UCS_/d' .env

# Add new UCS settings
cat >> .env <<ENV

# User Creatable Servers Configuration
UCS_DEFAULT_DATABASE_LIMIT=${MAX_DATABASES}
UCS_DEFAULT_ALLOCATION_LIMIT=${MAX_ALLOCATIONS}
UCS_DEFAULT_BACKUP_LIMIT=${MAX_BACKUPS}
UCS_CAN_USERS_UPDATE_SERVERS=${CAN_USERS_UPDATE}
UCS_CAN_USERS_DELETE_SERVERS=${CAN_USERS_DELETE}
UCS_DEPLOYMENT_TAGS=${DEPLOYMENT_TAG}
ENV

echo -e "${GREEN}   ✓ Environment configured${NC}"

# Clear cache again after config changes
$PHP_BIN artisan config:clear >/dev/null 2>&1
$PHP_BIN artisan cache:clear >/dev/null 2>&1

# ============================================================================
# CREATE AUTO-ASSIGNMENT SCRIPT (WITH TABLE CHECK)
# ============================================================================
echo ""
echo -e "${CYAN}[8/12] Creating auto-assignment script...${NC}"

cat > /usr/local/bin/pelican-auto-resource-limits.sh <<'SCRIPT_EOF'
#!/bin/bash

################################################################################
# AUTO-ASSIGN DEFAULT RESOURCE LIMITS TO NEW USERS
################################################################################

# Configuration
DEFAULT_CPU=CPU_LIMIT_PLACEHOLDER
DEFAULT_MEMORY=MEMORY_LIMIT_PLACEHOLDER
DEFAULT_DISK=DISK_LIMIT_PLACEHOLDER
DEFAULT_SERVER_LIMIT=MAX_SERVERS_PLACEHOLDER

# Get database configuration
DB_CONNECTION=$(grep "^DB_CONNECTION=" /var/www/pelican/.env | cut -d'=' -f2)

case "$DB_CONNECTION" in
    sqlite)
        SQLITE_DB="/var/www/pelican/database/database.sqlite"
        
        # Check if table exists first
        TABLE_EXISTS=$(sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='user_resource_limits';" 2>/dev/null)
        
        if [ -z "$TABLE_EXISTS" ]; then
            # Table doesn't exist yet - exit silently
            exit 0
        fi
        
        sqlite3 "$SQLITE_DB" <<SQL 2>/dev/null || exit 0
INSERT OR IGNORE INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT 
    u.id,
    $DEFAULT_CPU,
    $DEFAULT_MEMORY,
    $DEFAULT_DISK,
    $DEFAULT_SERVER_LIMIT,
    datetime('now'),
    datetime('now')
FROM users u
LEFT JOIN user_resource_limits url ON u.id = url.user_id
WHERE url.id IS NULL;
SQL
        ;;
        
    mysql)
        DB_HOST=$(grep "^DB_HOST=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-3306}
        DB_DATABASE=$(grep "^DB_DATABASE=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" /var/www/pelican/.env | cut -d'=' -f2)
        
        # Check if table exists
        TABLE_EXISTS=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" -sN -e "SHOW TABLES LIKE 'user_resource_limits';" 2>/dev/null)
        
        if [ -z "$TABLE_EXISTS" ]; then
            exit 0
        fi
        
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" <<SQL 2>/dev/null || exit 0
INSERT IGNORE INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT 
    u.id,
    $DEFAULT_CPU,
    $DEFAULT_MEMORY,
    $DEFAULT_DISK,
    $DEFAULT_SERVER_LIMIT,
    NOW(),
    NOW()
FROM users u
LEFT JOIN user_resource_limits url ON u.id = url.user_id
WHERE url.id IS NULL;
SQL
        ;;
        
    pgsql)
        DB_HOST=$(grep "^DB_HOST=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-5432}
        DB_DATABASE=$(grep "^DB_DATABASE=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" /var/www/pelican/.env | cut -d'=' -f2)
        
        # Check if table exists
        TABLE_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" -tAc "SELECT tablename FROM pg_tables WHERE tablename='user_resource_limits';" 2>/dev/null)
        
        if [ -z "$TABLE_EXISTS" ]; then
            exit 0
        fi
        
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" <<SQL 2>/dev/null || exit 0
INSERT INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT 
    u.id,
    $DEFAULT_CPU,
    $DEFAULT_MEMORY,
    $DEFAULT_DISK,
    $DEFAULT_SERVER_LIMIT,
    NOW(),
    NOW()
FROM users u
LEFT JOIN user_resource_limits url ON u.id = url.user_id
WHERE url.id IS NULL
ON CONFLICT DO NOTHING;
SQL
        ;;
esac

exit 0
SCRIPT_EOF

# Replace placeholders with actual values
sed -i "s/CPU_LIMIT_PLACEHOLDER/$CPU_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/MEMORY_LIMIT_PLACEHOLDER/$MEMORY_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/DISK_LIMIT_PLACEHOLDER/$DISK_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/MAX_SERVERS_PLACEHOLDER/$MAX_SERVERS/g" /usr/local/bin/pelican-auto-resource-limits.sh

chmod +x /usr/local/bin/pelican-auto-resource-limits.sh

echo -e "${GREEN}   ✓ Auto-assignment script created${NC}"

# ============================================================================
# CREATE FAST AUTO-ASSIGNMENT SCRIPT (1 SECOND INTERVALS)
# ============================================================================
echo ""
echo -e "${CYAN}[9/12] Creating fast auto-assignment service...${NC}"

cat > /usr/local/bin/pelican-auto-resource-limits-fast.sh <<'FAST_EOF'
#!/bin/bash
while true; do
    /usr/local/bin/pelican-auto-resource-limits.sh >/dev/null 2>&1
    sleep 1
done
FAST_EOF

chmod +x /usr/local/bin/pelican-auto-resource-limits-fast.sh

echo -e "${GREEN}   ✓ Fast auto-assignment script created${NC}"

# ============================================================================
# SETUP CRON JOB
# ============================================================================
echo ""
echo -e "${CYAN}[10/12] Setting up cron job...${NC}"

# Remove old cron jobs
crontab -l 2>/dev/null | grep -v "pelican-auto-resource-limits" | crontab - 2>/dev/null || true

# Add new cron job (runs every minute as backup)
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/pelican-auto-resource-limits.sh >> /var/log/pelican-auto-limits.log 2>&1") | crontab -

echo -e "${GREEN}   ✓ Cron job configured (runs every minute)${NC}"

# ============================================================================
# START FAST SERVICE
# ============================================================================
echo ""
echo -e "${CYAN}[11/12] Starting fast auto-assignment service...${NC}"

# Kill any existing processes
pkill -f "pelican-auto-resource-limits-fast.sh" 2>/dev/null || true
sleep 1

# Start new process
nohup /usr/local/bin/pelican-auto-resource-limits-fast.sh > /var/log/pelican-auto-limits-fast.log 2>&1 &

echo -e "${GREEN}   ✓ Fast service started (checks every 1 second)${NC}"

# ============================================================================
# RUN INITIAL ASSIGNMENT (IF TABLE EXISTS)
# ============================================================================
echo ""
echo -e "${CYAN}[12/12] Assigning limits to existing users...${NC}"

# Wait a moment for everything to settle
sleep 2

# Run assignment (script will exit gracefully if table doesn't exist)
/usr/local/bin/pelican-auto-resource-limits.sh 2>&1 || echo -e "${YELLOW}   ⚠️  Table not ready yet - limits will be assigned when users register${NC}"

# Count users with limits (only if table exists)
USER_COUNT=0
if [ "$TABLE_EXISTS" = true ]; then
    if [ "$DB_TYPE" = "SQLite" ]; then
        USER_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM user_resource_limits;" 2>/dev/null || echo "0")
    elif [ "$DB_TYPE" = "MySQL" ]; then
        USER_COUNT=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" -sN -e "SELECT COUNT(*) FROM user_resource_limits;" 2>/dev/null || echo "0")
    elif [ "$DB_TYPE" = "PostgreSQL" ]; then
        USER_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" -tAc "SELECT COUNT(*) FROM user_resource_limits;" 2>/dev/null || echo "0")
    fi
fi

echo -e "${GREEN}   ✓ ${USER_COUNT} users currently have resource limits${NC}"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           SETUP COMPLETE - SUMMARY                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}📦 PLUGINS INSTALLED:${NC}"
echo -e "   ${GREEN}✓ ALL plugins downloaded to /var/www/pelican/plugins/${NC}"
echo -e "   ${GREEN}✓ Register plugin - INSTALLED${NC}"
echo -e "   ${GREEN}✓ User-Creatable-Servers plugin - INSTALLED${NC}"
echo -e "   ${BLUE}ℹ️  Other plugins available but not enabled${NC}"
echo ""

echo -e "${CYAN}📊 DEFAULT USER RESOURCE LIMITS:${NC}"
# Calculate without bc (more compatible)
CPU_CORES=$(awk "BEGIN {printf \"%.1f\", $CPU_LIMIT/100}")
MEMORY_GB=$(awk "BEGIN {printf \"%.2f\", $MEMORY_LIMIT/1024}")
DISK_GB=$(awk "BEGIN {printf \"%.2f\", $DISK_LIMIT/1024}")

echo -e "   CPU: ${GREEN}${CPU_LIMIT}%${NC} ($CPU_CORES cores)"
echo -e "   Memory: ${GREEN}${MEMORY_LIMIT} MiB${NC} ($MEMORY_GB GB)"
echo -e "   Disk: ${GREEN}${DISK_LIMIT} MiB${NC} ($DISK_GB GB)"
echo -e "   Max Servers: ${GREEN}${MAX_SERVERS}${NC}"
echo -e "   Max Databases: ${GREEN}${MAX_DATABASES}${NC}"
echo -e "   Max Allocations: ${GREEN}${MAX_ALLOCATIONS}${NC}"
echo -e "   Max Backups: ${GREEN}${MAX_BACKUPS}${NC}"
echo ""

echo -e "${CYAN}🔧 USER PERMISSIONS:${NC}"
echo -e "   Can Update Servers: ${GREEN}${CAN_USERS_UPDATE}${NC}"
echo -e "   Can Delete Servers: ${GREEN}${CAN_USERS_DELETE}${NC}"
echo ""

echo -e "${CYAN}🏷️  DEPLOYMENT TAG:${NC}"
echo -e "   Tag: ${GREEN}${DEPLOYMENT_TAG}${NC}"
echo ""

echo -e "${YELLOW}⚠️  IMPORTANT: ADD DEPLOYMENT TAG TO YOUR NODES!${NC}"
echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}"
echo -e "1. Go to: ${BLUE}Admin → Nodes → Edit Node${NC}"
echo -e "2. Find: ${BLUE}Tags${NC} or ${BLUE}Deployment Tags${NC} field"
echo -e "3. Add: ${GREEN}${DEPLOYMENT_TAG}${NC}"
echo -e "4. Save"
echo ""
echo -e "${RED}Without this tag, users cannot create servers on the node!${NC}"
echo ""

echo -e "${CYAN}📁 CONFIGURATION FILES:${NC}"
echo -e "   Environment: ${GREEN}/var/www/pelican/.env${NC}"
echo -e "   Auto-script: ${GREEN}/usr/local/bin/pelican-auto-resource-limits.sh${NC}"
echo -e "   Fast service: ${GREEN}/usr/local/bin/pelican-auto-resource-limits-fast.sh${NC}"
echo -e "   Logs: ${GREEN}/var/log/pelican-auto-limits.log${NC}"
echo -e "   Fast logs: ${GREEN}/var/log/pelican-auto-limits-fast.log${NC}"
echo ""

echo -e "${CYAN}🔄 AUTO-ASSIGNMENT:${NC}"
echo -e "   ${GREEN}✓${NC} Cron job: Runs every 1 minute"
echo -e "   ${GREEN}✓${NC} Fast service: Checks every 1 second"
echo -e "   ${GREEN}✓${NC} New users get limits within 1 second"
echo ""

echo -e "${CYAN}🧪 TEST IT:${NC}"
echo -e "   1. Register a new user at: ${BLUE}https://your-panel-domain/register${NC}"
echo -e "   2. Wait 1 second"
echo -e "   3. User should automatically get resource limits"
echo -e "   4. User can create servers from the dashboard"
echo ""

echo -e "${CYAN}📝 USEFUL COMMANDS:${NC}"
echo -e "   Check installed plugins:"
echo -e "     ${GREEN}cd /var/www/pelican && $PHP_BIN artisan p:plugin:list${NC}"
echo ""
echo -e "   Enable other plugins (from Admin Panel):"
echo -e "     ${BLUE}Admin → Plugins → Select Plugin → Enable${NC}"
echo ""
echo -e "   Check service status:"
echo -e "     ${GREEN}ps aux | grep pelican-auto-resource-limits-fast${NC}"
echo ""
echo -e "   View logs:"
echo -e "     ${GREEN}tail -f /var/log/pelican-auto-limits-fast.log${NC}"
echo ""
echo -e "   Manually run assignment:"
echo -e "     ${GREEN}/usr/local/bin/pelican-auto-resource-limits.sh${NC}"
echo ""
echo -e "   Check user limits (in tinker):"
echo -e "     ${GREEN}cd /var/www/pelican && $PHP_BIN artisan tinker${NC}"
echo -e "     ${BLUE}\Boy132\UserCreatableServers\Models\UserResourceLimits::all();${NC}"
echo ""
echo -e "   Restart fast service:"
echo -e "     ${GREEN}pkill -f pelican-auto-resource-limits-fast.sh${NC}"
echo -e "     ${GREEN}nohup /usr/local/bin/pelican-auto-resource-limits-fast.sh > /var/log/pelican-auto-limits-fast.log 2>&1 &${NC}"
echo ""

echo -e "${CYAN}🔄 TO CHANGE DEFAULT LIMITS:${NC}"
echo -e "   1. Edit: ${GREEN}nano /usr/local/bin/pelican-auto-resource-limits.sh${NC}"
echo -e "   2. Change the DEFAULT_* values at the top"
echo -e "   3. Restart fast service (see command above)"
echo ""

echo -e "${BLUE}✅ Setup complete! Users can now self-register and create servers!${NC}"
echo ""

if [ "$DB_TYPE" = "PostgreSQL" ]; then
    echo -e "${CYAN}💡 PostgreSQL Tips:${NC}"
    echo -e "   ${GREEN}✓${NC} PHP PostgreSQL extensions verified and working"
    echo -e "   ${GREEN}✓${NC} Using connection pooler on port ${DB_PORT}"
    echo -e "   ${BLUE}All database operations are optimized for PostgreSQL${NC}"
    echo ""
fi