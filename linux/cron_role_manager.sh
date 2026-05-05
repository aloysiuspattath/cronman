#!/bin/bash
# =============================================================================
# cron_role_manager.sh (Linux Optimized)
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
# ROLE FILE: /etc/server_role
#   Must contain either:  PRIMARY  or  STANDBY
#
# USAGE:
#   ./cron_role_manager.sh              # uses /etc/server_role
#   ./cron_role_manager.sh --dry-run    # preview changes without applying
#   ./cron_role_manager.sh --status     # show current job classification
#
# SUPPORTS: Linux
# =============================================================================

ROLE_FILE="/etc/server_role"
LOG_FILE="/var/log/dr_cron_manager.log"
TMPFILE="/tmp/crontab_mgr_$$.txt"
DRY_RUN=false
STATUS_ONLY=false

# --- Argument parsing ---
for arg in "$@"; do
    case "$arg" in
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
show_user_status() {
    local target_user="$1"
    local crontab_content
    crontab_content=$(crontab -u "$target_user" -l 2>/dev/null)
    
    if [ -z "$crontab_content" ]; then
        return
    fi
    
    # Check if there are any managed tags
    if ! echo "$crontab_content" | awk 'tolower($0) ~ /#always/ || tolower($0) ~ /#primary/ {found=1; exit} END {if(found) exit 0; else exit 1}'; then
        return
    fi
    
    echo "  --- [ $target_user ] ---"
    echo "$crontab_content" | awk '
        tolower($0) ~ /#always/  { gsub(/^####/, ""); print "  [ALWAYS  ] " $0 }
        tolower($0) ~ /#primary/ {
            if (/^####/) {
                line = $0; sub(/^####/, "", line)
                print "  [DISABLED] " line
            } else {
                print "  [ACTIVE  ] " $0
            }
        }
    '
    echo ""
}

# --- Find valid users via passwd ---
get_valid_users() {
    awk -F: '$7 !~ /nologin|false|sync|halt|shutdown/ && $3 >= 0 { print $1 }' /etc/passwd
}

if [ "$STATUS_ONLY" = true ]; then
    echo ""
    echo "=========================================="
    echo "  Cron Job Status on: $HOSTNAME"
    echo "  Current Role      : $ROLE"
    echo "=========================================="
    echo ""
    
    if [ "$(id -u)" -eq 0 ]; then
        USER_LIST=$(get_valid_users | sort -u)
        for SYSTEM_USER in $USER_LIST; do
            show_user_status "$SYSTEM_USER"
        done
    else
        show_user_status "$(whoami)"
    fi
    exit 0
fi

# --- Process User Function ---
process_user() {
    local target_user="$1"
    local user_tmpfile="${TMPFILE}_${target_user}"
    
    # Dump current crontab
    crontab -u "$target_user" -l > "$user_tmpfile" 2>/dev/null
    
    if [ ! -s "$user_tmpfile" ]; then
        rm -f "$user_tmpfile"
        return
    fi

    # Check if there are any #PRIMARY tags to process
    local P_TAG="#[Pp][Rr][Ii][Mm][Aa][Rr][Yy]"
    if ! grep "${P_TAG}" "$user_tmpfile" >/dev/null 2>&1; then
        rm -f "$user_tmpfile"
        return
    fi

    log "Processing crontab for user: $target_user"

    # Apply role logic
    local WILL_CHANGE=0
    
    if [ "$ROLE" = "PRIMARY" ]; then
        WILL_CHANGE=$(grep -c "^####.*${P_TAG}" "$user_tmpfile" 2>/dev/null)
        [ -z "$WILL_CHANGE" ] && WILL_CHANGE=0
        if [ "$WILL_CHANGE" -gt 0 ]; then
            log "  Lines to enable: $WILL_CHANGE"
            sed "/^####.*${P_TAG}/ s/^####//" "$user_tmpfile" > "${user_tmpfile}.new"
            mv "${user_tmpfile}.new" "$user_tmpfile"
        fi
    elif [ "$ROLE" = "STANDBY" ]; then
        WILL_CHANGE=$(grep -c "^[^#].*${P_TAG}" "$user_tmpfile" 2>/dev/null)
        [ -z "$WILL_CHANGE" ] && WILL_CHANGE=0
        if [ "$WILL_CHANGE" -gt 0 ]; then
            log "  Lines to disable: $WILL_CHANGE"
            sed "/^[^#].*${P_TAG}/ s/^/####/" "$user_tmpfile" > "${user_tmpfile}.new"
            mv "${user_tmpfile}.new" "$user_tmpfile"
        fi
    fi

    # Apply or preview
    if [ "$WILL_CHANGE" -eq 0 ]; then
        log "  No changes required for $target_user."
    elif [ "$DRY_RUN" = true ]; then
        log "  DRY-RUN MODE: Changes NOT applied for $target_user. Preview:"
        echo "  --- [ $target_user ] ----------------------------------------"
        cat "$user_tmpfile"
        echo "  -----------------------------------------------------------"
    else
        if crontab -u "$target_user" "$user_tmpfile" 2>/dev/null; then
            log "  Crontab updated successfully for $target_user."
        else
            log "  ERROR: Failed to apply crontab for $target_user."
        fi
    fi

    rm -f "$user_tmpfile"
}

# --- Execution ---
if [ "$(id -u)" -eq 0 ]; then
    log "Running as root. Discovering users with active crontabs..."
    USER_LIST=$(get_valid_users | sort -u)
    for SYSTEM_USER in $USER_LIST; do
        process_user "$SYSTEM_USER"
    done
else
    # Running as a normal user
    CURRENT_USER=$(whoami)
    log "Running as $CURRENT_USER. Updating personal crontab only."
    process_user "$CURRENT_USER"
fi

# --- Cleanup ---
rm -f "${TMPFILE}"*
log "Done."
exit 0
