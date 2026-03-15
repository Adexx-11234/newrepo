#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v3.0
# Created by NexusTechPro
# Architecture:
#   - ~/vms/         = compressed backup storage (persistent on /home)
#   - /nexusvms/     = runtime directory (tmpfs, RAM-backed, fast)
#   - VM always runs from /nexusvms/ (tmpfs)
#   - On start:    restore ~/vms/name.img → /nexusvms/name.img → boot
#   - On freeze:   kill → delete /nexusvms copy → restore fresh → restart
#   - On shutdown: recompress /nexusvms copy → ~/vms/ → delete tmpfs copy
# =============================

# --- ANSI COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;97m'
NC='\033[0m'

# --- DIRECTORIES ---
BACKUP_DIR="${BACKUP_DIR:-$HOME/vms}"   # persistent compressed backups on /home
RUNTIME_DIR="/nexusvms"                  # tmpfs runtime images

# --- HEADER ---
display_header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  Created by NexusTechPro"
    echo -e "  Enhanced Multi-VM Manager v3.0"
    echo -e "========================================================================${NC}"
    echo
}

# --- STATUS PRINT ---
print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO")    echo -e "${CYAN}[INFO]${NC} $message" ;;
        "WARN")    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "INPUT")   echo -e "${WHITE}[INPUT]${NC} $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

# --- VALIDATE INPUT ---
validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")   [[ "$value" =~ ^[0-9]+$ ]] || { print_status "ERROR" "Must be a number"; return 1; } ;;
        "size")     [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status "ERROR" "Must be a size with unit (e.g., 10G)"; return 1; } ;;
        "port")     [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] || { print_status "ERROR" "Must be valid port (23-65535)"; return 1; } ;;
        "name")     [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_status "ERROR" "Only letters, numbers, hyphens, underscores"; return 1; } ;;
        "username") [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || { print_status "ERROR" "Must start with letter/underscore"; return 1; } ;;
    esac
    return 0
}

# --- CHECK DEPENDENCIES ---
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        print_status "INFO" "Try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

# --- CLEANUP ---
cleanup() {
    rm -f /tmp/vps-user-data /tmp/vps-meta-data 2>/dev/null || true
}

# --- CHECK FREE SPACE ---
check_space() {
    local path=$1
    local needed_gb=$2
    local free_kb
    free_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}')
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if [[ $free_gb -lt $needed_gb ]]; then
        print_status "ERROR" "Not enough space on $path (need ${needed_gb}G, have ${free_gb}G free)"
        return 1
    fi
    return 0
}

