#!/bin/bash
# Install the scheduled RAC backup on RAC nodes (run again on a node that was off; idempotent).
# usage (from the host): ./install_rac_backup.sh prm1 stb1 [prm2 stb2]
# On each node, as oracle: ~/rman_tns = own TNS_ADMIN (copy of the database home's tnsnames.ora + alias rcat_lab,
# sqlnet.ora pointing to the wallet) and an auto-login wallet with SYS for orcl / orcl_stb and RCO for the catalog.
# The wallet password is random, generated here, used once and never stored: to change a credential the wallet
# is simply created again. DB_PASSWORD / RCO_PASSWORD come from ../../lab.env and travel over ssh stdin only.
# Then: rac_backup_job.sh -> /u02/backup/bin, systemd units -> enable rac-backup-0/1.timer, and a check that every
# alias logs in through the wallet (no password typed).
set -eu
H=$(cd "$(dirname "$0")/../.." && pwd); D=$(cd "$(dirname "$0")" && pwd)
. "$H/lab.env"; : "${DB_PASSWORD:?}" "${RCO_PASSWORD:?}"
[ $# -gt 0 ] || { echo "usage: $0 <node>..."; exit 2; }
for n in "$@"; do
  echo "== $n"
  wpw="W$(openssl rand -base64 18 | tr -d '/+=')9"
  ssh -o BatchMode=yes oracle@$n 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1
set -eu
T=$HOME/rman_tns; rm -rf "$T"; mkdir -m 700 "$T"
cp "$ORACLE_HOME/network/admin/tnsnames.ora" "$T/tnsnames.ora"
cat >> "$T/tnsnames.ora" <<'TNS'
RCAT_LAB = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = prm3.rac)(PORT = 1521))(CONNECT_DATA = (SERVICE_NAME = rcat.rac)))
TNS
cat > "$T/sqlnet.ora" <<SQLNET
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = $T/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)
SQLNET
mkdir -m 700 "$T/wallet"
EOF
  printf '%s\n%s\n' "$wpw" "$wpw" | ssh -o BatchMode=yes oracle@$n \
    '. ~/.bash_profile >/dev/null 2>&1; mkstore -wrl ~/rman_tns/wallet -create >/dev/null'
  for c in "orcl sys $DB_PASSWORD" "orcl_stb sys $DB_PASSWORD" "rcat_lab rco $RCO_PASSWORD"; do
    read -r alias user pw <<< "$c"
    printf '%s\n%s\n%s\n' "$pw" "$pw" "$wpw" | ssh -o BatchMode=yes oracle@$n \
      ". ~/.bash_profile >/dev/null 2>&1; mkstore -wrl ~/rman_tns/wallet -createCredential $alias $user >/dev/null"
  done
  unset wpw
  scp -q "$D/rac_backup_job.sh" oracle@$n:/tmp/rac_backup_job.sh
  scp -q "$D/systemd/rac-backup@.service" "$D/systemd/rac-backup-0.timer" "$D/systemd/rac-backup-1.timer" root@$n:/etc/systemd/system/
  ssh -o BatchMode=yes root@$n 'mkdir -p /u02/backup/bin && chown oracle:oinstall /u02/backup /u02/backup/bin
    install -o oracle -g oinstall -m 750 /tmp/rac_backup_job.sh /u02/backup/bin/rac_backup_job.sh && rm -f /tmp/rac_backup_job.sh
    systemctl daemon-reload && systemctl enable --now rac-backup-0.timer rac-backup-1.timer >/dev/null 2>&1
    systemctl list-timers rac-backup-0.timer rac-backup-1.timer --no-pager | sed -n "2,3p"'
  # every alias through the wallet, no password typed
  ssh -o BatchMode=yes oracle@$n 'bash -s' <<'EOF'
. ~/.bash_profile >/dev/null 2>&1; export TNS_ADMIN=$HOME/rman_tns
for a in orcl orcl_stb; do
  r=$(printf 'set heading off feedback off pages 0\nselect db_unique_name || chr(32) || database_role from v$database;\n' | sqlplus -s -L /@$a as sysdba 2>&1 | grep -vE '^$' | head -n 1)
  echo "   wallet login /@$a as sysdba: $r"
done
r=$(printf "set heading off feedback off pages 0\nselect sys_context('userenv', 'session_user') from dual;\n" | sqlplus -s -L /@rcat_lab 2>&1 | grep -vE '^$' | head -n 1)
echo "   wallet login /@rcat_lab: $r"
EOF
done
