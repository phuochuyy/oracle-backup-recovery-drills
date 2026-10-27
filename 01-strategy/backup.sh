#!/bin/bash
# Backup job for orcl3: level 0 or level 1 incremental + archived logs not yet backed up.
# usage (on prm3, as oracle): ./backup.sh 0|1     log: /u02/backup/logs/backup_<level>_<time>.log
. ~/.bash_profile >/dev/null 2>&1
set -eu
lvl=$1; mkdir -p /u02/backup/orcl3 /u02/backup/logs
log=/u02/backup/logs/backup_L${lvl}_$(date +%Y%m%d_%H%M%S).log
start=$(date +%s)
rman target / log="$log" <<RMAN
backup incremental level $lvl database tag 'L$lvl' plus archivelog not backed up 1 times tag 'ARCH';
delete noprompt obsolete;
RMAN
rc=$?
echo "level $lvl rc=$rc elapsed $(( $(date +%s) - start )) s, log $log"
grep -E "RMAN-|ORA-" "$log" | grep -vE "RMAN-08120|RMAN-08137" | head -n 5 || true
exit $rc
