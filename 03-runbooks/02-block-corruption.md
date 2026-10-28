# Runbook — Corrupted block

**Symptoms:** `ORA-01578: ORACLE data block corrupted (file # n, block # b)`, `ORA-01110`; a query or
RMAN backup fails on one object while the rest works.

## Decide

Repair only the blocks — the datafile and the PDB stay online. With an Active Data Guard standby, 23ai has
usually already repaired it automatically from the standby (check the alert log).

## Commands (drill 3: 20 s, PDB open)

```
VALIDATE DATAFILE n;                       -- or VALIDATE DATABASE; finds ALL bad blocks, not just the first
```
```sql
select file#, block#, blocks, corruption_type from v$database_block_corruption;
```
```
RECOVER CORRUPTION LIST;                   -- or RECOVER DATAFILE n BLOCK b;
```

## Verify

`v$database_block_corruption` empty after a new `VALIDATE`; the failing query works; data check.

## Traps I hit

- **RMAN `VALIDATE` exits non-zero when it finds corruption** — in a script with `set -e` that stops
  everything with the block still broken. Check the output, not only the exit code.
- Block numbers from a rowid in a **bigfile** tablespace need `DBMS_ROWID.ROWID_BLOCK_NUMBER(rowid, 'BIGFILE')`.
- Find out *why* (storage, `dd`, a bug): the alert log and OS logs, before the next corruption.
