#!/bin/bash
# Drill 3 — a corrupted block in DRILLPDB on orcl3 (prm3, datafiles on a filesystem).
# Overwrite the block holding ACCOUNTS row 1234 with zeros, see ORA-01578, find it with VALIDATE, repair
# only that block with RMAN block media recovery (no datafile restore, the PDB stays open).
# Without an Active Data Guard standby running, 23ai cannot repair it automatically from the standby.
# RTO = from the ORA-01578 to the block repaired and the data verified.
# usage (from the host): ./drill.sh
set -eu
out=$(cd "$(dirname "$0")" && pwd)/run.log; : > "$out"
say() { echo "$(date +%T) $*" | tee -a "$out"; }
ts() { date +%s.%N; }
P="ssh -o BatchMode=yes oracle@prm3"
sql() { $P ". ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba"; }

# lines 500: with the default 80 the file name was cut to ".../o1_mf" and my first run made dd write a
# new 75 MB file of that name instead of touching the datafile (nothing was damaged; file removed)
loc=$(printf "set heading off feedback off pages 0 lines 500 trimspool on\nalter session set container=DRILLPDB;\nselect f.file_id||':'||dbms_rowid.rowid_block_number(a.rowid, 'BIGFILE')||':'||f.file_name from bank.accounts a, dba_data_files f where a.account_id = 1234 and f.tablespace_name = 'BANK_DATA';\nexit\n" | sql | grep -E "^[0-9]+:")
fno=${loc%%:*}; rest=${loc#*:}; blk=${rest%%:*}; fname=${rest#*:}
say "ACCOUNTS row 1234 is in file #$fno block $blk ($fname)"
$P "test -f '$fname'" && [[ $fname == *.dbf ]] || { say "datafile name looks wrong: $fname — stop"; exit 1; }

say "overwrite block $blk with zeros (dd, direct IO) and flush the buffer cache"
$P "dd if=/dev/zero of='$fname' bs=8192 seek=$blk count=1 conv=notrunc oflag=direct status=none"
printf "alter system flush buffer_cache;\nexit\n" | sql >> "$out"

say "read the row"
printf "alter session set container=DRILLPDB;\nselect balance from bank.accounts where account_id = 1234;\nexit\n" | sql | grep -E "ORA-" | tee -a "$out" || { say "no error reading the row — corruption not in place, stop"; exit 1; }
t0=$(ts)

say "find all corrupt blocks: VALIDATE DATAFILE"
# RMAN exits non-zero when VALIDATE finds corruption — here that is the expected result
$P ". ~/.bash_profile >/dev/null 2>&1; echo 'validate datafile $fno;' | rman target /" >> "$out" 2>&1 || true
printf "set lines 120\nselect file#, block#, blocks, corruption_type from v\$database_block_corruption;\nexit\n" | sql | tee -a "$out" | grep -E "^ +[0-9]+ +[0-9]+" || true

say "repair: RECOVER CORRUPTION LIST (block media recovery from the level 0/1 backups + archived logs)"
$P ". ~/.bash_profile >/dev/null 2>&1; echo 'recover corruption list;' | rman target /" >> "$out" 2>&1
grep -E "RMAN-0|ORA-|Finished recover|starting media recovery|media recovery complete" "$out" | tail -n 4 || true
t1=$(ts)
printf "select count(*) still_corrupt from v\$database_block_corruption;\nexit\n" | sql | grep -E "^ +[0-9]+$" | tee -a "$out" || true
v=$($P "cd ~/brlab; BANKDB_DIR=~/perflab/01-setup/bankdb ./04-scripts/verify_drillpdb.sh")
say "verify: $v"
say "RTO $(printf '%.0f' $(echo "$t1 - $t0" | bc)) s (block media recovery, PDB stayed open)"
