#!/bin/bash
# RMAN on orcl3 connects as C##BKADMIN with SYSBACKUP through an auto-login wallet, instead of OS authentication as SYSDBA.
# ~/rman_tns = its own TNS_ADMIN, so nothing else on the machine picks this wallet up. The wallet password is random, used
# once and never stored: to change the credential, run this again. BKADMIN_PASSWORD_B comes from the security
# repository's lab.env (03-hardening/07_admin_roles.sh creates the account) and travels over ssh stdin only.
# usage (from the host): ./install_bk_wallet.sh prm3
set -eu
D=$(cd "$(dirname "$0")" && pwd)
. "$D/../../oracle-security-compliance-lab/lab.env"; : "${BKADMIN_PASSWORD_B:?run 03-hardening/07_admin_roles.sh first}"
n=${1:?host}
wpw="W$(openssl rand -base64 18 | tr -d '/+=')9#"
ssh -o BatchMode=yes "oracle@$n" 'bash -s' <<'REMOTE'
. ~/.bash_profile >/dev/null 2>&1
set -eu
T=$HOME/rman_tns; rm -rf "$T"; mkdir -m 700 "$T" "$T/wallet"
cat > "$T/tnsnames.ora" <<'TNS'
ORCL3_BK = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))(CONNECT_DATA = (SERVICE_NAME = orcl3.rac)))
TNS
cat > "$T/sqlnet.ora" <<SQLNET
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = $T/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)
SQLNET
REMOTE
printf '%s\n%s\n' "$wpw" "$wpw" | ssh -o BatchMode=yes "oracle@$n" '. ~/.bash_profile >/dev/null 2>&1; mkstore -wrl ~/rman_tns/wallet -createALO >/dev/null'
printf '%s\n%s\n%s\n' "$BKADMIN_PASSWORD_B" "$BKADMIN_PASSWORD_B" "$wpw" | ssh -o BatchMode=yes "oracle@$n" '. ~/.bash_profile >/dev/null 2>&1; mkstore -wrl ~/rman_tns/wallet -createCredential orcl3_bk c##bkadmin >/dev/null'
unset wpw
ssh -o BatchMode=yes "oracle@$n" 'bash -s' <<'REMOTE'
. ~/.bash_profile >/dev/null 2>&1; export TNS_ADMIN=$HOME/rman_tns
printf "set heading off feedback off pages 0\nselect sys_context('userenv', 'session_user') || chr(32) || sys_context('userenv', 'cdb_name') from dual;\nexit\n" | sqlplus -s -L "/@orcl3_bk as sysbackup" | tail -n 1 | sed 's/^/wallet login as sysbackup: /'
REMOTE
