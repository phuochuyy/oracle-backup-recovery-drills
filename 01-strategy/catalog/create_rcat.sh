#!/bin/bash
# Recovery catalog in its own PDB on orcl3 (prm3 runs in every lab scenario).
# Needed for backup offload on the RAC: without a catalog, RMAN cannot CONFIGURE on the standby
# (RMAN-05021) and the primary cannot see backups taken on the standby.
# usage (on prm3, as oracle): ./create_rcat.sh <pdbadmin_pw> <rco_pw>
. ~/.bash_profile >/dev/null 2>&1
set -eu
sqlplus -s / as sysdba <<SQL
whenever sqlerror exit failure
create pluggable database rcat admin user pdbadmin identified by "$1"
  create_file_dest = '/u02/oradata/ORCL3' standbys = none;
alter pluggable database rcat open;
alter pluggable database rcat save state;
alter session set container = rcat;
create tablespace rcat_data datafile size 200m autoextend on next 64m maxsize 2g;
create user rco identified by "$2" default tablespace rcat_data quota unlimited on rcat_data;
grant recovery_catalog_owner to rco;
exit
SQL
echo "catalog owner created in PDB RCAT (service rcat.rac)"
