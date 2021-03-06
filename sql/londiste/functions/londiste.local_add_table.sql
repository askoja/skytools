create or replace function londiste.local_add_table(
    in i_queue_name     text,
    in i_table_name     text,
    in i_trg_args       text[],
    in i_table_attrs    text,
    in i_dest_table     text,
    out ret_code        int4,
    out ret_note        text)
as $$
-- ----------------------------------------------------------------------
-- Function: londiste.local_add_table(5)
--
--      Register table on Londiste node, with customizable trigger args.
--
-- Parameters:
--      i_queue_name    - queue name
--      i_table_name    - table name
--      i_trg_args      - args to trigger, or magic parameters.
--      i_table_attrs   - args to python handler
--      i_dest_table    - actual name of destination table (NULL if same)
--
-- Trigger args:
--      See documentation for pgq triggers.
--
-- Magic parameters:
--      no_triggers     - skip trigger creation
--      skip_truncate   - set 'skip_truncate' table attribute
--      expect_sync     - set table state to 'ok'
--      tgflags=X       - trigger creation flags
--      merge_all       - merge table from all sources. required for
--                        multi-source table
--      no_merge        - do not merge tables from different sources
--      skip            - create skip trigger. same as S flag
--      virtual_table   - skips structure check and trigger creation
--
-- Trigger creation flags (default: AIUDL):
--      I - ON INSERT
--      U - ON UPDATE
--      D - ON DELETE
--      Q - use pgq.sqltriga() as trigger function
--      L - use pgq.logutriga() as trigger function
--      B - BEFORE
--      A - AFTER
--      S - SKIP
--
-- Example:
--      > londiste.local_add_table('q', 'tbl', array['tgflags=BI', 'SKIP', 'pkey=col1,col2'])
--
-- Returns:
--      200 - Ok
--      301 - Warning, trigger exists that will fire before londiste one
--      400 - No such set
------------------------------------------------------------------------
declare
    col_types text;
    fq_table_name text;
    new_state text;
    trunctrg_name text;
    pgversion int;
    logtrg_previous text;
    lg_name text;
    lg_func text;
    lg_pos text;
    lg_event text;
    lg_args text;
    _extra_args text;
    tbl record;
    i integer;
    j integer;
    sql text;
    arg text;
    _node record;
    _tbloid oid;
    _combined_queue text;
    _combined_table text;
    -- skip trigger
    _skip_prefix text := 'zzz_';
    _skip_trg_count integer;
    _skip_trg_name text;
    -- check local tables from all sources
    _queue_name text;
    _local boolean;
    -- array with all tgflags values
    _check_flags char[] := array['B','A','Q','L','I','U','D','S'];
    -- given tgflags array
    _tgflags char[];
    -- ordinary argument array
    _args text[];
    -- argument flags
    _expect_sync boolean := false;
    _merge_all boolean := false;
    _no_merge boolean := false;
    _skip_truncate boolean := false;
    _no_triggers boolean := false;
    _skip boolean := false;
    _virtual_table boolean := false;
    _dest_table text;
    _got_extra1 boolean := false;
    _table_name2 text;
    _desc text;
