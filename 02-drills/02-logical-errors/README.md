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
- Fix: `FLASHBACK TABLE bank.accounts TO SCN ...` (needs `ENABLE ROW MOVEMENT`). **It takes about 7 minutes**
  for 4,285 rows — see below.

My first version used `VERSIONS BETWEEN TIMESTAMP` with a timestamp taken 2 s before the update and
found **0 rows**: timestamps are mapped to SCNs with ~3 s granularity. Use SCNs for anything precise.

## Re-run 2026-10-29

Same steps and results, checksums PASS ([`run-rerun-20261029.log`](run-rerun-20261029.log)). Flashback Drop < 1 s;
Flashback Table 6 min 50 s (I had written "< 1 s" for both — see the next section).

## Why Flashback Table took 7 minutes (2026-11-01)

Every run spent ~7 minutes in `FLASHBACK TABLE bank.accounts TO SCN` — [`run.log`](run.log) 7:06,
[`run-rerun-20261029.log`](run-rerun-20261029.log) 6:49, [`run-r3-20261029.log`](run-r3-20261029.log) 7:20,
[`run-r4-20261101.log`](run-r4-20261101.log) 7:48 — while this README said "< 1 s". My mistake: I read the
Flashback Drop timing and never looked at the second one.

ASH for the 2026-11-01 run: one statement, 467 samples **on CPU**, current object `TRANSACTIONS` in 443 of them
and `CARDS` in 12. Flashback Table moves the changed rows (delete + insert), so for every parent row of `ACCOUNTS`
Oracle checks the child tables — and BANKDB leaves the foreign-key columns `TRANSACTIONS.ACCOUNT_ID` and
`CARDS.ACCOUNT_ID` unindexed on purpose: 4,285 rows × a scan of 500,000 transactions.

Proof: the same drill with temporary indexes on both `ACCOUNT_ID` columns → **Flashback Table 2.96 s**
([`run-r4-fk-indexed-20261101.log`](run-r4-fk-indexed-20261101.log)); indexes dropped again afterwards, BANKDB checksums
identical. Same lesson as the performance lab's case 1: index foreign keys of parent tables that change.

The indexed run also showed a weakness of the 2a clean-up: it names the `BIN$` indexes of `CARDS` by their first
column, so the extra index was renamed `CARDS_PAN_UK` and the real ones stayed `BIN$` (`ORA-00955`); repaired by
hand. The rename only works on the original index set.