# --- GET VM LIST ---
get_vm_list() {
    find "$BACKUP_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# --- LOAD VM CONFIG ---
load_vm_config() {
    local vm_name=$1
    local config_file="$BACKUP_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS CREATED
        source "$config_file"
        BACKUP_IMG="$BACKUP_DIR/$vm_name.img"
        RUNTIME_IMG="$RUNTIME_DIR/$vm_name.img"
        SEED_FILE="$BACKUP_DIR/$vm_name-seed.iso"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# --- SAVE VM CONFIG ---
save_vm_config() {
    local config_file="$BACKUP_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# --- RESTORE FROM BACKUP TO TMPFS ---
# Decompresses ~/vms/name.img → /nexusvms/name.img
restore_to_tmpfs() {
    local vm_name=$1
    local backup_img="$BACKUP_DIR/$vm_name.img"
    local runtime_img="$RUNTIME_DIR/$vm_name.img"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    if [[ ! -f "$backup_img" ]]; then
        print_status "ERROR" "No backup image found at $backup_img"
        return 1
    fi

    mkdir -p "$RUNTIME_DIR"

    # Compressed backup is ~7G, decompressed will be larger — check space
    local backup_gb
    backup_gb=$(du -BG "$backup_img" 2>/dev/null | awk '{gsub("G",""); print $1}')
    local needed_gb=$(( ${backup_gb:-8} * 3 ))
    check_space "/" "$needed_gb" || return 1

    print_status "INFO" "Restoring from backup to tmpfs (~2-3 mins)..."
    echo "[$(date '+%H:%M:%S')] Restoring: $backup_img → $runtime_img" >> "$watchdog_log"

    if qemu-img convert -O qcow2 "$backup_img" "$runtime_img" 2>> "$watchdog_log"; then
        local sz
        sz=$(du -sh "$runtime_img" 2>/dev/null | awk '{print $1}')
        print_status "SUCCESS" "Restored to tmpfs ($sz)"
        echo "[$(date '+%H:%M:%S')] Restore complete: $sz" >> "$watchdog_log"
        return 0
    else
        print_status "ERROR" "Restore failed"
        rm -f "$runtime_img"
        return 1
    fi
}

# --- SAVE TMPFS BACK TO BACKUP ---
# Recompresses /nexusvms/name.img → ~/vms/name.img
save_to_backup() {
    local vm_name=$1
    local backup_img="$BACKUP_DIR/$vm_name.img"
    local runtime_img="$RUNTIME_DIR/$vm_name.img"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    if [[ ! -f "$runtime_img" ]]; then
        print_status "WARN" "No runtime image found — nothing to save"
        return 1
    fi

    # Need ~half the runtime size for compressed backup
    local runtime_gb
    runtime_gb=$(du -BG "$runtime_img" 2>/dev/null | awk '{gsub("G",""); print $1}')
    local needed_gb=$(( (${runtime_gb:-10} / 2) + 2 ))
    check_space "$BACKUP_DIR" "$needed_gb" || return 1

    print_status "INFO" "Compressing and saving back to /home backup..."
    echo "[$(date '+%H:%M:%S')] Saving: $runtime_img → $backup_img" >> "$watchdog_log"

    local tmp_backup="${backup_img}.saving"
    if qemu-img convert -O qcow2 -c "$runtime_img" "$tmp_backup" 2>> "$watchdog_log"; then
        mv "$tmp_backup" "$backup_img"
        local sz
        sz=$(du -sh "$backup_img" 2>/dev/null | awk '{print $1}')
        print_status "SUCCESS" "Saved to backup ($sz compressed)"
        echo "[$(date '+%H:%M:%S')] Save complete: $sz" >> "$watchdog_log"
        return 0
    else
        print_status "ERROR" "Save to backup failed"
        rm -f "$tmp_backup"
        return 1
    fi
}

# --- FREEZE RECOVERY ---
# Full cycle: kill → delete tmpfs → restore fresh from /home → restart
freeze_recovery() {
    local vm_name=$1
    local runtime_img="$RUNTIME_DIR/$vm_name.img"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$watchdog_log"

    # Step 1 — Kill frozen VM
    echo "[$(date '+%H:%M:%S')] Step 1: Killing frozen VM..." >> "$watchdog_log"
    kill_vm "$vm_name" 2>/dev/null || true
    sleep 2

    # Step 2 — Delete frozen tmpfs copy
    echo "[$(date '+%H:%M:%S')] Step 2: Deleting frozen tmpfs image..." >> "$watchdog_log"
    rm -f "$runtime_img"

    # Step 3 — Restore fresh from /home backup
    echo "[$(date '+%H:%M:%S')] Step 3: Restoring fresh from /home backup..." >> "$watchdog_log"
    if ! restore_to_tmpfs "$vm_name"; then
        echo "[$(date '+%H:%M:%S')] ERROR: Restore failed — cannot recover" >> "$watchdog_log"
        return 1
    fi

    # Step 4 — Restart VM
    echo "[$(date '+%H:%M:%S')] Step 4: Restarting VM..." >> "$watchdog_log"
    rm -f "$serial_log"
    local qemu_cmd
    qemu_cmd=$(build_qemu_cmd "$vm_name")
    if eval "$qemu_cmd" >> "$watchdog_log" 2>&1; then
        echo "[$(date '+%H:%M:%S')] VM restarted successfully" >> "$watchdog_log"
        echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY COMPLETE =====" >> "$watchdog_log"
        return 0
    else
        echo "[$(date '+%H:%M:%S')] ERROR: Failed to restart VM" >> "$watchdog_log"
        return 1
    fi
}

# --- SETUP VM IMAGE (first time only) ---
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$RUNTIME_DIR"

    local base_img="$BACKUP_DIR/$VM_NAME-base.img"

    if [[ ! -f "$base_img" ]]; then
        print_status "INFO" "Downloading from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$base_img.tmp"; then
            print_status "ERROR" "Download failed"
            exit 1
        fi
        mv "$base_img.tmp" "$base_img"
    fi

    qemu-img resize "$base_img" "$DISK_SIZE" 2>/dev/null || true

    print_status "INFO" "Compressing base image into backup storage..."
    qemu-img convert -O qcow2 -c "$base_img" "$BACKUP_DIR/$VM_NAME.img"
    rm -f "$base_img"

    cat > /tmp/vps-user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
write_files:
  - path: /etc/systemd/journald.conf.d/no-freeze.conf
    content: |
      [Journal]
      Storage=volatile
      Compress=no
      Seal=no
      SyncIntervalSec=0
      RateLimitIntervalSec=0
      RateLimitBurst=0
  - path: /etc/docker/daemon.json
    content: |
      {
        "dns": ["8.8.8.8", "1.1.1.1"],
        "dns-opts": ["ndots:0"],
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "3"},
        "iptables": true,
        "userland-proxy": false
      }
    permissions: '0644'
  - path: /etc/sysctl.d/99-vm-tweaks.conf
    content: |
      net.ipv4.ip_forward=1
      net.bridge.bridge-nf-call-iptables=1
      vm.dirty_ratio=10
      vm.dirty_background_ratio=5
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - systemctl restart systemd-journald
  - journalctl --vacuum-size=1M 2>/dev/null || true
  - sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& systemd.journald.forward_to_console=0 udev.log_level=3 systemd.log_level=warning/' /etc/default/grub
  - update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
EOF

    cat > /tmp/vps-meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    cloud-localds "$SEED_FILE" /tmp/vps-user-data /tmp/vps-meta-data || {
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    }

    print_status "SUCCESS" "VM '$VM_NAME' setup complete."
}

# --- BUILD QEMU COMMAND ---
# Always uses RUNTIME_DIR (tmpfs) for the main disk image
build_qemu_cmd() {
    local vm_name=$1
    local runtime_img="$RUNTIME_DIR/$vm_name.img"
    local seed_file="$BACKUP_DIR/$vm_name-seed.iso"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"

    local kvm_flag="-enable-kvm"
    if [[ ! -w /dev/kvm ]]; then
        print_status "WARN" "KVM not available — using TCG (slower but stable)"
        kvm_flag="-accel tcg,thread=multi"
    fi

    local cmd=(
        qemu-system-x86_64
        $kvm_flag
        -machine q35,mem-merge=off
        -m "$MEMORY"
        -smp "$CPUS"
        -cpu host,+x2apic
        -drive "file=$runtime_img,format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads"
        -drive "file=$seed_file,format=raw,if=virtio,cache=writeback"
        -boot order=c
        -device virtio-net-pci,netdev=n0
        -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
        -device virtio-balloon-pci
        -serial "file:$serial_log"
        -display none
        -daemonize
        -pidfile "$BACKUP_DIR/$vm_name.pid"
    )

    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        local idx=1
        for forward in "${forwards[@]}"; do
            IFS=':' read -r host_port guest_port <<< "$forward"
            cmd+=(-device "virtio-net-pci,netdev=n$idx")
            cmd+=(-netdev "user,id=n$idx,hostfwd=tcp::$host_port-:$guest_port")
            ((idx++))
        done
    fi

    echo "${cmd[@]}"
}

# --- CHECK SSH PORT OPEN ---
# Reads actual SSH banner — frozen VMs accept TCP but never send "SSH-"
check_ssh_port_open() {
    local port=$1
    local banner
    banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$port && cat <&3" 2>/dev/null | head -1)
    [[ "$banner" == SSH-* ]] && return 0
    return 1
}

# --- APPLY POST-BOOT FIXES ---
apply_post_boot_fixes() {
    local port=$1
    local user=$2
    local pass=$3

    if ! command -v sshpass &>/dev/null; then
        print_status "WARN" "sshpass not found — skipping auto-fixes"
        return 0
    fi

    print_status "INFO" "Applying post-boot hardening..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<'REMOTE' 2>/dev/null || true
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/no-freeze.conf <<'JF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
JF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true
if command -v docker &>/dev/null; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DF'
{
  "dns": ["8.8.8.8", "1.1.1.1"],
  "dns-opts": ["ndots:0"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "iptables": true,
  "userland-proxy": false
}
DF
    systemctl restart docker 2>/dev/null || true
fi
REMOTE
    print_status "SUCCESS" "Post-boot hardening applied"
}

# --- KILL VM ---
kill_vm() {
    local vm_name=$1
    local pid_file="$BACKUP_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || true
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    pkill -f "qemu-system-x86_64.*$RUNTIME_DIR/$vm_name" 2>/dev/null || true
}

# --- IS VM RUNNING ---
is_vm_running() {
    local vm_name=$1
    local pid_file="$BACKUP_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || return 1
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}

# --- WAIT FOR SSH WITH FREEZE DETECTION ---
wait_for_ssh() {
    local vm_name=$1
    local max_wait=120
    local elapsed=0
    local recovery_count=0
    local max_recoveries=3
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    print_status "INFO" "Waiting for VM to boot (max ${max_wait}s)..."
    echo -n "   "

    while true; do
        if check_ssh_port_open "$SSH_PORT"; then
            echo ""
            print_status "SUCCESS" "SSH ready after ${elapsed}s"
            return 0
        fi

        # Stale serial log = frozen kernel
        if [[ -f "$serial_log" && $elapsed -gt 20 ]]; then
            local last_mod now age
            last_mod=$(stat -c %Y "$serial_log" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$((now - last_mod))

            if [[ $age -gt 30 ]]; then
                echo ""
                print_status "WARN" "Freeze detected (serial stale ${age}s)"
                print_status "WARN" "Froze at: $(tail -1 "$serial_log" 2>/dev/null)"
                echo "[$(date '+%H:%M:%S')] Boot freeze: serial stale ${age}s" >> "$watchdog_log"

                if [[ $recovery_count -ge $max_recoveries ]]; then
                    print_status "ERROR" "Max recoveries ($max_recoveries) reached — giving up"
                    return 1
                fi

                ((recovery_count++))
                print_status "INFO" "Recovery attempt $recovery_count/$max_recoveries..."
                if freeze_recovery "$vm_name"; then
                    print_status "SUCCESS" "Recovery done — waiting for reboot..."
                    elapsed=0
                    echo -n "   "
                else
                    print_status "ERROR" "Recovery failed"
                    return 1
                fi
            fi
        fi

        if [[ $elapsed -ge $max_wait ]]; then
            echo ""
            if [[ $recovery_count -lt $max_recoveries ]]; then
                ((recovery_count++))
                print_status "WARN" "SSH timeout — treating as freeze. Recovery $recovery_count/$max_recoveries..."
                echo "[$(date '+%H:%M:%S')] SSH timeout — treating as freeze" >> "$watchdog_log"
                if freeze_recovery "$vm_name"; then
                    elapsed=0
                    echo -n "   "
                    continue
                fi
            fi
            print_status "ERROR" "VM failed to boot"
            return 1
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
}

# --- BACKGROUND WATCHDOG ---
# Runs for entire VM lifetime — triggers freeze_recovery on freeze
start_freeze_watchdog() {
    local vm_name=$1
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    (
        local recovery_count=0
        local max_recoveries=3

        sleep 120  # grace period during boot

        while true; do
            sleep 30

            [[ ! -f "$BACKUP_DIR/$vm_name.pid" ]] && exit 0

            local pid
            pid=$(cat "$BACKUP_DIR/$vm_name.pid" 2>/dev/null) || exit 0
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] QEMU process died unexpectedly" >> "$watchdog_log"
                exit 0
            fi

            if ! check_ssh_port_open "$SSH_PORT"; then
                local stale=0
                if [[ -f "$serial_log" ]]; then
                    local lm now
                    lm=$(stat -c %Y "$serial_log" 2>/dev/null || echo 0)
                    now=$(date +%s)
                    stale=$((now - lm))
                fi

                if [[ $stale -gt 40 ]]; then
                    echo "[$(date '+%H:%M:%S')] FREEZE — SSH no banner, serial stale ${stale}s" >> "$watchdog_log"
                    echo "[$(date '+%H:%M:%S')] Froze at: $(tail -1 "$serial_log" 2>/dev/null)" >> "$watchdog_log"

                    if [[ $recovery_count -ge $max_recoveries ]]; then
                        echo "[$(date '+%H:%M:%S')] Max recoveries reached. Watchdog stopping." >> "$watchdog_log"
                        exit 1
                    fi

                    ((recovery_count++))
                    echo "[$(date '+%H:%M:%S')] Recovery $recovery_count/$max_recoveries" >> "$watchdog_log"

                    if freeze_recovery "$vm_name"; then
                        echo "[$(date '+%H:%M:%S')] Recovery complete" >> "$watchdog_log"
                        recovery_count=0
                        sleep 120
                    else
                        echo "[$(date '+%H:%M:%S')] Recovery failed — watchdog stopping" >> "$watchdog_log"
                        exit 1
                    fi
                else
                    echo "[$(date '+%H:%M:%S')] SSH down, serial active (${stale}s) — likely rebooting" >> "$watchdog_log"
                fi
            else
                recovery_count=0
            fi
        done
    ) >> "$watchdog_log" 2>&1 &

    disown
    print_status "SUCCESS" "Freeze watchdog running in background"
    print_status "INFO"    "Log: $BACKUP_DIR/$vm_name.watchdog.log"
}

# --- SSH INTO VM ---
ssh_into_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running"
        return 1
    fi

    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    sleep 3

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  Connecting: ${USERNAME}@localhost:${SSH_PORT}"
    echo -e "  Password:   ${PASSWORD}"
    echo -e "==========================================${NC}"
    echo ""

    if command -v sshpass &>/dev/null; then
        sshpass -p "$PASSWORD" ssh $ssh_opts -p "$SSH_PORT" "${USERNAME}@localhost"
    else
        print_status "WARN" "sshpass not installed — type password manually"
        ssh $ssh_opts -p "$SSH_PORT" "${USERNAME}@localhost"
    fi
}

# --- CREATE NEW VM ---
create_new_vm() {
    print_status "INFO" "Creating a new VM"

    check_space "$BACKUP_DIR" 3 || return 1
    check_space "/" 10 || return 1

    print_status "INFO" "Select an OS:"
    local os_keys=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_keys[$i]="$os"
        ((i++))
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_keys[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        fi
        print_status "ERROR" "Invalid selection"
    done

    while true; do
        read -p "$(print_status "INPUT" "VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        validate_input "name" "$VM_NAME" || continue
        [[ -f "$BACKUP_DIR/$VM_NAME.conf" ]] && { print_status "ERROR" "VM '$VM_NAME' already exists"; continue; }
        break
    done

    while true; do
        read -p "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        validate_input "name" "$HOSTNAME" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        validate_input "username" "$USERNAME" && break
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        [[ -n "$PASSWORD" ]] && break
        print_status "ERROR" "Password cannot be empty"
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size — keep at 10G max (default: 10G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-10G}"
        validate_input "size" "$DISK_SIZE" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 4096): ")" MEMORY
        MEMORY="${MEMORY:-4096}"
        validate_input "number" "$MEMORY" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        validate_input "number" "$CPUS" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        validate_input "port" "$SSH_PORT" || continue
        ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && { print_status "ERROR" "Port $SSH_PORT in use"; continue; }
        break
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, or Enter for none): ")" PORT_FORWARDS
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    GUI_MODE=false

    BACKUP_IMG="$BACKUP_DIR/$VM_NAME.img"
    RUNTIME_IMG="$RUNTIME_DIR/$VM_NAME.img"
    SEED_FILE="$BACKUP_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

# --- START VM ---
start_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if is_vm_running "$vm_name"; then
        print_status "SUCCESS" "VM '$vm_name' is already running!"
        ssh_into_vm "$vm_name"
        print_status "INFO" "SSH session ended. Goodbye!"
        exit 0
    fi

    if [[ ! -f "$BACKUP_IMG" ]]; then
        print_status "ERROR" "No backup image found: $BACKUP_IMG"
        return 1
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed file missing, recreating..."
        setup_vm_image
    fi

    # Restore from backup to tmpfs if not already there
    if [[ ! -f "$RUNTIME_IMG" ]]; then
        print_status "INFO" "Restoring from /home backup to tmpfs..."
        restore_to_tmpfs "$vm_name" || return 1
    else
        print_status "INFO" "Runtime image already in tmpfs"
    fi

    rm -f "$BACKUP_DIR/$vm_name.serial.log"
    > "$BACKUP_DIR/$vm_name.watchdog.log"
    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    ssh-keygen -R "localhost" 2>/dev/null || true

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH port: $SSH_PORT | User: $USERNAME | Password: $PASSWORD"

    local qemu_cmd
    qemu_cmd=$(build_qemu_cmd "$vm_name")
    eval "$qemu_cmd" || {
        print_status "ERROR" "Failed to start QEMU"
        return 1
    }

    # Start watchdog immediately
    start_freeze_watchdog "$vm_name"

    if wait_for_ssh "$vm_name"; then
        apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"
        ssh_into_vm "$vm_name"
        echo ""
        print_status "INFO" "SSH session ended — saving VM state back to /home backup..."
        kill_vm "$vm_name"
        if save_to_backup "$vm_name"; then
            rm -f "$RUNTIME_IMG"
            print_status "SUCCESS" "VM state saved. Goodbye!"
        else
            print_status "WARN" "Save failed — runtime image left in tmpfs at $RUNTIME_IMG"
        fi
        exit 0
    else
        print_status "ERROR" "VM failed to boot. Check logs:"
        print_status "INFO"  "  Serial:   tail -30 $BACKUP_DIR/$vm_name.serial.log"
        print_status "INFO"  "  Watchdog: tail -30 $BACKUP_DIR/$vm_name.watchdog.log"
    fi
}

