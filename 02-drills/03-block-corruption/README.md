# Drill 3 — Corrupted block, repaired while the PDB stays open

**Failure:** the 8 KB block holding `ACCOUNTS` row 1234 (file 26, block 9144 of the bigfile `BANK_DATA`)
overwritten with zeros (`dd`, then flush buffer cache). Reading the row:
`ORA-01578: ORACLE data block corrupted (file # 26, block # 9144)`.

**Recovery** ([`drill.sh`](drill.sh), [`run.log`](run.log)):
1. `VALIDATE DATAFILE 26` → file `FAILED`, block listed in `V$DATABASE_BLOCK_CORRUPTION`.
2. `RECOVER CORRUPTION LIST` → only that block is restored from the level 0/1 backups and rolled
   forward with archived logs (media recovery 7 s).

**RTO 20 s**, PDB open the whole time, checksums PASS.

**Notes**
- With an Active Data Guard standby running, 23ai repairs such a block automatically from the standby
  (automatic block media recovery); here the standby was down on purpose.
- Bigfile tablespace: the block number from a rowid needs `DBMS_ROWID.ROWID_BLOCK_NUMBER(rowid, 'BIGFILE')`.
- My first run printed the datafile name with SQL*Plus' default 80-character lines; the name was cut and
  `dd` created a new 75 MB file instead of hitting the datafile — nothing was damaged, the file was removed
  ([first attempt](run-first-attempt.log)). The script now refuses to run `dd` unless the target exists and
  is a `.dbf`, and stops if reading the row does *not* fail.
