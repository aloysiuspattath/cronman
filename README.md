# DC-DR Cron Job Manager

Automates enabling/disabling cron jobs across Primary and Standby servers during DR drills or failovers — for **Linux and AIX**.

---

## How It Works

Jobs in the crontab are tagged with a comment at the end of the line:

| Tag | Meaning |
|---|---|
| `#ALWAYS` | Runs on every server, always. Never touched. |
| `#PRIMARY` | Runs only on the current PRIMARY server. Toggled on switch. |

**When a server is STANDBY**, lines tagged `#PRIMARY` get `####` prepended:
```
####0 2 * * * /scripts/backup.sh  #PRIMARY   ← disabled
```
**When a server becomes PRIMARY**, `####` is removed and the job runs again.

---

## Files

| Script | Purpose |
|---|---|
| `make_primary.sh` | Makes **this** server PRIMARY — enables all `#PRIMARY` cron jobs |
| `make_standby.sh` | Makes **this** server STANDBY — disables all `#PRIMARY` cron jobs |
| `cron_role_manager.sh` | Core engine called by the above two scripts |
| `cron_backup.sh` | Backs up crontabs for **all users** before any change |
| `cron_restore.sh` | Restores all users' crontabs from a backup |
| `cron_audit.sh` | Shows job status across all users with warnings |

---

## Setup

### Step 1 — Deploy scripts to each server

Log into each server individually and clone the repo:

```bash
# Run this on each server (DC and DR separately):
git clone https://github.com/aloysiuspattath/cronman.git /tmp/cronman
cp /tmp/cronman/*.sh /usr/local/bin/
chmod +x /usr/local/bin/make_primary.sh \
         /usr/local/bin/make_standby.sh \
         /usr/local/bin/cron_role_manager.sh \
         /usr/local/bin/cron_backup.sh \
         /usr/local/bin/cron_restore.sh \
         /usr/local/bin/cron_audit.sh
```

### Step 2 — Set the initial role on each server
```bash
# On DC server (normally primary):
echo "PRIMARY" > /etc/server_role

# On DR server (normally standby):
echo "STANDBY" > /etc/server_role
```

### Step 3 — Tag jobs in each user's crontab

Edit crontabs (`crontab -e`) and add tags at the end of each line:

```cron
# Jobs that ALWAYS run (on both servers):
*/5 * * * *   /scripts/health_check.sh   #ALWAYS
0 * * * *     /scripts/log_rotate.sh     #ALWAYS

# Jobs that run ONLY on PRIMARY:
0 2 * * *     /scripts/db_backup.sh      #PRIMARY
0 6 * * 1     /scripts/weekly_report.sh  #PRIMARY
30 3 * * *    /scripts/data_sync.sh      #PRIMARY
```

### Step 4 — Apply the initial state on both servers
```bash
# Applies crontab based on server_role — run once after tagging
sudo /usr/local/bin/cron_role_manager.sh
```

### Step 5 — Verify
```bash
sudo /usr/local/bin/cron_audit.sh
```

---

## DR Drill Procedure

> Log into each server individually. No SSH between servers required.

### Start of Drill (DR becomes primary)
```bash
# Step 1 — Log into DC server and step it down:
sudo make_standby.sh

# Step 2 — Log into DR server and activate it:
sudo make_primary.sh
```

### End of Drill (DC returns to primary)
```bash
# Step 1 — Log into DR server and step it down:
sudo make_standby.sh

# Step 2 — Log into DC server and activate it:
sudo make_primary.sh
```

> **Tip:** Use `--dry-run` to preview what will change before committing:
> `sudo make_primary.sh --dry-run`

---

## Individual Commands

```bash
# Preview changes without applying (safe to test)
make_primary.sh --dry-run
make_standby.sh --dry-run

# Show job status on current server
cron_audit.sh

# Show job status for a specific user only
cron_audit.sh --user oracle

# Manually back up all crontabs
cron_backup.sh

# List available backups
cron_backup.sh --list

# Restore all crontabs from a backup
cron_restore.sh --backup-dir /var/backups/cron_dr/20260320_183000_dc-server

# Restore a single user's crontab
cron_restore.sh --backup-dir <dir> --user oracle
```

---

## Backup Location

All backups are saved to: `/var/backups/cron_dr/<timestamp>_<hostname>/`

Each backup contains:
- `user_<username>.cron` — one file per user
- `system_cron/` — copy of `/etc/cron.d`, `/etc/cron.daily`, etc.
- `metadata.txt` — role, hostname, timestamp at time of backup
- `HOW_TO_RESTORE.txt` — restore instructions

---

## Log Files

| File | Contents |
|---|---|
| `/var/log/dr_cron_manager.log` | All role switches and backup events |
| `/var/log/dr_switchover.log` | Switchover orchestration events |

---

## AIX Notes

- AIX uses `/var/spool/cron/crontabs/` — `cron_backup.sh` handles this automatically
- `sed -i` is not available on AIX — all scripts use the portable `sed + temp file` approach
- `crontab -u <user>` works the same on AIX as Linux

---

## Crontab Example (copy-paste ready)

```cron
# -------------------------------------------------------
# DC-DR MANAGED CRONTAB — use #ALWAYS or #PRIMARY tags
# Managed by: /usr/local/bin/cron_role_manager.sh
# -------------------------------------------------------

# ALWAYS running (both PRIMARY and STANDBY):
*/5 * * * *   /scripts/health_check.sh    #ALWAYS
0 * * * *     /scripts/log_rotate.sh      #ALWAYS

# PRIMARY only (disabled automatically on STANDBY):
0 2 * * *     /scripts/db_backup.sh       #PRIMARY
0 6 * * 1     /scripts/weekly_report.sh   #PRIMARY
30 3 * * *    /scripts/data_sync.sh       #PRIMARY
```
