# Runbook — Online redo log member or group missing

**Symptoms:** alert log `ORA-00313 open failed for members of log group n`, `ORA-00312`, `ORA-27037`.
`V$LOGFILE.STATUS` may still say OK (LGWR keeps deleted files open) — check the files on disk
(`check_backup_health.sh` does). On a **GoldenGate source**: capture `ABORTED`, `ORA-01343`, `ORA-01304`.

## Decide

```sql
select l.group#, l.status, l.archived, f.member, f.status from v$log l join v$logfile f using (group#);
```

| Lost | Group state | Action | Data loss |
|------|-------------|--------|-----------|
| one member | any | when INACTIVE: drop member, add member | none |
| all members | INACTIVE, archived | `ALTER DATABASE CLEAR LOGFILE GROUP n` | none (drill 6b: 5 s) |
| all members | INACTIVE, not archived | `CLEAR UNARCHIVED LOGFILE GROUP n`, then **level 0 at once** | PITR across that sequence; GG cannot read it |
| all members | ACTIVE | `ALTER SYSTEM CHECKPOINT`, then as INACTIVE | none if the instance is up |
| all members | CURRENT | instance crashes → failover to SYNC standby, or restore + `RECOVER UNTIL CANCEL`, `RESETLOGS` | without standby: the current log |

## Commands (drill 6a)

```sql
alter system switch logfile;  alter system checkpoint;      -- until the group is INACTIVE
alter database drop logfile member '/u02/redo2/redo13b.log';
alter database add logfile member '/u02/redo2/redo13b.log' to group 13;   -- INVALID until first used
```
Then check the GoldenGate capture (`cdb_capture.status = ENABLED`) and Extract lag.

## Traps I hit

- **One missing member stopped GoldenGate for 2.5 min** although the database was fine: when the group
  became CURRENT, LogMiner failed to open it. On a GG source, fix a missing member immediately.
- orcl3 had **one member per group on the datafile disk** — found during this drill. Two members on
  different disks is the baseline.
