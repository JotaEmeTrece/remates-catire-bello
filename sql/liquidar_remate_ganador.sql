begin;

create or replace function public.set_ganador_carrera(p_remate_id uuid, p_horse_num integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_race_id uuid;
  v_horse_id uuid;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin, es_super_admin
  into v_is_admin, v_is_super
  from public.profiles
  where id = v_admin_id;

  if coalesce(v_is_admin, false) = false and coalesce(v_is_super, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  select * into v_remate
  from public.remates
  where id = p_remate_id;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado <> 'cerrado' then
    raise exception 'Para liquidar, el remate debe estar "cerrado" (estado actual: %)', v_remate.estado;
  end if;

  v_race_id := v_remate.race_id;

  select id into v_horse_id
  from public.horses
  where race_id = v_race_id
    and numero = p_horse_num;

  if not found then
    raise exception 'No existe un caballo con ese numero en esta carrera';
  end if;

  update public.race_results
  set ganador_horse_id = v_horse_id,
      created_at = now()
  where race_id = v_race_id;

  if not found then
    insert into public.race_results (race_id, ganador_horse_id)
    values (v_race_id, v_horse_id);
  end if;

  return v_horse_id;
end;
$function$;

revoke all on function public.set_ganador_carrera(uuid, integer) from public;
grant execute on function public.set_ganador_carrera(uuid, integer) to authenticated;

create or replace function public.liquidar_remate(p_remate_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_ganador_horse_id uuid;
  v_ganador_user_id uuid;
  v_pozo_total numeric := 0;
  v_premio numeric := 0;
  r record;
  v_wallet public.wallets%rowtype;
  v_total_blocked numeric;
  v_total_win numeric;
  v_release numeric;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin, es_super_admin
  into v_is_admin, v_is_super
  from public.profiles
  where id = v_admin_id;

  if coalesce(v_is_admin, false) = false and coalesce(v_is_super, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  select * into v_remate
  from public.remates
  where id = p_remate_id
  for update;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado <> 'cerrado' then
    raise exception 'Para liquidar, el remate debe estar "cerrado" (estado actual: %)', v_remate.estado;
  end if;

  select ganador_horse_id
  into v_ganador_horse_id
  from public.race_results
  where race_id = v_remate.race_id;

  if v_ganador_horse_id is null then
    raise exception 'Debes indicar el caballo ganador antes de liquidar';
  end if;

  select coalesce(sum(coalesce(b.max_monto, h.precio_salida)), 0)
  into v_pozo_total
  from public.horses h
  left join (
    select horse_id, max(monto)::numeric as max_monto
    from public.bids
    where remate_id = p_remate_id
    group by horse_id
  ) b on b.horse_id = h.id
  where h.race_id = v_remate.race_id;

  select b.user_id
  into v_ganador_user_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id = v_ganador_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  if v_ganador_user_id is null then
    v_premio := 0;
  else
    v_premio := round(v_pozo_total * 0.75, 2);
  end if;

  for r in
    with winners as (
      select distinct on (b.horse_id)
        b.id as bid_id,
        b.user_id,
        b.horse_id,
        b.monto
      from public.bids b
      where b.remate_id = p_remate_id
      order by b.horse_id, b.monto desc, b.created_at asc
    ),
    agg as (
      select
        b.user_id,
        sum(b.monto)::numeric as total_blocked,
        coalesce(sum(w.monto),0)::numeric as total_win
      from public.bids b
      left join winners w
        on w.bid_id = b.id
      where b.remate_id = p_remate_id
      group by b.user_id
    )
    select * from agg
  loop
    v_total_blocked := coalesce(r.total_blocked,0);
    v_total_win     := coalesce(r.total_win,0);
    v_release       := v_total_blocked - v_total_win;

    select * into v_wallet
    from public.wallets
    where user_id = r.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para user_id %', r.user_id;
    end if;

    if v_wallet.saldo_bloqueado < v_total_blocked then
      raise exception 'Inconsistencia: wallet bloqueado (%) < total bloqueado remate (%) para user_id %',
        v_wallet.saldo_bloqueado, v_total_blocked, r.user_id;
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_release,
        saldo_bloqueado  = saldo_bloqueado  - v_total_blocked
    where id = v_wallet.id;

    if v_release > 0 then
      insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
      values (
        v_wallet.id,
        'ajuste_manual'::wallet_movement_type,
        v_release,
        'Liberacion de apuestas perdedoras (liquidacion remate ' || v_remate.nombre || ')',
        p_remate_id::text
      );
    end if;

    if v_total_win > 0 then
      insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
      values (
        v_wallet.id,
        'ajuste_manual'::wallet_movement_type,
        -v_total_win,
        'Pago por remate ganado (liquidacion remate ' || v_remate.nombre || ')',
        p_remate_id::text
      );
    end if;
  end loop;

  if v_ganador_user_id is not null and v_premio > 0 then
    select * into v_wallet
    from public.wallets
    where user_id = v_ganador_user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para ganador';
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_premio
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (
      v_wallet.id,
      'premio'::wallet_movement_type,
      v_premio,
      'Premio por remate (liquidacion remate ' || v_remate.nombre || ')',
      p_remate_id::text
    );
  end if;

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado';
end;
$function$;

commit;
