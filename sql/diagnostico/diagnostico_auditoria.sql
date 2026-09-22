-- ============================================================================
--  DIAGNOSTICO DE AUDITORIA - Remates Catire Bello
--  Fecha: 2026-08-26
--
--  TODAS las consultas de este archivo son de SOLO LECTURA.
--  No hacen INSERT, UPDATE, DELETE, ALTER ni DROP. Se pueden correr
--  en produccion sin riesgo.
--
--  Corre cada bloque por separado en el editor SQL de Supabase y guarda
--  el resultado. Cada bloque responde a un hallazgo del informe
--  AUDITORIA_2026-08.md
-- ============================================================================


-- ============================================================================
-- D1 · ESCALADA DE PRIVILEGIOS (hallazgo S1) - EL MAS URGENTE
-- ============================================================================
-- Pregunta: ¿un usuario normal puede hacerse admin a si mismo?
--
-- COMO LEERLO:
--   trigger_inmutabilidad = 0  Y  update_para_authenticated = true
--      -> AGUJERO ABIERTO. Cualquier usuario logueado puede ejecutar
--         update profiles set es_admin=true where id=auth.uid()
--         y tomar control total de la plataforma y de las wallets.
--         Es lo primero que tienes que cerrar hoy.
--   trigger_inmutabilidad >= 1
--      -> Protegido. El hardening SI esta aplicado en produccion.

select
  (select count(*) from pg_trigger
    where tgrelid = 'public.profiles'::regclass
      and tgname = 'enforce_admin_immutability')                as trigger_inmutabilidad,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='promover_usuario')  as rpc_promover_usuario,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='tr_check_admin_immutability') as fn_inmutabilidad,
  has_table_privilege('authenticated','public.profiles','UPDATE') as update_para_authenticated;

-- Politicas actuales sobre profiles (busca cualquiera de UPDATE sin
-- restriccion de columnas):
select policyname, cmd, roles, qual as using_expr, with_check
from pg_policies
where schemaname='public' and tablename='profiles'
order by cmd, policyname;


-- ============================================================================
-- D2 · ESTADO GENERAL DE RLS (hallazgos S2, S3)
-- ============================================================================
-- Cualquier tabla de public con rls_habilitado = false es una tabla
-- completamente abierta a quien tenga la anon key.

select c.relname                as tabla,
       c.relrowsecurity         as rls_habilitado,
       c.relforcerowsecurity    as rls_forzado,
       (select count(*) from pg_policies pp
         where pp.schemaname='public' and pp.tablename=c.relname) as n_politicas
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname='public' and c.relkind='r'
order by c.relrowsecurity, c.relname;

-- Politicas demasiado permisivas (using = true) sobre tablas sensibles.
-- Se espera encontrar bids_select_auth aqui (hallazgo S2).
select tablename, policyname, cmd, roles, qual
from pg_policies
where schemaname='public'
  and (qual = 'true' or qual is null)
  and cmd in ('SELECT','ALL')
order by tablename;


-- ============================================================================
-- D3 · ¿EL CODIGO DESPLEGADO ES EL DEL REPO? (hallazgos C1, C2, C3)
-- ============================================================================
-- Compara la definicion viva de las funciones contra los defectos que
-- encontre en los scripts del repo.
--
-- COMO LEERLO: cada columna en true = ese defecto ESTA en produccion.

select
  p.proname as funcion,
  pg_get_functiondef(p.oid) like '%coalesce(b.max_monto, h.precio_salida)%'
      as C1_pozo_inflado,
  pg_get_functiondef(p.oid) like '%* 0.75%'
      as C2_comision_hardcodeada,
  pg_get_functiondef(p.oid) like '%sum(b.monto)::numeric as total_blocked%'
      as C3_total_blocked_mal,
  pg_get_functiondef(p.oid) like '%porcentaje_casa%'
      as usa_porcentaje_casa
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public'
  and p.proname in ('liquidar_remate','cancelar_remate','admin_contabilidad_resumen')
order by p.proname;

