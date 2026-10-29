# Oracle Backup & Recovery Drills — RMAN · Flashback · measured RTO

> Status: backup strategy done (orcl3, and the RAC offloaded to its standby); **14 drills done** on the
> RAC primary, on orcl3 and on a throw-away CDB for the RESETLOGS ones; backup health check; runbooks per failure type.
> A backup is only proven by a restore: each drill records the steps run, the time to recover, and
> the data verified afterwards.

## Backup strategy (orcl3) — done

| Item | Setting |
|------|---------|
| Retention | recovery window of 7 days |
| Backups | level 0 weekly, level 1 daily, archived logs every 30 min (systemd timers, [`01-strategy/systemd`](01-strategy/systemd)) |
| Format | compressed backupsets, `BASIC` algorithm (EE; LOW/MEDIUM/HIGH need Advanced Compression), 2 channels |
| Location | `/u02/backup` on a different virtual disk than the datafiles |
| Block change tracking | enabled — level 1 read 0.1 % of blocks |
| Archived log deletion | applied on the standby **and** backed up once ([why](notes/worklog.md)) |
| Online redo | 2 members per group on different disks ([found with 1](02-drills/06-redo-log/)) |
| Monitoring | [`check_backup_health.sh`](04-scripts/check_backup_health.sh): backup age per datafile, FRA, RMAN failures, redo members on disk, archive dests, GG capture |
| Proof | `RESTORE DATABASE VALIDATE` + archived logs since level 0, no errors |

First results: [`01-strategy/results`](01-strategy/results/README.md) — level 0 111 s → 2.3 GB, level 1 10 s.

Test data: **DRILLPDB** with the shared BANKDB dataset at scale 1 ([`create_drillpdb.sh`](01-strategy/create_drillpdb.sh)); after every drill [`verify_drillpdb.sh`](04-scripts/verify_drillpdb.sh) compares counts and checksums with the known values.

## Drills done

