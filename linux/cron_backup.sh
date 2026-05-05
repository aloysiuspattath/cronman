#!/bin/bash
# =============================================================================
# cron_backup.sh
# Backup crontabs for ALL users before a DR switch
#
# PURPOSE:
#   Before any crontab modification (role switch), this script captures a
#   timestamped backup of every user's crontab and the system cron dirs.
#   Use cron_restore.sh to roll back from any backup.
#
# USAGE:
#   ./cron_backup.sh                      # backup to default location
#   ./cron_backup.sh --dir /mybackups     # backup to custom directory
#   ./cron_backup.sh --list               # list available backups
#
# NOTE: Must be run as root to read all users' crontabs
# SUPPORTS: Linux and AIX
# =============================================================================

BACKUP_BASE="/var/backups/cron_dr"
LOG_FILE="/var/log/dr_cron_manager.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LIST_MODE=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)  BACKUP_BASE="$2"; shift 2 ;;
        --list) LIST_MODE=true; shift ;;
        --help)
            echo "Usage: $0 [--dir <path>] [--list]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- List mode ---
if [ "$LIST_MODE" = true ]; then
    echo ""
    echo "Available Cron Backups in: $BACKUP_BASE"
    echo "--------------------------------------------"
    if [ -d "$BACKUP_BASE" ]; then
        ls -lt "$BACKUP_BASE" | grep "^d" | awk '{print "  " $NF}'
    else
        echo "  No backups found."
    fi
    echo ""
    exit 0
fi

# --- Check root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root to back up all users' crontabs."
    exit 1
fi

BACKUP_DIR="${BACKUP_BASE}/${TIMESTAMP}_$(hostname)"
mkdir -p "$BACKUP_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_backup] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

log "Starting crontab backup to: $BACKUP_DIR"
echo "Server Role at backup time: $(cat /etc/server_role 2>/dev/null || echo 'UNKNOWN')" > "$BACKUP_DIR/metadata.txt"
echo "Hostname: $(hostname)" >> "$BACKUP_DIR/metadata.txt"
echo "Timestamp: $TIMESTAMP" >> "$BACKUP_DIR/metadata.txt"
echo "OS: $(uname -s)" >> "$BACKUP_DIR/metadata.txt"

# =============================================================================
# 1. Backup each user's crontab
# =============================================================================
log "Backing up user crontabs..."

# Get all users who have a valid login shell (works on Linux and AIX)
USER_LIST=$(cat /etc/passwd | awk -F: '
    $7 !~ /nologin|false|sync|halt|shutdown/ && $3 >= 0 { print $1 }
')

BACKED_UP=0
SKIPPED=0

for USER in $USER_LIST; do
    CRON_CONTENT=$(crontab -u "$USER" -l 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$CRON_CONTENT" ]; then
        echo "$CRON_CONTENT" > "$BACKUP_DIR/user_${USER}.cron"
        log "  Backed up crontab for user: $USER"
        BACKED_UP=$((BACKED_UP + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

log "Users backed up: $BACKED_UP | Skipped (no crontab): $SKIPPED"

# =============================================================================
# 2. Backup system cron directories
# =============================================================================
log "Backing up system cron directories..."

SYSDIR_BACKUP="$BACKUP_DIR/system_cron"
mkdir -p "$SYSDIR_BACKUP"

# Linux and AIX system cron locations
for CRONDIR in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
    if [ -d "$CRONDIR" ]; then
        cp -rp "$CRONDIR" "$SYSDIR_BACKUP/" 2>/dev/null
        log "  Copied: $CRONDIR"
    fi
done

# AIX-specific: /var/spool/cron/crontabs
if [ -d "/var/spool/cron/crontabs" ]; then
    cp -rp /var/spool/cron/crontabs "$SYSDIR_BACKUP/aix_spool_crontabs" 2>/dev/null
    log "  Copied AIX spool: /var/spool/cron/crontabs"
fi

# =============================================================================
# 3. Write restore instructions
# =============================================================================
cat > "$BACKUP_DIR/HOW_TO_RESTORE.txt" << EOF
To restore all crontabs from this backup:
  sudo ./cron_restore.sh --backup-dir $BACKUP_DIR

To restore a single user's crontab:
  crontab -u <username> $BACKUP_DIR/user_<username>.cron

To restore system cron dirs:
  cp -rp $SYSDIR_BACKUP/cron.d/* /etc/cron.d/
EOF

# =============================================================================
# 4. Summary
# =============================================================================
log "Backup complete."
log "Backup location : $BACKUP_DIR"
log "Users backed up : $BACKED_UP"

echo ""
echo "=============================================="
echo "  Backup complete!"
echo "  Location : $BACKUP_DIR"
echo "  Users    : $BACKED_UP crontabs saved"
echo "=============================================="
echo ""

# Return the backup dir so callers (dr_switchover.sh) can reference it
echo "$BACKUP_DIR"
exit 0
