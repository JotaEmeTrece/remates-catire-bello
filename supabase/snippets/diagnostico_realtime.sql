-- ===========================================================================
--  QUE TIENE EL ESQUEMA realtime EN ESTA INSTALACION -> solo mira.
--
--    $db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
--    Get-Content supabase/snippets/diagnostico_realtime.sql | docker exec -i $db psql -U postgres -d postgres
-- ===========================================================================
\pset pager off

\echo ''
\echo '=== 1. Funciones del esquema realtime que nos interesan ==='
select p.proname,
       pg_get_function_arguments(p.oid) as argumentos,
       pg_get_function_result(p.oid)    as devuelve,
       has_function_privilege('postgres', p.oid, 'execute') as postgres_puede
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'realtime'
  and p.proname in ('send','broadcast_changes','topic')
order by p.proname, p.oid;

\echo ''
\echo '=== 2. La tabla realtime.messages: existe, tiene RLS, que columnas ==='
select c.relname, c.relrowsecurity as rls_activa
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'realtime' and c.relname like 'messages%'
order by c.relname;

select a.attname, format_type(a.atttypid, a.atttypmod) as tipo
from pg_attribute a
where a.attrelid = 'realtime.messages'::regclass and a.attnum > 0 and not a.attisdropped
order by a.attnum;

\echo ''
\echo '=== 3. Politicas que ya existan sobre realtime.messages ==='
select policyname, cmd, roles::text, qual
from pg_policies where schemaname = 'realtime' and tablename = 'messages';
\echo '(vacio = ninguna: nadie recibe nada en canales privados todavia)'

\echo ''
\echo '=== 4. Que publicaciones hay (postgres_changes) ==='
select pubname, puballtables from pg_publication;
select schemaname, tablename from pg_publication_tables order by 1,2;
\echo '(vacio = ninguna tabla publicada)'

\echo ''
\echo '=== 5. Permisos sobre el esquema realtime ==='
select has_schema_privilege('anon','realtime','usage')          as anon_usage,
       has_schema_privilege('authenticated','realtime','usage') as auth_usage,
       has_table_privilege('anon','realtime.messages','select')          as anon_select_messages,
       has_table_privilege('authenticated','realtime.messages','select') as auth_select_messages;
