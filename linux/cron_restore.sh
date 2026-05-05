#!/bin/bash
# =============================================================================
# cron_restore.sh
# Restore crontabs for ALL users from a backup created by cron_backup.sh
#
# USAGE:
#   ./cron_restore.sh --backup-dir /var/backups/cron_dr/20260320_183000_dc-server
#   ./cron_restore.sh --backup-dir <dir> --user oracle   # restore single user only
#   ./cron_restore.sh --backup-dir <dir> --dry-run       # preview only
#
# NOTE: Must be run as root
# =============================================================================

LOG_FILE="/var/log/dr_cron_manager.log"
BACKUP_DIR=""
TARGET_USER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --user)       TARGET_USER="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --help)
            echo "Usage: $0 --backup-dir <path> [--user <username>] [--dry-run]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_restore] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

# --- Validations ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must be run as root."
    exit 1
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Valid --backup-dir required."
    echo "       List backups with: ./cron_backup.sh --list"
    exit 1
fi

log "Restoring from backup: $BACKUP_DIR"
if [ -f "$BACKUP_DIR/metadata.txt" ]; then
    log "Backup metadata:"
    cat "$BACKUP_DIR/metadata.txt" | while read line; do log "  $line"; done
fi

RESTORED=0
FAILED=0

# --- Restore single user or all users ---
if [ -n "$TARGET_USER" ]; then
    CRON_FILE="$BACKUP_DIR/user_${TARGET_USER}.cron"
    if [ ! -f "$CRON_FILE" ]; then
        log "ERROR: No backup found for user '$TARGET_USER' in $BACKUP_DIR"
        exit 1
    fi
    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: Would restore crontab for $TARGET_USER"
        cat "$CRON_FILE"
    else
        crontab -u "$TARGET_USER" "$CRON_FILE"
        log "Restored crontab for: $TARGET_USER"
    fi
else
    # Restore all users from backup
    for CRON_FILE in "$BACKUP_DIR"/user_*.cron; do
        [ -f "$CRON_FILE" ] || continue
        # Extract username from filename: user_oracle.cron → oracle
        USER=$(basename "$CRON_FILE" .cron | sed 's/^user_//')
        if [ "$DRY_RUN" = true ]; then
            log "DRY-RUN: Would restore crontab for $USER"
        else
            crontab -u "$USER" "$CRON_FILE"
            if [ $? -eq 0 ]; then
                log "Restored: $USER"
                RESTORED=$((RESTORED + 1))
            else
                log "ERROR: Failed to restore crontab for $USER"
                FAILED=$((FAILED + 1))
            fi
        fi
    done
fi

echo ""
echo "=============================================="
if [ "$DRY_RUN" = true ]; then
    echo "  DRY-RUN complete. No changes applied."
else
    echo "  Restore complete!"
    echo "  Restored : $RESTORED users"
    [ "$FAILED" -gt 0 ] && echo "  FAILED   : $FAILED users (check log: $LOG_FILE)"
fi
echo "=============================================="
echo ""
exit 0
