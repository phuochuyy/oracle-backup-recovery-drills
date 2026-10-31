# Worklog

What I did, what went wrong, how I fixed it. Newest at the bottom.

## Backup strategy on orcl3 (branch `feature/backup-strategy`)

- **Backup location.** `/u02/backup` could not be created as oracle (`/u02` belongs to root). Created by
  root and given to oracle — and that location is the right one anyway: `/u02/oradata` is the datafile
  disk (vdb), `/u02/backup` is on the root disk (vda). Backups must not share a disk with the datafiles.
- **RMAN-01009 "found integer".** `rman target / @01-strategy/configure.rman` and
  `cmdfile=01-strategy/...` both fail: RMAN parses the unquoted leading `01` as a number. Quote the path.
- **The deletion policy was wrong once backups existed.** `RESTORE ARCHIVELOG ... VALIDATE` failed with
  RMAN-06025 for logs that had been deleted without ever being backed up. My validate command was too
  wide (logs older than the level 0 do not matter), but it exposed a real gap: with only
  `APPLIED ON ALL STANDBY`, the 10-minute housekeeping job could delete a log before the next backup,
  making point-in-time recovery into that window impossible. Changed the primary to
  `APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK` (standby keeps `APPLIED ON ALL STANDBY` — no
  backups run there, it would never delete anything). Consequence: archived logs must be backed up
  regularly → systemd timers (archived logs every 30 min, level 1 daily, level 0 Sunday).
- `RESTORE ARCHIVELOG` has no `FROM TAG`; validate now takes the start time of the latest level 0.
- Tested the DRILLPDB checksum check both ways (+1 on one balance → FAIL, reverted → PASS) before
  trusting it for the drills.

## Drills on the RAC (branch `drills/region-a`)

- **RMAN-05021** — `CONFIGURE` is not allowed on a standby control file without a catalog. Built a
  recovery catalog in PDB RCAT on prm3; then the standby's settings must be stored
  `FOR DB_UNIQUE_NAME orcl_stb` (settings without it only apply to the connected database — first
  attempt left the standby with compression/parallelism defaults).
- Found **COMPRESSION ALGORITHM 'MEDIUM'** configured on both RAC databases (Advanced Compression
  Option) — set to BASIC.
- **PLS-00201 'DBMS_LOCK'** → RMAN-01005 on every catalog write: 23ai's RECOVERY_CATALOG_OWNER role
  lacks it; granted EXECUTE ON DBMS_LOCK.
- **RMAN-06820** — a standby backup with `target /` cannot log in to the primary to archive the current
  log; use `target sys/...@orcl_stb`.
- The first standby level 0 "took" 612 s — the level 0 itself took ~1 min; the rest was the
  `plus archivelog` steps waiting for the primary's current log to arrive.
- DRILLPDB was only `MOUNTED` on the ADG standby; my verify script said FAIL (no output) — correct.
  Opened it read only → PASS.
- Drill 2: a PL/SQL rename block that forgot NOT NULL constraints (ORA-02250), and a versions query
  by timestamp that found nothing (3 s granularity). Both fixed, both kept in the drill notes.

## Drills on orcl3 (branch `drills/single-instance`)

- **Drill 3, first run:** the datafile name came back cut at 80 characters, so `dd` wrote into a *new*
  file `.../o1_mf` (75 MB = 9,145 × 8 KB) instead of the datafile. Reading the row returned no error, which
  is how I noticed. Removed the file after checking size, time and permissions. Script now uses
  `lines 500`, checks the target is an existing `.dbf`, and stops if the corruption is not really there.
- **RMAN VALIDATE exits non-zero when it finds corruption** — expected here; `set -e` stopped my script
  with the block still corrupt. Finished that run by hand, fixed the script, ran it again end to end
  (RTO 20 s) so the evidence comes from one clean run.
- **RECOVER TABLE** worked first time (221 s) but left the auxiliary instance's online redo logs (1.6 GB).

## Throw-away CDB DRILL (branch `drills/throwaway-cdb`)

- **DUPLICATE without catalog and target:** `RMAN-05521 ... requires that UNDO TABLESPACE is specified`
  (because PDBs were skipped). Added `UNDO TABLESPACE 'UNDOTBS1'`. The failed run left an instance mounted on
  a copy of orcl3's control file — aborted it and removed the copy before retrying.
- Deliberately **no `NOFILENAMECHECK`**: the standby ORCL3_STB on the same VM uses the same paths.
- **Host disk at 96 %:** removed the copied orcl3 backups right after the duplicate, replaced the 200 MB redo
  logs by 64 MB ones.
- **5a:** wrong autobackup (from the FRA, older) → ORA-01194. `SET ... FORMAT` was ignored until `SET DBID`.
- **5b:** recovery worked, my check failed — PDBs MOUNTED after restart. `SAVE STATE`.
- **5c:** `RMAN-06172` — the dummy instance only searched `$ORACLE_HOME/dbs`. Same fix in 5f before running it.

## Redo logs and the health check (branch `drills/redo-log`)

- **Found:** orcl3 had one member per redo group, on the datafile/FRA disk. Added a second member on the
  other disk online (`multiplex_redo.sh`).
- **6a surprised me:** deleting one member did nothing to the database (`V$LOGFILE` still OK — LGWR keeps
  the file open), but the GoldenGate capture aborted when the group became CURRENT (`ORA-01343`, then
  `ORA-01304`) and Extract abended in a loop for 2.5 min. Fixed by drop + re-add member; Extract came back
  by autorestart.
- **Health check, first version wrong:** "last level 0" was 12.7 h old — the same as the last level 1,
  because the level 1 run had made automatic level 0 backups of the new RCAT datafiles. Switched to "oldest
  datafile". Then it reported file 30 (RCAT) as never having a level 0: it only has a level 1 whose
  `incremental_change# = creation_change#`. `RESTORE DATAFILE 30 PREVIEW` showed RMAN restores from it, so it
  counts as a base. Also sorted by the `to_char` string at first ("9.0" > "13.5").
- **6b first run:** `set -e` + `grep` with no output, again.

## 2026-10-29 — +FRA full on the RAC primary

- My health check said "fra used 16 %" all day; the disk group was filling with archived logs the FRA did
  not manage (`LOCATION=+FRA`). I had checked the FRA view only, never the disk group. Found only when
  GoldenGate stopped and I followed the CRS trace: Stuck Archiver → service tree stopped.
- First guess was my password change (it happened in the same minute); the CRS trace showed it was not.

## 2026-11-01 — level 1 skipped silently (branch `fix/backup-lock-wait`)

- **Problem:** health check `CRIT backup L0/L1 oldest file #21: 49.5 h ago`; the 02:00 level 1 left no log,
  systemd showed nothing wrong.
- **Cause:** the archived-log timer (`*:00/30`) fires in the same minute as the level 1 (02:00) and the level 0
  (Sun 03:00). `backup.sh` used `flock -n … exit 0`: the loser of the race skipped with exit code 0 = success.
  On 10-30 the level 1 won, on 11-01 the archived-log job won. Reproduced with the old script: lock held 15 s →
  level 1 "finished" in 0 s, result success, no log.
- **Fix:** `flock -w 1800` (wait up to 30 min; exit 1 if the lock never comes). Same test: waited 14 s, ran,
  health check OK. Deployed only `backup.sh` (not `install_timers.sh`, which would also restart the level 0 timer).
- **Lesson:** a "skip" must exit non-zero, or monitoring sees a success. The health check caught the effect
  (old backups), which is why both checks are needed.
