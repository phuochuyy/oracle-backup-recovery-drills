# Drill 1 — Lost datafile on the RAC primary

**Failure:** DRILLPDB's `BANK_DATA` datafile (#40, 512 MB, ASM `+DATA`) deleted with `asmcmd rm`.
Opening the PDB fails with `ORA-01157: cannot identify/lock data file 40`.
**Script:** [`drill.sh`](drill.sh) — times everything from the failed open to the PDB open again,
then checks the BANKDB checksums.

| Method | What RMAN does | RTO | Data check |
|--------|----------------|-----|------------|
| `service` | `RESTORE DATAFILE 40 FROM SERVICE orcl_stb` — pulls the file from the Data Guard standby over the network (restore 3 s), then `RECOVER` | **14 s** | PASS |
| `backup` | finds the piece in the recovery catalog, copies it from stb1, `CATALOG START WITH`, `RESTORE` (7 s) from the **standby's** level 0 (`tag=STB_L0`), `RECOVER` with archived logs 21–24 from the primary FRA | **17 s** | PASS |

Logs: [`run-service.log`](run-service.log), [`run-backup.log`](run-backup.log).

**Take-aways**
- With a standby, a lost datafile does not need any backup on the primary: `FROM SERVICE` is the
  fastest path (12c+).
- Backups taken on the standby restore the primary (same DBID). Without a recovery catalog the
  primary would not even know they exist.
- ASM/OMF gives the restored file a new name; the control file is updated by RMAN.
