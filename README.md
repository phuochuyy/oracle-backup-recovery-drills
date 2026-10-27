# Oracle Backup & Recovery Drills — RMAN · Flashback · measured RTO

> Status: **in progress** — backup strategy done on orcl3 (single instance); drills next, on the
> RAC cluster (Region A) and on a throw-away CDB for the destructive ones.
> A backup is only proven by a restore: each drill records the steps run, the time to recover, and
> the data verified afterwards.

## Backup strategy (orcl3) — done

| Item | Setting |
|------|---------|
| Retention | recovery window of 7 days |
| Backups | level 0 weekly, level 1 daily, archived logs every 30 min (systemd timers, [`01-strategy/systemd`](01-strategy/systemd)) |
| Format | compressed backupsets, `BASIC` algorithm (EE; LOW/MEDIUM/HIGH need Advanced Compression), 2 channels |
| Location | `/u02/backup` on a different virtual disk than the datafiles |
| Block change tracking | enabled — level 1 read 0.1 % of blocks |
| Archived log deletion | applied on the standby **and** backed up once ([why](notes/worklog.md)) |
| Proof | `RESTORE DATABASE VALIDATE` + archived logs since level 0, no errors |

First results: [`01-strategy/results`](01-strategy/results/README.md) — level 0 111 s → 2.3 GB, level 1 10 s.

Test data: **DRILLPDB** with the shared BANKDB dataset at scale 1 ([`create_drillpdb.sh`](01-strategy/create_drillpdb.sh)); after every drill [`verify_drillpdb.sh`](04-scripts/verify_drillpdb.sh) compares counts and checksums with the known values.

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
