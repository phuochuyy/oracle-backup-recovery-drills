#!/bin/bash
# DRILLPDB: a small PDB with the shared BANKDB dataset at scale 1, whose checksums are known
# (oracle-performance-tuning-lab/01-setup/bankdb/README.md). After every restore drill,
# 03_verify.sql must print exactly those numbers.
# Unlike PERF, DRILLPDB is protected by Data Guard (default STANDBYS=ALL).
# usage (as oracle on the primary): BANKDB_DIR=<path to bankdb scripts> ./create_drillpdb.sh <pdbadmin_pw> <bank_pw> [file_dest]
#   file_dest: /u02/oradata/ORCL3 on orcl3 (filesystem, default), +DATA on the RAC (ASM)
. ~/.bash_profile >/dev/null 2>&1
set -eu
: "${BANKDB_DIR:?path to oracle-performance-tuning-lab/01-setup/bankdb}"
sqlplus -s / as sysdba <<SQL
whenever sqlerror exit failure
create pluggable database drillpdb admin user pdbadmin identified by "$1" create_file_dest = '${3:-/u02/oradata/ORCL3}';
alter pluggable database drillpdb open;
alter pluggable database drillpdb save state;
exit
SQL
sqlplus -s / as sysdba @"$BANKDB_DIR/01_schema.sql" DRILLPDB "$2" > /dev/null
sqlplus -s / as sysdba @"$BANKDB_DIR/02_load.sql" DRILLPDB 1 | grep -E "rows created|ORA-"
sqlplus -s / as sysdba @"$BANKDB_DIR/03_verify.sql" DRILLPDB
