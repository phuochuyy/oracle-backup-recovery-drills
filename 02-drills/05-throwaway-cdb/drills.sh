#!/bin/bash
# Destructive drills on the throw-away CDB DRILL (stb3). Each drill breaks something for real,
# recovers it, then checks DRILLPDB's BANKDB checksums. RTO = from the failure being visible to the
# database open with verified data.
# usage (from the host): ./drills.sh prep | 5a | 5b | 5c | 5d | 5e | 5f
set -eu
case_=$1
dir=$(cd "$(dirname "$0")" && pwd); out=$dir/run-$case_.log; : > "$out"
say() { echo "$(date +%T) $*" | tee -a "$out"; }
ts() { date +%s.%N; }
S="ssh -o BatchMode=yes oracle@stb3"
ENV=". ~/.bash_profile >/dev/null 2>&1; export ORACLE_SID=DRILL"
OH=/u01/app/oracle/product/23.26.0/dbhome_1
sql()  { $S "$ENV; sqlplus -s / as sysdba" 2>&1 | tee -a "$out"; }
rman() { $S "$ENV; rman target /" >> "$out" 2>&1 || true; }
val()  { printf "set heading off feedback off pages 0 lines 500\n$1\nexit\n" | $S "$ENV; sqlplus -s / as sysdba" | grep -vE "^$" | head -n 50; }
verify() { $S "cd ~/brlab; VERIFY_SID=DRILL BANKDB_DIR=~/bankdb ./04-scripts/verify_drillpdb.sh" | tee -a "$out"; }
rto() { say "RTO $(printf '%.0f' $(echo "$(ts) - $1" | bc)) s ($case_)"; }
errs() { grep -E "RMAN-0[0-9]|ORA-" "$out" | grep -vE "RMAN-08120|RMAN-08137|$1" | head -n 5 || true; }

case $case_ in
prep)
  say "spfile from pfile, restart on spfile, flashback on, controlfile autobackup, level 0"
  printf "create spfile from pfile;\nshutdown immediate\nstartup\nalter database flashback on;\nselect log_mode, flashback_on from v\$database;\nexit\n" | sql >/dev/null
  # host disk is tight: replace the 6 x 200 MB redo logs inherited from orcl3 by 3 x 64 MB
  sql >/dev/null <<'SQL'
alter database add logfile size 64m;
alter database add logfile size 64m;
alter database add logfile size 64m;
begin
  for i in 1 .. 8 loop execute immediate 'alter system switch logfile'; end loop;
  execute immediate 'alter system checkpoint';
  for g in (select group# from v$log where bytes > 100*1024*1024 and status = 'INACTIVE') loop
    execute immediate 'alter database drop logfile group ' || g.group#;
  end loop;
end;
/
select group#, bytes/1048576 mb, status from v$log;
exit
SQL
  rman <<'RMAN'
configure controlfile autobackup on;
configure controlfile autobackup format for device type disk to '/u02/drill/drill_bkp/cf_%F';
configure channel device type disk format '/u02/drill/drill_bkp/%d_%T_%U';
configure device type disk parallelism 2 backup type to compressed backupset;
configure compression algorithm 'BASIC';
backup database plus archivelog;
RMAN
  errs XXX
  # without SAVE STATE the PDBs stay MOUNTED after every restart (drill 5b's first run "failed" on that)
  printf "alter pluggable database all open;\nalter pluggable database all save state;\nexit\n" | sql >/dev/null
  say "DBID $(val 'select dbid from v$database;')"
  $S "du -sh /u02/drill/drill_bkp" | tee -a "$out" ;;

5a)
  dbid=$(val 'select dbid from v$database;')
  cfs=$(val 'select name from v$controlfile;')
  say "shutdown abort and delete all control files: $(echo $cfs)"
  printf "shutdown abort\nexit\n" | sql >/dev/null
  $S "rm -f $(echo $cfs)"
  printf "startup\nexit\n" | sql | grep -E "ORA-" | head -n 2
  t0=$(ts)
  # The CONFIGUREd autobackup format lives in the control file that is gone. Attempt 1: RMAN looked only in
  # the FRA, took an older autobackup (from the DUPLICATE) and recovery stopped short (ORA-01194).
  # Attempt 2 added SET ... FORMAT, still FRA: "search with format ... not attempted because DBID was not
  # set". The DBID has to be known before the failure (runbook / backup log).
  rman <<RMAN
