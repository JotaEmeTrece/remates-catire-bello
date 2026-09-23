select
  'enum apuesta_desbloqueo' as chequeo,
  (exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
           where t.typname = 'wallet_movement_type' and e.enumlabel = 'apuesta_desbloqueo'))::text as estado
union all select
  'FK bids->horses en RESTRICT',
  coalesce((select (confdeltype = 'r')::text from pg_constraint
            where conname = 'bids_horse_id_fkey'), 'no existe la FK')
union all select
  'funcion _cerrar_remate_interno',
  (exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = '_cerrar_remate_interno'))::text
union all select
  'admin_actions.admin_id acepta null',
  coalesce((select (not attnotnull)::text from pg_attribute
            where attrelid = 'public.admin_actions'::regclass and attname = 'admin_id'), '?')
union all select
  'hacer_puja con precedencia corregida',
  coalesce((select (pg_get_functiondef(p.oid) like '%horse_id is not null%')::text
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'hacer_puja'), '?')
union all select
  'hacer_puja sin el piso apuesta_minima',
  coalesce((select (pg_get_functiondef(p.oid) not like '%v_remate.apuesta_minima%')::text
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'hacer_puja'), '?')
union all select
  'resumen_casa ya borrada',
  (not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'resumen_casa'))::text
order by 1;
