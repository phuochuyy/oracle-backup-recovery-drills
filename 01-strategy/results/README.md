# First backups of orcl3

| Backup | Elapsed | Result |
|--------|---------|--------|
| Level 0, whole CDB (13.7 GB of datafiles), BASIC-compressed, 2 channels | 111 s | 2.3 GB of backup pieces |
| Level 1 right after (block change tracking enabled) | 10 s | read 1,135 of 1,823,744 blocks (0.1 %) |
| `RESTORE DATABASE VALIDATE` + archived logs since level 0 | 129 s | no errors |

Block change tracking: the level 0 shows `USED_CHANGE_TRACKING = NO` for the 3 files of the brand new
DRILLPDB (not yet in the tracking bitmap), `YES` for the other 19 files.
