# Drill 6 — Lost online redo log members, on the primary with a standby and GoldenGate

**Finding first:** every online redo group of orcl3 had **one member**, on the same disk as the datafiles
and the FRA. Losing the CURRENT group would lose committed transactions. Fixed online with
[`multiplex_redo.sh`](../../01-strategy/multiplex_redo.sh): a second member per group on the other disk.

## 6a — one member deleted (explored by hand, [`explore-6a.log`](explore-6a.log))

`rm /u02/redo2/redo13b.log` while group 13 was INACTIVE, then log switches.

| What | Result |
|------|--------|
| Database | kept running; LGWR writes to the surviving member (and still holds the deleted file open) |
| `V$LOGFILE.STATUS` | still **OK** — not a useful alarm for this |
| Alert log | `ORA-00313 / ORA-00312 / ORA-27037` from processes that open the file by name |
| Archiving | fine — ARCn archived the group from the surviving member |
| **GoldenGate Extract** | **down 2.5 min**: when group 13 became CURRENT, the capture's LogMiner reader failed to open it (`ORA-00313` → `ORA-01343 corruption in the logstream`), capture `ABORTED` (`ORA-01304`), Extract abended and restarted in a loop |

**Repair:** switch until the group is INACTIVE, `ALTER DATABASE DROP LOGFILE MEMBER`, `ADD LOGFILE MEMBER`
(new member shows INVALID until first written). The capture came back by itself (Extract autorestart),
lag 0 a few seconds later, no data loss (Extract restarts from its checkpoint).

So multiplexing protected the **database**, but not the **replication**: a missing member is an incident
on a GoldenGate source, not a warning to fix next week.

## 6b — both members of a group deleted ([`drill.sh`](drill.sh), [`run-6b.log`](run-6b.log))

Only an **INACTIVE, ARCHIVED** group is used; the script re-checks that before clearing.

1. Both members deleted → [`check_backup_health.sh`](../../04-scripts/check_backup_health.sh) reports
   `CRIT redo member ... MISSING on disk` (it checks the files, not `V$LOGFILE`).
2. `ALTER DATABASE CLEAR LOGFILE GROUP n` re-creates both members.
3. Switch through all groups, health check OK. GoldenGate not affected — the group had already been read.

**RTO 5 s.**

| Group state when lost | Action | Data loss |
|------|--------|-----------|
| INACTIVE, archived | `CLEAR LOGFILE` | none |
| INACTIVE, **not** archived | `CLEAR UNARCHIVED LOGFILE` → take a new level 0 at once; the missing sequence breaks PITR across it and GoldenGate cannot read it | PITR window |
| ACTIVE (needed for crash recovery) | `ALTER SYSTEM CHECKPOINT`, then as INACTIVE; if the instance is already down: restore + incomplete recovery | possibly |
| CURRENT | instance crashes; incomplete recovery `UNTIL CANCEL` / failover to the SYNC standby (the better answer) | without standby: the current log's changes |

The last two rows were not run on orcl3 (it is a primary with a standby and GoldenGate).

## Notes

- My first 6b run stopped after the repair: a PL/SQL block with no output → `grep` returned 1 → `set -e`
  ([first attempt](run-6b-first-attempt.log)). Same bug class as in drill 3 and the perf lab.
- On Linux, `rm` of an open file does not stop the writer — a real disk failure would surface as I/O errors
  in LGWR instead; the effect on readers that open by name (LogMiner, ARCn, RMAN) is the same.
