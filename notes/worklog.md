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

## 2026-11-01 — drill 2b timing was wrong in the README (branch `docs/drill2-flashback-fk`)

- **Problem:** README and runbook said Flashback Table took "< 1 s"; all four logs show ~7 min (7:06, 6:49, 7:20, 7:48).
  I had copied the Flashback Drop timing.
- **Cause:** ASH — 467 CPU samples, current object `TRANSACTIONS` (443) / `CARDS` (12): Flashback Table moves rows,
  and each `ACCOUNTS` row is checked against the unindexed child foreign keys (BANKDB leaves them unindexed on purpose).
- **Proof:** temporary indexes on `TRANSACTIONS.ACCOUNT_ID` and `CARDS.ACCOUNT_ID` → 2.96 s. Dropped afterwards;
  checksums identical.
- **My mistake on the way:** the 2a clean-up renamed my extra `CARDS` index to `CARDS_PAN_UK` (it maps `BIN$`
  indexes by first column) and left the real ones as `BIN$` (`ORA-00955`). Repaired by hand: dropped the extra index
  after checking it was the non-unique `ACCOUNT_ID` one, renamed the two real indexes back.
- **Lesson:** read every timing in a log, not the first one; a test that adds objects must not run through a
  clean-up written for the original object set.

## 2026-11-01 — new offload level 0 not in the catalog (branch `docs/offload-after-failover`)

- **Problem:** after deleting the old-incarnation backups, a new level 0 on stb1 finished `rc=0` (760 s, 2.8 GB) but
  `LIST BACKUP OF DATAFILE 40` in the catalog did not show it; the log had one line `ORA-20079: full resync from
  primary database is not done`.
- **Cause:** the failovers created a new incarnation the catalog did not know yet; a standby cannot register its
  backups before a full resync from the primary. Disk backups are also site-bound: connected to the primary,
  RMAN only lists/crosschecks the primary's own backups.
- **Fix:** `RESYNC CATALOG` connected to `orcl` (primary) → full resync; then connected to `orcl_stb`: resync +
  crosscheck → level 0 key 7930 listed.
- **Lesson:** `rc=0` is not proof — check that the catalog shows the backup; after a failover resync from the primary first.

## 2026-11-01 — RMAN passwords off the command line (branch `fix/password-off-cmdline`)

- **Problem:** `backup_standby.sh` ran `rman target "sys/<pw>@..." catalog "rco/<pw>@..."` — both passwords visible in
  `ps` on stb1 for the whole backup. Same class as the security lab's finding 10.
- **Fix:** `rman log=...` with `CONNECT TARGET` / `CONNECT CATALOG` inside the here-document. Test: `ps` shows only
  `rman`, the log has `connect target *`, 0 lines with a password, level 1 rc=0.
- **Open:** that level 1 took 615 s — check block change tracking on the standby.

## 2026-11-02 — capacity checks (branch `feature/capacity-checks`)

- Trigger: the host (sparse VM disk images) filled up when stb3 pulled a ~3.7 GB redo gap after transport was
  switched back on; 4 VMs paused. Inside the VMs every check was green — a VM cannot see the host's space.
- Added check 7 to `check_backup_health.sh`: data disk groups, file systems, and on a primary the MB of archived
  redo each standby destination has not received (current incarnation, per thread, from the destination's own
  `V$ARCHIVED_LOG` rows). Verified the arithmetic with a simulated 5-log gap against a hand count (380 MB, 10 logs).
- Not verified yet: a real deferred destination (orcl3 dest 2 in scenario `dg-a`) — prm3 was off; the hourly
  run on prm3 will show it after the next `install_scheduled_checks.sh prm3`.
- What I tried first and dropped: ASM `thin_provisioned=TRUE` + rebalance on the standby FRA returned 0 MB to the
  host (one disk, nothing moved) — set back to FALSE.

## 2026-11-03 — backup age checked on the wrong side (branch `fix/health-check-backup-site`)

- **Problem:** `lab-health` on prm1 reported `CRIT backup base … 9999 h` every hour. I had documented it as an
  expected, permanent CRIT (the RAC's backups run on the standby, the primary's control file does not list them).
  The other half I had missed: on the standby the backup-age checks were skipped (`if role = PRIMARY`), so nothing
  checked the RAC's backups at all. And the check ignored the incarnation (blind spot written down on 2026-10-30).
- **Fix:** `BACKUP_ROLE` per host in `~/brlab/health.env` (written by `install_scheduled_checks.sh`); backup ages
  only from backups of the current incarnation, or of files unchanged since (PDB$SEED).
- **My slip on the way:** the first version filtered strictly by the current incarnation → PDB$SEED files #2, #4, #9
  "never backed up". Their backup carries the resetlogs SCN of the incarnation they were last written in.
- **Result:** prm1 `OK backup age (checked there)`; stb1 `CRIT … file #45 9999 h` — real: `UNDO_6` of DRILLPDB and
  SECPDB (created 2026-11-01 18:08, after the last level 0/1) never backed up. Taken by the next level 0 offload.
- **Lesson:** a "permanent, expected" CRIT is a check in the wrong place — move the check, do not accept the noise.

