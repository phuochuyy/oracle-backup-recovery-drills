#!/bin/bash
# Backup job for orcl3.
#   0 | 1 : level 0 / level 1 incremental of the whole CDB + archived logs not yet backed up
#   arch  : only archived logs not yet backed up (every 30 min: the deletion policy needs them backed up
#           before the housekeeping job may delete them)
# usage (on prm3, as oracle): backup.sh 0|1|arch     log: /u02/backup/logs/backup_<mode>_<time>.log
. ~/.bash_profile >/dev/null 2>&1
set -eu
mode=$1; mkdir -p /u02/backup/orcl3 /u02/backup/logs
exec 9>/u02/backup/logs/.backup.lock
flock -n 9 || { echo "another backup is running, skip"; exit 0; }
log=/u02/backup/logs/backup_${mode}_$(date +%Y%m%d_%H%M%S).log
case $mode in
  0|1)  cmd="backup incremental level $mode database tag 'L$mode' plus archivelog not backed up 1 times tag 'ARCH';" ;;
  arch) cmd="backup archivelog all not backed up 1 times tag 'ARCH';" ;;
  *)    echo "mode must be 0, 1 or arch"; exit 2 ;;
esac
# Persistent timers catch up a missed run right at boot: on 2026-10-29 the level 1 started at 12:02:55,
# before the instance, and failed with ORA-01034 — so wait (max 15 min) for the database to be open
for i in $(seq 1 90); do
  om=$(printf 'set heading off feedback off\nselect open_mode from v$database;\nexit\n' | sqlplus -s / as sysdba 2>/dev/null | grep -oE 'READ WRITE|MOUNTED|READ ONLY' | head -n 1)
  [ "$om" = "READ WRITE" ] && break; sleep 10
done
[ "${om:-}" = "READ WRITE" ] || { echo "database not open after 15 min (open_mode=${om:-none}), backup not run"; exit 1; }
start=$(date +%s)
rc=0
rman target / log="$log" <<RMAN || rc=$?
$cmd
delete noprompt obsolete;
RMAN
echo "mode $mode rc=$rc elapsed $(( $(date +%s) - start )) s, log $log"
grep -E "RMAN-|ORA-" "$log" | grep -vE "RMAN-08120|RMAN-08137" | head -n 5 || true
exit $rc
