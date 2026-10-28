# Drill 4 — TRUNCATE by mistake, RECOVER TABLE from backup

**Failure:** `TRUNCATE TABLE bank.transactions` (500,000 rows). Flashback Table cannot undo a truncate.

**Recovery** ([`drill.sh`](drill.sh), [`run.log`](run.log)):
```
RECOVER TABLE bank.transactions OF PLUGGABLE DATABASE drillpdb
  UNTIL SCN <scn before the truncate>
  AUXILIARY DESTINATION '/u02/backup/aux'
  REMAP TABLE bank.transactions:transactions_rec;
```
RMAN builds an automatic auxiliary instance from the backups, recovers the PDB to that SCN, exports the
table with Data Pump and imports it as `TRANSACTIONS_REC` (500,000 rows, 39 MB). The original table still
exists (empty), hence the remap; the rows are copied back with a direct-path insert (2.4 s).

**RTO 221 s**, checksums PASS.

**Notes**
- Capture the SCN before risky operations; with only a time, use the latest time you are sure is before
  the mistake.
- The auxiliary destination needs room for SYSTEM/SYSAUX/UNDO of the CDB and the PDB plus the table's
  tablespace. RMAN removed the auxiliary datafiles but left its **8 online redo logs (1.6 GB)** behind —
  clean the auxiliary destination afterwards.
