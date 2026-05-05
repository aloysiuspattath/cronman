#!/bin/bash
# =============================================================================
# make_standby.sh
# Make THIS server the STANDBY (passive) server
#
# WHEN TO RUN:
#   - DR Drill START : run on the DC server  (DC steps down, DR takes over)
#   - DR Drill END   : run on the DR server  (DR steps down, DC returns)
#
# WHAT IT DOES:
#   1. Backs up all users' crontabs (safety net)
#   2. Sets /etc/server_role to STANDBY
#   3. Disables all cron jobs tagged with #PRIMARY
#   4. Logs everything to /var/log/dr_switchover.log
#
# USAGE:
#   sudo ./make_standby.sh            # apply
#   sudo ./make_standby.sh --dry-run  # preview without changing anything
#
# SUPPORTS: Linux and AIX
# =============================================================================

ROLE_FILE="/etc/server_role"
LOG_FILE="/var/log/dr_switchover.log"
CRON_MANAGER="/usr/local/bin/cron_role_manager.sh"
BACKUP_SCRIPT="/usr/local/bin/cron_backup.sh"
DRY_RUN=false
NEW_ROLE="STANDBY"

# --- Argument parsing ---
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --help)
            echo "Usage: $0 [--dry-run]"
            echo "  Makes this server STANDBY and disables all #PRIMARY cron jobs."
            echo "  Run this on whichever server should step down to standby."
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# --- Logging ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [make_standby] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

separator() { echo "============================================================"; }

separator
log "Hostname : $(hostname)"
log "Action   : Switching to STANDBY"
separator

# --- Validation ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must be run as root (sudo)."
    exit 1
fi

if [ ! -f "$CRON_MANAGER" ]; then
    log "ERROR: $CRON_MANAGER not found. Deploy the correct cron_role_manager script first."
    exit 1
fi

# --- Dry-run mode ---
if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: Would set role to STANDBY. Preview of cron changes:"
    echo "$NEW_ROLE" > "$ROLE_FILE"
    "$CRON_MANAGER" --dry-run
    exit 0
fi

# --- Step 1: Backup all users' crontabs ---
if [ -f "$BACKUP_SCRIPT" ]; then
    log "Step 1: Backing up all users crontabs..."
    BACKUP_DIR=$(bash "$BACKUP_SCRIPT" 2>/dev/null | tail -1)
    log "        Backup saved: $BACKUP_DIR"
    log "        Restore with: sudo cron_restore.sh --backup-dir $BACKUP_DIR"
else
    log "Step 1: WARNING - cron_backup.sh not found. Skipping backup."
fi

# --- Step 2: Set role ---
log "Step 2: Writing STANDBY to $ROLE_FILE..."
echo "$NEW_ROLE" > "$ROLE_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Could not write to $ROLE_FILE. Check permissions."
    exit 1
fi

# --- Step 3: Disable #PRIMARY cron jobs ---
log "Step 3: Disabling #PRIMARY cron jobs..."
"$CRON_MANAGER"
if [ $? -ne 0 ]; then
    log "ERROR: $CRON_MANAGER failed."
    log "       Restore crontabs manually from: $BACKUP_DIR"
    exit 1
fi

# --- Done ---
separator
log "SUCCESS: This server is now STANDBY."
log "         All #PRIMARY cron jobs are DISABLED."
separator

exit 0
