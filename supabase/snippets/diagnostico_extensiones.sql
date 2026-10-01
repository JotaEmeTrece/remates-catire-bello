-- ===========================================================================
--  diagnostico_extensiones.sql   -   SOLO LECTURA
--
--  PARA QUE: responder, sin suposiciones, las tres preguntas que importan
--  cuando P47 se queja de una extension en `public`:
--
--     1. Que extensiones hay, en que esquema, y de QUIEN son.
--     2. Quien puede ejecutar sus funciones.
--     3. Podemos hacer algo al respecto desde este rol, o no.
--
--  La tercera es la que me falte el 01/10. Di por hecho que `postgres` podia
--  revocar lo que quisiera en `public`, porque en un Postgres pelado es asi.
--  En Supabase no: supautils intercepta CREATE EXTENSION y la crea con un rol
--  privilegiado, asi que `postgres` no es el dueno y no puede revocar lo que
--  no concedio. Esta consulta lo dice de frente en vez de dejarte deducirlo de
--  cuarenta warnings.
--
--      Get-Content supabase/snippets/diagnostico_extensiones.sql | docker exec -i $db psql -U postgres -d postgres
-- ===========================================================================

\echo '=== 1. Quien soy y que puedo ==='
select current_user,
       (select rolsuper from pg_roles where rolname = current_user) as soy_superusuario;

\echo '=== 2. Las extensiones instaladas, su esquema y su dueno ==='
\echo '    (si el dueno no es el rol de arriba, no puedes revocarle nada)'
select e.extname,
       n.nspname                       as esquema,
       pg_get_userbyid(e.extowner)     as dueno,
       pg_get_userbyid(e.extowner) = current_user as puedo_tocarla
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
order by n.nspname, e.extname;

\echo '=== 3. Funciones de extension que viven en public, y quien las ve ==='
select x.extname,
       pg_get_userbyid(x.extowner) as dueno,
       count(*)                                                                      as funciones,
       count(*) filter (where has_function_privilege('authenticated', p.oid,'execute')) as las_ve_authenticated,
       count(*) filter (where has_function_privilege('anon', p.oid,'execute'))          as las_ve_anon
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_depend d on d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
join pg_extension x on x.oid = d.refobjid
where n.nspname = 'public' and p.prokind = 'f'
group by x.extname, x.extowner
order by x.extname;

\echo '=== 4. El ACL crudo de una, para ver QUIEN concedio ==='
\echo '    en anon=X/supabase_admin, lo de despues de la barra es el que concedio:'
\echo '    si no eres tu, tu revoke no hace nada y PostgreSQL solo avisa.'
select p.oid::regprocedure::text as firma, p.proacl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_depend d on d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
where n.nspname = 'public' and p.prokind = 'f'
order by p.proname
limit 3;

\echo '=== 5. Y la pregunta que de verdad importa: esto esta en produccion? ==='
\echo '    No se puede responder desde aqui. Se responde en el repo, y la'
\echo '    respuesta al 01/10 es NO: ninguna migracion crea extensiones.'
\echo '    Para comprobarlo tu mismo:  grep -ri "create extension" supabase/migrations/'
