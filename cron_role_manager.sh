#!/usr/bin/bash
###############################################################################
# cron_role_manager.sh
# DC-DR Cron Job Role Manager
###############################################################################

ROLE_FILE="/etc/server_role"
LOG_FILE="/var/log/dr_cron_manager.log"
TMPFILE="/tmp/crontab_mgr_$$.txt"

DRY_RUN=false
STATUS_ONLY=false

###############################################################################
# Argument parsing
###############################################################################
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --status)  STATUS_ONLY=true ;;
    --help)
      echo "Usage: $0 [--dry-run] [--status] [--help]"
      exit 0
      ;;
  esac
done

###############################################################################
# Logging
###############################################################################
log() {
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] [cron_role_manager] $1"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

###############################################################################
# Validate role file
###############################################################################
if [ ! -f "$ROLE_FILE" ]; then
  log "ERROR: Role file not found: $ROLE_FILE"
  exit 1
fi

ROLE=$(cat "$ROLE_FILE" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

if [ "$ROLE" != "PRIMARY" ] && [ "$ROLE" != "STANDBY" ]; then
  log "ERROR: Invalid role '$ROLE'. Must be PRIMARY or STANDBY."
  exit 1
fi

HOSTNAME=$(hostname)
log "Server: $HOSTNAME | Role: $ROLE"

###############################################################################
# Status mode
###############################################################################
if [ "$STATUS_ONLY" = true ]; then
  echo ""
  echo "Cron Job Status on: $HOSTNAME"
  echo "Current Role     : $ROLE"
  echo ""

  crontab -l 2>/dev/null | awk '
    /#ALWAYS/ {
      gsub(/^####/, "", $0)
      print "[ALWAYS ] " $0
    }
    /#PRIMARY/ {
      if ($0 ~ /^####/) {
        sub(/^####/, "", $0)
        print "[DISABLED] " $0
      } else {
        print "[ACTIVE ] " $0
      }
    }
  '
  echo ""
  exit 0
fi

###############################################################################
# Dump current crontab
###############################################################################
if ! crontab -l > "$TMPFILE" 2>/dev/null; then
  log "WARNING: No existing crontab found. Starting empty."
  : > "$TMPFILE"
fi

###############################################################################
# Apply role logic
###############################################################################
if [ "$ROLE" = "PRIMARY" ]; then
  log "Enabling all #PRIMARY jobs"
  sed -e '/^####.*#PRIMARY/s/^####//' "$TMPFILE" > "${TMPFILE}.new"
else
  log "Disabling all #PRIMARY jobs"
  sed -e '/^[^#].*#PRIMARY/s/^/####/' "$TMPFILE" > "${TMPFILE}.new"
fi

###############################################################################
# Apply or preview
###############################################################################
if [ "$DRY_RUN" = true ]; then
  log "DRY-RUN MODE: no changes applied"
  echo "------------------------------------------------------------"
  cat "${TMPFILE}.new"
  echo "------------------------------------------------------------"
else
  if crontab "${TMPFILE}.new"; then
    log "Crontab updated successfully"
  else
    log "ERROR: Failed to update crontab"
    exit 1
  fi
fi

###############################################################################
# Cleanup
###############################################################################
rm -f "$TMPFILE" "${TMPFILE}.new"
log "Done."
exit 0
