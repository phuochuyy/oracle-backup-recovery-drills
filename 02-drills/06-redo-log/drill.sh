#!/bin/bash
# Drill 6b — both members of an online redo group lost, on the primary orcl3 (standby + GG Extract running).
# Only an INACTIVE, ARCHIVED group is used: CLEAR LOGFILE then just re-creates its files. Clearing an
# UNARCHIVED group would leave a hole in the archived-log sequence (backups and GoldenGate both need it).
# Detection: check_backup_health.sh (checks the members on disk; V$LOGFILE keeps saying OK while LGWR
# holds the deleted files open). RTO = from the health check reporting CRIT to the check being OK again.
# usage (from the host): ./drill.sh
set -eu
out=$(cd "$(dirname "$0")" && pwd)/run-6b.log; : > "$out"
say() { echo "$(date +%T) $*" | tee -a "$out"; }
P="ssh -o BatchMode=yes oracle@prm3"
q() { printf "set heading off feedback off pages 0 lines 500\n%s\nexit\n" "$1" | $P ". ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba" | sed -E 's/^[[:space:]]+//' | grep -vE "^$"; }
health() { $P "~/brlab/04-scripts/check_backup_health.sh" | tee -a "$out" | grep -E "^CRIT|redo" || true; }

g=$(q "select min(group#) from v\$log where status = 'INACTIVE' and archived = 'YES';")
[ -n "$g" ] || { say "no INACTIVE archived group, stop"; exit 1; }
members=$(q "select member from v\$logfile where group# = $g;")
say "group $g (INACTIVE, archived): delete both members: $(echo $members)"
$P "rm -f $(echo $members)"
say "health check"
health
t0=$(date +%s.%N)
say "the database itself does not notice:"
q "select group# || ' ' || member || ' ' || nvl(status, 'OK') from v\$logfile where group# = $g;" | tee -a "$out"

say "repair: re-check status, CLEAR LOGFILE GROUP $g (re-creates both members)"
st=$(q "select status || ' ' || archived from v\$log where group# = $g;")
[ "$st" = "INACTIVE YES" ] || { say "group $g is now '$st' - not clearing, stop"; exit 1; }
q "alter database clear logfile group $g;" | tee -a "$out"
$P "ls -la $(echo $members)" | tee -a "$out"
say "switch through all groups, then health check"
q "begin for i in 1 .. 7 loop execute immediate 'alter system switch logfile'; end loop; end;
/" >/dev/null || true   # no output -> grep returns 1 -> set -e stopped the first run here
health
t1=$(date +%s.%N)
say "alert log since the drill:"
$P "awk '/^$(date +%Y-%m-%dT%H:%M -d @${t0%.*})/{f=1} f' /u01/app/oracle/diag/rdbms/orcl3/ORCL3/trace/alert_ORCL3.log | grep -E 'ORA-|Clearing|clear' | sort | uniq -c" | tee -a "$out" || true
say "RTO $(printf '%.0f' $(echo "$t1 - $t0" | bc)) s (from detection to health OK)"
