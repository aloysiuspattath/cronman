#!/bin/bash
# =============================================================================
# make_primary.sh
# Make THIS server the PRIMARY (active) server
#
# WHEN TO RUN:
#   - DR Drill START : run on the DR server  (DR takes over as primary)
#   - DR Drill END   : run on the DC server  (DC returns as primary)
#
# WHAT IT DOES:
#   1. Backs up all users' crontabs (safety net)
#   2. Sets /etc/server_role to PRIMARY
#   3. Enables all cron jobs tagged with #PRIMARY
#   4. Logs everything to /var/log/dr_switchover.log
#
# USAGE:
#   sudo ./make_primary.sh            # apply
#   sudo ./make_primary.sh --dry-run  # preview without changing anything
#
# SUPPORTS: Linux and AIX
# =============================================================================

ROLE_FILE="/etc/server_role"
LOG_FILE="/var/log/dr_switchover.log"

if [ "$(uname)" = "AIX" ]; then
    CRON_MANAGER="/usr/local/bin/cron_role_manager_aix.sh"
else
    CRON_MANAGER="/usr/local/bin/cron_role_manager.sh"
fi
BACKUP_SCRIPT="/usr/local/bin/cron_backup.sh"
DRY_RUN=false
NEW_ROLE="PRIMARY"

# --- Argument parsing ---
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --help)
            echo "Usage: $0 [--dry-run]"
            echo "  Makes this server PRIMARY and enables all #PRIMARY cron jobs."
            echo "  Run this on whichever server should become the active server."
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# --- Logging ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [make_primary] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

separator() { echo "============================================================"; }

separator
log "Hostname : $(hostname)"
log "Action   : Switching to PRIMARY"
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
    log "DRY-RUN: Would set role to PRIMARY. Preview of cron changes:"
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
log "Step 2: Writing PRIMARY to $ROLE_FILE..."
echo "$NEW_ROLE" > "$ROLE_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Could not write to $ROLE_FILE. Check permissions."
    exit 1
fi

# --- Step 3: Enable #PRIMARY cron jobs ---
log "Step 3: Enabling #PRIMARY cron jobs..."
"$CRON_MANAGER"
if [ $? -ne 0 ]; then
    log "ERROR: $CRON_MANAGER failed."
    log "       Restore crontabs manually from: $BACKUP_DIR"
    exit 1
fi

# --- Done ---
separator
log "SUCCESS: This server is now PRIMARY."
log "         All #PRIMARY cron jobs are ENABLED."
separator

exit 0
