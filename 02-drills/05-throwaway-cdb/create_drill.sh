#!/bin/bash
# Throw-away CDB "DRILL" on stb3 for the drills that need RESETLOGS or destroy the whole database
# (they must never run on a database that has a standby or a GoldenGate capture).
# Backup-based DUPLICATE: copy orcl3's backups to stb3, duplicate from that location, skipping the PDBs
# the drills do not need. The standby instance ORCL3_STB on stb3 must be stopped first (RAM).
# usage (from the host): ./create_drill.sh
set -eu
P3="ssh -o BatchMode=yes oracle@prm3"; S3="ssh -o BatchMode=yes oracle@stb3"
log=$(cd "$(dirname "$0")" && pwd)/create_drill.log; : > "$log"
say() { echo "$(date +%T) $*" | tee -a "$log"; }

say "copy orcl3 backups prm3 -> stb3:/u02/drill/backup (skipped if already there)"
$S3 "ls /u02/drill/backup | grep -q ." || $P3 "scp -q -o BatchMode=yes /u02/backup/orcl3/* stb3:/u02/drill/backup/"
$S3 "du -sh /u02/drill/backup" | tee -a "$log"

say "parameter file + directories for DRILL"
$S3 'mkdir -p /u02/oradata/DRILL /u02/oradata/DRILL_FRA /u01/app/oracle/admin/DRILL/adump
cat > /u01/app/oracle/product/23.26.0/dbhome_1/dbs/initDRILL.ora <<PFILE
db_name=DRILL
enable_pluggable_database=true
compatible=23.6.0
sga_target=1200M
pga_aggregate_target=300M
processes=200
db_create_file_dest=/u02/oradata/DRILL
db_recovery_file_dest=/u02/oradata/DRILL_FRA
db_recovery_file_dest_size=6G
audit_file_dest=/u01/app/oracle/admin/DRILL/adump
PFILE
cat /u01/app/oracle/product/23.26.0/dbhome_1/dbs/initDRILL.ora | wc -l'

# - UNDO TABLESPACE: without catalog and target connection RMAN must be told the root's undo tablespace
#   when PDBs are skipped (RMAN-05521 on the first run).
# - NEVER add NOFILENAMECHECK here: the standby ORCL3_STB on this host has its datafiles under the same
#   paths as orcl3; with db_create_file_dest set, DRILL gets new OMF names under /u02/oradata/DRILL.
# - a failed run leaves the auxiliary instance MOUNTED on a copy of orcl3's control file: abort it and
#   remove that copy before retrying.
$S3 ". ~/.bash_profile >/dev/null 2>&1; export ORACLE_SID=DRILL; echo 'shutdown abort' | sqlplus -s / as sysdba >/dev/null 2>&1; rm -rf /u02/oradata/DRILL/*"
say "start the auxiliary instance and duplicate (skip PERF, GGREPL, RCAT)"
start=$(date +%s)
$S3 ". ~/.bash_profile >/dev/null 2>&1; export ORACLE_SID=DRILL
echo 'startup nomount' | sqlplus -s / as sysdba
rman auxiliary / <<RMAN
duplicate database to drill
  skip pluggable database perf, ggrepl, rcat
  undo tablespace 'UNDOTBS1'
  backup location '/u02/drill/backup';
RMAN" >> "$log" 2>&1 || true
say "duplicate took $(( $(date +%s) - start )) s"
grep -E "RMAN-0|ORA-|Finished Duplicate|database opened" "$log" | tail -n 5
$S3 ". ~/.bash_profile >/dev/null 2>&1; export ORACLE_SID=DRILL; printf \"select name, open_mode, dbid from v\\\$database;\nselect name, open_mode from v\\\$pdbs;\nexit\n\" | sqlplus -s / as sysdba" | tee -a "$log"