# --- STOP VM ---
stop_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if is_vm_running "$vm_name"; then
        print_status "INFO" "Stopping VM and saving state..."
        kill_vm "$vm_name"
        if save_to_backup "$vm_name"; then
            rm -f "$RUNTIME_IMG"
            print_status "SUCCESS" "VM '$vm_name' stopped and saved to backup"
        else
            print_status "WARN" "Stop OK but save failed — runtime image kept at $RUNTIME_IMG"
        fi
    else
        print_status "INFO" "VM '$vm_name' is not running"
    fi
}

# --- ATTACH WATCHDOG TO RUNNING VM ---
attach_watchdog() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running"
        return 1
    fi

    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    echo "[$(date '+%H:%M:%S')] Watchdog manually attached" >> "$watchdog_log"
    start_freeze_watchdog "$vm_name"
    print_status "SUCCESS" "Watchdog attached — monitoring for freezes now"
    print_status "INFO"    "Monitor: tail -f $watchdog_log"
}

# --- SHOW VM INFO ---
show_vm_info() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    local status="Stopped"
    is_vm_running "$vm_name" && status="Running"

    echo ""
    print_status "INFO" "VM: $vm_name"
    echo "=========================================="
    echo "Status:        $status"
    echo "OS:            $OS_TYPE ($CODENAME)"
    echo "Hostname:      $HOSTNAME"
    echo "Username:      $USERNAME"
    echo "Password:      $PASSWORD"
    echo "SSH Port:      $SSH_PORT"
    echo "Memory:        $MEMORY MB"
    echo "CPUs:          $CPUS"
    echo "Disk:          $DISK_SIZE virtual"
    echo "Port Forwards: ${PORT_FORWARDS:-None}"
    echo "Created:       $CREATED"
    echo ""
    echo "Backup (/home):"
    [[ -f "$BACKUP_IMG" ]] && du -sh "$BACKUP_IMG" | awk '{print "  " $1 " compressed"}' || echo "  Not found"
    echo "Runtime (tmpfs):"
    [[ -f "$RUNTIME_IMG" ]] && du -sh "$RUNTIME_IMG" | awk '{print "  " $1}' || echo "  Not in tmpfs"
    echo ""
    df -h /home | tail -1 | awk '{print "/home:   " $4 " free of " $2 " (" $5 " used)"}'
    df -h /     | tail -1 | awk '{print "tmpfs:   " $4 " free of " $2 " (" $5 " used)"}'
    echo "=========================================="
    echo ""

    if [[ "$status" == "Running" ]]; then
        read -p "$(print_status "INPUT" "Connect via SSH? (Y/n): ")" connect
        connect="${connect:-Y}"
        if [[ "$connect" =~ ^[Yy]$ ]]; then
            ssh_into_vm "$vm_name"
            print_status "INFO" "SSH session ended. Saving state..."
            kill_vm "$vm_name"
            save_to_backup "$vm_name" && rm -f "$RUNTIME_IMG"
            print_status "SUCCESS" "Saved. Goodbye!"
            exit 0
        fi
    else
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# --- DELETE VM ---
delete_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    print_status "WARN" "This permanently deletes VM '$vm_name' and ALL data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        is_vm_running "$vm_name" && kill_vm "$vm_name"
        rm -f "$BACKUP_IMG" "$RUNTIME_IMG" "$SEED_FILE"
        rm -f "$BACKUP_DIR/$vm_name.conf" "$BACKUP_DIR/$vm_name.pid"
        rm -f "$BACKUP_DIR/$vm_name.serial.log" "$BACKUP_DIR/$vm_name.watchdog.log"
        print_status "SUCCESS" "VM '$vm_name' deleted"
    else
        print_status "INFO" "Cancelled"
    fi
}

