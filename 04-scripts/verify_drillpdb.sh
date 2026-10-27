#!/bin/bash
# Compare DRILLPDB against the known BANKDB scale-1 checksums. Prints PASS/FAIL.
# usage (on prm3, as oracle): BANKDB_DIR=... ./verify_drillpdb.sh
. ~/.bash_profile >/dev/null 2>&1
: "${BANKDB_DIR:?}"
expected="BRANCHES 100 219112276800
CUSTOMERS 20000 42985318080702
ACCOUNTS 30000 64734798406535
CARDS 24000 51687336812041
TRANSACTIONS 500000 1074490917450361"
actual=$(sqlplus -s / as sysdba @"$BANKDB_DIR/03_verify.sql" DRILLPDB | grep -E "^[A-Z]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$" | awk '{print $1, $2, $3}')
[ -n "$actual" ] || { echo "FAIL (no output — PDB not open?)"; exit 1; }
if [ "$actual" = "$expected" ]; then echo "PASS (5 tables, counts and checksums match)"; else echo "FAIL"; diff <(echo "$expected") <(echo "$actual"); exit 1; fi