-- Si necesitas ver el codigo completo de una funcion:
-- select pg_get_functiondef('public.liquidar_remate(uuid)'::regprocedure);

-- Los TRES numeros de comision que no coinciden (hallazgo C2).
-- default_columna  : lo que la base pone si nadie toca el campo (se espera 20.00)
-- fallback_contab. : el coalesce de admin_contabilidad_resumen (25)
-- liquidacion      : el 0.75 hardcodeado -> casa 25%
select
  (select column_default from information_schema.columns
    where table_schema='public' and table_name='remates'
      and column_name='porcentaje_casa')                    as default_columna,
  '25 (coalesce en admin_contabilidad_resumen)'             as fallback_contabilidad,
  '25 (0.75 hardcodeado en liquidar_remate)'                as liquidacion;

-- Distribucion real de porcentaje_casa en tus remates. Cualquier valor
-- distinto de 25 es un remate donde contabilidad y liquidacion discrepan.
select coalesce(porcentaje_casa, -1) as porcentaje_casa,
       count(*) as n_remates,
       count(*) filter (where estado='liquidado') as ya_liquidados
from public.remates
group by 1 order by 1;


-- ============================================================================
-- D4 · DOBLE ACREDITACION EN RECARGAS Y RETIROS (hallazgo C4)
-- ============================================================================
-- COMO LEERLO: tiene_for_update = false -> el bug esta presente.
-- Un doble clic del admin puede acreditar la recarga dos veces.

select p.proname as funcion,
       (pg_get_functiondef(p.oid) ilike '%p_deposit_request_id%for update%'
        or pg_get_functiondef(p.oid) ilike '%p_withdraw_id%for update%')
         as tiene_for_update_en_solicitud,
       pg_get_functiondef(p.oid) ilike '%estado = ''pendiente''%where id%'
         as tiene_guarda_en_update
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('aprobar_recarga','procesar_retiro');

-- ¿Ya ocurrio? Busca recargas aprobadas que generaron mas de un
-- movimiento de wallet. Cualquier fila aqui es dinero acreditado dos veces.
select wm.ref_externa as deposit_request_id,
       count(*)       as movimientos,
       sum(wm.monto)  as total_acreditado
from public.wallet_movements wm
where wm.tipo = 'recarga'
group by wm.ref_externa
having count(*) > 1;


-- ============================================================================
-- D5 · DINERO FANTASMA YA PAGADO (hallazgo C1) - EL NUMERO QUE DUELE
-- ============================================================================
-- Calcula, para cada remate ya liquidado, cuanto del pozo era dinero real
-- (pujas efectivas) y cuanto era inventado (precio_salida de caballos que
-- nadie pujo).
--
-- COMO LEERLO: la columna sobrepago_estimado es lo que la casa pago de mas
-- en cada remate. El total al final es tu perdida acumulada por este bug.

with liq as (
  select r.id, r.nombre, r.race_id, coalesce(r.porcentaje_casa,25)::numeric as pct
  from public.remates r
  where r.estado = 'liquidado'
),
tops as (
  select b.remate_id, b.horse_id, max(b.monto) as max_monto
  from public.bids b group by b.remate_id, b.horse_id
),
calc as (
  select l.id, l.nombre, l.pct,
    coalesce(sum(t.max_monto), 0)                              as pozo_real,
    coalesce(sum(coalesce(t.max_monto, h.precio_salida)), 0)   as pozo_calculado
  from liq l
  join public.horses h on h.race_id = l.race_id
  left join tops t on t.remate_id = l.id and t.horse_id = h.id
  group by l.id, l.nombre, l.pct
)
select nombre,
       pozo_real,
       pozo_calculado,
       (pozo_calculado - pozo_real)                                as pozo_inventado,
       round(pozo_calculado * (1 - pct/100.0), 2)                  as premio_pagado,
       round(pozo_real     * (1 - pct/100.0), 2)                   as premio_correcto,
       round((pozo_calculado - pozo_real) * (1 - pct/100.0), 2)    as sobrepago_estimado
from calc
where pozo_calculado > pozo_real
order by sobrepago_estimado desc;