# --- EDIT VM CONFIG ---
edit_vm_config() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    while true; do
        echo "What would you like to edit?"
        echo "  1) Hostname    2) Username    3) Password"
        echo "  4) SSH Port    5) Memory      6) CPUs"
        echo "  7) Port Forwards"
        echo "  0) Back"
        read -p "$(print_status "INPUT" "Choice: ")" edit_choice

        case $edit_choice in
            1) read -p "$(print_status "INPUT" "New hostname [$HOSTNAME]: ")" v; HOSTNAME="${v:-$HOSTNAME}" ;;
            2) while true; do read -p "$(print_status "INPUT" "New username [$USERNAME]: ")" v; v="${v:-$USERNAME}"; validate_input "username" "$v" && { USERNAME="$v"; break; }; done ;;
            3) while true; do read -s -p "$(print_status "INPUT" "New password: ")" v; echo; [[ -n "$v" ]] && { PASSWORD="$v"; break; } || print_status "ERROR" "Cannot be empty"; done ;;
            4) while true; do read -p "$(print_status "INPUT" "New SSH port [$SSH_PORT]: ")" v; v="${v:-$SSH_PORT}"; validate_input "port" "$v" && { SSH_PORT="$v"; break; }; done ;;
            5) while true; do read -p "$(print_status "INPUT" "New memory MB [$MEMORY]: ")" v; v="${v:-$MEMORY}"; validate_input "number" "$v" && { MEMORY="$v"; break; }; done ;;
            6) while true; do read -p "$(print_status "INPUT" "New CPUs [$CPUS]: ")" v; v="${v:-$CPUS}"; validate_input "number" "$v" && { CPUS="$v"; break; }; done ;;
            7) read -p "$(print_status "INPUT" "Port forwards [${PORT_FORWARDS:-none}]: ")" v; PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            0) return 0 ;;
            *) print_status "ERROR" "Invalid"; continue ;;
        esac

        save_vm_config
        read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
        [[ "$cont" =~ ^[Yy]$ ]] || break
    done
}

