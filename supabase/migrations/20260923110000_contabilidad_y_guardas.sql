-- ============================================================================
--  Bloque 1 - tareas 1.4, 1.5 y 1.7
--
--  1.4  admin_contabilidad_resumen: restar los retiros PENDIENTES del dinero
--       de la casa. Ya se calculaban, solo no se restaban.
--  1.5  eliminar resumen_casa: funcion muerta, con el signo de los retiros
--       invertido y doble conteo de premios. La app usa admin_contabilidad_resumen.
--  1.7  aprobar_recarga y procesar_retiro: agregar la guarda
--       `and estado = 'pendiente'` al UPDATE final, como segunda red.
--
--  Las tres funciones se reemplazan COMPLETAS, extraidas del baseline (es decir,
--  de produccion) y parcheadas de forma quirurgica. No hay transcripcion a mano.
-- ============================================================================

-- 1.4 -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."admin_contabilidad_resumen"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  -- Tarea 1.4: los retiros PENDIENTES ya se descontaron de la wallet del
  -- usuario al solicitarlos, pero el dinero todavia no salio del banco de la
  -- casa. Sin restarlos, figuran como dinero disponible cuando en realidad
  -- son una deuda ya comprometida.
  v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios - v_retiros_pendientes;

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
$$;

-- ---------------------------------------------------------------------------
-- 1.7 (a) ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden aprobar recargas';
  end if;

  select * into v_request
  from public.deposit_requests
  where id = p_deposit_request_id;

  if not found then
    raise exception 'Solicitud de recarga no existe';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de recarga no esta pendiente (estado actual: %)', v_request.estado;
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = v_request.user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario de la recarga';
  end if;

  v_wallet.saldo_disponible := v_wallet.saldo_disponible + v_request.monto;

  update public.wallets
  set saldo_disponible = v_wallet.saldo_disponible
  where id = v_wallet.id;

  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'recarga'::wallet_movement_type,
    v_request.monto,
    'Recarga aprobada (metodo: ' || v_request.metodo || ', ref: ' || v_request.referencia || ')',
    v_request.id::text
  );

  -- Tarea 1.7: segunda red. El FOR UPDATE de arriba ya serializa, pero si
  -- alguna vez falla, esta guarda impide pisar un estado ya procesado.
  update public.deposit_requests
  set estado = 'aprobado'::deposit_status,
      approved_at = now(),
      approved_by = v_user_id
  where id = v_request.id
    and estado = 'pendiente'::deposit_status;

  if not found then
    raise exception 'La solicitud cambio de estado mientras se procesaba';
  end if;

  perform public.log_admin_action(
    v_user_id,
    'aprobar_recarga',
    'deposit_requests',
    v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'aprobado'),
      'monto', v_request.monto,
      'user_id', v_request.user_id,
      'metodo', v_request.metodo,
      'referencia', v_request.referencia
    ),
    true,
    null
  );

  return 'Recarga aprobada y saldo acreditado';

exception
  when others then
    perform public.log_admin_action(
      v_user_id,
      'aprobar_recarga',
      'deposit_requests',
      coalesce(p_deposit_request_id::text, ''),
      jsonb_build_object(
        'next', jsonb_build_object('estado', 'aprobado')
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1.7 (b) ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.withdraw_requests%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden procesar retiros';
  end if;

  select * into v_request
  from public.withdraw_requests
  where id = p_withdraw_id;

  if not found then
    raise exception 'Solicitud de retiro no existe';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de retiro ya fue procesada (estado actual: %)', v_request.estado;
  end if;

  if p_nuevo_estado = 'pagado' then
    update public.withdraw_requests
    set estado = 'pagado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id
    where id = v_request.id
      and estado = 'pendiente'::withdraw_status;

    if not found then
      raise exception 'La solicitud cambio de estado mientras se procesaba';
    end if;

    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'pagado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true,
      null
    );

    return 'Retiro marcado como pagado';

  elsif p_nuevo_estado = 'rechazado' then
    select * into v_wallet
    from public.wallets
    where user_id = v_request.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el usuario del retiro';
    end if;

    v_wallet.saldo_disponible := v_wallet.saldo_disponible + v_request.monto;

    update public.wallets
    set saldo_disponible = v_wallet.saldo_disponible
    where id = v_wallet.id;

    insert into public.wallet_movements (
      wallet_id, tipo, monto, descripcion, ref_externa
    ) values (
      v_wallet.id,
      'ajuste_manual'::wallet_movement_type,
      v_request.monto,
      'Devolucion de retiro rechazado',
      v_request.id::text
    );

    update public.withdraw_requests
    set estado = 'rechazado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id
    where id = v_request.id
      and estado = 'pendiente'::withdraw_status;

    if not found then
      raise exception 'La solicitud cambio de estado mientras se procesaba';
    end if;

    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'rechazado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true,
      null
    );

    return 'Retiro rechazado y saldo devuelto al usuario';
  else
    raise exception 'Estado no soportado. Use ''pagado'' o ''rechazado''';
  end if;

exception
  when others then
    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      coalesce(p_withdraw_id::text, ''),
      jsonb_build_object(
        'next', jsonb_build_object('estado', p_nuevo_estado)
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1.5 -------------------------------------------------------------------
-- Funcion muerta. La app llama admin_contabilidad_resumen. Esta tenia:
--   * el signo invertido: solicitar_retiro inserta el movimiento 'retiro' con
--     monto NEGATIVO, asi que "- v_total_retiros" SUMABA los retiros al dinero
--     de la casa en vez de restarlos.
--   * doble conteo: restaba los premios, que ya estan dentro de v_saldo_usuarios.
-- Ademas era la unica funcion de dinero sin SECURITY DEFINER ni search_path fijo.
drop function if exists public.resumen_casa();
