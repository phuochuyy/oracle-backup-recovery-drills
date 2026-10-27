#!/bin/bash
# Prove the backups are restorable without restoring anything: RMAN reads the backup pieces
# and checks every block. usage (on prm3, as oracle): ./validate.sh
. ~/.bash_profile >/dev/null 2>&1
start=$(date +%s)
rman target / <<'RMAN' | grep -E "Finished restore|RMAN-|ORA-|channel ORA_DISK_[0-9]: (validation|restored)" | grep -vE "RMAN-08120"
restore database validate;
restore archivelog from time 'sysdate-1' validate;
RMAN
echo "validate elapsed $(( $(date +%s) - start )) s"
