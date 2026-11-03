#!/bin/bash
# Scheduled backup of the RAC (systemd timers on every RAC node: prm1, prm2, stb1, stb2). It runs only where it should:
#   - on the STANDBY (offload), never on the primary — after a failover the roles swap, and so does the node
#   - on one node of the standby cluster (the first one with a running instance); the others exit 0
#   - only when the recovery catalog (RCAT on prm3) answers
# Before every backup: RESYNC CATALOG connected to the primary. After a failover the standby's backup is
# otherwise not recorded (rc=0, only ORA-20079 in the log — the level 0 of 2026-11-01).
# Credentials: auto-login wallet (secure external password store) in ~/rman_tns with its own TNS_ADMIN, made by
# install_rac_backup.sh — no password in any file or on any command line. The database home's sqlnet.ora is
# left alone (labctl manages it).
# usage (as oracle): rac_backup_job.sh 0|1        log: /u02/backup/logs/rac_L<lvl>_<time>.log
. ~/.bash_profile >/dev/null 2>&1
set -eu
lvl=${1:?usage: rac_backup_job.sh 0|1}
case $lvl in 0|1) ;; *) echo "level must be 0 or 1"; exit 2 ;; esac
export TNS_ADMIN=$HOME/rman_tns
me=$(hostname -s)
mkdir -p /u02/backup/orcl /u02/backup/logs

dbinfo() {
  sqlplus -s / as sysdba 2>/dev/null <<'SQL' | grep -E '^(PRIMARY|PHYSICAL_STANDBY) ' | head -n 1
set heading off feedback off pages 0 lines 200
select replace(database_role, ' ', '_') || ' ' || db_unique_name || ' ' || replace(open_mode, ' ', '_') from v$database;
SQL
}
# a run caught up at boot (Persistent=true) may start before the instance: wait up to 15 min
info=""; for i in $(seq 1 90); do info=$(dbinfo); [ -n "$info" ] && break; sleep 10; done
[ -n "$info" ] || { echo "$me: no instance after 15 min, backup NOT run"; exit 1; }
read -r role dbu om <<< "$info"
[ "$role" = PHYSICAL_STANDBY ] || { echo "$me: $dbu is $role — the RAC is backed up on its standby, skip"; exit 0; }
first=$(srvctl status database -db "$dbu" | awk '/is running on node/ {print $NF}' | sort | head -n 1)
[ "$first" = "$me" ] || { echo "$me: $first takes the backup for $dbu, skip"; exit 0; }
case $dbu in orcl_stb) prim=orcl ;; orcl) prim=orcl_stb ;; *) echo "unknown database $dbu"; exit 2 ;; esac

exec 9>/u02/backup/logs/.rac_backup.lock
flock -w 1800 9 || { echo "$me: another RAC backup still running after 30 min, this one NOT run"; exit 1; }
ts=$(date +%Y%m%d_%H%M%S); log=/u02/backup/logs/rac_L${lvl}_$ts.log; rlog=/u02/backup/logs/rac_resync_$ts.log
start=$(date +%s); rc=0
# Two RMAN sessions: RMAN refuses a second CONNECT TARGET in one session (RMAN-06167) and goes on with the first
# target — the first version of this job backed up the PRIMARY that way (2026-11-04 02:53, 2.9 GB into its FRA).
rman log="$rlog" <<RMAN || { echo "$me: RESYNC CATALOG from the primary $prim failed, backup NOT run (log $rlog)"; exit 1; }
connect target /@$prim
connect catalog /@rcat_lab
resync catalog;
RMAN
rman log="$log" <<RMAN || rc=$?
connect target /@$dbu
connect catalog /@rcat_lab
backup incremental level $lvl database tag 'STB_L$lvl' plus archivelog not backed up 1 times tag 'STB_ARCH';
RMAN
# the backup must have run on this standby's instances, never on the primary's
chan=$(grep -oE "instance=[a-z0-9_]+" "$log" | sort -u | sed 's/^instance=//')
bad=$(echo "$chan" | grep -vxE "${dbu}[0-9]+" || true)   # orcl_stb1 must not pass as orcl
[ -n "$chan" ] && [ -z "$bad" ] || { echo "$me: channels not only on $dbu instances ($(echo $chan)) — check $log"; rc=1; }
# rc=0 is not enough: a backup the catalog did not record is useless for a restore through the catalog
if grep -q "ORA-20079" "$log"; then echo "ORA-20079: backup NOT recorded in the catalog"; rc=1; fi
echo "$me: $dbu standby level $lvl rc=$rc elapsed $(( $(date +%s) - start )) s, log $log"
grep -E "RMAN-|ORA-" "$log" | grep -vE "RMAN-08120|RMAN-08137" | head -n 5 || true
exit $rc
