#!/bin/bash
# =============================================================================
# cron_role_manager.sh
# DC-DR Cron Job Role Manager
#
# PURPOSE:
#   Enables or disables cron jobs tagged with #PRIMARY based on the server's
#   current role (PRIMARY or STANDBY). Jobs tagged with #ALWAYS are never
#   touched and run on both servers at all times.
#
# CRONTAB TAG CONVENTION:
#   #ALWAYS   → Job runs regardless of server role (never modified)
#   #PRIMARY  → Job runs only on the PRIMARY server (toggled by this script)
#
# EXAMPLE CRONTAB ENTRIES:
#   */5 * * * * /scripts/health_check.sh   #ALWAYS
#   0 2 * * *   /scripts/backup.sh         #PRIMARY
#
# ROLE FILE: /etc/server_role
#   Must contain either:  PRIMARY  or  STANDBY
#
# USAGE:
#   ./cron_role_manager.sh              # uses /etc/server_role
#   ./cron_role_manager.sh --dry-run    # preview changes without applying
#   ./cron_role_manager.sh --status     # show current job classification
#
# SUPPORTS: Linux and AIX
# =============================================================================

ROLE_FILE="/etc/server_role"
LOG_FILE="/var/log/dr_cron_manager.log"
TMPFILE="/tmp/crontab_mgr_$$.txt"
DRY_RUN=false
STATUS_ONLY=false

# --- Argument parsing ---
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --status)  STATUS_ONLY=true ;;
        --help)
            echo "Usage: $0 [--dry-run] [--status] [--help]"
            echo "  --dry-run   Preview changes without applying to crontab"
            echo "  --status    Show current job classification and exit"
            exit 0
            ;;
    esac
done

# --- Logging ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_role_manager] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

# --- Check role file ---
if [ ! -f "$ROLE_FILE" ]; then
    log "ERROR: Role file not found: $ROLE_FILE"
    log "       Create it with:  echo 'PRIMARY' > $ROLE_FILE"
    exit 1
fi

ROLE=$(cat "$ROLE_FILE" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

if [ "$ROLE" != "PRIMARY" ] && [ "$ROLE" != "STANDBY" ]; then
    log "ERROR: Invalid role '$ROLE' in $ROLE_FILE. Must be PRIMARY or STANDBY."
    exit 1
fi

HOSTNAME=$(hostname)
log "Server: $HOSTNAME | Role: $ROLE"

# --- Status mode ---
if [ "$STATUS_ONLY" = true ]; then
    echo ""
    echo "=========================================="
    echo "  Cron Job Status on: $HOSTNAME"
    echo "  Current Role      : $ROLE"
    echo "=========================================="
    echo ""
    crontab -l 2>/dev/null | awk '
        /#ALWAYS/  { gsub(/^####/, ""); print "  [ALWAYS  ] " $0 }
        /#PRIMARY/ {
            if (/^####/) {
                line = $0; sub(/^####/, "", line)
                print "  [DISABLED] " line
            } else {
                print "  [ACTIVE  ] " $0
            }
        }
    '
    echo ""
    exit 0
fi

# --- Dump current crontab ---
crontab -l > "$TMPFILE" 2>/dev/null
if [ $? -ne 0 ]; then
    log "WARNING: No existing crontab found for user $(whoami). Starting fresh."
    > "$TMPFILE"
fi

# --- Apply role logic ---
#
# SAFETY RULES for sed patterns:
#   1. Only lines containing the EXACT token '#PRIMARY' are ever matched.
#   2. Lines with #ALWAYS, plain comments, untagged jobs — completely untouched.
#   3. Already-disabled lines (####) are never double-commented.
#   4. Already-enabled lines are never double-enabled.
#
# Pattern breakdown:
#   Enable  : ^#### then anything then literal '#PRIMARY' at end of line
#   Disable : line must NOT start with # (so no plain comments)
#             then anything then literal '#PRIMARY' at end of line

if [ "$ROLE" = "PRIMARY" ]; then
    log "Enabling all #PRIMARY jobs..."

    # Show lines that WILL be changed (for audit trail)
    WILL_CHANGE=$(grep -c '^####.*#PRIMARY[[:space:]]*$' "$TMPFILE" 2>/dev/null || echo 0)
    log "Lines to enable: $WILL_CHANGE"

    # Remove #### only from lines that:
    #   - Start with ####
    #   - Contain #PRIMARY (exact, at end of line, optional trailing space)
    sed "s/^####\(.*#PRIMARY[[:space:]]*\)$/\1/" "$TMPFILE" > "${TMPFILE}.new"
    mv "${TMPFILE}.new" "$TMPFILE"

elif [ "$ROLE" = "STANDBY" ]; then
    log "Disabling all #PRIMARY jobs..."

    # Show lines that WILL be changed (for audit trail)
    WILL_CHANGE=$(grep -c '^[^#].*#PRIMARY[[:space:]]*$' "$TMPFILE" 2>/dev/null || echo 0)
    log "Lines to disable: $WILL_CHANGE"

    # Add #### only to lines that:
    #   - Do NOT start with # (skips already-commented and plain comment lines)
    #   - Contain #PRIMARY (exact, at end of line, optional trailing space)
    sed "s/^\([^#].*#PRIMARY[[:space:]]*\)$/####\1/" "$TMPFILE" > "${TMPFILE}.new"
    mv "${TMPFILE}.new" "$TMPFILE"
fi

# --- Apply or preview ---
if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN MODE: Changes NOT applied. Preview of new crontab:"
    echo "-----------------------------------------------------------"
    cat "$TMPFILE"
    echo "-----------------------------------------------------------"
else
    crontab "$TMPFILE"
    if [ $? -eq 0 ]; then
        log "Crontab updated successfully."
    else
        log "ERROR: Failed to apply crontab. Manual review required: $TMPFILE"
        exit 1
    fi
fi

# --- Cleanup ---
rm -f "$TMPFILE"
log "Done."
exit 0