begin

    -------- i_trg_args ARGUMENTS PARSING

    if array_lower(i_trg_args, 1) is not null then
        for i in array_lower(i_trg_args, 1) .. array_upper(i_trg_args, 1) loop
            arg := i_trg_args[i];
            if arg like 'tgflags=%' then
                -- special flag handling
                arg := upper(substr(arg, 9));
                for j in array_lower(_check_flags, 1) .. array_upper(_check_flags, 1) loop
                    if position(_check_flags[j] in arg) > 0 then
                        _tgflags := array_append(_tgflags, _check_flags[j]);
                    end if;
                end loop;
            elsif arg = 'expect_sync' then
                _expect_sync := true;
            elsif arg = 'skip_truncate' then
                _skip_truncate := true;
            elsif arg = 'no_triggers' then
                _no_triggers := true;
            elsif arg = 'merge_all' then
                _merge_all = true;
            elsif arg = 'no_merge' then
                _no_merge = true;
            elsif lower(arg) = 'skip' then
                _skip := true;
            elsif arg = 'virtual_table' then
                _virtual_table := true;
                _expect_sync := true;   -- do not copy
                _no_triggers := true;   -- do not create triggers
            else
                if arg like 'ev_extra1=%' then
                    _got_extra1 := true;
                end if;
                -- ordinary arg
                _args = array_append(_args, quote_literal(arg));
            end if;
        end loop;
    end if;

    if _merge_all and _no_merge then
        select 405, 'Cannot use merge-all and no-merge together'
        into ret_code, ret_note;
        return;
    end if;

    fq_table_name := londiste.make_fqname(i_table_name);
    _dest_table := londiste.make_fqname(coalesce(i_dest_table, i_table_name));

    if _dest_table <> fq_table_name and not _got_extra1 then
        -- if renamed table, enforce trigger to put
        -- global table name into extra1
        arg := 'ev_extra1=' || quote_literal(fq_table_name);
        _args := array_append(_args, quote_literal(arg));
    end if;

    if _dest_table = fq_table_name then
        _desc := fq_table_name;
    else
        _desc := fq_table_name || '(' || _dest_table || ')';
    end if;

    -------- TABLE STRUCTURE CHECK

    if not _virtual_table then
        _tbloid := londiste.find_table_oid(_dest_table);
        if _tbloid is null then
            select 404, 'Table does not exist: ' || _desc into ret_code, ret_note;
            return;
        end if;
        col_types := londiste.find_column_types(_dest_table);
        if position('k' in col_types) < 1 then
            -- allow missing primary key in case of combined table where
            -- pkey was removed by londiste
            perform 1 from londiste.table_info t,
                pgq_node.node_info n_this,
                pgq_node.node_info n_other
              where n_this.queue_name = i_queue_name
                and n_other.combined_queue = n_this.combined_queue
                and n_other.queue_name <> n_this.queue_name
                and t.queue_name = n_other.queue_name
                and coalesce(t.dest_table, t.table_name) = _dest_table
                and t.dropped_ddl is not null;
            if not found then
                select 400, 'Primary key missing on table: ' || _desc into ret_code, ret_note;
                return;
            end if;
        end if;
    end if;

    -------- TABLE REGISTRATION LOGIC

    select * from pgq_node.get_node_info(i_queue_name) into _node;
    if not found or _node.ret_code >= 400 then
        select 400, 'No such set: ' || i_queue_name into ret_code, ret_note;
        return;
    end if;

    select merge_state, local into tbl
        from londiste.table_info
        where queue_name = i_queue_name and table_name = fq_table_name;
    if not found then
        -- add to set on root
        if _node.node_type = 'root' then
            select f.ret_code, f.ret_note into ret_code, ret_note
                from londiste.global_add_table(i_queue_name, i_table_name) f;
            if ret_code <> 200 then
                return;
            end if;
        else
            select 404, 'Table not available on queue: ' || _desc
                into ret_code, ret_note;
            return;
        end if;

        -- reload info
        select merge_state, local into tbl
            from londiste.table_info
            where queue_name = i_queue_name and table_name = fq_table_name;
    end if;

    if tbl.local then
        select 200, 'Table already added: ' || _desc into ret_code, ret_note;
        return;
    end if;

    if _node.node_type = 'root' then
        new_state := 'ok';
        perform londiste.root_notify_change(i_queue_name, 'londiste.add-table', fq_table_name);
    elsif _node.node_type = 'leaf' and _node.combined_type = 'branch' then
        new_state := 'ok';
    elsif _expect_sync then
        new_state := 'ok';
    else
        new_state := NULL;
    end if;

    update londiste.table_info
        set local = true,
            merge_state = new_state,
            table_attrs = coalesce(i_table_attrs, table_attrs),
            dest_table = nullif(_dest_table, fq_table_name)
        where queue_name = i_queue_name and table_name = fq_table_name;
    if not found then
        raise exception 'lost table: %', fq_table_name;
    end if;

    -- merge all table sources on leaf
    if _node.node_type = 'leaf' and not _no_merge then
        for _queue_name, _table_name2, _local in
            select t2.queue_name, t2.table_name, t2.local
            from londiste.table_info t
            join pgq_node.node_info n on (n.queue_name = t.queue_name)
            left join pgq_node.node_info n2 on (n2.combined_queue = n.combined_queue or
                    (n2.combined_queue is null and n.combined_queue is null))
            left join londiste.table_info t2
              on (t2.queue_name = n2.queue_name and
                  coalesce(t2.dest_table, t2.table_name) = coalesce(t.dest_table, t.table_name))
            where t.queue_name = i_queue_name
              and t.table_name = fq_table_name
              and t2.queue_name != i_queue_name -- skip self
        loop
            -- if table from some other source is already marked as local,
            -- raise error
            if _local and coalesce(new_state, 'x') <> 'ok' then
                select 405, 'Found local table '|| _desc
                        || ' in queue ' || _queue_name
                        || ', use remove-table first to remove all previous '
                        || 'table subscriptions'
                into ret_code, ret_note;
                return;
            end if;

           -- when table comes from multiple sources, merge_all switch is
           -- required
           if not _merge_all and coalesce(new_state, 'x') <> 'ok' then
               select 405, 'Found multiple sources for table '|| _desc
                       || ', use merge-all or no-merge to continue'
               into ret_code, ret_note;
               return;
           end if;

            update londiste.table_info
               set local = true,
                   merge_state = new_state,
                   table_attrs = coalesce(i_table_attrs, table_attrs)
               where queue_name = _queue_name and table_name = _table_name2;
            if not found then
                raise exception 'lost table: % on queue %', _table_name2, _queue_name;
            end if;
        end loop;

        -- if this node has combined_queue, add table there too
        -- note: we need to keep both table_name/dest_table values
        select n2.queue_name, t.table_name
            from pgq_node.node_info n1
            join pgq_node.node_info n2
                on (n2.queue_name = n1.combined_queue)
            left join londiste.table_info t
                on (t.queue_name = n2.queue_name and t.table_name = fq_table_name and t.local)
            where n1.queue_name = i_queue_name and n2.node_type = 'root'
            into _combined_queue, _combined_table;
        if found and _combined_table is null then
            select f.ret_code, f.ret_note
                from londiste.local_add_table(_combined_queue, fq_table_name, i_trg_args, i_table_attrs, _dest_table) f
                into ret_code, ret_note;
            if ret_code >= 300 then
                return;
            end if;
        end if;
    end if;

    if _skip_truncate then
        perform 1
        from londiste.local_set_table_attrs(i_queue_name, fq_table_name,
            coalesce(i_table_attrs || '&skip_truncate=1', 'skip_truncate=1'));
    end if;

    -------- TRIGGER LOGIC

    -- new trigger
    _extra_args := '';
    lg_name := '_londiste_' || i_queue_name;
    lg_func := 'pgq.logutriga';
    lg_event := '';
    lg_args := quote_literal(i_queue_name);
    lg_pos := 'after';

    if array_lower(_args, 1) is not null then
        lg_args := lg_args || ', ' || array_to_string(_args, ', ');
    end if;

    if 'B' = any(_tgflags) then
        lg_pos := 'before';
    end if;
    if 'A' = any(_tgflags)  then
        lg_pos := 'after';
    end if;
    if 'Q' = any(_tgflags) then
        lg_func := 'pgq.sqltriga';
    end if;
    if 'L' = any(_tgflags) then
        lg_func := 'pgq.logutriga';
    end if;
    if 'I' = any(_tgflags) then
        lg_event := lg_event || ' or insert';
    end if;
    if 'U' = any(_tgflags) then
        lg_event := lg_event || ' or update';
    end if;
    if 'D' = any(_tgflags) then
        lg_event := lg_event || ' or delete';
    end if;
    if 'S' = any(_tgflags) then
        _skip := true;
    end if;

    if _node.node_type = 'leaf' then
        -- on weird leafs the trigger funcs may not exist
        perform 1 from pg_proc p join pg_namespace n on (n.oid = p.pronamespace)
            where n.nspname = 'pgq' and p.proname in ('logutriga', 'sqltriga');
        if not found then
            select 200, 'Table added with no triggers: ' || _desc into ret_code, ret_note;
            return;
        end if;
        -- on regular leaf, install deny trigger
        _extra_args := ', ' || quote_literal('deny');
    end if;

    -- if skip param given, rename previous skip triggers and prefix current
    if _skip then
        -- get count and name of existing skip triggers
        select count(*), min(t.tgname)
        into _skip_trg_count, _skip_trg_name
        from pg_catalog.pg_trigger t
        where t.tgrelid = londiste.find_table_oid(_dest_table)
            and position(E'\\000skip\\000' in lower(tgargs::text)) > 0;
        -- if no previous skip triggers, prefix name and add SKIP to args
        if _skip_trg_count = 0 then
            lg_name := _skip_prefix || lg_name;
            lg_args := lg_args || ', ' || quote_literal('SKIP');
        -- if one previous skip trigger, check it's prefix and
        -- do not use SKIP on current trigger
        elsif _skip_trg_count = 1 then
            -- if not prefixed then rename
            if position(_skip_prefix in _skip_trg_name) != 1 then
                sql := 'alter trigger ' || _skip_trg_name
                    || ' on ' || londiste.quote_fqname(_dest_table)
                    || ' rename to ' || _skip_prefix || _skip_trg_name;
                execute sql;
            end if;
        else
            select 405, 'Multiple SKIP triggers in table: ' || _desc
            into ret_code, ret_note;
            return;
        end if;
    end if;

    -- create Ins/Upd/Del trigger if it does not exists already
    perform 1 from pg_catalog.pg_trigger
        where tgrelid = londiste.find_table_oid(_dest_table)
            and tgname = lg_name;
    if not found then

        if _no_triggers then
            select 200, 'Table added with no triggers: ' || _desc
            into ret_code, ret_note;
            return;
        end if;

        -- finalize event
        lg_event := substr(lg_event, 4);
        if lg_event = '' then
            lg_event := 'insert or update or delete';
        end if;

        -- create trigger
        sql := 'create trigger ' || quote_ident(lg_name)
            || ' ' || lg_pos || ' ' || lg_event
            || ' on ' || londiste.quote_fqname(_dest_table)
            || ' for each row execute procedure '
            || lg_func || '(' || lg_args || _extra_args || ')';
        execute sql;
    end if;

    -- create truncate trigger if it does not exists already
    show server_version_num into pgversion;
    if pgversion >= 80400 then
        trunctrg_name  := '_londiste_' || i_queue_name || '_truncate';
        perform 1 from pg_catalog.pg_trigger
          where tgrelid = londiste.find_table_oid(_dest_table)
            and tgname = trunctrg_name;
        if not found then
            sql := 'create trigger ' || quote_ident(trunctrg_name)
                || ' after truncate on ' || londiste.quote_fqname(_dest_table)
                || ' for each statement execute procedure pgq.sqltriga(' || quote_literal(i_queue_name)
                || _extra_args || ')';
            execute sql;
        end if;
    end if;

    -- Check that no trigger exists on the target table that will get fired
    -- before londiste one (this could have londiste replicate data
    -- out-of-order
    --
    -- Don't report all the trigger names, 8.3 does not have array_accum
    -- available

    if pgversion >= 90000 then
        select tg.tgname into logtrg_previous
        from pg_class r join pg_trigger tg on (tg.tgrelid = r.oid)
        where r.oid = londiste.find_table_oid(_dest_table)
          and not tg.tgisinternal
          and tg.tgname < lg_name::name
          -- per-row AFTER trigger
          and (tg.tgtype & 3) = 1   -- bits: 0:ROW, 1:BEFORE
          -- current londiste
          and not londiste.is_replica_func(tg.tgfoid)
          -- old londiste
          and substring(tg.tgname from 1 for 10) != '_londiste_'
          and substring(tg.tgname from char_length(tg.tgname) - 6) != '_logger'
        order by 1 limit 1;
    else
        select tg.tgname into logtrg_previous
        from pg_class r join pg_trigger tg on (tg.tgrelid = r.oid)
        where r.oid = londiste.find_table_oid(_dest_table)
          and not tg.tgisconstraint
          and tg.tgname < lg_name::name
          -- per-row AFTER trigger
          and (tg.tgtype & 3) = 1   -- bits: 0:ROW, 1:BEFORE
          -- current londiste
          and not londiste.is_replica_func(tg.tgfoid)
          -- old londiste
          and substring(tg.tgname from 1 for 10) != '_londiste_'
          and substring(tg.tgname from char_length(tg.tgname) - 6) != '_logger'
        order by 1 limit 1;
    end if;

    if logtrg_previous is not null then
       select 301,
              'Table added: ' || _desc
                              || ', but londiste trigger is not first: '
                              || logtrg_previous
         into ret_code, ret_note;
        return;
    end if;

    select 200, 'Table added: ' || _desc into ret_code, ret_note;
    return;
end;
$$ language plpgsql;

create or replace function londiste.local_add_table(
    in i_queue_name     text,
    in i_table_name     text,
    in i_trg_args       text[],
    in i_table_attrs    text,
    out ret_code        int4,
    out ret_note        text)
as $$
-- ----------------------------------------------------------------------
-- Function: londiste.local_add_table(4)
--
--      Register table on Londiste node.
-- ----------------------------------------------------------------------
begin
    select f.ret_code, f.ret_note into ret_code, ret_note
      from londiste.local_add_table(i_queue_name, i_table_name, i_trg_args, i_table_attrs, null) f;
    return;
end;
$$ language plpgsql;

create or replace function londiste.local_add_table(
    in i_queue_name     text,
    in i_table_name     text,
    in i_trg_args       text[],
    out ret_code        int4,
    out ret_note        text)
as $$
-- ----------------------------------------------------------------------
-- Function: londiste.local_add_table(3)
--
--      Register table on Londiste node.
-- ----------------------------------------------------------------------
begin
    select f.ret_code, f.ret_note into ret_code, ret_note
      from londiste.local_add_table(i_queue_name, i_table_name, i_trg_args, null) f;
    return;
end;
$$ language plpgsql;

create or replace function londiste.local_add_table(
    in i_queue_name     text,
    in i_table_name     text,
    out ret_code        int4,
    out ret_note        text)
as $$
-- ----------------------------------------------------------------------
-- Function: londiste.local_add_table(2)
--
--      Register table on Londiste node.
-- ----------------------------------------------------------------------
begin
    select f.ret_code, f.ret_note into ret_code, ret_note
      from londiste.local_add_table(i_queue_name, i_table_name, null) f;
    return;
end;
$$ language plpgsql strict;


