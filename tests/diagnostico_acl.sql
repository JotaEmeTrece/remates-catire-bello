-- ===========================================================================
--  DIAGNOSTICO DE PERMISOS -> no modifica nada, solo mira.
--
--    $db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
--    Get-Content tests/diagnostico_acl.sql | docker exec -i $db psql -U postgres -d postgres
--
--  Responde tres preguntas:
--    1. De donde le viene a `anon` el select sobre deposit_requests.
--    2. Que funciones de `public` puede llamar cualquiera hoy.
--    3. Que tablas de `public` puede leer o escribir `anon` hoy.
-- ===========================================================================
\pset pager off

\echo ''
\echo '=== 1a. ACL de deposit_requests, desglosado ==='
select coalesce(nullif(pg_get_userbyid(a.grantee), ''), 'PUBLIC') as quien,
       a.privilege_type as privilegio,
       pg_get_userbyid(a.grantor) as quien_lo_dio
from pg_class c
cross join lateral aclexplode(c.relacl) a
where c.oid = 'public.deposit_requests'::regclass
order by 1, 2;

\echo ''
\echo '=== 1b. De que roles es miembro anon ==='
select pg_get_userbyid(m.roleid) as es_miembro_de, m.admin_option
from pg_auth_members m
where m.member = 'anon'::regrole;

\echo ''
\echo '=== 1c. Atributos del rol anon ==='
select rolname, rolsuper, rolbypassrls, rolinherit from pg_roles where rolname in ('anon','authenticated');

\echo ''
\echo '=== 2. Funciones de public ejecutables por authenticated o anon ==='
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentos,
       p.prosecdef as es_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       case when p.proacl is null then 'SIN ACL (default: PUBLIC ejecuta)'
            else p.proacl::text end as acl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind = 'f'
  and (has_function_privilege('authenticated', p.oid, 'execute')
    or has_function_privilege('anon', p.oid, 'execute'))
order by p.proname;

\echo ''
\echo '=== 3. Tablas de public y lo que puede anon ==='
select c.relname as tabla,
       c.relrowsecurity as rls,
       has_table_privilege('anon', c.oid, 'select') as anon_select,
       has_table_privilege('anon', c.oid, 'insert') as anon_insert,
       has_table_privilege('anon', c.oid, 'update') as anon_update,
       has_table_privilege('anon', c.oid, 'delete') as anon_delete,
       case when c.relacl is null then 'SIN ACL' else c.relacl::text end as acl
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

\echo ''
\echo '=== 4. Privilegios por defecto vigentes (\ddp) ==='
select coalesce(n.nspname, '(GLOBAL: todos los esquemas)') as ambito,
       pg_get_userbyid(d.defaclrole) as para_el_rol,
       case d.defaclobjtype when 'r' then 'tablas' when 'f' then 'funciones'
            when 'S' then 'secuencias' when 'T' then 'tipos' else d.defaclobjtype::text end as sobre,
       d.defaclacl::text as acl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
order by 1, 2, 3;