-- Total acumulado de sobrepago:
with liq as (
  select r.id, r.race_id, coalesce(r.porcentaje_casa,25)::numeric as pct
  from public.remates r where r.estado='liquidado'
),
tops as (
  select b.remate_id, b.horse_id, max(b.monto) as max_monto
  from public.bids b group by b.remate_id, b.horse_id
),
calc as (
  select l.id, l.pct,
    coalesce(sum(t.max_monto),0)                            as pozo_real,
    coalesce(sum(coalesce(t.max_monto,h.precio_salida)),0)  as pozo_calc
  from liq l join public.horses h on h.race_id=l.race_id
  left join tops t on t.remate_id=l.id and t.horse_id=h.id
  group by l.id, l.pct
)
select round(sum((pozo_calc - pozo_real) * (1 - pct/100.0)), 2) as SOBREPAGO_TOTAL_BS
from calc;


-- ============================================================================
-- D6 · CONSISTENCIA DE WALLETS (hallazgo C3)
-- ============================================================================
-- El saldo_bloqueado de cada usuario deberia ser exactamente la suma de sus
-- pujas donde HOY es el lider, en remates que siguen abiertos.
--
-- COMO LEERLO: cualquier fila con diferencia <> 0 es una wallet descuadrada.
-- diferencia > 0 -> hay dinero bloqueado que no respalda ninguna puja viva.
-- diferencia < 0 -> hay pujas vivas sin respaldo bloqueado (peor).

with lideres as (
  select distinct on (b.remate_id, b.horse_id)
         b.remate_id, b.horse_id, b.user_id, b.monto
  from public.bids b
  join public.remates r on r.id = b.remate_id
  where r.estado = 'abierto'
  order by b.remate_id, b.horse_id, b.monto desc, b.created_at asc
),
esperado as (
  select user_id, sum(monto) as bloqueado_esperado
  from lideres group by user_id
)
select w.user_id,
       p.username,
       w.saldo_bloqueado                                  as bloqueado_real,
       coalesce(e.bloqueado_esperado, 0)                  as bloqueado_esperado,
       w.saldo_bloqueado - coalesce(e.bloqueado_esperado,0) as diferencia
from public.wallets w
left join esperado e on e.user_id = w.user_id
left join public.profiles p on p.id = w.user_id
where w.saldo_bloqueado <> coalesce(e.bloqueado_esperado, 0)
order by abs(w.saldo_bloqueado - coalesce(e.bloqueado_esperado,0)) desc;


-- ============================================================================
-- D7 · INTEGRIDAD DE DATOS DE CARRERAS (hallazgo P3)
-- ============================================================================
-- Caballos con numero duplicado en la misma carrera. Cualquier fila aqui
-- significa que set_ganador_carrera puede liquidar al caballo equivocado.

select race_id, numero, count(*) as repetidos,
       string_agg(nombre, ' | ') as caballos
from public.horses
group by race_id, numero
having count(*) > 1;

-- Constraints unicos existentes sobre horses y race_results
-- (se espera que NO exista unique(race_id,numero) -> ese es el problema):
select conrelid::regclass as tabla, conname, pg_get_constraintdef(oid) as definicion
from pg_constraint
where conrelid in ('public.horses'::regclass,'public.race_results'::regclass)
order by tabla, conname;

-- Remates abiertos cuya carrera ya paso (sintoma de cron caido, hallazgo O3):
select r.id, r.nombre, r.estado, r.closes_at, ra.fecha, ra.hora_programada
from public.remates r
join public.races ra on ra.id = r.race_id
where r.estado = 'abierto'
  and r.closes_at is not null
  and r.closes_at < now() - interval '5 minutes'
order by r.closes_at;

-- Remates sin ninguna regla de precio (sintoma de creacion a medias, P1):
select r.id, r.nombre, r.estado, r.created_at
from public.remates r
where not exists (select 1 from public.remate_price_rules pr where pr.remate_id = r.id)
order by r.created_at desc;

