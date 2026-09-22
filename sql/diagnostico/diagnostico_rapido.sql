-- ============================================================================
--  DIAGNOSTICO RAPIDO - Remates Catire Bello
--  UNA SOLA CONSULTA. Devuelve TODO en una tabla.
--
--  El editor SQL de Supabase solo muestra el resultado del ULTIMO select
--  cuando pegas varios. Por eso el archivo anterior parecia devolver solo
--  los admins: corrio todo, pero solo te mostro la ultima tabla.
--
--  Este archivo es UNA sola consulta. Pegala completa, dale RUN, y copiame
--  la tabla entera.
--
--  SOLO LECTURA. No modifica nada.
-- ============================================================================

with

-- S1: ¿puede un usuario hacerse admin a si mismo?
s1 as (
  select
    (select count(*) from pg_trigger
      where tgrelid='public.profiles'::regclass
        and tgname='enforce_admin_immutability')                       as trg,
    has_table_privilege('authenticated','public.profiles','UPDATE')     as upd,
    (select count(*) from pg_policies
      where schemaname='public' and tablename='profiles'
        and cmd in ('UPDATE','ALL') and 'authenticated' = any(roles))   as pol
),

-- C2: los tres numeros de comision
c2 as (
  select
    (select coalesce(column_default,'(sin default)') from information_schema.columns
      where table_schema='public' and table_name='remates'
        and column_name='porcentaje_casa')                              as col_default,
    coalesce((select string_agg(distinct coalesce(porcentaje_casa::text,'NULL'), ', ')
      from public.remates), '(no hay remates)')                         as valores_reales,
    (select count(*) from public.remates
      where coalesce(porcentaje_casa,-1) <> 25)                         as remates_distintos_de_25
),

-- C3/C4: ¿que version del codigo esta desplegada?
fn as (
  select
    max(case when proname='liquidar_remate' then
      (pg_get_functiondef(p.oid) like '%0.75%')::int end)                 as liq_hardcode,
    max(case when proname='liquidar_remate' then
      (pg_get_functiondef(p.oid) like '%porcentaje_casa%')::int end)      as liq_usa_pct,
    max(case when proname='liquidar_remate' then
      (pg_get_functiondef(p.oid) like '%sum(b.monto)::numeric as total_blocked%')::int end) as liq_c3,
    max(case when proname='liquidar_remate' then
      (pg_get_functiondef(p.oid) like '%v_pozo_total%')::int end)         as liq_calcula_pozo,
    max(case when proname='cancelar_remate' then
      (pg_get_functiondef(p.oid) like '%sum(b.monto)%')::int end)         as can_c3,
    max(case when proname='aprobar_recarga' then
      (pg_get_functiondef(p.oid) ilike '%p_deposit_request_id%for update%')::int end) as rec_lock,
    max(case when proname='procesar_retiro' then
      (pg_get_functiondef(p.oid) ilike '%p_withdraw_id%for update%')::int end)        as ret_lock,
    max(case when proname='resumen_casa' then 1 end)                    as existe_resumen_casa
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
),

-- C4: ¿ya hubo doble acreditacion?
dobles as (
  select count(*) as n from (
    select ref_externa from public.wallet_movements
    where tipo='recarga' group by ref_externa having count(*)>1
  ) x
),

-- C3: wallets descuadradas
desc_w as (
  select count(*) as n, coalesce(sum(abs(dif)),0) as bs from (
    select w.saldo_bloqueado - coalesce(e.esp,0) as dif
    from public.wallets w
    left join (
      select user_id, sum(monto) as esp from (
        select distinct on (b.remate_id,b.horse_id) b.user_id, b.monto
        from public.bids b join public.remates r on r.id=b.remate_id
        where r.estado='abierto'
        order by b.remate_id,b.horse_id,b.monto desc,b.created_at asc
      ) l group by user_id
    ) e on e.user_id=w.user_id
    where w.saldo_bloqueado <> coalesce(e.esp,0)
  ) y
),

