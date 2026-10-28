# Oracle Backup & Recovery Drills — RMAN · Flashback · measured RTO

> Status: backup strategy done (orcl3, and the RAC offloaded to its standby); **12 drills done** on the
> RAC primary, on orcl3 and on a throw-away CDB for the RESETLOGS ones. Still open: redo log member loss,
> one-page runbooks.
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

## Drills done

| # | Failure | Where | Recovery | RTO | Data |
|---|---------|-------|----------|-----|------|
| 1a | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | `RESTORE ... FROM SERVICE` standby | 14 s | PASS |
| 1b | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | standby's backup via recovery catalog | 17 s | PASS |
| 2a | [Dropped table](02-drills/02-logical-errors/) | RAC primary | Flashback Drop + re-create the lost FK | < 1 s | PASS |
| 2b | [Bad batch update](02-drills/02-logical-errors/) | RAC primary | versions query (SCN) + Flashback Table | < 1 s | PASS |
| 3 | [Corrupted block](02-drills/03-block-corruption/) | orcl3, filesystem | `VALIDATE` + `RECOVER CORRUPTION LIST`, PDB stays open | 20 s | PASS |
| 4 | [TRUNCATE by mistake](02-drills/04-recover-table/) | orcl3 | `RECOVER TABLE ... UNTIL SCN` (auxiliary instance) + copy back | 221 s | PASS |
| 5a | [All control files lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | `SET DBID`, control file from autobackup, `RESETLOGS` | 15 s | PASS |
| 5b | [SYSTEM datafile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | mount, restore + recover datafile 1 | 34 s | PASS |
| 5c | [spfile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | dummy instance, spfile from autobackup | 9 s | PASS |
| 5d | [`DROP USER ... CASCADE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | Flashback Database to SCN | 17 s | PASS |
| 5e | [`DROP TABLE ... PURGE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | PDB point-in-time recovery (no auxiliary instance) | 25 s | PASS |
| 5f | [Host loss (only backups left)](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | spfile → control file → database, `RESETLOGS` | 76 s | PASS |

Backups of the RAC run on the **standby** (offload) and are registered in a **recovery catalog**
(PDB RCAT on prm3): [`01-strategy/catalog`](01-strategy/catalog), [`01-strategy/offload`](01-strategy/offload).

Interview notes: [INTERVIEW.md](INTERVIEW.md). Problems I hit: [notes/worklog.md](notes/worklog.md).

## Remaining

- Lost redo log member / whole group (`CLEAR LOGFILE`, impact of an `ACTIVE`/`CURRENT` group)
- `03-runbooks/`: one page per failure type, written from the drill logs
- Backup monitoring script (last backup age, FRA usage, `V$RMAN_STATUS` errors)
