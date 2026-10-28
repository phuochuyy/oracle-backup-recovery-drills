# Runbooks

One page per failure type, written from the drills (every command here was run in a drill; the RTO is the
measured one on a small lab database). Start with the first column.

| Symptom | Runbook |
|---------|---------|
| `ORA-01157`, `ORA-01110` — a datafile is missing (non-SYSTEM, SYSTEM) | [01-datafile.md](01-datafile.md) |
| `ORA-01578` — corrupted block | [02-block-corruption.md](02-block-corruption.md) |
| Rows/table/user dropped, truncated or wrongly updated | [03-logical-error.md](03-logical-error.md) |
| `ORA-00313`, `ORA-00312` — redo member/group missing | [04-redo-log.md](04-redo-log.md) |
| `ORA-00205` control file, `LRM-00109` spfile, whole host gone | [05-controlfile-spfile-host.md](05-controlfile-spfile-host.md) |

## Before any of them

1. **Stop and write down the time** and the first error text. Do not restart things repeatedly.
2. Is there a **standby**? For a primary with a SYNC standby, failover may be faster and lose nothing —
   decide with the business, do not repair the primary just because you can.
3. Is the database a **GoldenGate source**? RESETLOGS, clearing an unarchived log or Flashback Database
   all break the Extract's position; plan the GG side before you start.
4. Know the **DBID** (it is in the backup log and in `check_backup_health.sh`-style reports). Without it,
   RMAN does not search your autobackup location (drill 5a).
5. After recovery: verify the data (here: BANKDB checksums), run `check_backup_health.sh`, and take a new
   level 0 after every `RESETLOGS`.
