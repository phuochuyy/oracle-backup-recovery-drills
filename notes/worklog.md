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
