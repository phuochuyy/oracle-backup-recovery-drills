#!/bin/bash
# Drill 4 — TRUNCATE TABLE by mistake (500 K rows). Flashback Table cannot undo a TRUNCATE (DDL).
# RMAN RECOVER TABLE builds an auxiliary instance from the backups, recovers the PDB until the SCN
# before the truncate, exports the table and imports it under a new name (the original still exists,
# empty). Then the rows are copied back. RTO = from the truncate to the data verified.
# usage (from the host): ./drill.sh
set -eu
out=$(cd "$(dirname "$0")" && pwd)/run.log; : > "$out"
say() { echo "$(date +%T) $*" | tee -a "$out"; }
ts() { date +%s.%N; }
P="ssh -o BatchMode=yes oracle@prm3"
sql() { $P ". ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba"; }

scn=$(printf "set heading off feedback off pages 0\nselect current_scn from v\$database;\nexit\n" | sql | tr -d ' \t' | grep -E "^[0-9]+$")
say "SCN before the mistake: $scn"
printf "alter session set container=DRILLPDB;\ntruncate table bank.transactions;\nselect count(*) rows_left from bank.transactions;\nexit\n" | sql | grep -vE "^$|Session altered" | tee -a "$out"
t0=$(ts)

say "RECOVER TABLE from backup (auxiliary instance in /u02/backup/aux)"
$P "mkdir -p /u02/backup/aux"
$P ". ~/.bash_profile >/dev/null 2>&1; rman target /" >> "$out" 2>&1 <<RMAN || true
recover table bank.transactions of pluggable database drillpdb
  until scn $scn
  auxiliary destination '/u02/backup/aux'
  remap table bank.transactions:transactions_rec;
RMAN
grep -E "RMAN-0|ORA-|Finished recover|Import job|imported|Removing automatic instance" "$out" | tail -n 6 || true

say "copy the recovered rows back and drop the helper table"
printf "alter session set container=DRILLPDB;\nset timing on\ninsert /*+ append */ into bank.transactions select * from bank.transactions_rec;\ncommit;\ndrop table bank.transactions_rec purge;\nexit\n" | sql | grep -E "rows created|ORA-|Elapsed" | tee -a "$out"
t1=$(ts)
v=$($P "cd ~/brlab; BANKDB_DIR=~/perflab/01-setup/bankdb ./04-scripts/verify_drillpdb.sh")
say "verify: $v"
say "RTO $(printf '%.0f' $(echo "$t1 - $t0" | bc)) s (RECOVER TABLE + copy back)"
$P "du -sh /u02/backup/aux 2>/dev/null; ls /u02/backup/aux | head"
