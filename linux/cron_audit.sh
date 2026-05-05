#!/bin/bash
# =============================================================================
# cron_audit.sh
# Audit and display cron job classification across all users
#
# PURPOSE:
#   Shows the status of all DR-managed (#PRIMARY) cron jobs for every user.
#   Labels each job as ACTIVE or DISABLED, and warns on mismatches.
#   Output is written to both stdout and a timestamped audit log.
#
# USAGE:
#   ./cron_audit.sh              # audit all users
#   ./cron_audit.sh --user root  # audit a single user
#   ./cron_audit.sh --summary    # counts only (also logged)
#
# LOG:  /var/log/dr_cron_audit.log
# NOTE: Run as root to see all users' crontabs
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
ROLE=$(cat "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
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
    local user=$1
    local cron_content
    cron_content=$(crontab -u "$user" -l 2>/dev/null)
    [ $? -ne 0 ] && return   # user has no crontab
    [ -z "$cron_content" ] && return

    local active=0 disabled=0

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
        /#PRIMARY/ {
            if (/^####/) {
                line = $0; sub(/^####/, "", line)
                printf "    \033[31m[DISABLED]\033[0m %s\n", line
            } else {
                printf "    \033[36m[ACTIVE  ]\033[0m %s\n", $0
            }
        }
    '
}

# =============================================================================
# MAIN — pipe all output to both stdout and the audit log
# =============================================================================
{
    print_header

    if [ -n "$TARGET_USER" ]; then
        audit_user "$TARGET_USER"
    else
        if [ "$(id -u)" -ne 0 ]; then
            echo ""
            echo "  NOTE: Not running as root — showing current user ($(whoami)) only."
            echo "        Run as root to audit all users."
            audit_user "$(whoami)"
        else
            USER_LIST=$(cat /etc/passwd | awk -F: '
                $7 !~ /nologin|false|sync|halt|shutdown/ && $3 >= 0 { print $1 }
            ')
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
