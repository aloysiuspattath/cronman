#!/usr/bin/ksh
# =============================================================================
# cron_role_manager_aix.sh (AIX Optimized)
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
#   ./cron_role_manager_aix.sh              # uses /etc/server_role
#   ./cron_role_manager_aix.sh --dry-run    # preview changes without applying
#   ./cron_role_manager_aix.sh --status     # show current job classification
#
# SUPPORTS: AIX
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
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_role_manager] $1"
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
    target_user="$1"
    
    if [ "$(id -un)" = "$target_user" ]; then
        crontab_content=$(crontab -l 2>/dev/null)
    else
        crontab_content=$(crontab -l "$target_user" 2>/dev/null)
    fi
    
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

# --- Find valid users via spool ---
get_spool_users() {
    spool_dir="/var/spool/cron/crontabs"
    if [ -d "$spool_dir" ] && [ -r "$spool_dir" ]; then
        for f in "$spool_dir"/*; do
            [ -e "$f" ] || continue
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            # Skip hidden files or backups
            case "$fname" in
                .*|*~|*.bak) continue ;;
            esac
            echo "$fname"
        done
    else
        # Fallback to passwd if spool is unreadable
        awk -F: '$7 !~ /nologin|false|sync|halt|shutdown/ && $3 >= 0 { print $1 }' /etc/passwd
    fi
}

if [ "$STATUS_ONLY" = true ]; then
    echo ""
    echo "=========================================="
    echo "  Cron Job Status on: $HOSTNAME"
    echo "  Current Role      : $ROLE"
    echo "=========================================="
    echo ""
    
    if [ "$(id -u)" -eq 0 ]; then
        USER_LIST=$(get_spool_users | sort -u)
        for SYSTEM_USER in $USER_LIST; do
            show_user_status "$SYSTEM_USER"
        done
    else
        show_user_status "$(id -un)"
    fi
    exit 0
fi

# --- Process User Function ---
process_user() {
    target_user="$1"
    user_tmpfile="${TMPFILE}_${target_user}"
    
    # Dump current crontab handling AIX where -u is not supported
    if [ "$(id -un)" = "$target_user" ]; then
        crontab -l > "$user_tmpfile" 2>/dev/null
    else
        crontab -l "$target_user" > "$user_tmpfile" 2>/dev/null
    fi
    
    if [ ! -s "$user_tmpfile" ]; then
        rm -f "$user_tmpfile"
        return
    fi

    # Check if there are any #PRIMARY tags to process
    P_TAG="#[Pp][Rr][Ii][Mm][Aa][Rr][Yy]"
    if ! grep "${P_TAG}" "$user_tmpfile" >/dev/null 2>&1; then
        rm -f "$user_tmpfile"
        return
    fi

    log "Processing crontab for user: $target_user"

    # Apply role logic
    WILL_CHANGE=0
    
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
        chown "$target_user" "$user_tmpfile"
        if [ "$(id -un)" = "$target_user" ]; then
            if crontab "$user_tmpfile" >/dev/null 2>&1; then
                log "  Crontab updated successfully for $target_user."
            else
                log "  ERROR: Failed to apply crontab for $target_user."
            fi
        else
            # su without '-' to avoid executing interactive .profile scripts
            if su "$target_user" -c "crontab $user_tmpfile" >/dev/null 2>&1; then
                log "  Crontab updated successfully for $target_user."
            else
                log "  ERROR: Failed to apply crontab for $target_user."
            fi
        fi
    fi

    rm -f "$user_tmpfile"
}

# --- Execution ---
if [ "$(id -u)" -eq 0 ]; then
    log "Running as root. Discovering users with active crontabs..."
    USER_LIST=$(get_spool_users | sort -u)
    for SYSTEM_USER in $USER_LIST; do
        process_user "$SYSTEM_USER"
    done
else
    # Running as a normal user
    CURRENT_USER=$(id -un)
    log "Running as $CURRENT_USER. Updating personal crontab only."
    process_user "$CURRENT_USER"
fi

# --- Cleanup ---
rm -f "${TMPFILE}"*
log "Done."
exit 0
