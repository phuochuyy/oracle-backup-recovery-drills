#!/bin/bash
# Roll a far-behind physical standby forward from its primary over the network, instead of shipping the archived-log
# gap: RECOVER STANDBY DATABASE FROM SERVICE refreshes the standby control file, restores datafiles added on the
# primary since, and recovers with an incremental of the changed blocks only.
# Used for stb3 (ORCL3_STB) after two days with Region B transport off: 68 archived logs / 3.7 GB behind, on a lab host
# with ~10 GB free (shipping such a gap once filled the host and paused 4 VMs).
# usage (from the host): ./roll_forward_standby.sh <standby host> <primary connect alias>    e.g. stb3 orcl3
# SYS password from ../lab.env over ssh stdin (CONNECT inside a quoted here-document on the VM), never on a command
# line. The standby must be out of the broker's hands meanwhile (labctl: LABCTL_NO_PROTECT=1 ./labctl.sh dg-b).
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
. "$H/lab.env"; : "${DB_PASSWORD:?}"
host=${1:?standby host} prim=${2:?primary alias}
ts=$(date +%Y%m%d_%H%M%S)
# 1) remote part without secrets: checks, restart to mount (variables expanded on the VM)
ssh -o BatchMode=yes oracle@$host 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
q() { printf 'set heading off feedback off pages 0 lines 200\n%s\nexit\n' "$1" | sqlplus -s / as sysdba; }
role=$(q "select database_role || ' / ' || open_mode || ' / scn ' || current_scn from v\$database;" | head -n 1)
echo "before: $role"
case "$role" in "PHYSICAL STANDBY"*) ;; *) echo "not a physical standby, stop"; exit 1 ;; esac
printf 'alter database recover managed standby database cancel;\nshutdown immediate\nstartup mount\nexit\n' | sqlplus -s / as sysdba >/dev/null 2>&1 || true
echo "mounted: $(q "select open_mode from v\$database;" | head -n 1)"
EOF
# 2) RMAN: the CONNECT line (with the password) is built here and sent on stdin; quoted here-document on the VM
log=/home/oracle/rman_logs/roll_forward_$ts.log   # /u02/backup is root-owned on stb3: the first run lost its log
{ printf 'connect target "sys/%s"\n' "$DB_PASSWORD"; printf 'recover standby database from service %s;\n' "$prim"; } \
  | ssh -o BatchMode=yes oracle@$host ". ~/.bash_profile >/dev/null 2>&1; mkdir -p /home/oracle/rman_logs; t0=\$(date +%s); rman log=$log >/dev/null; rc=\$?; echo \"rman rc=\$rc in \$(( \$(date +%s) - t0 )) s, log $log\"; exit \$rc" \
  || echo "RMAN failed — see $log on $host"
ssh -o BatchMode=yes oracle@$host "grep -E 'RMAN-|ORA-' $log | grep -vE 'RMAN-08120' | head -n 8; grep -cE 'restoring datafile|channel ORA_DISK_1: restore complete' $log | sed 's/^/restore lines: /'" || true
# 3) state after
ssh -o BatchMode=yes oracle@$host 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
printf 'set heading off feedback off pages 0 lines 200\nselect database_role || chr(32) || open_mode || chr(32) || current_scn from v$database;\nselect count(*) from v$datafile;\nexit\n' | sqlplus -s / as sysdba
EOF
