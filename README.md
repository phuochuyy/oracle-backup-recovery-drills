# Oracle Backup & Recovery Drills — RMAN · Flashback · measured RTO

> Status: **planned**. A backup is only proven by a restore: each drill records the steps run,
> the time to recover, and the data verified afterwards.

## Goal

Design a backup strategy for the lab databases and rehearse the failures a DBA must recover from,
with a runbook and a measured recovery time for each.

## Strategy to implement

- ARCHIVELOG, Fast Recovery Area sizing, block change tracking
- Incremental level 0 weekly + level 1 daily, compressed, `BACKUP OPTIMIZATION ON`
- Backups offloaded to the Data Guard standby (Region B: stb3), retention policy + `DELETE OBSOLETE`
- Control file / SPFILE autobackup; `RESTORE ... VALIDATE` scheduled check
- Optional: Zero Data Loss–style archive log retention on the standby

## Drills

| # | Failure | Recovery | Record |
|---|---------|----------|--------|
| 1 | Lost datafile (non-system) | `RESTORE/RECOVER DATAFILE` (also `FROM SERVICE` standby) | RTO, rows checked |
| 2 | Lost SYSTEM datafile | mount, restore, recover | RTO |
| 3 | Lost all control files | restore from autobackup, `RESETLOGS` | RTO, SCN |
| 4 | Lost SPFILE | restore from autobackup | RTO |
| 5 | Lost redo log member / group | clear / recreate | impact |
| 6 | Logical error: dropped table | Flashback Drop; `RECOVER TABLE ... UNTIL SCN` | rows restored |
| 7 | Bad batch update | Flashback Query / Table / Database | SCN used, rows |
| 8 | PDB point-in-time recovery | `RECOVER PLUGGABLE DATABASE UNTIL ...` | RTO, other PDBs unaffected |
| 9 | Block corruption | `VALIDATE`, `RECOVER ... BLOCK` | blocks repaired |
| 10 | Full loss of host | restore to new VM / `DUPLICATE` | end-to-end RTO |

## Deliverables checklist

- [ ] `01-strategy/` RMAN configuration + backup scripts + cron/systemd timers
- [ ] `02-drills/<n>-<name>.md` per drill: how the failure was caused, commands, output, RTO
- [ ] `03-runbooks/` one-page recovery runbook per failure type
- [ ] `04-scripts/` backup monitoring (last backup age, FRA usage, `V$RMAN_STATUS` errors)
- [ ] RTO summary table in this README

## CV line (fill only with measured numbers)

`Ran N RMAN/Flashback recovery drills (datafile, control file, PITR, table recovery); RTO X–Y min.`
