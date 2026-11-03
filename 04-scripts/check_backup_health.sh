#!/bin/bash
# Backup / recovery health check for orcl3, one line per check: OK | WARN | CRIT.
# Exit code = number of CRIT lines. Run as oracle on the database host.
# Each check exists because the problem happened in this lab (see notes/worklog.md):
#  - redo members are checked ON DISK: a deleted member stays "OK" in V$LOGFILE while LGWR holds it open,
#    but GoldenGate's LogMiner fails on it (drill 6a)
#  - FRA usage on this database (the standby's FRA filled up twice in the perf lab — run it there too)
#  - capacity (7): the VM disks are sparse images on a small host; a standby that was off pulled a 3.7 GB
#    redo gap in one go and filled the host. A VM cannot see the host's free space — these checks report
#    what fills it: disk groups, file systems, and the redo each standby still has to receive.
# usage: ./check_backup_health.sh   (env: L0_MAX_H=170 L1_MAX_H=26 ARCH_MAX_H=1 FRA_WARN=80 FRA_CRIT=90
#        DATA_WARN=80 DATA_CRIT=90 FS_WARN=80 FS_CRIT=90 GAP_WARN_MB=1024)
. ~/.bash_profile >/dev/null 2>&1
# per-host settings written by install_scheduled_checks.sh (BACKUP_ROLE, thresholds)
[ -f ~/brlab/health.env ] && . ~/brlab/health.env
# Where this database's backups are taken: PRIMARY (orcl3, timers) or PHYSICAL STANDBY (the RAC offloads its
# backups to the standby). The backup-age checks run on that side only. Until 2026-11-03 they ran on the
# primary only: the RAC primary reported "never backed up" every hour (its control file does not see the
# standby's backups) and nothing checked the side where the backups really are.
BACKUP_ROLE=${BACKUP_ROLE:-PRIMARY}
L0_MAX_H=${L0_MAX_H:-170} L1_MAX_H=${L1_MAX_H:-26} ARCH_MAX_H=${ARCH_MAX_H:-1}
FRA_WARN=${FRA_WARN:-80} FRA_CRIT=${FRA_CRIT:-90}
DATA_WARN=${DATA_WARN:-80} DATA_CRIT=${DATA_CRIT:-90} FS_WARN=${FS_WARN:-80} FS_CRIT=${FS_CRIT:-90} GAP_WARN_MB=${GAP_WARN_MB:-1024}
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
#    Only backups of the current incarnation count: after a failover the previous level 0 cannot be used
#    (ORA-01207 in drill 1b) although it is recent. Exception: a file unchanged since its backup (PDB$SEED:
#    its backup carries the resetlogs SCN of the incarnation the file was last written in).
if [ "$role" = "$BACKUP_ROLE" ]; then
  # a file unchanged since its last backup (checkpoint SCN not moved: PDB$SEED, read-only tablespaces) is
  # skipped by BACKUP OPTIMIZATION and needs no new backup — counted as current (it made PDB$SEED's files
  # CRIT 36 h after the level 0 on 2026-10-29)
  for k in "base:(b.incremental_level = 0 or b.incremental_change# <= b.creation_change#):$L0_MAX_H" \
           "L0/L1:b.incremental_level in (0, 1):$L1_MAX_H"; do
    IFS=: read -r name cond max <<< "$k"
    read -r h f <<< "$(q "select to_char(h, 'FM99990.0'), file# from (
        select case when d.checkpoint_change# <= max(b.checkpoint_change#) then 0
                    else nvl((sysdate - max(b.completion_time)) * 24, 9999) end h, d.file#
          from v\$datafile d left join v\$backup_datafile b on b.file# = d.file# and $cond
               and (b.resetlogs_change# = (select resetlogs_change# from v\$database_incarnation where status = 'CURRENT')
                    or b.checkpoint_change# >= d.checkpoint_change#)
         group by d.file#, d.checkpoint_change# order by 1 desc, 2) where rownum = 1;")"
    awk -v h="$h" -v m="$max" 'BEGIN { exit !(h <= m) }' && s=OK || s=CRIT
    line $s "backup $name" "oldest file #$f: ${h} h ago (max $max h)"
  done
  h=$(q "select to_char(nvl((sysdate - max(completion_time)) * 24, 9999), 'FM99990.0') from v\$backup_set_details where backup_type = 'L';")
  awk -v h="$h" -v m="$ARCH_MAX_H" 'BEGIN { exit !(h <= m) }' && s=OK || s=WARN
  line $s "backup archivelog" "last ${h} h ago (max $ARCH_MAX_H h)"
else
  line OK "backup age" "backups are taken on the $(echo "$BACKUP_ROLE" | tr A-Z a-z) side (checked there)"
fi

# 2. RMAN jobs that failed in the last 24 h
f=$(q "select count(*) from v\$rman_status where start_time > sysdate - 1 and status like 'FAILED%' and row_level = 0;")
[ "$f" -eq 0 ] && line OK "rman failures 24h" 0 || line WARN "rman failures 24h" "$f (see V\$RMAN_STATUS)"

# 2b. the last run of each systemd backup job (where the timers exist): a job that never reached the
#     database leaves nothing in V$RMAN_STATUS — the 12:02 catch-up run on 2026-10-29 failed with ORA-01034
#     at boot while check 2 said 0 failures
for m in 0 1 arch; do
  r=$(systemctl show "orcl3-backup@$m.service" -p Result --value 2>/dev/null) || continue
  t=$(systemctl show "orcl3-backup@$m.service" -p ExecMainExitTimestamp --value 2>/dev/null)
  [ -z "$t" ] && continue                      # never ran since boot
  [ "$r" = success ] && line OK "backup job $m" "last run $t: success" || line CRIT "backup job $m" "last run $t: $r (see /u02/backup/logs)"
done

# 3. FRA usage
p=$(q "select round(space_used / space_limit * 100) from v\$recovery_file_dest;")
r=$(q "select round(space_reclaimable / space_limit * 100) from v\$recovery_file_dest;")
s=OK; [ "$p" -ge "$FRA_WARN" ] && s=WARN; [ "$p" -ge "$FRA_CRIT" ] && s=CRIT
line $s "fra used" "${p} % (reclaimable ${r} %)"
# V$RECOVERY_FILE_DEST only counts files the FRA manages. Archived logs written with LOCATION=+FRA instead
# of USE_DB_RECOVERY_FILE_DEST are not counted and never auto-deleted: on 2026-10-29 orcl showed "16 %"
# while +FRA had 208 MB of 20 GB free and the primary hung (Stuck Archiver). So check the disk group too.
dg=$(q "select value from v\$parameter where name = 'db_recovery_file_dest';")
case $dg in
  +*) f=$(q "select round(free_mb / total_mb * 100) || ' ' || free_mb || ' ' || total_mb from v\$asm_diskgroup where name = upper('${dg#+}');")
      read -r fp fm tm <<< "$f"
      if [ -n "$fp" ]; then
        s=OK; [ $((100 - fp)) -ge "$FRA_WARN" ] && s=WARN; [ $((100 - fp)) -ge "$FRA_CRIT" ] && s=CRIT
        line $s "fra disk group" "$dg: $fm MB free of $tm MB"
      fi ;;
