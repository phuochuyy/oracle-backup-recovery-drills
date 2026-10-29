#!/bin/bash
# Install the scheduled health check on the database VMs and the weekly restore validate on prm3.
# usage (from the repo, on the host): 04-scripts/install_scheduled_checks.sh [host...]   default: prm1 stb1 prm3
# Hosts that are off are skipped — run it again for them (prm2, stb2, stb3) when they are up.
set -u
d=$(cd "$(dirname "$0")/.." && pwd)
for h in ${@:-prm1 stb1 prm3}; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 root@$h true 2>/dev/null || { echo "$h: not reachable, skipped"; continue; }
  ssh root@$h "mkdir -p /home/oracle/brlab/04-scripts /home/oracle/brlab/01-strategy && chown -R oracle:oinstall /home/oracle/brlab"
  scp -q "$d/04-scripts/check_backup_health.sh" "$d/04-scripts/scheduled_check.sh" oracle@$h:brlab/04-scripts/
  scp -q "$d/04-scripts/systemd/lab-health.service" "$d/04-scripts/systemd/lab-health.timer" root@$h:/etc/systemd/system/
  timers=lab-health.timer
  if [ $h = prm3 ]; then
    scp -q "$d/01-strategy/validate.sh" oracle@$h:brlab/01-strategy/
    scp -q "$d/04-scripts/systemd/orcl3-validate.service" "$d/04-scripts/systemd/orcl3-validate.timer" root@$h:/etc/systemd/system/
    timers="$timers orcl3-validate.timer"
  fi
  ssh root@$h "systemctl daemon-reload && systemctl enable --now $timers >/dev/null 2>&1; systemctl list-timers $timers --no-pager | grep -E 'lab-health|orcl3-validate' | awk '{print \"$h:\", \$(NF-1), \"next\", \$1, \$2, \$3}'"
done
