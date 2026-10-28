#!/bin/bash
# Finding: orcl3's online redo groups had ONE member each, on the same disk (vdb) as the datafiles and
# the FRA. Losing the CURRENT group = losing committed transactions. Add a second member to every group
# on the other disk (vda, /u02/redo2). Online, no downtime. New members show INVALID until LGWR has
# written to them once, so the script switches through all groups.
# usage (from the host): ./multiplex_redo.sh
set -eu
ssh -o BatchMode=yes root@prm3 "mkdir -p /u02/redo2 && chown oracle:oinstall /u02/redo2 && chmod 750 /u02/redo2"
ssh -o BatchMode=yes oracle@prm3 '. ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba' <<'SQL'
set serveroutput on lines 200 pages 50
declare
  n pls_integer;
begin
  for g in (select group# from v$log l
             where (select count(*) from v$logfile f where f.group# = l.group# and f.type = 'ONLINE') = 1) loop
    execute immediate 'alter database add logfile member ''/u02/redo2/redo' || g.group# || 'b.log'' to group ' || g.group#;
    dbms_output.put_line('group ' || g.group# || ': member b added');
  end loop;
  select count(*) into n from v$log;
  for i in 1 .. n loop execute immediate 'alter system switch logfile'; end loop;
  execute immediate 'alter system checkpoint';
end;
/
col member for a45
select f.group#, f.member, nvl(f.status, 'OK') status, l.status group_status
  from v$logfile f join v$log l on l.group# = f.group# where f.type = 'ONLINE' order by 1, 2;
exit
SQL
