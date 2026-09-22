-- UNA sola consulta. Codigo fuente de cerrar_remate y cancelar_remate.
--
-- Por que lo pido: los marcadores dicen que la cerrar_remate desplegada
-- pesa 3129 caracteres y menciona total_blocked y total_win, cuando la del
-- repo es un simple cambio de estado de ~1000. Son funciones distintas y
-- necesito ver la que corre de verdad antes de tocar nada.
select
  p.proname as funcion,
  pg_get_functiondef(p.oid) as codigo_desplegado
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('cerrar_remate','cancelar_remate')
order by p.proname;
