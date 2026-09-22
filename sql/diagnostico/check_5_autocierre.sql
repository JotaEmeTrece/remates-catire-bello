-- UNA sola consulta.
--
-- Sospecha: el cron auto_cerrar_remates hace un UPDATE plano y NO llama a
-- cerrar_remate. Si es asi, hay DOS comportamientos distintos para la misma
-- transicion de estado: el boton del admin libera saldos (con el defecto) y
-- el cron no libera nada.
--
-- COMO LEERLO:
--   llama_a_cerrar_remate = false  -> confirmado, son dos caminos distintos
select
  p.proname                                              as funcion,
  pg_get_functiondef(p.oid) ilike '%cerrar_remate(%'     as llama_a_cerrar_remate,
  pg_get_functiondef(p.oid) ilike '%saldo_bloqueado%'    as toca_saldos,
  pg_get_functiondef(p.oid)                              as codigo
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'auto_cerrar_remates';
