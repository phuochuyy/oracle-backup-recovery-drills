#!/bin/bash
# Backup / recovery health check for orcl3, one line per check: OK | WARN | CRIT.
# Exit code = number of CRIT lines. Run as oracle on the database host.
# Each check exists because the problem happened in this lab (see notes/worklog.md):
#  - redo members are checked ON DISK: a deleted member stays "OK" in V$LOGFILE while LGWR holds it open,
#    but GoldenGate's LogMiner fails on it (drill 6a)
#  - FRA usage on this database (the standby's FRA filled up twice in the perf lab — run it there too)
# usage: ./check_backup_health.sh   (env: L0_MAX_H=170 L1_MAX_H=26 ARCH_MAX_H=1 FRA_WARN=80 FRA_CRIT=90)
. ~/.bash_profile >/dev/null 2>&1
L0_MAX_H=${L0_MAX_H:-170} L1_MAX_H=${L1_MAX_H:-26} ARCH_MAX_H=${ARCH_MAX_H:-1}
FRA_WARN=${FRA_WARN:-80} FRA_CRIT=${FRA_CRIT:-90}
crit=0
line() { [ "$1" = CRIT ] && crit=$((crit + 1)); printf "%-4s %-22s %s\n" "$1" "$2" "$3"; }
q() { printf "set heading off feedback off pages 0 lines 500 trimspool on\n%s\nexit\n" "$1" | sqlplus -s / as sysdba \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | grep -vE "^$"; }

role=$(q "select database_role from v\$database;")
line OK role "$(q "select db_unique_name || ' ' || database_role || ' ' || open_mode from v\$database;")"

# 1. backup age per datafile (hours); the worst file is reported. Not max(completion_time) of all
#    level 0 sets: a level 1 run makes an automatic level 0 of new datafiles, which made "last L0" look
#    recent although the database's L0 was older. A level 1 of a file created after the L0 has
#    incremental_change# = creation_change# (all blocks): RMAN restores from it (RESTORE ... PREVIEW),
#    so it counts as a base. Files never backed up count as 9999 h.
if [ "$role" = PRIMARY ]; then
  for k in "base:(b.incremental_level = 0 or b.incremental_change# <= b.creation_change#):$L0_MAX_H" \
           "L0/L1:b.incremental_level in (0, 1):$L1_MAX_H"; do
    IFS=: read -r name cond max <<< "$k"
    read -r h f <<< "$(q "select to_char(h, 'FM99990.0'), file# from (
        select nvl((sysdate - max(b.completion_time)) * 24, 9999) h, d.file#
          from v\$datafile d left join v\$backup_datafile b on b.file# = d.file# and $cond
         group by d.file# order by 1 desc, 2) where rownum = 1;")"
    awk -v h="$h" -v m="$max" 'BEGIN { exit !(h <= m) }' && s=OK || s=CRIT
    line $s "backup $name" "oldest file #$f: ${h} h ago (max $max h)"
  done
  h=$(q "select to_char(nvl((sysdate - max(completion_time)) * 24, 9999), 'FM99990.0') from v\$backup_set_details where backup_type = 'L';")
  awk -v h="$h" -v m="$ARCH_MAX_H" 'BEGIN { exit !(h <= m) }' && s=OK || s=WARN
  line $s "backup archivelog" "last ${h} h ago (max $ARCH_MAX_H h)"
fi

# 2. RMAN jobs that failed in the last 24 h
f=$(q "select count(*) from v\$rman_status where start_time > sysdate - 1 and status like 'FAILED%' and row_level = 0;")
[ "$f" -eq 0 ] && line OK "rman failures 24h" 0 || line WARN "rman failures 24h" "$f (see V\$RMAN_STATUS)"

# 3. FRA usage
p=$(q "select round(space_used / space_limit * 100) from v\$recovery_file_dest;")
r=$(q "select round(space_reclaimable / space_limit * 100) from v\$recovery_file_dest;")
s=OK; [ "$p" -ge "$FRA_WARN" ] && s=WARN; [ "$p" -ge "$FRA_CRIT" ] && s=CRIT
line $s "fra used" "${p} % (reclaimable ${r} %)"

# 4. every online redo member exists on disk, every group has >= 2 members
missing=0
while read -r g m; do
  [ -f "$m" ] || { line CRIT "redo member" "group $g: $m MISSING on disk"; missing=$((missing + 1)); }
done < <(q "select group# || ' ' || member from v\$logfile where type = 'ONLINE';")
single=$(q "select listagg(group#, ',') from (select group# from v\$logfile where type = 'ONLINE' group by group# having count(*) < 2);")
[ -n "$single" ] && line WARN "redo multiplexing" "groups with one member: $single"
[ "$missing" -eq 0 ] && line OK "redo members" "$(q "select count(*) from v\$logfile where type = 'ONLINE';") on disk"

# 5. archive destinations (local + standby)
while read -r d st err; do
  [ "$st" = VALID ] && line OK "archive dest $d" "$st" || line CRIT "archive dest $d" "$st $err"
done < <(q "select dest_id || ' ' || status || ' ' || error from v\$archive_dest where status <> 'INACTIVE' and destination is not null;")

# 6. GoldenGate capture (if any)
while read -r c st; do
  [ "$st" = ENABLED ] && line OK "gg capture $c" "$st" || line CRIT "gg capture $c" "$st"
done < <(q "select capture_name || ' ' || status from cdb_capture;")

exit $crit
