#!/usr/bin/ksh
# =============================================================================
# cron_backup.sh (AIX)
# Backup crontabs for ALL users before a DR switch
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
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_backup] $1"
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

get_spool_users() {
    spool_dir="/var/spool/cron/crontabs"
    if [ -d "$spool_dir" ] && [ -r "$spool_dir" ]; then
        for f in "$spool_dir"/*; do
            [ -e "$f" ] || continue
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            case "$fname" in
                .*|*~|*.bak) continue ;;
            esac
            echo "$fname"
        done
    else
        awk -F: '$7 !~ /nologin|false|sync|halt|shutdown/ && $3 >= 0 { print $1 }' /etc/passwd
    fi
}

USER_LIST=$(get_spool_users | sort -u)

BACKED_UP=0
SKIPPED=0

for USER in $USER_LIST; do
    if [ "$(id -un)" = "$USER" ]; then
        CRON_CONTENT=$(crontab -l 2>/dev/null)
        cron_rc=$?
    else
        CRON_CONTENT=$(crontab -l "$USER" 2>/dev/null)
        cron_rc=$?
    fi

    if [ $cron_rc -eq 0 ] && [ -n "$CRON_CONTENT" ]; then
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
  su - <username> -c "crontab $BACKUP_DIR/user_<username>.cron"

To restore system cron dirs:
  cp -rp $SYSDIR_BACKUP/aix_spool_crontabs/* /var/spool/cron/crontabs/
EOF

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

echo "$BACKUP_DIR"
exit 0
