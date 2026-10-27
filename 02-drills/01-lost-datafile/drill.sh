#!/bin/bash
# Drill 1 — lose a datafile of DRILLPDB on the RAC primary (ASM) and recover it.
#   method service : RESTORE DATAFILE ... FROM SERVICE orcl_stb (pull the file from the standby, no backup needed)
#   method backup  : copy the standby's backup pieces to prm1, CATALOG them, RESTORE + RECOVER
# RTO = from the failed PDB open (ORA-01157) to the PDB open again with verified data.
# usage (from the host): DB_PASSWORD=... RCO_PASSWORD=... ./drill.sh service|backup
set -eu
method=$1; : "${DB_PASSWORD:?}" "${RCO_PASSWORD:?}"
out=$(cd "$(dirname "$0")" && pwd)/run-$method.log; : > "$out"
ts() { date +%s.%N; }
say() { echo "$(date +%T) $*" | tee -a "$out"; }
P="ssh -o BatchMode=yes oracle@prm1"
CAT="rco/${RCO_PASSWORD}@//prm3.rac:1521/rcat.rac"

df=$($P ". ~/.bash_profile >/dev/null 2>&1; printf \"set heading off feedback off pages 0\nalter session set container=DRILLPDB;\nselect file_id||':'||file_name from dba_data_files where tablespace_name='BANK_DATA';\nexit\n\" | sqlplus -s / as sysdba" | grep -E "^[0-9]+:")
fno=${df%%:*}; fname=${df#*:}
say "target datafile #$fno $fname"

say "close DRILLPDB and delete the datafile from ASM (the 'failure')"
$P ". ~/.bash_profile >/dev/null 2>&1; echo 'alter pluggable database drillpdb close immediate instances=all;' | sqlplus -s / as sysdba" >> "$out"
ssh -o BatchMode=yes root@prm1 "su - grid -c \"asmcmd rm -f '$fname'\"" >> "$out" 2>&1

say "open DRILLPDB (expect ORA-01157)"
$P ". ~/.bash_profile >/dev/null 2>&1; echo 'alter pluggable database drillpdb open;' | sqlplus -s / as sysdba" | grep -E "ORA-" | tee -a "$out"
t0=$(ts)

if [ "$method" = service ]; then
  say "restore from the standby over the network"
  $P ". ~/.bash_profile >/dev/null 2>&1; rman target sys/$DB_PASSWORD@orcl catalog $CAT" >> "$out" 2>&1 <<RMAN
restore datafile $fno from service orcl_stb;
recover datafile $fno;
RMAN
else
  say "copy the standby's backup pieces of file $fno to prm1"
  pieces=$(ssh -o BatchMode=yes oracle@prm3 ". ~/.bash_profile >/dev/null 2>&1; printf \"set heading off feedback off pages 0\nalter session set container=rcat;\nselect distinct p.handle from rco.rc_backup_piece p join rco.rc_backup_datafile d on d.bs_key = p.bs_key join rco.rc_site s on s.site_key = p.site_key where s.db_unique_name = 'ORCL_STB' and d.file# = $fno and p.status = 'A';\nexit\n\" | sqlplus -s / as sysdba" | grep "^/")
  ssh -o BatchMode=yes root@prm1 "mkdir -p /u02/backup/orcl_from_stb && chown oracle:oinstall /u02/backup/orcl_from_stb"
  for p in $pieces; do ssh -o BatchMode=yes oracle@stb1 "cat $p" | $P "cat > /u02/backup/orcl_from_stb/$(basename $p)"; done
  say "copied $(echo $pieces | wc -w) piece(s)"
  $P ". ~/.bash_profile >/dev/null 2>&1; rman target / catalog $CAT" >> "$out" 2>&1 <<RMAN
catalog start with '/u02/backup/orcl_from_stb/' noprompt;
restore datafile $fno;
recover datafile $fno;
RMAN
fi
grep -E "RMAN-0|ORA-" "$out" | grep -vE "RMAN-08120|ORA-01157|ORA-01110" | head -n 5 || true

say "open DRILLPDB again"
$P ". ~/.bash_profile >/dev/null 2>&1; echo 'alter pluggable database drillpdb open instances=all;' | sqlplus -s / as sysdba" >> "$out"
t1=$(ts)
v=$($P "cd ~/brlab; BANKDB_DIR=~/bankdb ./04-scripts/verify_drillpdb.sh")
say "verify: $v"
say "RTO $(printf '%.0f' $(echo "$t1 - $t0" | bc)) s (method $method)"
