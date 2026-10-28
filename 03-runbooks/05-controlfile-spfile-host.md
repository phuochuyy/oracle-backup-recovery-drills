# Runbook — Control files, spfile, or the whole host lost

**Symptoms:** `ORA-00205: error in identifying control file`; `ORA-01078` + `LRM-00109 could not open
parameter file`; or nothing left but the backup location.

**Needed beforehand:** the **DBID**, the autobackup location/format, a backup location reachable from the
(new) host. Without `SET DBID`, RMAN searches only the default locations.

## Control files (drill 5a: 15 s)

```
SET DBID 1600577461;
STARTUP NOMOUNT;
RUN { SET CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '/u02/drill/drill_bkp/cf_%F';
      RESTORE CONTROLFILE FROM AUTOBACKUP; }
ALTER DATABASE MOUNT;
RECOVER DATABASE;              -- online logs still there -> complete recovery
ALTER DATABASE OPEN RESETLOGS;
```

## spfile (drill 5c: 9 s)

```
SET DBID 1600577461;
STARTUP FORCE NOMOUNT;         -- RMAN starts a dummy instance without a parameter file
RUN { SET CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '/u02/drill/drill_bkp/cf_%F';
      RESTORE SPFILE FROM AUTOBACKUP; }
STARTUP FORCE;
```

## Whole host (drill 5f: 76 s on 5 GB)

Install the same Oracle Home on the new host, make the backups reachable, then:
spfile (as above) → `STARTUP FORCE NOMOUNT` → control file (as above) → `MOUNT` → `RESTORE DATABASE` →
`RECOVER DATABASE` (ends with `RMAN-06054 ... unknown archived log` — expected, the online redo is gone) →
`OPEN RESETLOGS` → `ALTER PLUGGABLE DATABASE ALL OPEN`.
Data since the last archived-log backup is lost — with a SYNC standby, **fail over instead**.

## After

New level 0 (new incarnation), check `V$DATABASE_INCARNATION`, save PDB state, re-point standby/GoldenGate.

## Traps I hit

- **5a:** RMAN took an *older* autobackup from the FRA → `ORA-01194 file 1 needs more recovery`. `SET ... FORMAT`
  was ignored: "search with format ... not attempted because DBID was not set".
- **5c:** `RMAN-06172 no AUTOBACKUP found` — the dummy instance only searched `$ORACLE_HOME/dbs`.
- A `DUPLICATE` onto a host with another database using the same paths: never `NOFILENAMECHECK`.