| # | Failure | Where | Recovery | RTO | Data |
|---|---------|-------|----------|-----|------|
| 1a | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | `RESTORE ... FROM SERVICE` standby | 14 s (45–49 s re-run with TDE, restore itself unchanged) | PASS |
| 1b | [Lost datafile](02-drills/01-lost-datafile/) | RAC primary, ASM | standby's backup via recovery catalog | 17 s (re-run 29/10: **failed** after 2 failovers — old-incarnation level 0, `ORA-01207`; PASS in 20 s after a new level 0) | PASS |
| 2a | [Dropped table](02-drills/02-logical-errors/) | RAC primary | Flashback Drop + re-create the lost FK | < 1 s (re-run 29/10: same) | PASS |
| 2b | [Bad batch update](02-drills/02-logical-errors/) | RAC primary | versions query (SCN) + Flashback Table | < 1 s | PASS |
| 3 | [Corrupted block](02-drills/03-block-corruption/) | orcl3, filesystem | `VALIDATE` + `RECOVER CORRUPTION LIST`, PDB stays open | 20 s (re-run: 111 s — 110 archived logs since the level 0) | PASS |
| 4 | [TRUNCATE by mistake](02-drills/04-recover-table/) | orcl3 | `RECOVER TABLE ... UNTIL SCN` (auxiliary instance) + copy back | 221 s (re-run: 253 s) | PASS |
| 5a | [All control files lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | `SET DBID`, control file from autobackup, `RESETLOGS` | 15 s | PASS |
| 5b | [SYSTEM datafile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | mount, restore + recover datafile 1 | 34 s | PASS |
| 5c | [spfile lost](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | dummy instance, spfile from autobackup | 9 s | PASS |
| 5d | [`DROP USER ... CASCADE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | Flashback Database to SCN | 17 s | PASS |
| 5e | [`DROP TABLE ... PURGE`](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | PDB point-in-time recovery (no auxiliary instance) | 25 s | PASS |
| 5f | [Host loss (only backups left)](02-drills/05-throwaway-cdb/) | DRILL (throw-away) | spfile → control file → database, `RESETLOGS` | 76 s | PASS |
| 6a | [One redo member lost](02-drills/06-redo-log/) | orcl3 (primary, GG source) | drop + add member; **GoldenGate Extract was down 2.5 min** | 0 s DB | PASS |
| 6b | [Whole redo group lost](02-drills/06-redo-log/) | orcl3 | found by health check, `CLEAR LOGFILE` (inactive, archived) | 5 s (re-run: 6 s) | PASS |

Backups of the RAC run on the **standby** (offload, started by hand — no timer for the RAC) and are registered in a **recovery catalog**
(PDB RCAT on prm3): [`01-strategy/catalog`](01-strategy/catalog), [`01-strategy/offload`](01-strategy/offload).

Runbooks: [03-runbooks](03-runbooks/README.md). Problems I hit: [notes/worklog.md](notes/worklog.md).

## Remaining

- Run the health check from a timer and on the standby too
- **TDE keystore in the backup strategy.** Since the security lab, DRILLPDB's `BANK_DATA` on the RAC is
  encrypted: its backups are useless on another host without the keystore. The keystore has an off-host
  copy and a tested restore ([security lab, 02-tde](https://github.com/phuochuyy/oracle-security-compliance-lab/blob/main/02-tde/README.md)),
  but it is not part of this repo's backup schedule or runbooks yet. Drill 1a re-run with TDE: PASS

## Incident 2026-10-29 17:19 — the RAC primary hung on a full `+FRA`

During the security re-run, GoldenGate GG_A stopped. Cause, from the CRS trace: `ora.orcl.db` changed to
**"Stuck Archiver"** at 17:19:38, CRS could not fail the `ogg_a` service over (its other instance is on
prm2, powered off) and stopped the service's resource tree: service → GoldenGate → DBFS.

- `+FRA`: **208 MB free of 20 GB**, while `V$RECOVERY_FILE_DEST` said 3 of 18 GB used (16 %) — the number my
  health check and the Ansible health playbook both report as OK.
- 14.7 GB of `+FRA/ORCL/ARCHIVELOG` were archived logs with `IS_RECOVERY_DEST_FILE = NO`: the archive
  destination was `LOCATION=+FRA` instead of `LOCATION=USE_DB_RECOVERY_FILE_DEST`. The FRA does not count
  such files and never deletes them, although the RMAN deletion policy (`APPLIED ON ALL STANDBY BACKED UP
  1 TIMES`) would allow it. Region A has no archived-log housekeeping job (Region B has one).
- The standby `orcl_stb` has the same setting: 145 unmanaged logs, 10.7 GB free (not urgent yet).

Immediate fix (no file deleted): `log_archive_dest_1='LOCATION=+DATA ...'` on orcl (memory, then spfile) —
the archiver resumed at once, CRS restarted the service tree and GoldenGate by itself. +DATA had 13.6 GB free.

**Closed the same evening (approved):** a second design flaw explained why nothing could be deleted —
in a recovery catalog, **disk backups belong to the site that took them**. All backups run on the
standby, so for the primary no log was ever "BACKED UP 1 TIMES TO DISK": RMAN refused all 479
(`RMAN-08138`). Steps: the 51 logs with no backup anywhere backed up from prm1 (192 MB); primary
deletion policy changed to `APPLIED ON ALL STANDBY` (the standby keeps `... BACKED UP 1 TIMES TO DISK`,
it is where backups run); `delete archivelog all` under the policies: 480 files on prm1, 151 on stb1;
dest 1 back to `USE_DB_RECOVERY_FILE_DEST` on both — new logs `IS_RECOVERY_DEST_FILE = YES`.
`+FRA` free: prm1 208 MB → 14.8 GB, stb1 10.7 → 15.5 GB. Broker SUCCESS, GoldenGate running both ways.
Note: 39 logs of 10-21 (an older incarnation, known only to the catalog, outside the 7-day recovery
window) were deleted too; I had not checked them for a backup first.
Open: RAC backups on the standby are still started by hand — with the new primary policy the standby is
the only place logs wait for a backup, so its backup needs a schedule.

Original plan, for the record: delete the logs that are applied on the
standby and backed up (via the catalog), then set dest 1 back to `USE_DB_RECOVERY_FILE_DEST` on both
databases, so the FRA manages and recycles them. The health check now looks at the disk group and at
unmanaged logs ([`check_backup_health.sh`](04-scripts/check_backup_health.sh)): `CRIT fra disk group
+FRA: 208 MB free of 20480 MB`, `WARN archived logs 429 in +FRA but not managed by the FRA`.

**Consequence found 40 min later — the cleanup broke GoldenGate capture.** At 19:38 Extract EXTA abended:
`ORA-01292: LogMiner for upstream capture cannot find log file`. The capture (`OGG$CAP_EXTA`, per-PDB in
ORCLPDB2) still needed thread 1 sequences 14–26 from its restart SCN; `DBA_REGISTERED_ARCHIVED_LOG` had them
as `PURGEABLE = NO`, yet `delete archivelog all` deleted 14–23 and reported **0 `RMAN-08137`** ("needed for
upstream capture") — RMAN in the root did not protect the logs of a capture that lives in a PDB.
Repair: sequences 14–22 restored from the standby's backups (`SET ARCHIVELOG DESTINATION`), 23 copied
from the standby's FRA, all copied to prm1 and `CATALOG START WITH` → capture attached again. A second
abend followed: `ORA-04036` — the instance was at its PGA limit (2,167 MB of 2 GB, ~200 processes) and the
catch-up needed more → `pga_aggregate_limit` 3G on both sites; Extract caught up, rows identical on both
sides. The restored files stay in `/u02/arch_restore` until the capture's checkpoint passes sequence 23.

**Rule:** before deleting archived logs on a database with GoldenGate, compare with the capture's
`REQUIRED_CHECKPOINT_SCN` (in the PDB for per-PDB capture) — do not rely on RMAN-08137 alone.

## Quick re-check 2026-10-29 21:1x (after the cleanup and the password rotation)

| Drill | Result | Log |
|-------|--------|-----|
| 1a datafile from the standby | PASS, RTO 25 s | [`run-service-r3-20261029.log`](02-drills/01-lost-datafile/run-service-r3-20261029.log) |
| 2 Flashback Drop / Table | PASS, same steps, 0 ORA- lines | [`run-r3-20261029.log`](02-drills/02-logical-errors/run-r3-20261029.log) |
| 6b whole redo group lost | PASS, 4 s from detection to OK | [`run-6b-r3-20261029.log`](02-drills/06-redo-log/run-6b-r3-20261029.log) |

The health check also caught a datafile created that afternoon and never backed up (SQLT's tablespace,
file #33): `CRIT backup L0/L1 ... 9999 h` → the level 1 job (RMAN backs up a new file as level 0) → OK.

## Scheduled checks (2026-10-30)

[`install_scheduled_checks.sh`](04-scripts/install_scheduled_checks.sh) installs two systemd timers, both
`Persistent=false` (no catch-up at boot — the lesson of the backup that ran before the instance) and skipped
while the instance is down ([`scheduled_check.sh`](04-scripts/scheduled_check.sh)):

| Timer | Where | When | What |
|-------|-------|------|------|
| `lab-health.timer` | prm1, stb1, prm3 | every hour at :20 | `check_backup_health.sh`; full output to `~/health/<date>.log` |
| `orcl3-validate.timer` | prm3 | Sunday 05:00, after the level 0 (03:00) | `validate.sh`: `RESTORE DATABASE VALIDATE` + archived logs since that level 0 |

**Alerting on a change, not on a state:** a line in `~/health/alerts.log` and in the journal
(`journalctl -t lab-health`) only when a CRIT/WARN appears or clears. Some CRITs are permanent here by design
(Region B's deferred destination in scenario `dg-a`; backup age on the RAC primary, whose backups run on the
standby) — an alert on every run would be noise nobody reads. Tested: first run = baseline, second run =
no alert, a simulated change → `new CRIT …` and `cleared WARN …`. The first test failed: `comm` needs both
state files sorted with the same collation, and my test sorted with another locale than systemd's —
the script now sets `LC_ALL=C`. No mail server in the lab: alerts are read with `labctl`/ssh.

First run of the validate service (by hand, 2026-10-30 00:22): **OK in 202 s** — the level 0 of 10-28 02:00, the level 1s and every archived log since read and checked block by block, nothing restored.

The RAC is not validated on a schedule yet: its backups (on the standby) are still started by hand.

**Blind spot found while setting this up:** after the three failovers of 2026-10-29 evening the RAC is in
incarnation 21 (20:58), and its newest level 0 (13:15) belongs to incarnation 18 — a restore from backup would
fail like drill 1b (`ORA-01207`) until a new level 0 is taken; `RESTORE FROM SERVICE` (drill 1a) still works.
`check_backup_health.sh` checks the age of the backups, not their incarnation, so it reports OK.