-- Caja
caja as (
  select
    (select coalesce(sum(monto),0) from public.deposit_requests  where estado='aprobado')  as rec,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pagado')    as ret,
    (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pendiente') as retp,
    (select coalesce(sum(saldo_disponible+saldo_bloqueado),0) from public.wallets)         as saldos
),

-- Integridad de carreras
integ as (
  select
    (select count(*) from (select race_id,numero from public.horses
       group by race_id,numero having count(*)>1) d)                    as horses_dup,
    (select count(*) from pg_constraint
      where conrelid='public.horses'::regclass and contype='u'
        and pg_get_constraintdef(oid) ilike '%numero%')                 as horses_unique,
    (select count(*) from public.remates r where not exists
      (select 1 from public.remate_price_rules pr where pr.remate_id=r.id)) as sin_reglas,
    (select count(*) from public.races ra where not exists
      (select 1 from public.remates r where r.race_id=ra.id))           as carreras_huerfanas,
    (select count(*) from public.remates
      where estado='abierto' and closes_at is not null
        and closes_at < now() - interval '5 minutes')                   as vencidos_abiertos
),

-- RLS
rls as (
  select
    (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='r' and c.relrowsecurity=false) as sin_rls,
    (select count(*) from pg_policies where schemaname='public'
      and tablename='bids' and cmd='SELECT' and qual='true')            as bids_abierta,
    (select count(*) from public.admin_actions)                         as bitacora
),

-- Remates liquidados: cuanto del pozo puso la casa (caballos sin puja)
casa_expuesta as (
  select
    count(*)                                as n_liquidados,
    coalesce(sum(pozo_usuarios),0)          as pozo_usuarios,
    coalesce(sum(pozo_casa),0)              as pozo_casa,
    coalesce(sum(case when gano_usuario
                      then pozo_usuarios - round((pozo_usuarios+pozo_casa)*0.75,2)
                      else pozo_usuarios end),0)                                 as resultado_neto_casa
  from (
    select l.id,
      coalesce(sum(t.max_monto),0)                                       as pozo_usuarios,
      coalesce(sum(case when t.max_monto is null then h.precio_salida else 0 end),0) as pozo_casa,
      bool_or(t.horse_id is not null and t.horse_id = rr.ganador_horse_id) as gano_usuario
    from (select id, race_id from public.remates where estado='liquidado') l
    join public.horses h on h.race_id=l.race_id
    left join (select remate_id,horse_id,max(monto) as max_monto
               from public.bids group by remate_id,horse_id) t
      on t.remate_id=l.id and t.horse_id=h.id
    left join public.race_results rr on rr.race_id=l.race_id
    group by l.id
  ) z
)

select * from (
  select 1 as ord,'S1 SEGURIDAD' as bloque,'Trigger enforce_admin_immutability' as chequeo,
         (select trg::text from s1) as valor,
         case when (select trg from s1)=0 then '>>> AGUJERO ABIERTO: cualquier usuario puede hacerse admin'
              else 'OK: protegido' end as veredicto
  union all select 2,'S1 SEGURIDAD','UPDATE sobre profiles para authenticated',
         (select upd::text from s1),
         case when (select upd from s1) then 'Revisar junto al trigger' else 'OK: revocado' end
  union all select 3,'S1 SEGURIDAD','Politicas UPDATE/ALL sobre profiles',(select pol::text from s1),'informativo'
  union all select 10,'C2 COMISION','Default de la columna porcentaje_casa',(select col_default from c2),
         'Si no es 25, es una trampa latente'
  union all select 11,'C2 COMISION','Valores reales en tus remates',(select valores_reales from c2),
         'Si TODOS son 25, contabilidad y liquidacion coinciden hoy'
  union all select 12,'C2 COMISION','Remates con porcentaje distinto de 25',(select remates_distintos_de_25::text from c2),
         case when (select remates_distintos_de_25 from c2)>0
              then '>>> Esos remates tienen contabilidad y liquidacion DISTINTAS'
              else 'OK: hoy coinciden por coincidencia, no por diseno' end
  union all select 20,'VERSION','liquidar_remate tiene 0.75 hardcodeado',(select liq_hardcode::text from fn),
         '1 = si, ignora porcentaje_casa'
  union all select 21,'VERSION','liquidar_remate lee porcentaje_casa',(select coalesce(liq_usa_pct,0)::text from fn),
         '0 = no lo lee nunca'
  union all select 22,'VERSION','liquidar_remate calcula el pozo',(select coalesce(liq_calcula_pozo,0)::text from fn),
         '0 = version VIEJA desplegada, distinta a la del repo'
  union all select 23,'C3 BLOQUEOS','liquidar_remate usa sum(b.monto) como total_blocked',(select coalesce(liq_c3,0)::text from fn),
         '1 = el defecto C3 esta en produccion'
  union all select 24,'C3 BLOQUEOS','cancelar_remate usa sum(b.monto)',(select coalesce(can_c3,0)::text from fn),'1 = mismo defecto'
  union all select 30,'C4 IDEMPOTENCIA','aprobar_recarga tiene FOR UPDATE en la solicitud',(select coalesce(rec_lock,0)::text from fn),
         case when coalesce((select rec_lock from fn),0)=0 then '>>> NO es idempotente bajo concurrencia' else 'OK' end
  union all select 31,'C4 IDEMPOTENCIA','procesar_retiro tiene FOR UPDATE en la solicitud',(select coalesce(ret_lock,0)::text from fn),
         case when coalesce((select ret_lock from fn),0)=0 then '>>> NO es idempotente bajo concurrencia' else 'OK' end
  union all select 32,'C4 IDEMPOTENCIA','Recargas ya acreditadas 2+ veces',(select n::text from dobles),
         case when (select n from dobles)>0 then '>>> YA OCURRIO' else 'OK: nunca paso' end
  union all select 40,'C3 BLOQUEOS','Wallets descuadradas (bloqueado <> pujas lider)',(select n::text from desc_w),
         case when (select n from desc_w)>0 then '>>> Descuadre de '||(select bs::text from desc_w)||' Bs' else 'OK: todo cuadra' end
  union all select 50,'CAJA','Recargas aprobadas',(select rec::text from caja),'entradas reales'
  union all select 51,'CAJA','Retiros pagados',(select ret::text from caja),'salidas reales'
  union all select 52,'CAJA','Retiros pendientes',(select retp::text from caja),'ya descontados de la wallet, aun no pagados'
  union all select 53,'CAJA','Saldo total de usuarios',(select saldos::text from caja),'pasivo con los usuarios'
  union all select 54,'CAJA','Dinero casa REPORTADO por el panel',(select (rec-ret-saldos)::text from caja),'formula actual'
  union all select 55,'CAJA','Dinero casa CORREGIDO (A1)',(select (rec-ret-saldos-retp)::text from caja),
         'restando retiros pendientes. Si es NEGATIVO, debes mas de lo que tienes'
  union all select 60,'POZO CASA','Remates liquidados',(select n_liquidados::text from casa_expuesta),''
  union all select 61,'POZO CASA','Pozo aportado por usuarios',(select pozo_usuarios::text from casa_expuesta),'dinero real'
  union all select 62,'POZO CASA','Pozo aportado por la casa (caballos sin puja)',(select pozo_casa::text from casa_expuesta),
         'dinero que la casa comprometio sin registrarlo en ningun lado'
  union all select 63,'POZO CASA','Resultado neto de la casa en remates',(select resultado_neto_casa::text from casa_expuesta),
         'Caja real: cobrado a usuarios menos premios pagados. Negativo = la casa puso de su bolsillo'
  union all select 70,'INTEGRIDAD','Caballos con numero duplicado',(select horses_dup::text from integ),
         case when (select horses_dup from integ)>0 then '>>> set_ganador_carrera puede liquidar el caballo equivocado' else 'OK' end
  union all select 71,'INTEGRIDAD','Constraint unique(race_id,numero)',(select horses_unique::text from integ),
         case when (select horses_unique from integ)=0 then 'Falta: nada impide duplicados' else 'OK' end
  union all select 72,'INTEGRIDAD','Remates sin reglas de precio',(select sin_reglas::text from integ),'sintoma de creacion a medias'
  union all select 73,'INTEGRIDAD','Carreras sin remate',(select carreras_huerfanas::text from integ),'huerfanos por creacion no atomica'
  union all select 74,'INTEGRIDAD','Remates vencidos aun abiertos',(select vencidos_abiertos::text from integ),
         case when (select vencidos_abiertos from integ)>0 then '>>> El cron de autocierre no esta corriendo' else 'OK' end
  union all select 80,'RLS','Tablas public sin RLS',(select sin_rls::text from rls),
         case when (select sin_rls from rls)>0 then '>>> Abiertas a cualquiera con la anon key' else 'OK' end
  union all select 81,'RLS','Politica bids SELECT using(true)',(select bids_abierta::text from rls),
         case when (select bids_abierta from rls)>0 then 'Cualquier usuario lee todas las pujas' else 'OK' end
  union all select 82,'AUDITORIA','Registros en admin_actions',(select bitacora::text from rls),
         case when (select bitacora from rls)=0 then 'Bitacora VACIA: sin rastro de operaciones de dinero' else 'OK' end
  union all select 90,'LIMPIEZA','resumen_casa (funcion vieja) existe',(select coalesce(existe_resumen_casa,0)::text from fn),
         '1 = borrar, tiene el signo invertido'
) t
order by ord;
