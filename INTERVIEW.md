# Interview notes — Oracle Backup & Recovery Drills

> Status: strategy and the first drills are done; the destructive drills (control file, SYSTEM,
> PITR, host loss) are still to come — say so if asked.

## The 2-minute story

I set up RMAN for two databases: a single instance (orcl3) with weekly level 0, daily level 1 and
30-minute archived-log backups, and a 2-node RAC (orcl) whose backups are **offloaded to its Active Data
Guard standby** and registered in a **recovery catalog**. Then I break things on purpose and time the
recovery. Every drill ends with a checksum comparison of a known dataset (BANKDB in DRILLPDB), so
"recovered" means the data is provably identical, not just "the database opened".

What I found on the way was more useful than the drills themselves: the archived-log deletion policy could
delete a log before it had been backed up (a hole in point-in-time recovery); MEDIUM compression was
configured although it needs the Advanced Compression license; and without a catalog the primary did not
even know the standby's backups existed.

## Likely questions

**Recovery window or redundancy?** Recovery window (7 days): the question the business asks is "can we go
back to any point in the last week?", not "how many copies do we have?".

**What does block change tracking do?** It records changed blocks so a level 1 reads only those: my level 1
read 1,135 of 1.8 M blocks (0.1 %) and took 10 s instead of scanning every datafile.

**How do you lose a datafile and get it back?** Drill 1: datafile deleted from ASM, `ORA-01157` on open.
Fastest with a standby: `RESTORE DATAFILE n FROM SERVICE <standby>; RECOVER DATAFILE n;` — 14 s, no backup
needed. From the standby's backup via the catalog: 17 s.

**Why a recovery catalog?** Without one, RMAN cannot `CONFIGURE` on a standby (RMAN-05021), the primary
cannot see backups taken on the standby, and per-database settings (`FOR DB_UNIQUE_NAME`) are impossible.
With backup offload to a standby it is effectively mandatory.

**Archived-log deletion policy — what is right?** On the database that is backed up: applied on all standbys
**and** backed up at least once. With only "applied on standby" an automatic cleanup can delete a log
before the next backup and break PITR into that window.

**Someone dropped a table.** If the recycle bin has it: `FLASHBACK TABLE ... TO BEFORE DROP` in < 1 s —
but foreign keys are not restored and indexes/constraints come back with `BIN$` names (drill 2a).
If it was truncated or purged: `RECOVER TABLE ... UNTIL SCN` from backup — drill 4: 500,000 rows back in
221 s through an automatic auxiliary instance.

**A query fails with ORA-01578.** Find all bad blocks with `VALIDATE`, repair only those with
`RECOVER CORRUPTION LIST` — the PDB stays open (drill 3, 20 s). With an ADG standby, 23ai repairs it
automatically from the standby.

**A batch updated the wrong rows yesterday.** Find what changed with a versions query (by **SCN** —
`VERSIONS BETWEEN TIMESTAMP` has ~3 s granularity and found nothing in my first try), then
`FLASHBACK TABLE ... TO SCN` (needs row movement), or Flashback Database / PITR for wider damage.

**Which RMAN compression can I use without extra license?** BASIC. LOW, MEDIUM and HIGH need the Advanced
Compression Option.

## 5-minute demo

```bash
# lost datafile on the RAC primary, restored from the standby
DB_PASSWORD=... RCO_PASSWORD=... ./02-drills/01-lost-datafile/drill.sh service
#   ORA-01157 ... RTO 14 s ... verify: PASS
```

## Limitations

- No shared backup storage between sites in the lab: restoring the primary from standby backups needs the
  pieces copied first (the drill does it and counts it in the RTO).
- RAC with one running node (host RAM).