set dbid $dbid;
startup nomount;
run {
  set controlfile autobackup format for device type disk to '/u02/drill/drill_bkp/cf_%F';
  restore controlfile from autobackup;
}
alter database mount;
recover database;
alter database open resetlogs;
RMAN
  printf "alter pluggable database all open;\nexit\n" | sql >/dev/null
  errs "ORA-00205|ORA-01589|ORA-00264|ORA-01157|ORA-01110"; verify; rto $t0 ;;

5b)
  f1=$(val 'select name from v$datafile where file# = 1;')
  say "shutdown abort and delete SYSTEM datafile $f1"
  printf "shutdown abort\nexit\n" | sql >/dev/null
  $S "rm -f '$f1'"
  printf "startup\nexit\n" | sql | grep -E "ORA-" | head -n 2
  t0=$(ts)
  rman <<'RMAN'
startup force mount;
restore datafile 1;
recover datafile 1;
alter database open;
RMAN
  errs "ORA-01157|ORA-01110"; verify; rto $t0 ;;

5c)
  dbid=$(val 'select dbid from v$database;')
  say "shutdown and delete spfile + pfile (DBID $dbid noted beforehand, as a runbook says)"
  printf "shutdown immediate\nexit\n" | sql >/dev/null
  $S "rm -f $OH/dbs/spfileDRILL.ora $OH/dbs/initDRILL.ora"
  printf "startup\nexit\n" | sql | grep -E "ORA-|LRM-" | head -n 2
  t0=$(ts)
  # the dummy instance (no parameter file) knows neither the FRA nor the autobackup format: first run
  # searched only \$ORACLE_HOME/dbs -> RMAN-06172. The format must be SET inside a RUN block.
  rman <<RMAN
set dbid $dbid;
startup force nomount;
run {
  set controlfile autobackup format for device type disk to '/u02/drill/drill_bkp/cf_%F';
  restore spfile from autobackup;
}
startup force;
RMAN
  errs "ORA-01078|LRM-00109|ORA-01507"; verify; rto $t0 ;;

5d)
  scn=$(val 'select current_scn from v$database;')
  say "SCN $scn, then DROP USER bank CASCADE in DRILLPDB"
  printf "alter session set container=DRILLPDB;\ndrop user bank cascade;\nexit\n" | sql >/dev/null
  verify || true
  t0=$(ts)
  printf "shutdown immediate\nstartup mount\nflashback database to scn $scn;\nalter database open resetlogs;\nalter pluggable database all open;\nexit\n" | sql | grep -E "ORA-|Flashback complete" || true
  verify; rto $t0 ;;

5e)
  scn=$(val 'select current_scn from v$database;')
  say "SCN $scn, then DROP TABLE bank.cards PURGE (not in the recycle bin)"
  printf "alter session set container=DRILLPDB;\ndrop table bank.cards cascade constraints purge;\nexit\n" | sql >/dev/null
  verify || true
  t0=$(ts)
  printf "alter pluggable database drillpdb close immediate;\nexit\n" | sql >/dev/null
  rman <<RMAN
run {
  set until scn $scn;
  restore pluggable database drillpdb;
  recover pluggable database drillpdb;
}
alter pluggable database drillpdb open resetlogs;
RMAN
  errs XXX; verify; rto $t0 ;;

5f)
  say "fresh level 0 first (the previous drills opened new incarnations)"
  rman <<'RMAN'
backup database plus archivelog;
delete noprompt obsolete;
RMAN
  dbid=$(val 'select dbid from v$database;')
  files=$(val "select name from v\$datafile union all select name from v\$tempfile union all select member from v\$logfile union all select name from v\$controlfile;")
  say "host loss: shutdown abort, delete $(echo $files | wc -w) database files, spfile, flashback logs (backups kept)"
  printf "shutdown abort\nexit\n" | sql >/dev/null
  $S "rm -f $(echo $files) $OH/dbs/spfileDRILL.ora $OH/dbs/initDRILL.ora; rm -rf /u02/oradata/DRILL_FRA/DRILL/flashback /u02/oradata/DRILL_FRA/DRILL/onlinelog"
  t0=$(ts)
  rman <<RMAN
set dbid $dbid;
startup force nomount;
run {
  set controlfile autobackup format for device type disk to '/u02/drill/drill_bkp/cf_%F';
  restore spfile from autobackup;
}
startup force nomount;
run {
  set controlfile autobackup format for device type disk to '/u02/drill/drill_bkp/cf_%F';
  restore controlfile from autobackup;
}
alter database mount;
restore database;
recover database;
alter database open resetlogs;
RMAN
  printf "alter pluggable database all open;\nexit\n" | sql >/dev/null
  errs "ORA-01078|LRM-00109|ORA-01507|ORA-00205|ORA-01589|ORA-00264"; verify; rto $t0 ;;
esac