esac
n=$(q "select count(*) from v\$archived_log where deleted = 'NO' and is_recovery_dest_file = 'NO' and name like '$dg%';")
[ "${n:-0}" -gt 0 ] && line WARN "archived logs" "$n in $dg but not managed by the FRA (archive dest not USE_DB_RECOVERY_FILE_DEST): never auto-deleted"

# 4. every online redo member exists on disk, every group has >= 2 members
missing=0
asm=0
while read -r g m; do
  # ASM members (+DG/...) cannot be tested with -f; V$LOGFILE status is all there is from here
  case $m in +*) asm=$((asm + 1)); continue ;; esac
  [ -f "$m" ] || { line CRIT "redo member" "group $g: $m MISSING on disk"; missing=$((missing + 1)); }
done < <(q "select group# || ' ' || member from v\$logfile where type = 'ONLINE';")
single=$(q "select listagg(group#, ',') from (select group# from v\$logfile where type = 'ONLINE' group by group# having count(*) < 2);")
# sqlplus may print an empty listagg as "(null)" (SET NULL in a login script) — that is not a finding
[ "$single" = "(null)" ] && single=""
[ -n "$single" ] && line WARN "redo multiplexing" "groups with one member: $single"
[ "$missing" -eq 0 ] && line OK "redo members" "$(q "select count(*) from v\$logfile where type = 'ONLINE';") online members$( [ $asm -gt 0 ] && echo ", $asm in ASM (not checked on disk)")"

# 5. archive destinations (local + standby)
while read -r d st err; do
  [ "$st" = VALID ] && line OK "archive dest $d" "$st" || line CRIT "archive dest $d" "$st $err"
done < <(q "select dest_id || ' ' || status || ' ' || error from v\$archive_dest where status <> 'INACTIVE' and destination is not null;")

# 6. GoldenGate capture (if any)
while read -r c st; do
  [ "$st" = ENABLED ] && line OK "gg capture $c" "$st" || line CRIT "gg capture $c" "$st"
