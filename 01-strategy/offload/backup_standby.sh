#!/bin/bash
# Level 0/1 backup taken on the standby (offload), recorded in the recovery catalog so the primary
# knows about it. usage on stb1 as oracle: RCO_PASSWORD=... ./backup_standby.sh 0|1
. ~/.bash_profile >/dev/null 2>&1
set -eu
: "${RCO_PASSWORD:?}"
lvl=$1; mkdir -p /u02/backup/orcl /u02/backup/logs
log=/u02/backup/logs/backup_stb_L${lvl}_$(date +%Y%m%d_%H%M%S).log
start=$(date +%s); rc=0
rman target / catalog "rco/${RCO_PASSWORD}@//prm3.rac:1521/rcat.rac" log="$log" <<RMAN || rc=$?
backup incremental level $lvl database tag 'STB_L$lvl' plus archivelog not backed up 1 times tag 'STB_ARCH';
RMAN
echo "standby level $lvl rc=$rc elapsed $(( $(date +%s) - start )) s, log $log"
grep -E "RMAN-|ORA-" "$log" | grep -vE "RMAN-08120|RMAN-08137" | head -n 5 || true
exit $rc
