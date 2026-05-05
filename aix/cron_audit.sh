#!/usr/bin/ksh
# =============================================================================
# cron_audit.sh (AIX)
# Audit and display cron job classification across all users
# =============================================================================

LOG_FILE="/var/log/dr_cron_manager.log"
AUDIT_LOG="/var/log/dr_cron_audit.log"
TARGET_USER=""
SUMMARY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --user)    TARGET_USER="$2"; shift 2 ;;
        --summary) SUMMARY_ONLY=true; shift ;;
        --help)
            echo "Usage: $0 [--user <username>] [--summary]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

ROLE_FILE="/etc/server_role"
ROLE=$(tr -d '[:space:]' < "$ROLE_FILE" 2>/dev/null | tr '[:lower:]' '[:upper:]')
HOSTNAME=$(hostname)

TOTAL_ACTIVE=0
TOTAL_DISABLED=0

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║  %-60s  ║\n" "Cron Audit - $(date '+%Y-%m-%d %H:%M:%S')"
    printf "║  %-60s  ║\n" "Server  : $HOSTNAME"
    printf "║  %-60s  ║\n" "Role    : ${ROLE:-UNKNOWN}"
    printf "║  %-60s  ║\n" "Log     : $AUDIT_LOG"
    echo "╚══════════════════════════════════════════════════════════════╝"
}

audit_user() {
    user=$1
    if [ "$(id -un)" = "$user" ]; then
        cron_content=$(crontab -l 2>/dev/null)
    else
        cron_content=$(crontab -l "$user" 2>/dev/null)
    fi
    [ -z "$cron_content" ] && return

    active=0
    disabled=0

    # Count #PRIMARY tagged jobs only
    active=$(echo "$cron_content"   | grep -i '#PRIMARY' | grep -cv '^####')
    disabled=$(echo "$cron_content" | grep -i '#PRIMARY' | grep -c '^####')

    TOTAL_ACTIVE=$((TOTAL_ACTIVE + active))
    TOTAL_DISABLED=$((TOTAL_DISABLED + disabled))

    if [ "$SUMMARY_ONLY" = true ]; then return; fi

    # Print per-user (only #PRIMARY tagged jobs)
    echo ""
    echo "  ── User: $user ─────────────────────────────────────────"
    echo "$cron_content" | awk '
        tolower($0) ~ /#primary/ {
            if (/^####/) {
                line = $0; sub(/^####/, "", line)
                printf "    \033[31m[DISABLED]\033[0m %s\n", line
            } else {
                printf "    \033[36m[ACTIVE  ]\033[0m %s\n", $0
            }
        }
    '
}

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

{
    print_header

    if [ -n "$TARGET_USER" ]; then
        audit_user "$TARGET_USER"
    else
        if [ "$(id -u)" -ne 0 ]; then
            echo ""
            echo "  NOTE: Not running as root — showing current user ($(id -un)) only."
            echo "        Run as root to audit all users."
            audit_user "$(id -un)"
        else
            USER_LIST=$(get_spool_users | sort -u)
            for USER in $USER_LIST; do
                audit_user "$USER"
            done
        fi
    fi

    echo ""
    echo "  ── Summary ──────────────────────────────────────────────────"
    echo "    [ACTIVE  ] Active PRIMARY jobs  : $TOTAL_ACTIVE"
    echo "    [DISABLED] Disabled PRIMARY jobs : $TOTAL_DISABLED"
    echo ""

    if [ "$ROLE" = "PRIMARY" ] && [ "$TOTAL_DISABLED" -gt 0 ]; then
        echo "  ⚠ WARNING: Server is PRIMARY but $TOTAL_DISABLED job(s) are still disabled."
        echo "             Run: make_primary.sh to fix."
    fi
    if [ "$ROLE" = "STANDBY" ] && [ "$TOTAL_ACTIVE" -gt 0 ]; then
        echo "  ⚠ WARNING: Server is STANDBY but $TOTAL_ACTIVE PRIMARY job(s) are still active."
        echo "             Run: make_standby.sh to fix."
    fi
    echo ""

} | tee -a "$AUDIT_LOG"

exit 0
