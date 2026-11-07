#!/bin/bash
# Roll a far-behind physical standby forward from its primary over the network, instead of shipping the archived-log
# gap: RECOVER STANDBY DATABASE FROM SERVICE refreshes the standby control file, restores datafiles added on the
# primary since, and recovers with an incremental of the changed blocks only.
# Used for stb3 (ORCL3_STB) after two days with Region B transport off: 68 archived logs / 3.7 GB behind, on a lab host
# with ~10 GB free (shipping such a gap once filled the host and paused 4 VMs).
# usage (from the host): ./roll_forward_standby.sh <standby host> <primary connect alias> [primary host]   e.g. stb3 orcl3 prm3
#                        ./roll_forward_standby.sh --open <standby host>   afterwards, with transport on: read only + apply
# SYS password from ../lab.env over ssh stdin (CONNECT inside a quoted here-document on the VM), never on a command
# line. Transport to the standby stays off meanwhile (labctl: LABCTL_NO_PROTECT=1 ./labctl.sh dg-b). Apply is switched
# off through the broker first: otherwise the broker restarts redo apply when the standby mounts, and RMAN stops with
# ORA-01153 halfway, after the control file was replaced.
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
. "$H/lab.env"; : "${DB_PASSWORD:?}"
open_standby() {  # redo from the primary must reach the standby first, or OPEN waits with no error ("class slave wait")
  ssh -o BatchMode=yes oracle@"$1" 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
q() { printf 'set heading off feedback off pages 0 lines 200\n%s\nexit\n' "$1" | sqlplus -s / as sysdba; }
uname=$(q "select db_unique_name from v\$database;" | head -n 1)
dgmgrl -silent / "edit database '$uname' set state='APPLY-OFF'" | grep -v '^$' | grep -v '^Connected'
printf 'alter database open read only;\nalter pluggable database all open read only;\nexit\n' | timeout 300 sqlplus -s / as sysdba | grep -E 'ORA-'
dgmgrl -silent / "edit database '$uname' set state='APPLY-ON'" | grep -v '^$' | grep -v '^Connected'
m=$(q "select open_mode from v\$database;" | head -n 1); echo "open mode: $m"
[ "$m" = "READ ONLY WITH APPLY" ]
EOF
}
if [ "${1:-}" = --open ]; then open_standby "${2:?standby host}"; exit $?; fi
host=${1:?standby host} prim=${2:?primary alias} prim_host=${3:-}
echo "host disk free before: $(df -BM --output=avail / | tail -n 1)"
ts=$(date +%Y%m%d_%H%M%S)
# 1) remote part without secrets: checks, restart to mount (variables expanded on the VM)
ssh -o BatchMode=yes oracle@$host 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
q() { printf 'set heading off feedback off pages 0 lines 200\n%s\nexit\n' "$1" | sqlplus -s / as sysdba; }
# an earlier failed run can leave the instance down or in NOMOUNT
case $(q "select status from v\$instance;" | head -n 1) in
  STARTED) printf 'alter database mount standby database;\nexit\n' | sqlplus -s / as sysdba >/dev/null ;;
  OPEN|MOUNTED) ;;
  *) printf 'startup mount\nexit\n' | sqlplus -s / as sysdba >/dev/null ;;
esac
role=$(q "select database_role || ' / ' || open_mode || ' / scn ' || current_scn from v\$database;" | head -n 1)
echo "before: $role"
case "$role" in "PHYSICAL STANDBY"*) ;; *) echo "not a physical standby, stop"; exit 1 ;; esac
uname=$(q "select db_unique_name from v\$database;" | head -n 1)
for i in 1 2 3 4 5 6; do
  dgmgrl -silent / "edit database '$uname' set state='APPLY-OFF'" >/dev/null 2>&1
  dgmgrl -silent / "show database '$uname'" 2>/dev/null | grep -q 'Intended State: *APPLY-OFF' && break
  [ "$i" = 6 ] && { echo "broker did not take APPLY-OFF, stop"; exit 1; }
  sleep 10
done
echo "broker: APPLY-OFF"
printf 'alter database recover managed standby database cancel;\nshutdown immediate\nstartup mount\nexit\n' | sqlplus -s / as sysdba >/dev/null 2>&1 || true
echo "mounted: $(q "select open_mode from v\$database;" | head -n 1)"
EOF
# 2) RMAN: the CONNECT line (with the password) is built here and sent on stdin; quoted here-document on the VM
log=/home/oracle/rman_logs/roll_forward_$ts.log   # /u02/backup is root-owned on stb3: the first run lost its log
{ printf 'connect target "sys/%s"\n' "$DB_PASSWORD"; printf 'recover standby database from service %s;\n' "$prim"; } \
  | ssh -o BatchMode=yes oracle@$host ". ~/.bash_profile >/dev/null 2>&1; mkdir -p /home/oracle/rman_logs; t0=\$(date +%s); rman log=$log >/dev/null; rc=\$?; echo \"rman rc=\$rc in \$(( \$(date +%s) - t0 )) s, log $log\"; exit \$rc" \
  && rc=0 || { rc=$?; echo "RMAN failed — see $log on $host. Apply stays off."; }
