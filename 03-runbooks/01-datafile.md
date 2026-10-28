# Runbook — Lost or damaged datafile

**Symptoms:** `ORA-01157: cannot identify/lock data file n`, `ORA-01110`; PDB will not open; or the file
is reported in `V$RECOVER_FILE`.

## Decide

| File | Database state | Path |
|------|----------------|------|
| non-SYSTEM (user/PDB data) | CDB stays open | offline the file / close the PDB, restore, recover, online |
| SYSTEM or UNDO of the root | instance down | mount, restore, recover, open |
| any, standby available | — | `RESTORE ... FROM SERVICE <standby>` — no local backup needed, fastest |

## Commands

```sql
-- which file, which PDB
select file#, error, change# from v$recover_file;
select file#, con_id, name from v$datafile where file# = &n;
```
```
-- non-SYSTEM, CDB open (drill 1: 14 s from the standby, 17 s from the standby's backup)
ALTER PLUGGABLE DATABASE drillpdb CLOSE IMMEDIATE;      -- or: ALTER DATABASE DATAFILE n OFFLINE;
RESTORE DATAFILE n FROM SERVICE orcl_stb;               -- or: RESTORE DATAFILE n;
RECOVER DATAFILE n;
ALTER PLUGGABLE DATABASE drillpdb OPEN;

-- SYSTEM (drill 5b: 34 s)
STARTUP FORCE MOUNT;
RESTORE DATAFILE 1;
RECOVER DATAFILE 1;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
```

## Verify

`select count(*) from v$recover_file;` = 0, application data check, `check_backup_health.sh`.

## Traps I hit

- Backups taken **on the standby** restore the primary (same DBID), but the primary only sees them through
  a **recovery catalog**; and pieces on another host must be copied and `CATALOG START WITH` first.
- After a restart **PDBs stay MOUNTED** unless their state was saved (`ALTER PLUGGABLE DATABASE ALL SAVE STATE`)
  — my first 5b check "failed" although recovery had worked.
- ASM/OMF gives the restored file a new name; RMAN updates the control file, do not rename by hand.
