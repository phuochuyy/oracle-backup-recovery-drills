-- Block change tracking: level 1 backups read only the blocks changed since level 0
-- instead of scanning every datafile.
-- usage: sqlplus / as sysdba @enable_bct.sql
alter database enable block change tracking using file '/u02/oradata/ORCL3/bct_orcl3.chg';
select status, filename, round(bytes / 1048576) mb from v$block_change_tracking;
exit