# --- RESIZE VM DISK ---
resize_vm_disk() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    is_vm_running "$vm_name" && { print_status "ERROR" "Stop the VM first"; return 1; }

    print_status "INFO" "Current disk size: $DISK_SIZE"
    local target="$RUNTIME_IMG"
    [[ ! -f "$RUNTIME_IMG" ]] && target="$BACKUP_IMG"

    while true; do
        read -p "$(print_status "INPUT" "New disk size (e.g., 15G): ")" new_size
        validate_input "size" "$new_size" || continue
        if qemu-img resize "$target" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "Disk resized to $new_size"
        else
            print_status "ERROR" "Resize failed"
        fi
        break
    done
}

# --- SHOW VM PERFORMANCE ---
show_vm_performance() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    echo ""
    print_status "INFO" "Performance: $vm_name"
    echo "=========================================="
    if is_vm_running "$vm_name"; then
        local pid
        pid=$(cat "$BACKUP_DIR/$vm_name.pid" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && ps -p "$pid" -o pid,%cpu,%mem,rss,vsz --no-headers 2>/dev/null || true
        echo ""
        free -h
        echo ""
        echo "Runtime image (tmpfs):"
        du -h "$RUNTIME_IMG" 2>/dev/null || echo "  Not found"
        echo "Backup image (/home):"
        du -h "$BACKUP_IMG" 2>/dev/null || echo "  Not found"
        if [[ -f "$BACKUP_DIR/$vm_name.serial.log" ]]; then
            echo ""
            echo "Last boot messages:"
            tail -5 "$BACKUP_DIR/$vm_name.serial.log"
        fi
    else
        print_status "INFO" "VM not running"
        echo "Config: ${MEMORY}MB RAM | ${CPUS} CPUs | ${DISK_SIZE} virtual disk"
        echo ""
        echo "Backup: $(du -sh "$BACKUP_IMG" 2>/dev/null | awk '{print $1}') compressed"
        [[ -f "$RUNTIME_IMG" ]] && echo "Runtime: $(du -sh "$RUNTIME_IMG" 2>/dev/null | awk '{print $1}') in tmpfs"
    fi
    echo ""
    echo "=========================================="
    df -h /home | tail -1 | awk '{print "/home:   " $4 " free of " $2}'
    df -h /     | tail -1 | awk '{print "tmpfs:   " $4 " free of " $2}'
    echo "=========================================="
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- VIEW SERIAL LOG ---
view_serial_log() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    if [[ -f "$serial_log" ]]; then
        print_status "INFO" "Serial log (last 30 lines):"
        echo "=========================================="
        tail -30 "$serial_log"
        echo "=========================================="
    else
        print_status "WARN" "No serial log found"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- VIEW WATCHDOG LOG ---
view_watchdog_log() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    if [[ -f "$watchdog_log" && -s "$watchdog_log" ]]; then
        print_status "INFO" "Watchdog log (last 40 lines):"
        echo "=========================================="
        tail -40 "$watchdog_log"
        echo "=========================================="
    else
        print_status "INFO" "No watchdog activity yet"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- MAIN MENU ---
main_menu() {
    while true; do
        display_header

        echo -e "${CYAN}Storage:${NC}"
        df -h /home | tail -1 | awk '{print "  /home (backup):  " $4 " free of " $2 " (" $5 " used)"}'
        df -h /     | tail -1 | awk '{print "  tmpfs (runtime): " $4 " free of " $2 " (" $5 " used)"}'
        echo ""

        local vms=()
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local sc rt=""
                if is_vm_running "${vms[$i]}"; then
                    sc="${GREEN}Running${NC}"
                else
                    sc="${RED}Stopped${NC}"
                fi
                [[ -f "$RUNTIME_DIR/${vms[$i]}.img" ]] && rt=" ${CYAN}[tmpfs]${NC}"
                printf "  %2d) %s (" $((i+1)) "${vms[$i]}"
                echo -e "$sc)$rt"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start VM + Auto-SSH"
            echo "  3) Stop VM + Save state"
            echo "  4) Show VM info / SSH connect"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) View serial log"
            echo " 10) View watchdog log"
            echo " 11) Attach watchdog to running VM"
        fi
        echo "  0) Exit"
        echo

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        case $choice in
            1) create_new_vm ;;
            2)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && start_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            3)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && stop_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            4)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_info "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            5)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && edit_vm_config "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            6)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && delete_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            7)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && resize_vm_disk "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            8)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_performance "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            9)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && view_serial_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            10)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && view_watchdog_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            11)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && attach_watchdog "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            0) print_status "INFO" "Goodbye!"; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")" 2>/dev/null || true
    done
}

# --- INIT ---
trap cleanup EXIT
check_dependencies
mkdir -p "$BACKUP_DIR"
mkdir -p "$RUNTIME_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04 (minimal)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (minimal)"]="ubuntu|noble|https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04 (standard)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (standard)"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

main_menu