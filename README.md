# Oracle Backup & Recovery Drills

A backup is only proven by a restore. This project sets up an RMAN backup strategy for a single-instance database and for a RAC whose backups run on its Data Guard standby, then deliberately breaks things and recovers them.

Every drill is timed, and the data is checked with checksums afterwards.

## What is in it

- **Backup strategy**: incremental backups, block change tracking, a recovery catalog, scheduled jobs and restore validation.
- **Recovery drills**: a lost data file, a corrupted block, logical errors, lost control files, the loss of a whole server, lost redo logs.
- **Health check**: backup age, recovery area and disk group space, GoldenGate capture.
- **Runbooks** for each type of failure.
- **A real incident**: a primary that stopped accepting writes while monitoring looked fine.

## Where to look

- [Strategy, drill results and incident](docs/details.md)
- [Drills](02-drills/)
- [Runbooks](03-runbooks/README.md)
- [Scripts](04-scripts/)
- [Worklog, including my mistakes](notes/worklog.md)