## 2026-11-03 — no check saw that FSFO could not fail over (branch `fix/health-check-fsfo`)

- **Problem (run 5 of the HA/DR lab):** after a hard reset of the primary (stb1, out of memory) the observer stayed
  disconnected for 25 min and redo transport was UNSYNCHRONIZED. The planned power-off of the primary then caused
  no failover. Correct behaviour in Zero Data Loss mode — but nothing had reported the state.
- **Fix:** check 8 on a primary with FSFO enabled: `OK` only when SYNCHRONIZED with the observer present, else `CRIT`.
  Hourly `lab-health` alerts on the change. Evidence: `01-strategy/results/health-check-fsfo-20261103.txt`.


## Re-run after run 5 — the fix was in Git, not on the server

- Before the level 0 offload after run 5, stb1 still had the **old** `backup_standby.sh` (passwords on the RMAN
  command line): the 11-01 fix had been tested and committed, but the copy on stb1 was never replaced. Copied the repo
  version before the backup; md5 on stb1 = md5 in Git (`42082a22…`). Level 0 offload rc=0, 500 s.
- Lesson: "fixed" means deployed on every host that runs it, checked by md5 — not merged.

## Re-run after run 5 — drill 1 password on the command line (branch `fix/drill1-password-stdin`)

- **Problem:** `02-drills/01-lost-datafile/drill.sh` ran `rman target sys/<pw>@orcl catalog rco/<pw>@...` inside the
  ssh command — visible in `ps` on prm1 and on the host. When I fixed `backup_standby.sh` on 11-01 I grepped only
  that file's pattern, not every script that starts RMAN.
- **Fix:** CONNECT lines inside the here-document (stdin), both methods. Test: drill 1a PASS, RTO 25 s; 61 `ps`
  samples, 0 with a password; the log shows `connect target *`.
- **Lesson:** after a class of bug is found, grep the whole repo for the class (`grep -rn 'PASSWORD@'`), not the file.

## Scheduled RAC backup on the standby (branch `feature/rac-backup-timer`)

- **Gap:** the RAC had no backup schedule — the offload level 0/1 on stb1 was started by hand, and after every
  failover someone had to remember the catalog resync. UNDO_6 went without any backup that way.
- **Built:** [`rac_backup_job.sh`](../01-strategy/offload/rac_backup_job.sh) + systemd timers on every RAC node
  (level 1 daily 03:30, `Persistent=true`; level 0 Sunday 04:00, not persistent — 2.8 GB caught up at boot could fill
  the lab host, the health check reports a missed one). The job runs only on the standby, on one node of it, resyncs
  the catalog from the primary first, and fails on `ORA-20079`. Credentials: auto-login wallet in its own
  `TNS_ADMIN`, made by [`install_rac_backup.sh`](../01-strategy/offload/install_rac_backup.sh) with a random wallet
  password that is never stored. Installed on prm1 and stb1 (prm2/stb2: run the installer when they are up).
- **My mistake, caught by the first real run:** resync and backup were in one RMAN session; the second
  `CONNECT TARGET` (to the standby) failed with `RMAN-06167 already connected` and RMAN went on with the first target
  — **it backed up the primary**: 755 MB level 1 + 2,180 MB archived logs into the primary's FRA (62 → 80 %). Valid
  backups, wrong place. Now two RMAN sessions, and the job fails unless every channel ran on an instance of the
  standby database (`orcl_stb1` must not pass as `orcl`).
- **Test:** on prm1 (primary) the service exits 0 "skip"; on stb1 level 1 rc=0 in 640 s, channels only on
  `orcl_stb1`, backup sets in the catalog (tag STB_L1); health check `backup L0/L1` OK (0.1 h).

## Rolling stb3 forward instead of shipping the gap (Region B, after the HA/DR run 5)

- stb3 was 68 archived logs / 3.7 GB behind. `RECOVER STANDBY DATABASE FROM SERVICE orcl3`
  ([`roll_forward_standby.sh`](../01-strategy/roll_forward_standby.sh)) brought it to the primary's SCN in ~100 s: 30
  datafiles / 17,726 MB identical to the primary, nothing to recover.
- **My misjudgement:** I chose it to save host disk, but the standby's datafiles grew to the primary's size (UNDO 3.8 GB,
  BANK_DATA 3.3 GB filled in) — host free 10.3 → 0.66 GB, no VM paused. Recovered by deleting (with the user's OK)
  141 backed-up archived logs on prm3 below SCN 35,700,000 — below stb3, below the GoldenGate EXTB checkpoint and below the
  Debezium offset. The first `DELETE` removed nothing (`RMAN-08120 not yet applied by standby`: a roll-forward does not
  update what the primary knows) and my output filter hid the warning — counted the files on disk the second time
  (155 → 14, `FORCE`). The host showed the freed space only half a minute after `fstrim`.
- The first run lost its RMAN log (`/u02/backup` is root-owned on stb3) — now under `/home/oracle/rman_logs`.
- Side effect found at the switchover: the restored control file names redo log directories that exist only on prm3
  (HA/DR finding F16).
