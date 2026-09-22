-- UNA sola consulta. Pega, RUN, y copiame la tabla.
-- Marcadores tolerantes sobre las funciones desplegadas.
select
  p.proname                                                as funcion,
  pg_get_functiondef(p.oid) ilike '%sum(b.monto)%'         as usa_sum_b_monto,
  pg_get_functiondef(p.oid) ilike '%total_blocked%'        as menciona_total_blocked,
  pg_get_functiondef(p.oid) ilike '%total_win%'            as menciona_total_win,
  pg_get_functiondef(p.oid) ilike '%precio_salida%'        as pozo_usa_precio_salida,
  pg_get_functiondef(p.oid) ilike '%retirado%'             as excluye_retirados,
  pg_get_functiondef(p.oid) ilike '%0.75%'                 as comision_hardcodeada,
  pg_get_functiondef(p.oid) ilike '%porcentaje_casa%'      as lee_porcentaje_casa,
  length(pg_get_functiondef(p.oid))                        as tamano
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('liquidar_remate','cancelar_remate','cerrar_remate');
