-- ===========================================================================
--  verificar_produccion.sql
--
--  Una sola consulta, para pegar en el editor SQL de Supabase. Cada fila es
--  un chequeo con su estado esperado. Cubre TODO lo aplicado hasta el
--  20260925100000.
--
--  Lee la columna `esperado`: si `estado` no coincide, esa migracion no esta
--  en produccion o algo la revirtio.
-- ===========================================================================

with chequeos as (

  -- ---------------- bloque 0 y 1 ----------------
  select 1 as n, 'enum apuesta_desbloqueo existe' as chequeo, 'true' as esperado,
    (exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
             where t.typname = 'wallet_movement_type' and e.enumlabel = 'apuesta_desbloqueo'))::text as estado

  union all select 2, 'funcion _cerrar_remate_interno existe', 'true',
    (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = '_cerrar_remate_interno'))::text

  union all select 3, 'admin_actions.admin_id acepta null', 'true',
    coalesce((select (not attnotnull)::text from pg_attribute
              where attrelid = 'public.admin_actions'::regclass and attname = 'admin_id'), 'no existe')

  union all select 4, 'regla por caballo gana sobre la general (1.10)', 'true',
    coalesce((select (pg_get_functiondef(p.oid) like '%horse_id is not null%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '_incremento_aplicable'), 'no existe')

  union all select 5, 'hacer_puja sin el piso apuesta_minima (2.17)', 'true',
    coalesce((select (pg_get_functiondef(p.oid) not like '%apuesta_minima%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'hacer_puja'), 'no existe')

  -- ---------------- bloque 2: saldo v2 ----------------
  union all select 6, 'funcion compromiso_usuario existe', 'true',
    (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'compromiso_usuario'))::text

  union all select 7, 'hacer_puja NO escribe en wallets (tajada B)', 'true',
    coalesce((select (pg_get_functiondef(p.oid) not like '%update public.wallets%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'hacer_puja'), 'no existe')

  union all select 8, 'enum apuesta_cobro existe (tajada C)', 'true',
    (exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
             where t.typname = 'wallet_movement_type' and e.enumlabel = 'apuesta_cobro'))::text

  union all select 9, 'mi_wallet_resumen devuelve 4 columnas (tajada E)', '4',
    coalesce((select count(*)::text from information_schema.routines r
              join information_schema.parameters pa on pa.specific_name = r.specific_name
              where r.routine_schema = 'public' and r.routine_name = 'mi_wallet_resumen'
                and pa.parameter_mode = 'OUT'), '0')

  union all select 10, 'funcion remate_minimos existe (tajada F)', 'true',
    (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'remate_minimos'))::text

  -- ---------------- 2.18: libro de la casa ----------------
  union all select 11, 'tabla house_ledger existe', 'true',
    (to_regclass('public.house_ledger') is not null)::text

  union all select 12, 'house_ledger con RLS activa', 'true',
    coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.house_ledger')), 'no existe')

  union all select 13, 'liquidar_remate escribe el asiento automatico', 'true',
    coalesce((select (pg_get_functiondef(p.oid) like '%resultado_remate%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'liquidar_remate'), 'no existe')

  union all select 14, 'registrar_movimiento_casa RECHAZA resultado_remate', 'true',
    coalesce((select (pg_get_functiondef(p.oid) like '%not in (''aporte_capital'',''retiro_utilidad'',''ajuste'')%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'registrar_movimiento_casa'), 'no existe')

  -- ---------------- 2.22 y permisos ----------------
  union all select 15, 'casa_resumen exige admin', 'true',
    coalesce((select (pg_get_functiondef(p.oid) like '%No autorizado%')::text
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'casa_resumen'), 'no existe')

  union all select 16, 'auto_cerrar_remates CERRADA a anon', 'false',
    has_function_privilege('anon', 'public.auto_cerrar_remates()', 'execute')::text

  union all select 17, 'auto_cerrar_remates CERRADA a authenticated', 'false',
    has_function_privilege('authenticated', 'public.auto_cerrar_remates()', 'execute')::text

  union all select 18, 'log_admin_action CERRADA a anon', 'false',
    has_function_privilege('anon',
      'public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)', 'execute')::text

  union all select 19, 'compromiso_usuario CERRADA a authenticated', 'false',
    has_function_privilege('authenticated', 'public.compromiso_usuario(uuid)', 'execute')::text

  union all select 20, 'resumen_casa (muerta) ya borrada', 'true',
    (not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'resumen_casa'))::text

  union all select 21, 'remate_minimos SIGUE publica (a proposito)', 'true',
    has_function_privilege('anon', 'public.remate_minimos(uuid)', 'execute')::text

  -- ---------------- 3.1: claves foraneas ----------------
  union all select 22, 'FK bids->horses en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint where conname = 'bids_horse_id_fkey'), 'no existe')

  union all select 23, 'FK bids->remates en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint where conname = 'bids_remate_id_fkey'), 'no existe')

  union all select 24, 'FK horses->races en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint where conname = 'horses_race_id_fkey'), 'no existe')

  union all select 25, 'FK remates->races en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint where conname = 'remates_race_id_fkey'), 'no existe')

  union all select 26, 'FK race_results->horses en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'race_results_ganador_horse_id_fkey'), 'no existe')

  -- 3.1 segunda mitad: la cadena del borrado de usuario
  union all select 27, 'FK wallet_movements->wallets en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'wallet_movements_wallet_id_fkey'), 'no existe')

  union all select 28, 'FK bids->profiles en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'bids_user_id_fkey'), 'no existe')

  union all select 29, 'FK deposit_requests->profiles en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'deposit_requests_user_id_fkey'), 'no existe')

  union all select 27+3, 'FK withdraw_requests->profiles en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'withdraw_requests_user_id_fkey'), 'no existe')

  union all select 27+4, 'FK race_results->races en RESTRICT', 'true',
    coalesce((select (confdeltype = 'r')::text from pg_constraint
              where conname = 'race_results_race_id_fkey'), 'no existe')

  union all select 27+5, 'FK wallets->profiles SIGUE en CASCADE (a proposito)', 'true',
    coalesce((select (confdeltype = 'c')::text from pg_constraint
              where conname = 'wallets_user_id_fkey'), 'no existe')

  -- ---------------- estado de los datos ----------------
  union all select 30, 'DATO: usuarios registrados', '(informativo)',
    (select count(*)::text from public.profiles)

  union all select 31, 'DATO: saldo total de usuarios', '(informativo)',
    (select coalesce(sum(saldo_disponible + saldo_bloqueado), 0)::text from public.wallets)

  union all select 32, 'DATO: remates abiertos', '(informativo)',
    (select count(*)::text from public.remates where estado = 'abierto')

  union all select 33, 'DATO: asientos en el libro de la casa', '(informativo)',
    (select count(*)::text from public.house_ledger)
)
select
  n as "#",
  chequeo,
  esperado,
  estado,
  case
    when esperado = '(informativo)' then '--'
    when estado = esperado then 'OK'
    else 'REVISAR'
  end as veredicto
from chequeos
order by n;
