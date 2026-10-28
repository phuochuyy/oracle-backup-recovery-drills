# Drill 5 — RESETLOGS and whole-database failures on a throw-away CDB

These drills open the database with `RESETLOGS` or destroy it completely. On orcl3 that would break its
standby and the GoldenGate Extract, so they run on **DRILL**: a copy of orcl3 made with a backup-based
`DUPLICATE` on stb3 while the standby instance there is stopped ([`create_drill.sh`](create_drill.sh),
102 s, PDBs PERF/GGREPL/RCAT skipped). DRILLPDB carries BANKDB, so every drill ends with the same checksum
check as on orcl3.

[`drills.sh`](drills.sh) `prep` adds an spfile, Flashback Database, control file autobackup to
`/u02/drill/drill_bkp` and a level 0. Each drill then breaks something for real (`shutdown abort` + `rm`).
RTO = from the failure being visible to the data verified.

| # | Failure | Recovery | RTO | Data |
|---|---------|----------|-----|------|
| 5a | all control files deleted (`ORA-00205`) | `SET DBID`; restore control file from autobackup; recover; `OPEN RESETLOGS` | 15 s | PASS |
| 5b | SYSTEM datafile deleted (`ORA-01157`) | mount; restore + recover datafile 1; open (no resetlogs) | 34 s | PASS |
| 5c | spfile and pfile deleted (`LRM-00109`) | `SET DBID`; dummy instance; restore spfile from autobackup | 9 s | PASS |
| 5d | `DROP USER bank CASCADE` | `FLASHBACK DATABASE TO SCN`; `OPEN RESETLOGS` | 17 s | PASS |
| 5e | `DROP TABLE bank.cards PURGE` (not in recycle bin) | PDB PITR: restore + recover DRILLPDB `UNTIL SCN`; open PDB resetlogs | 25 s | PASS |
| 5f | host loss: all datafiles, tempfiles, redo, control files, spfile, flashback logs | spfile → control file → restore + recover database → `OPEN RESETLOGS` | 76 s | PASS |

Small database (≈ 5 GB, local disk), so the times show the procedure, not a production RTO.

## What went wrong first (logs kept as `run-*-first-attempt.log`)

- **5a — wrong control file autobackup.** The autobackup format is stored in the control file that was
  lost. RMAN looked only in the FRA, found an *older* autobackup (from the DUPLICATE), and recovery
  stopped one log short: `ORA-01194 file 1 needs more recovery to be consistent`. Adding
  `SET CONTROLFILE AUTOBACKUP FORMAT` alone did not help — the log said
  `search with format ... not attempted because DBID was not set`. With `SET DBID` first it found the
  right piece. **Keep the DBID in the runbook / backup log.**
- **5b — PDBs stayed MOUNTED** after the restart, so my check failed although the recovery had worked.
  `ALTER PLUGGABLE DATABASE ALL SAVE STATE` belongs in every CDB's setup.
- **5c — `RMAN-06172 no AUTOBACKUP found`.** The dummy instance started without any parameter file knows
  neither the FRA nor the autobackup location; it only searched `$ORACLE_HOME/dbs`. The format has to be
  `SET` inside a `RUN` block before `RESTORE SPFILE FROM AUTOBACKUP`.

## Notes

- 5f ends recovery with `RMAN-06054 media recovery requesting unknown archived log` — expected: the online
  redo is gone, so recovery stops after the last archived log and anything only in the lost online log is
  lost. Here nothing was, because the level 0 just before archived the current log. On a real host loss
  the data-loss window is the time since the last archived-log backup (30 min on orcl3) — or zero with
  a SYNC standby, which is the better answer to host loss.
- 5e needed **no auxiliary instance**: with local undo (default since 12.2) RMAN recovers the PDB in place;
  the CDB and the other PDBs stayed open.
- 5d vs 5e: Flashback Database rewinds the whole CDB (all PDBs lose their changes after the SCN);
  PDB PITR rewinds only one PDB but needs a restore.
- 4 RESETLOGS left 5 incarnations in `V$DATABASE_INCARNATION`; RMAN recovered across them without help
  (5b restored a backup from an earlier incarnation).
- Never `NOFILENAMECHECK` when duplicating onto a host that already has a database with the same paths.
