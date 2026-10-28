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
