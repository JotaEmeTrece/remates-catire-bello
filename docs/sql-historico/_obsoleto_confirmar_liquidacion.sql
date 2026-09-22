-- ============================================================================
--  CONFIRMACION FINAL: ¿que version de liquidar_remate esta desplegada?
--
--  El diagnostico rapido uso un marcador de texto MUY especifico
--  ('sum(b.monto)::numeric as total_blocked') y devolvio 0. Eso puede
--  significar dos cosas distintas:
--    (a) el defecto C3 esta corregido en produccion, o
--    (b) el defecto sigue ahi pero escrito con otra sintaxis
--        (sin el ::numeric, con otro espaciado, con otro alias)
--
--  Estas dos consultas lo resuelven sin ambiguedad.
--  SOLO LECTURA.
-- ============================================================================

-- 1) Marcadores sueltos, mucho mas tolerantes que los del diagnostico rapido.
--    Si 'usa_sum_b_monto' = true y 'usa_total_win' = true, el defecto C3
--    SIGUE presente aunque el marcador estricto haya dado 0.
select
  p.proname                                                        as funcion,
  pg_get_functiondef(p.oid) ilike '%sum(b.monto)%'                 as usa_sum_b_monto,
  pg_get_functiondef(p.oid) ilike '%total_blocked%'                as menciona_total_blocked,
  pg_get_functiondef(p.oid) ilike '%total_win%'                    as menciona_total_win,
  pg_get_functiondef(p.oid) ilike '%saldo_bloqueado - %'           as descuenta_bloqueado,
  pg_get_functiondef(p.oid) ilike '%precio_salida%'                as pozo_incluye_precio_salida,
  pg_get_functiondef(p.oid) ilike '%retirado%'                     as excluye_retirados,
  pg_get_functiondef(p.oid) ilike '%0.75%'                         as comision_hardcodeada,
  pg_get_functiondef(p.oid) ilike '%porcentaje_casa%'              as lee_porcentaje_casa,
  length(pg_get_functiondef(p.oid))                                as tamano_caracteres
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('liquidar_remate','cancelar_remate');


-- 2) EL CODIGO COMPLETO de la funcion desplegada. Copiamelo tal cual:
--    con esto dejo de adivinar y comparo linea por linea contra el repo.
select pg_get_functiondef('public.liquidar_remate(uuid)'::regprocedure) as codigo_desplegado;


-- ============================================================================
-- 3) ¿Que pasa si un admin BORRA un caballo que ya tiene pujas?
--    La pantalla app/admin/remates/[id] permite borrar caballos sin ninguna
--    guarda. El comportamiento depende de la regla ON DELETE de la FK.
--
--    COMO LEERLO en la columna 'definicion':
--      ON DELETE CASCADE   -> >>> GRAVISIMO: se borran las pujas y el dinero
--                             bloqueado de esos usuarios queda huerfano para
--                             siempre (nada lo puede liberar).
--      ON DELETE RESTRICT
--      o sin clausula      -> OK: la base rechaza el borrado. El admin ve un
--                             error feo, pero el dinero esta a salvo.
-- ============================================================================

select
  con.conname                                   as constraint_name,
  con.conrelid::regclass                        as tabla_hija,
  con.confrelid::regclass                       as tabla_padre,
  case con.confdeltype
    when 'a' then 'NO ACTION (rechaza)'
    when 'r' then 'RESTRICT (rechaza)'
    when 'c' then '>>> CASCADE (borra en cascada)'
    when 'n' then 'SET NULL'
    when 'd' then 'SET DEFAULT'
  end                                           as on_delete,
  pg_get_constraintdef(con.oid)                 as definicion
from pg_constraint con
where con.contype = 'f'
  and con.confrelid in ('public.horses'::regclass,
                        'public.races'::regclass,
                        'public.remates'::regclass)
order by tabla_padre, tabla_hija;


-- ============================================================================
-- 4) ¿Hay algo que impida cambiar remates.estado con un UPDATE directo?
--    La pantalla de edicion escribe 'estado' directamente, saltandose las
--    RPC cerrar_remate / liquidar_remate y todas sus validaciones.
--
--    Se esperan 0 filas: no hay trigger ni constraint que lo controle.
-- ============================================================================

select tgname as trigger_name, pg_get_triggerdef(oid) as definicion
from pg_trigger
where tgrelid = 'public.remates'::regclass
  and not tgisinternal

union all

select con.conname, pg_get_constraintdef(con.oid)
from pg_constraint con
where con.conrelid = 'public.remates'::regclass
  and con.contype = 'c';
