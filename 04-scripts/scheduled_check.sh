#!/bin/bash
# Run by systemd timers (lab-health.timer, orcl3-validate.timer) as oracle.
#   scheduled_check.sh health     check_backup_health.sh, full output to ~/health/<date>.log
#   scheduled_check.sh validate   validate.sh (RESTORE ... VALIDATE), output to ~/health/validate-<date>.log
# Alerting = a change, not a state: a line goes to ~/health/alerts.log and to the journal (priority
# warning/crit) only when a CRIT/WARN appears or clears. Some CRITs are expected and permanent in this lab
# (Region B's deferred standby destination in scenario dg-a, backup age on the RAC primary whose backups
# run on the standby) — alerting on the state would fire every hour and nobody would read it.
# No catch-up at boot (Persistent=false) and nothing runs while the instance is down.
. ~/.bash_profile >/dev/null 2>&1
export LC_ALL=C   # comm needs both state files sorted the same way, whatever the caller's locale
H=$HOME/health; mkdir -p "$H"; now=$(date '+%F %T')
alert() { echo "$now $1 $2" >> "$H/alerts.log"; logger -t lab-health -p "user.$1" "$2"; }
pgrep 'ora_pmon_' >/dev/null || { echo "$now instance not running, skipped" >> "$H/$(date +%F).log"; exit 0; }

case $1 in
health)
  out=$(bash "$HOME/brlab/04-scripts/check_backup_health.sh" 2>&1)
  { echo "== $now"; echo "$out"; } >> "$H/$(date +%F).log"
  # the check prints fixed columns: status (4), name (22), detail. Compare status + name only — details
  # like "3.1 h ago" change every run
  echo "$out" | grep -E '^(CRIT|WARN) ' | awk '{print substr($0, 1, 4) "|" substr($0, 6, 22)}' \
    | sed 's/ *$//' | sort > "$H/state.new"
  touch "$H/state"
  comm -13 "$H/state" "$H/state.new" | while IFS='|' read -r s c; do
    lvl=$([ "$s" = CRIT ] && echo crit || echo warning)
    alert $lvl "new $s: $c — $(echo "$out" | grep -F -m1 "$s $c" | cut -c29-)"
  done
  comm -23 "$H/state" "$H/state.new" | while IFS='|' read -r s c; do alert notice "cleared $s: $c"; done
  mv "$H/state.new" "$H/state" ;;
validate)
  log=$H/validate-$(date +%F).log
  bash "$HOME/brlab/01-strategy/validate.sh" > "$log" 2>&1
  if grep -qE 'RMAN-|ORA-' "$log" || ! grep -q 'Finished restore' "$log"; then
    alert crit "RESTORE VALIDATE failed — see $log"
  else
    echo "$now validate OK: $(grep -c 'Finished restore' "$log") restore validations, $(grep -oE 'elapsed [0-9]+ s' "$log")" >> "$H/alerts.log"
  fi ;;
esac
