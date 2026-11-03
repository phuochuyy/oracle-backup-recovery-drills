# Oracle Backup & Recovery Drills — RMAN · Flashback · measured RTO

A backup is only proven by a restore. RMAN strategy for a single instance (orcl3) and a RAC whose backups run on
its Data Guard standby, then **14 recovery drills**, each timed and checked with data checksums afterwards
([`verify_drillpdb.sh`](04-scripts/verify_drillpdb.sh)).

- Strategy: level 0 weekly / level 1 daily / archived logs every 30 min (systemd timers), compressed backupsets,
  block change tracking (level 1 read 1,135 of 1,823,744 blocks = 0.062 %), recovery catalog, RAC backups offloaded
  to the standby, weekly `RESTORE … VALIDATE`, hourly [health check](04-scripts/check_backup_health.sh).

| # | Failure | Where | Recovery | RTO | Data |
|---|---------|-------|----------|-----|------|
| 1a | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | `RESTORE ... FROM SERVICE` standby | 14 s (45–49 s re-run with TDE, restore itself unchanged) | PASS |
| 1b | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | standby's backup via recovery catalog | 17 s (re-run 29/10: **failed** after 2 failovers — old-incarnation level 0, `ORA-01207`; PASS in 20 s after a new level 0) | PASS |
| 2a | [Dropped table](02-drills/02-logical-errors/) | RAC primary | Flashback Drop + re-create the lost FK | < 1 s (re-run 29/10: same) | PASS |
| 2b | [Bad batch update](02-drills/02-logical-errors/) | RAC primary | versions query (SCN) + Flashback Table | ~7 min (6:49–7:48 in 4 runs; I had written "< 1 s"): unindexed child foreign keys — [3 s with them indexed](02-drills/02-logical-errors/README.md#why-flashback-table-took-7-minutes-2026-11-01) | PASS |
| 3 | [Corrupted block](02-drills/03-block-corruption/) | orcl3, filesystem | `VALIDATE` + `RECOVER CORRUPTION LIST`, PDB stays open | 20 s (re-run: 111 s — 110 archived logs since the level 0) | PASS |
| 4 | [TRUNCATE by mistake](02-drills/04-recover-table/) | orcl3 | `RECOVER TABLE ... UNTIL SCN` (auxiliary instance) + copy back | 221 s (re-run: 253 s) | PASS |
| 5a | [All control files lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | `SET DBID`, control file from autobackup, `RESETLOGS` | 15 s | PASS |
| 5b | [SYSTEM datafile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | mount, restore + recover datafile 1 | 34 s | PASS |
| 5c | [spfile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | dummy instance, spfile from autobackup | 9 s | PASS |
| 5d | [`DROP USER ... CASCADE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | Flashback Database to SCN | 17 s | PASS |
| 5e | [`DROP TABLE ... PURGE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | PDB point-in-time recovery (no auxiliary instance) | 25 s | PASS |
| 5f | [Host loss (only backups left)](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | spfile → control file → database, `RESETLOGS` | 76 s | PASS |
| 6a | [One redo member lost](02-drills/06-redo-log/) | orcl3 (primary, GG source) | drop + add member; **GoldenGate Extract was down 2.5 min** | 0 s DB | PASS |
| 6b | [Whole redo group lost](02-drills/06-redo-log/) | orcl3 | found by health check, `CLEAR LOGFILE` (inactive, archived) | 5 s (re-run: 6 s) | PASS |

- Incident: the RAC primary hung on a full `+FRA` (Stuck Archiver) while monitoring said 16 % — archived logs
  outside the recovery area; and my clean-up then removed logs a GoldenGate capture still needed.
- Latest re-check after the HA/DR run 5: drills 1a 25 s, 2 PASS, 6b 5 s; drill 1's passwords moved off the command line.
- Full write-up (strategy, incident, re-checks, fixes): [`docs/details.md`](docs/details.md) · runbooks:
  [`03-runbooks/`](03-runbooks/README.md) · problems and my own mistakes: [`notes/worklog.md`](notes/worklog.md).
