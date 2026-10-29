# Drill 2 — Logical errors fixed with Flashback (no restore)

Script: [`drill.sql`](drill.sql), output: [`run.log`](run.log). Both cases end with the DRILLPDB
checksum check: PASS.

## 2a — `DROP TABLE bank.cards` by mistake

`FLASHBACK TABLE bank.cards TO BEFORE DROP` brings the table back in < 1 s, but:
- the **foreign key `CARDS_ACCOUNT_FK` is not restored** (9 constraints before, 8 after) —
  Flashback Drop does not bring back referential constraints;
- indexes and the other constraints come back with **`BIN$...` names**.

The script renames them and re-creates the foreign key. My first version only handled the PK/UK and
failed with `ORA-02250` on the NOT NULL constraints (also `BIN$`); fixed.

## 2b — A bad batch sets 4,285 balances to 0 and commits

- Investigation with a **versions query**: `VERSIONS BETWEEN SCN ... AND MAXVALUE` shows 4,285 rows
  changed, when, and the transaction id (XID) — the starting point to find who ran it.
- Fix: `FLASHBACK TABLE bank.accounts TO SCN ...` (needs `ENABLE ROW MOVEMENT`).

My first version used `VERSIONS BETWEEN TIMESTAMP` with a timestamp taken 2 s before the update and
found **0 rows**: timestamps are mapped to SCNs with ~3 s granularity. Use SCNs for anything precise.

## Re-run 2026-10-29

Same steps and results, each flashback < 1 s, checksums PASS ([`run-rerun-20261029.log`](run-rerun-20261029.log)).
