-- ===========================================================================
--  SEGUNDA RONDA -> dblink_connect_u y conexiones que si piden contrasena.
--  Solo mira, no modifica nada.
-- ===========================================================================
\pset pager off

\echo ''
\echo '=== 1. dblink_connect_u: quien la puede ejecutar ==='
select p.proname,
       pg_get_userbyid(p.proowner) as dueno,
       coalesce(p.proacl::text, '(sin ACL: solo el dueno)') as acl,
       has_function_privilege('postgres', p.oid, 'execute') as postgres_puede
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.proname like 'dblink_connect%'
order by p.proname;

\echo ''
\echo '=== 2. postgres es miembro de algun rol que pudiera darle ese permiso? ==='
select pg_get_userbyid(m.roleid) as miembro_de
from pg_auth_members m where m.member = 'postgres'::regrole;

\echo ''
\echo '=== 3. Probar dblink_connect_u ==='
do $$
begin
  begin
    perform dblink_connect_u('probe', 'dbname=postgres user=postgres');
    raise notice 'dblink_connect_u FUNCIONA';
    perform dblink_disconnect('probe');
  exception when others then
    raise notice 'dblink_connect_u falla -> [%] %', sqlstate, sqlerrm;
  end;
end $$;

\echo ''
\echo '=== 4. Y si postgres se concede el permiso a si mismo? ==='
do $$
begin
  begin
    execute 'grant execute on function dblink_connect_u(text) to postgres';
    execute 'grant execute on function dblink_connect_u(text, text) to postgres';
    raise notice 'grant aplicado';
  exception when others then
    raise notice 'no pudo conceder -> [%] %', sqlstate, sqlerrm;
  end;
  begin
    perform dblink_connect_u('probe2', 'dbname=postgres user=postgres');
    raise notice 'AHORA SI FUNCIONA dblink_connect_u';
    perform dblink_disconnect('probe2');
  exception when others then
    raise notice 'sigue fallando -> [%] %', sqlstate, sqlerrm;
  end;
end $$;

\echo ''
\echo '=== 5. Conexiones TCP que SI pedirian contrasena (no loopback) ==='
do $$
declare
  v_cad text;
  v_candidatas text[] := array[
    'dbname=postgres user=postgres host=supabase_db_remates-catire-bello port=5432 password=postgres',
    'dbname=postgres user=postgres host=db port=5432 password=postgres',
    'dbname=postgres user=authenticator host=127.0.0.1 port=5432 password=postgres'
  ];
begin
  foreach v_cad in array v_candidatas loop
    begin
      perform dblink_connect('probe3', v_cad);
      raise notice 'FUNCIONA -> %', v_cad;
      perform dblink_disconnect('probe3');
    exception when others then
      raise notice 'falla    -> %  ||  [%] %', v_cad, sqlstate, sqlerrm;
    end;
  end loop;
end $$;

\echo ''
\echo '=== 6. Reglas de pg_hba, si se pueden leer ==='
do $$
declare r record;
begin
  for r in select type, database, user_name, address, auth_method from pg_hba_file_rules loop
    raise notice '% % % % -> %', r.type, r.database, r.user_name, coalesce(r.address,'(local)'), r.auth_method;
  end loop;
exception when others then
  raise notice 'no se puede leer pg_hba_file_rules -> [%] %', sqlstate, sqlerrm;
end $$;
