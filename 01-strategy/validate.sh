#!/bin/bash
# Prove the backups are restorable without restoring anything: RMAN reads the backup pieces and
# checks every block. Archived logs are checked from the start of the latest level 0 — older logs were
# never backed up and are not needed to recover from it. (RESTORE ARCHIVELOG has no FROM TAG.)
# usage (on prm3, as oracle): ./validate.sh
. ~/.bash_profile >/dev/null 2>&1
l0=$(printf "set heading off feedback off pages 0\nselect to_char(max(start_time), 'YYYY-MM-DD HH24:MI:SS') from v\$backup_set_details where backup_type = 'I' and incremental_level = 0;\nexit\n" \
     | sqlplus -s / as sysdba | tr -d '\t' | grep -E "^[0-9]{4}-")
[ -n "$l0" ] || { echo "no level 0 backup found"; exit 1; }
echo "latest level 0 started $l0"
start=$(date +%s)
rman target / <<RMAN | grep -E "Finished restore|RMAN-|ORA-" | grep -vE "RMAN-08120|RMAN-08137"
restore database validate;
restore archivelog from time "to_date('$l0', 'YYYY-MM-DD HH24:MI:SS')" validate;
RMAN
echo "validate elapsed $(( $(date +%s) - start )) s"
