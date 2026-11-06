# Strategy: backup and recovery

The plan behind this lab, written as I would for a real system. Results: [details](details.md). Procedures: [runbooks](../03-runbooks/README.md).

## Goal

Be able to restore to any point in the retention window, and know it works: a backup only counts once a restore from it has been proven. Data Guard is not a backup: a mistaken delete reaches the standby in seconds.

## Plan

| | orcl3 (single instance) | orcl (RAC) |
|-|-------------------------|------------|
| Where the job runs | the database itself | the current **standby**, so the primary carries no backup load |
| Level 0 | Sunday 03:00 | Sunday 04:00 |
| Level 1 | daily 02:00, with block change tracking | daily 03:30 |
| Archived logs | every 30 minutes | with each backup |
| Proof | restore validate, Sunday 05:00 | restore validate, Sunday 05:30 |
| Catalog | control file | recovery catalog in `RCAT`, resynced from the primary before every backup |
| Retention | recovery window 7 days | recovery window 7 days |
| Encryption | AES256 with the TDE keystore | same |

## Choices, and what they cost

| Choice | Why | Cost |
|--------|-----|------|
| Recovery window, not redundancy | The question that matters: can I restore to any point in the last 7 days? | With a weekly level 0, up to two weeks of backups stay on disk |
| Offload to the standby | No backup load on the primary | Needs a catalog, and a resync after every failover or the backup is not recorded |
| Encrypted backups | A stolen piece is unreadable | A restore needs the keystore, so its off-host copy is part of recovery |
| Deletion only when applied on the standby and backed up once | No gap in point-in-time recovery | With a standby off for long, archived logs cannot be deleted automatically |
| Restore from the standby first | Fastest for a lost file on a Data Guard pair, no local backup needed | Only if the standby is healthy |

## When something breaks

Stop, write down the first error and the time. Find the smallest thing that restores service: block, file, table, PDB, then whole database. Check first whether the database is a GoldenGate source: `RESETLOGS` and clearing an unarchived log break the Extract's position. Then the [runbook](../03-runbooks/README.md) for that failure. After any restore, verify the data ([checksums](../04-scripts/verify_drillpdb.sh)).

## Monitoring

An hourly health check reports backup age per datafile (on the site that takes the backups), recovery area, disk groups, file systems, redo gap per standby, and the capture's restart point. Exit code is the number of critical findings.

## Against 3-2-1

| Rule | Here |
|------|------|
| 3 copies | Database, standby, backup pieces. The standby is not a backup, so this is only partly met |
| 2 media | Separate virtual disks, one physical disk: **not met** |
| 1 off-site | **Not met.** On a real system: object storage or tape, with immutable retention |

## Limits

One host, so a host loss was only simulated with a throw-away database. Drills ran on small datasets, so recovery times do not scale directly. Lab disk space forced one manual shortening of orcl3's window; on a real system that is the data owner's decision.
