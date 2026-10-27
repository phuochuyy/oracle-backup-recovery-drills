-- Drill 2 — logical errors in DRILLPDB, fixed with Flashback (no restore).
-- usage (on the primary): sqlplus -s / as sysdba @drill.sql
set lines 180 pages 100 timing on serveroutput on
col constraint_name for a32
col index_name for a32
alter session set container = DRILLPDB;
set serveroutput on

prompt == 2a: DROP TABLE bank.cards by mistake
prompt -- constraints and indexes of CARDS before:
select constraint_name, constraint_type, status from dba_constraints where owner = 'BANK' and table_name = 'CARDS' order by 1;
select index_name from dba_indexes where owner = 'BANK' and table_name = 'CARDS' order by 1;
drop table bank.cards;
select object_name, original_name, type from dba_recyclebin where owner = 'BANK' order by droptime;
flashback table bank.cards to before drop;
prompt -- constraints and indexes of CARDS after FLASHBACK ... TO BEFORE DROP:
select constraint_name, constraint_type, status from dba_constraints where owner = 'BANK' and table_name = 'CARDS' order by 1;
select index_name from dba_indexes where owner = 'BANK' and table_name = 'CARDS' order by 1;
prompt -- fix: rename the BIN$ objects, re-create the foreign key Flashback Drop does not bring back
declare
  procedure ren_idx(p_old varchar2, p_new varchar2) is
  begin execute immediate 'alter index bank."' || p_old || '" rename to ' || p_new; end;
begin
  -- NOT NULL check constraints come back as BIN$ too; my first version only handled P/U and
  -- built 'rename ... to <null>' for them (ORA-02250)
  for c in (select k.constraint_name, k.constraint_type,
                   (select min(column_name) from dba_cons_columns cc where cc.owner = k.owner
                     and cc.constraint_name = k.constraint_name) col
              from dba_constraints k
             where k.owner = 'BANK' and k.table_name = 'CARDS' and k.constraint_name like 'BIN$%') loop
    execute immediate 'alter table bank.cards rename constraint "' || c.constraint_name || '" to '
                   || case c.constraint_type when 'P' then 'cards_pk' when 'U' then 'cards_pan_uk'
                                             else 'cards_' || lower(c.col) || '_nn' end;
  end loop;
  for i in (select index_name, uniqueness, (select column_name from dba_ind_columns c where c.index_owner = 'BANK'
                   and c.index_name = x.index_name and c.column_position = 1) col
              from dba_indexes x where owner = 'BANK' and table_name = 'CARDS' and index_name like 'BIN$%') loop
    ren_idx(i.index_name, case i.col when 'CARD_ID' then 'cards_pk' else 'cards_pan_uk' end);
  end loop;
end;
/
alter table bank.cards add constraint cards_account_fk foreign key (account_id) references bank.accounts;
select constraint_name, constraint_type, status from dba_constraints where owner = 'BANK' and table_name = 'CARDS' order by 1;

prompt == 2b: a bad batch zeroes 1/7 of the balances and commits
alter table bank.accounts enable row movement;
-- SCN, not a timestamp: timestamps map to SCNs with ~3 s granularity, and my first version's
-- VERSIONS BETWEEN TIMESTAMP found 0 changed rows although 4,285 had just been updated
column scn_before new_value scn_before noprint
select current_scn scn_before from v$database;
exec dbms_session.sleep(2)
update bank.accounts set balance = 0 where mod(account_id, 7) = 0;
commit;
prompt -- investigate with a versions query: what changed, when, by which transaction
select count(*) rows_changed, min(versions_starttime) first_change, max(versions_xid) xid
from bank.accounts versions between scn &scn_before and maxvalue
where versions_operation = 'U';
flashback table bank.accounts to scn &scn_before;
alter table bank.accounts disable row movement;
exit
