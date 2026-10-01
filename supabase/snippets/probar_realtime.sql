-- ===========================================================================
--  EXPERIMENTO: localizar donde se pierde el mensaje de realtime.
--
--  Ten la pantalla del remate ABIERTA en el navegador antes de correr esto,
--  y pon el id del remate abajo.
--
--    $db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
--    Get-Content supabase/snippets/probar_realtime.sql | docker exec -i $db psql -U postgres -d postgres
--
--  Manda DOS mensajes al mismo canal por caminos distintos:
--    A) con realtime.send()  -- lo que usa la aplicacion
--    B) con un INSERT directo en realtime.messages
--
--  Lo que diga la consola del navegador parte el problema:
--    llegan los dos   -> el problema esta en los triggers, no en realtime
--    llega solo B     -> realtime.send escribe algo que el servidor no entrega
--    no llega ninguno -> el servidor no esta entregando; fallo de entrega
-- ===========================================================================
\pset pager off

-- <<<<<< PON AQUI EL ID DEL REMATE QUE TIENES ABIERTO >>>>>>
\set remate '00000000-0000-0000-0000-000000000000'

\echo ''
\echo '=== remates disponibles (copia el id del que tengas abierto) ==='
select id, nombre, estado from public.remates order by created_at desc nulls last limit 5;

\echo ''
\echo '=== A) por realtime.send(), como lo hace la aplicacion ==='
select realtime.send(
  jsonb_build_object('prueba', 'A', 'remate_id', :'remate'),
  'puja',
  'remate:' || :'remate',
  true);

\echo ''
\echo '=== B) por INSERT directo en realtime.messages ==='
insert into realtime.messages (topic, extension, event, private, payload)
values ('remate:' || :'remate', 'broadcast', 'puja', true,
        jsonb_build_object('prueba', 'B', 'remate_id', :'remate'));

\echo ''
\echo '=== Lo que quedo escrito, con el tema EXACTO ==='
select topic, extension, event, private, payload, inserted_at
from realtime.messages
where topic like '%' || :'remate' || '%'
order by inserted_at desc limit 5;