done < <(q "select capture_name || ' ' || status from cdb_capture;")

# 7. capacity
# 7a. disk groups holding datafiles (the FRA disk group is check 3)
for g in $(q "select distinct upper(regexp_substr(name, '^\+([^/]+)', 1, 1, null, 1)) from v\$datafile where name like '+%';"); do
  [ "+$g" = "$(echo "$dg" | tr '[:lower:]' '[:upper:]')" ] && continue
  read -r fm tm <<< "$(q "select free_mb || ' ' || total_mb from v\$asm_diskgroup where name = '$g';")"
  [ -n "$tm" ] && [ "$tm" -gt 0 ] || continue
  u=$(( (tm - fm) * 100 / tm )); s=OK; [ $u -ge "$DATA_WARN" ] && s=WARN; [ $u -ge "$DATA_CRIT" ] && s=CRIT
  line $s "data disk group" "+$g: $fm MB free of $tm MB ($u % used)"
done
# 7b. file systems: root, ORACLE_BASE, and wherever non-ASM datafiles or the FRA live (one line per mount)
dirs="/ ${ORACLE_BASE:-/u01/app/oracle} $(q "select distinct substr(name, 1, instr(name, '/', -1) - 1) from v\$datafile where name like '/%';")"
case $dg in /*) dirs="$dirs $dg" ;; esac
while read -r _ _ _ avail pct mnt; do
  u=${pct%\%}; s=OK; [ "$u" -ge "$FS_WARN" ] && s=WARN; [ "$u" -ge "$FS_CRIT" ] && s=CRIT
  line $s "fs $mnt" "$u % used, $((avail / 1024)) MB free"
done < <(df -Pk $dirs 2>/dev/null | awk 'NR > 1 && !seen[$6]++')
# 7c. primary only: redo each standby destination has not received yet (current incarnation) = what it will
#     pull when transport is switched on again. Logs already deleted here cannot be shipped (FAL) — the
#     standby would need them restored from a backup.
if [ "$role" = PRIMARY ]; then
  while read -r d st; do
    read -r mb n del <<< "$(q "with inc as (select resetlogs_change# r from v\$database_incarnation where status = 'CURRENT'),
        rcv as (select thread#, max(sequence#) s from v\$archived_log, inc
                 where dest_id = $d and standby_dest = 'YES' and resetlogs_change# = inc.r group by thread#),
        loc as (select l.thread#, l.sequence#, l.blocks * l.block_size b, l.deleted from v\$archived_log l, inc
                 where l.standby_dest = 'NO' and l.resetlogs_change# = inc.r
                   and l.dest_id = (select min(dest_id) from v\$archive_dest where target = 'PRIMARY' and status = 'VALID'))
      select round(nvl(sum(loc.b), 0) / 1048576) || ' ' || count(*) || ' ' || count(case when loc.deleted = 'YES' then 1 end)
        from loc left join rcv on rcv.thread# = loc.thread# where loc.sequence# > nvl(rcv.s, 0);")"
    s=OK; [ "${mb:-0}" -ge "$GAP_WARN_MB" ] && s=WARN; [ "${del:-0}" -gt 0 ] && s=WARN
    line $s "redo gap dest $d" "$st: ${mb:-0} MB in ${n:-0} archived logs not received$( [ "${del:-0}" -gt 0 ] && echo ", $del already deleted here (restore needed)")"
  done < <(q "select dest_id || ' ' || status from v\$archive_dest where target = 'STANDBY' and destination is not null and status <> 'INACTIVE';")
fi

# 8. primary with Fast-Start Failover: the observer is there and the target is synchronized. On 2026-11-03 the
#    observer hung after the primary was reset ("Primary database cannot be reached" for 25 min) and redo transport
#    fell back to UNSYNCHRONIZED; a power-off of the primary then caused no failover — and nothing had said so.
if [ "$role" = PRIMARY ]; then
  read -r fs ob tg <<< "$(q "select replace(fs_failover_status, ' ', '_') || ' ' || fs_failover_observer_present || ' ' || nvl(fs_failover_current_target, '-') from v\$database;")"
  case $fs in
    DISABLED|"") ;;
    SYNCHRONIZED) [ "$ob" = YES ] && line OK "fsfo" "$fs, observer present, target $tg" \
                                  || line CRIT "fsfo" "$fs but observer NOT present (target $tg): no automatic failover" ;;
    *) line CRIT "fsfo" "$fs, observer present=$ob (target $tg): a failover now could not be automatic" ;;
  esac
fi

exit $crit
