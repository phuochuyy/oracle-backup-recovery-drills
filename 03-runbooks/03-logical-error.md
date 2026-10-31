# Runbook — Logical error (wrong DROP, TRUNCATE, UPDATE/DELETE)

**Symptoms:** "the data is gone / wrong" — no ORA- error. First question: **when exactly** (time, or
better an SCN), which objects, what else changed since?

## Decide — smallest tool that works

| What happened | Tool | Measured |
|---------------|------|----------|
| `DROP TABLE` (no PURGE) | `FLASHBACK TABLE t TO BEFORE DROP` | < 1 s (drill 2a) |
| wrong `UPDATE`/`DELETE`, undo still has it | versions query by SCN, `FLASHBACK TABLE t TO SCN s` | < 1 s for a small table; **~7 min** for 4,285 rows of `ACCOUNTS` with unindexed child foreign keys, 3 s with them indexed (drill 2b) |
| `TRUNCATE`, `DROP ... PURGE`, undo too old | `RECOVER TABLE ... UNTIL SCN` (auxiliary instance) | 221 s for 500 K rows (drill 4) |
| many objects / a whole schema in one PDB | PDB point-in-time recovery | 25 s (drill 5e) |
| whole CDB, Flashback Database on | `FLASHBACK DATABASE TO SCN` | 17 s (drill 5d) |

## Commands

```sql
-- what changed (by SCN, not TIMESTAMP — ~3 s granularity, my first try found 0 rows)
select versions_startscn, versions_operation, t.* from bank.accounts versions between scn :a and :b t where ...;
alter table bank.accounts enable row movement;
flashback table bank.accounts to scn :before;
flashback table bank.accounts to before drop;          -- FKs pointing to it are NOT restored, indexes get BIN$ names
```
```
RECOVER TABLE bank.transactions OF PLUGGABLE DATABASE drillpdb
  UNTIL SCN s AUXILIARY DESTINATION '/u02/backup/aux'
  REMAP TABLE bank.transactions:transactions_rec;      -- then copy rows back (original still exists, empty)

ALTER PLUGGABLE DATABASE drillpdb CLOSE IMMEDIATE;      -- PDB PITR
RUN { SET UNTIL SCN s; RESTORE PLUGGABLE DATABASE drillpdb; RECOVER PLUGGABLE DATABASE drillpdb; }
ALTER PLUGGABLE DATABASE drillpdb OPEN RESETLOGS;
```
```sql
shutdown immediate; startup mount;                      -- Flashback Database: the WHOLE CDB goes back
flashback database to scn s; alter database open resetlogs;
```

## Traps I hit

- Flashback Drop: re-create the foreign keys that pointed at the table, rename `BIN$` indexes/constraints.
- `RECOVER TABLE` left the auxiliary instance's **online redo logs (1.6 GB)** behind — clean the auxiliary
  destination, and check it has room first.
- Flashback Database and PDB PITR: everything after the SCN is lost in that scope; on a primary with a
  standby/GoldenGate, prefer table-level tools or do it on a copy and move the data back.
