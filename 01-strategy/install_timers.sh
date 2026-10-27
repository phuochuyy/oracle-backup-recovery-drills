#!/bin/bash
# Install the backup script and systemd timers on prm3. usage (from the repo, on the host): ./install_timers.sh
set -eu
d=$(cd "$(dirname "$0")" && pwd)
scp -q "$d/backup.sh" root@prm3:/u02/backup/bin/backup.sh 2>/dev/null || { ssh root@prm3 'mkdir -p /u02/backup/bin'; scp -q "$d/backup.sh" root@prm3:/u02/backup/bin/backup.sh; }
scp -q "$d"/systemd/orcl3-backup@.service "$d"/systemd/orcl3-backup-*.timer root@prm3:/etc/systemd/system/
ssh root@prm3 'chown -R oracle:oinstall /u02/backup/bin; chmod 750 /u02/backup/bin/backup.sh; systemctl daemon-reload
  systemctl enable --now orcl3-backup-arch.timer orcl3-backup-1.timer orcl3-backup-0.timer
  systemctl list-timers "orcl3-backup-*" --no-pager'