-- Carreras sin remate y remates sin caballos (huerfanos por P1):
select 'carrera sin remate' as problema, ra.id, ra.nombre, ra.created_at
from public.races ra
where not exists (select 1 from public.remates r where r.race_id = ra.id)
union all
select 'remate sin caballos', r.id, r.nombre, r.created_at
from public.remates r
where not exists (select 1 from public.horses h where h.race_id = r.race_id)
order by created_at desc;


-- ============================================================================
-- D8 · CRON DE AUTOCIERRE (hallazgo O3)
-- ============================================================================
-- Si esto da error de "relacion cron.job no existe", pg_cron no esta
-- instalado y los remates NO se estan cerrando solos.

select jobid, jobname, schedule, active, command
from cron.job
where jobname = 'auto_cerrar_remates';

-- Ultimas 20 ejecuciones. Cualquier status distinto de 'succeeded' es alarma.
select runid, status, return_message, start_time, end_time
from cron.job_run_details
where jobid in (select jobid from cron.job where jobname='auto_cerrar_remates')
order by start_time desc
limit 20;


-- ============================================================================
-- D9 · CONTABILIDAD (hallazgos A1, A2)
-- ============================================================================
-- Cuadre real de la caja, con los retiros pendientes SI descontados.
--
-- dinero_casa_reportado : lo que muestra hoy el panel de contabilidad
-- dinero_casa_corregido : lo que realmente tiene la casa
-- La diferencia entre ambos es exactamente los retiros pendientes.

with caja as (
  select
    (select coalesce(sum(monto),0) from public.deposit_requests  where estado='aprobado')  as recargas_aprobadas,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pagado')    as retiros_pagados,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pendiente') as retiros_pendientes,
    (select coalesce(sum(saldo_disponible+saldo_bloqueado),0) from public.wallets)         as saldo_usuarios
)
select *,
  recargas_aprobadas - retiros_pagados - saldo_usuarios                       as dinero_casa_reportado,
  recargas_aprobadas - retiros_pagados - saldo_usuarios - retiros_pendientes  as dinero_casa_corregido
from caja;

-- Signo de los movimientos por tipo. Se espera ver 'retiro' con montos
-- NEGATIVOS (causa del error de signo en resumen_casa, hallazgo A2)
-- y 'ajuste_manual' con signos mezclados (hallazgo A3).
select tipo,
       count(*)                                  as n,
       count(*) filter (where monto < 0)         as negativos,
       count(*) filter (where monto > 0)         as positivos,
       min(monto) as minimo, max(monto) as maximo, sum(monto) as suma
from public.wallet_movements
group by tipo
order by tipo;

-- ¿Sigue existiendo la funcion vieja resumen_casa? (deberia borrarse, A2)
select p.proname,
       p.prosecdef as es_security_definer,
       p.proconfig as search_path_fijo
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('resumen_casa','admin_contabilidad_resumen');


-- ============================================================================
-- D10 · MISCELANEOS
-- ============================================================================
-- ¿profiles tiene columna email? listar_wallets_superadmin la usa
-- (p.email). Si no existe, esa RPC falla en tiempo de ejecucion.
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='profiles'
order by ordinal_position;

-- Funciones SECURITY DEFINER sin search_path fijo (riesgo de secuestro de
-- search_path). Se espera encontrar resumen_casa aqui.
select p.proname, p.prosecdef, p.proconfig
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef = true and p.proconfig is null;

-- ¿admin_actions se esta usando? Si devuelve 0, la bitacora esta vacia
-- y no hay rastro forense de ninguna operacion de dinero (hallazgo S3).
select count(*) as registros_en_bitacora,
       min(created_at) as primero,
       max(created_at) as ultimo
from public.admin_actions;

-- Total de usuarios con privilegios administrativos. Revisa que no haya
-- ninguno que no reconozcas (relevante si D1 salio positivo).
select id, username, es_admin, es_super_admin, created_at
from public.profiles
where coalesce(es_admin,false) or coalesce(es_super_admin,false)
order by created_at;

-- ============================================================================
-- FIN DEL DIAGNOSTICO
-- ============================================================================