ssh -o BatchMode=yes oracle@$host "grep -E 'RMAN-|ORA-' $log | grep -vE 'RMAN-08120' | head -n 8; grep -cE 'restoring datafile|channel ORA_DISK_1: restore complete' $log | sed 's/^/restore lines: /'" || true
# 3) state after
ssh -o BatchMode=yes oracle@$host 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
printf 'set heading off feedback off pages 0 lines 200\nselect database_role || chr(32) || open_mode || chr(32) || current_scn from v$database;\nselect count(*) from v$datafile;\nexit\n' | sqlplus -s / as sysdba
# the restored control file names the primary's paths; the database only notices at the role change (HA/DR finding F16)
printf 'set heading off feedback off pages 0 lines 300\nselect type || chr(32) || member from v$logfile;\nexit\n' | sqlplus -s / as sysdba \
  | while read -r t m; do [ -d "$(dirname "$m")" ] || echo "MISSING directory for $t log: $m"; done | sort -u
EOF
if [ "$rc" = 0 ]; then
  ssh -o BatchMode=yes oracle@$host 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
q() { printf 'set heading off feedback off pages 0 lines 300\n%s\nexit\n' "$1" | sqlplus -s / as sysdba; }
uname=$(q "select db_unique_name from v\$database;" | head -n 1)
# standby redo logs named after the primary's directory: drop and add again, the file then goes to this site's FRA.
# RMAN leaves STANDBY_FILE_MANAGEMENT at MANUAL, which these commands need; it goes back to AUTO right after.
# (a group appears once per member; one that was recreated earlier in the loop is skipped, its directory now exists)
q "select s.group# || ' ' || s.bytes || ' ' || f.member from v\$standby_log s join v\$logfile f on f.group# = s.group#;" \
  | while read -r g b m; do
      [ -d "$(dirname "$m")" ] && [ "$(q "select count(*) from v\$logfile where group# = $g;" | head -n 1 | tr -d ' ')" = 1 ] && continue
      # db_create_file_dest empty for this session: with both destinations set, OMF would add a second member, and
      # standby redo logs should not be multiplexed (every SYNC write would pay for it)
      printf "alter session set db_create_file_dest = '';\nalter database drop standby logfile group %s;\nalter database add standby logfile thread 1 group %s size %s;\nexit\n" "$g" "$g" "$b" \
        | sqlplus -s / as sysdba | grep -E 'ORA-'
      echo "standby log group $g recreated: $(q "select count(*) from v\$standby_log where group# = $g;" | head -n 1) of 1"
    done
q "select member from v\$logfile where type = 'ONLINE';" | while read -r m; do mkdir -p "$(dirname "$m")"; done
printf 'alter system set standby_file_management = AUTO scope = both;\nexit\n' | sqlplus -s / as sysdba | grep -E 'ORA-'
dgmgrl -silent / "edit database '$uname' set state='APPLY-ON'" | grep -v '^$' | grep -v '^Connected'
q "select member from v\$logfile;" > /tmp/roll_forward_logs.txt
for d in $(q "select value from v\$parameter where name in ('db_recovery_file_dest', 'db_create_file_dest');"); do
  for f in "$d/$uname/onlinelog"/*; do
    [ -f "$f" ] && { grep -qF "$f" /tmp/roll_forward_logs.txt || echo "not in the control file any more, can be deleted by hand: $f"; }
  done
done; rm -f /tmp/roll_forward_logs.txt
q "select count(*) || ' standby logs, ' || sum(case when f.member like '%' || '$uname' || '%' then 1 else 0 end) || ' in this site directory' from v\$standby_log s join v\$logfile f on f.group# = s.group#;"
EOF
fi
if [ -n "$prim_host" ]; then   # redo apply stops at the first block encrypted with a key the standby does not have
  ks='. ~/.bash_profile >/dev/null 2>&1; d=$(printf "set heading off feedback off pages 0 lines 200\nselect value from v\$parameter where name = chr(119)||chr(97)||chr(108)||chr(108)||chr(101)||chr(116)||chr(95)||chr(114)||chr(111)||chr(111)||chr(116);\nexit\n" | sqlplus -s / as sysdba); cd "$d/tde" && md5sum ewallet.p12 cwallet.sso'
  a=$(ssh -o BatchMode=yes oracle@"$host" "$ks")
  b=$(ssh -o BatchMode=yes oracle@"$prim_host" "$ks")
  [ "$a" = "$b" ] && echo "keystore: same as the primary" || { echo "keystore DIFFERS from the primary: copy it before apply"; rc=2; }
fi
echo "host disk free after: $(df -BM --output=avail / | tail -n 1)"
[ "$rc" = 0 ] && echo "Next: transport on, wait for lag 0, then $0 --open $host"
exit "$rc"
