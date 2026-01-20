-- Resumen financiero para el panel admin (contabilidad)
-- Devuelve totales: remates (pozo/premio/casa), recargas, retiros, saldo usuarios y dinero neto casa.

create or replace function public.admin_contabilidad_resumen()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;

  v_recargas_aprobadas numeric(14,2);
  v_retiros_pagados numeric(14,2);
  v_recargas_pendientes numeric(14,2);
  v_retiros_pendientes numeric(14,2);

  v_remates_liquidados integer;
  v_remates_pozo numeric(14,2);
  v_remates_premio numeric(14,2);
  v_remates_casa numeric(14,2);

  v_saldo_usuarios numeric(14,2);
  v_dinero_casa numeric(14,2);
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin, es_super_admin
    into v_is_admin, v_is_super
  from public.profiles
  where id = v_user_id;

  if coalesce(v_is_admin, false) = false and coalesce(v_is_super, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  -- Recargas / retiros (caja real)
  select coalesce(sum(monto),0)
    into v_recargas_aprobadas
  from public.deposit_requests
  where estado = 'aprobado'::deposit_status;

  select coalesce(sum(monto),0)
    into v_recargas_pendientes
  from public.deposit_requests
  where estado = 'pendiente'::deposit_status;

  select coalesce(sum(monto),0)
    into v_retiros_pagados
  from public.withdraw_requests
  where estado = 'pagado'::withdraw_status;

  select coalesce(sum(monto),0)
    into v_retiros_pendientes
  from public.withdraw_requests
  where estado = 'pendiente'::withdraw_status;

  -- Remates: pozo/premio/casa (segun regla de negocio)
  with liquidated as (
    select r.id, r.race_id, coalesce(r.porcentaje_casa,25)::numeric as pct_casa
    from public.remates r
    where r.estado = 'liquidado'::remate_status
  ),
  pozo as (
    select
      l.id as remate_id,
      sum(coalesce(b.max_monto, h.precio_salida))::numeric as pozo_total
    from liquidated l
    join public.horses h on h.race_id = l.race_id
    left join (
      select remate_id, horse_id, max(monto)::numeric as max_monto
      from public.bids
      group by remate_id, horse_id
    ) b on b.remate_id = l.id and b.horse_id = h.id
    group by l.id
  ),
  ganador as (
    select
      l.id as remate_id,
      rr.ganador_horse_id,
      (
        select b.user_id
        from public.bids b
        where b.remate_id = l.id and b.horse_id = rr.ganador_horse_id
        order by b.monto desc, b.created_at asc
        limit 1
      ) as ganador_user_id
    from liquidated l
    left join public.race_results rr on rr.race_id = l.race_id
  ),
  calc as (
    select
      l.id,
      p.pozo_total,
      case
        when g.ganador_user_id is null then 0
        else round(p.pozo_total * (1 - (l.pct_casa / 100.0)), 2)
      end as premio_total,
      case
        when g.ganador_user_id is null then p.pozo_total
        else round(p.pozo_total * (l.pct_casa / 100.0), 2)
      end as casa_total
    from liquidated l
    join pozo p on p.remate_id = l.id
    left join ganador g on g.remate_id = l.id
  )
  select
    coalesce(count(*)::int, 0),
    coalesce(sum(pozo_total),0),
    coalesce(sum(premio_total),0),
    coalesce(sum(casa_total),0)
  into
    v_remates_liquidados,
    v_remates_pozo,
    v_remates_premio,
    v_remates_casa
  from calc;

  -- Saldos usuarios y dinero neto casa (balance simple)
  select coalesce(sum(saldo_disponible + saldo_bloqueado), 0)
    into v_saldo_usuarios
  from public.wallets;

  v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios;

  return jsonb_build_object(
    'recargas_aprobadas', v_recargas_aprobadas,
    'recargas_pendientes', v_recargas_pendientes,
    'retiros_pagados', v_retiros_pagados,
    'retiros_pendientes', v_retiros_pendientes,
    'remates_liquidados', v_remates_liquidados,
    'remates_pozo_total', v_remates_pozo,
    'remates_premio_total', v_remates_premio,
    'remates_casa_total', v_remates_casa,
    'saldo_usuarios', v_saldo_usuarios,
    'dinero_casa', v_dinero_casa
  );
end;
$function$;

revoke all on function public.admin_contabilidad_resumen() from public;
grant execute on function public.admin_contabilidad_resumen() to authenticated;

