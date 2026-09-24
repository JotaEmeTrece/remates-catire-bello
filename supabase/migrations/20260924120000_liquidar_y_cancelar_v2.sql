-- ============================================================================
--  Bloque 2, tajada D - Liquidar solo paga el premio; cancelar se vuelve simple
--
--  Referencia: DISENO_SALDO_V2.md §6.3 y §6.4.
--
--  Cierra de una vez los tres defectos viejos del bloque 1 que quedaron
--  esperando a esta funcion:
--
--    1.1  el caballo retirado sumaba al pozo
--    1.2  el premio usaba un 0.75 clavado en vez de remates.porcentaje_casa
--    1.3  no habia guarda de solvencia: la casa acreditaba premios que no podia
--         pagar
--
--  Y elimina el bucle de cobro, que desde la tajada C ya no tiene nada que
--  hacer: al liquidar, el dinero YA esta cobrado.
--
--  Sobre el 0.75: el numero no estaba mal. 0.75 es exactamente 1 - 0.25, y 25%
--  es la comision por defecto. El defecto es que estaba CLAVADO: la tabla
--  remates tiene una columna porcentaje_casa que el admin llena en el
--  formulario, y la liquidacion la ignoraba. Un remate configurado al 30%
--  pagaba igual el 75%. La configuracion mentia. Para licenciar, donde cada
--  cliente pone su propio porcentaje, la columna tiene que mandar.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- liquidar_remate: calcula el pozo, comprueba que la casa pueda pagar, y paga.
-- Nada mas. El cobro ocurrio al cerrar.
-- ---------------------------------------------------------------------------
create or replace function public.liquidar_remate(p_remate_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_ganador_horse_id uuid;
  v_ganador_retirado boolean;
  v_ganador_user_id uuid;
  v_pozo_total numeric := 0;
  v_premio numeric := 0;
  v_caja numeric;
  v_wallet public.wallets%rowtype;
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

  select rr.ganador_horse_id, coalesce(h.retirado, false)
    into v_ganador_horse_id, v_ganador_retirado
  from public.race_results rr
  left join public.horses h on h.id = rr.ganador_horse_id
  where rr.race_id = v_remate.race_id;

  if v_ganador_horse_id is null then
    raise exception 'Debes indicar el caballo ganador antes de liquidar';
  end if;

  -- Un caballo retirado no corre, asi que no puede ganar. Sin esta guarda, a su
  -- lider se le pagaria el premio sin haberle cobrado nada al cerrar (los
  -- retirados quedan fuera del cobro y fuera del pozo): dinero de la nada.
  if v_ganador_retirado then
    raise exception 'El caballo marcado como ganador esta retirado. Corrige el resultado de la carrera antes de liquidar.';
  end if;

  -- POZO. Cada caballo aporta su puja mas alta, y si nadie lo pujo aporta su
  -- precio_salida, porque queda con la casa por ese monto.
  -- TAREA 1.1: los retirados quedan fuera de los dos terminos.
  select coalesce(sum(coalesce(t.max_monto, h.precio_salida)), 0)
    into v_pozo_total
  from public.horses h
  left join (
    select horse_id, max(monto)::numeric as max_monto
    from public.bids
    where remate_id = p_remate_id
    group by horse_id
  ) t on t.horse_id = h.id
  where h.race_id = v_remate.race_id
    and coalesce(h.retirado, false) = false;

  select b.user_id
    into v_ganador_user_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id = v_ganador_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  -- PREMIO. TAREA 1.2: sale de porcentaje_casa, no de un 0.75 clavado.
  if v_ganador_user_id is null then
    -- Gano un caballo de la casa: no hay premio que pagar, la casa se queda el
    -- pozo completo.
    v_premio := 0;
  else
    v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa, 25) / 100.0), 2);
  end if;

  -- GUARDA DE SOLVENCIA. TAREA 1.3.
  -- La casa banca los caballos que nadie pujo, y esos entran al pozo sin que
  -- nadie haya puesto ese dinero. Un remate de 10 caballos donde solo se puja
  -- uno genera un premio muy superior a lo que entro por caja. Acreditar eso
  -- es prometer un saldo que no se puede pagar cuando el usuario lo retire.
  if v_premio > 0 then
    v_caja := public.dinero_casa_disponible();
    if v_premio > v_caja then
      raise exception 'La casa no puede pagar este premio: son % Bs y la caja disponible es % Bs. Revisa la contabilidad antes de liquidar.',
        v_premio, v_caja;
    end if;
  end if;

  if v_ganador_user_id is not null and v_premio > 0 then
    select * into v_wallet
    from public.wallets
    where user_id = v_ganador_user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el ganador';
    end if;

    update public.wallets
       set saldo_disponible = saldo_disponible + v_premio
     where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'premio', v_premio,
            'Premio del remate ' || v_remate.nombre,
            p_remate_id::text);
  end if;

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado. Pozo ' || v_pozo_total::text || ' Bs, premio ' || v_premio::text || ' Bs.';
end;
$fn$;

-- ---------------------------------------------------------------------------
-- cancelar_remate: dos casos, los dos simples.
--
-- Abierto  -> no se cobro nada todavia. No hay nada que devolver.
-- Cerrado  -> se devuelve exactamente lo que se cobro al cerrar, leyendolo de
--             los movimientos 'apuesta_cobro' de este remate.
--
-- El caso "cerrado" es ademas la RUTA DE SALIDA de la tarea 2.13: hasta hoy,
-- un remate que se cerraba y no se podia liquidar (carrera suspendida, el
-- admin no alcanza a cargar el ganador) dejaba el dinero cobrado sin forma de
-- devolverlo salvo metiendo mano en la base.
-- ---------------------------------------------------------------------------
create or replace function public.cancelar_remate(p_remate_id uuid, p_motivo text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_remate public.remates%rowtype;
  v_wallet public.wallets%rowtype;
  v_total numeric := 0;
  v_users int := 0;
  r record;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false))
    into v_is_admin
  from public.profiles
  where id = v_admin_id;

  if coalesce(v_is_admin,false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  if p_motivo is null or length(trim(p_motivo)) = 0 then
    raise exception 'Motivo obligatorio';
  end if;

  select * into v_remate
  from public.remates
  where id = p_remate_id
  for update;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado not in ('abierto', 'cerrado') then
    raise exception 'Solo puedes cancelar un remate abierto o cerrado (estado actual: %)', v_remate.estado;
  end if;

  if v_remate.estado = 'cerrado' then
    -- Se devuelve lo cobrado, por usuario, ordenado para no cruzar candados.
    for r in
      select w.user_id, sum(-m.monto) as total
      from public.wallet_movements m
      join public.wallets w on w.id = m.wallet_id
      where m.ref_externa = p_remate_id::text
        and m.tipo = 'apuesta_cobro'
      group by w.user_id
      having sum(-m.monto) > 0
      order by w.user_id
    loop
      perform pg_advisory_xact_lock(1, hashtext(r.user_id::text));

      select * into v_wallet
      from public.wallets
      where user_id = r.user_id
      for update;

      if not found then
        raise exception 'No se encontro wallet para el usuario %', r.user_id;
      end if;

      update public.wallets
         set saldo_disponible = saldo_disponible + r.total
       where id = v_wallet.id;

      insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
      values (v_wallet.id, 'apuesta_devolucion', r.total,
              'Devolucion por cancelacion del remate ' || v_remate.nombre,
              p_remate_id::text);

      v_total := v_total + r.total;
      v_users := v_users + 1;
    end loop;
  end if;

  update public.remates
  set estado = 'cancelado',
      cancelled_at = now(),
      cancelled_by = v_admin_id,
      cancelled_reason = p_motivo
  where id = p_remate_id;

  perform public.log_admin_action(
    v_admin_id, 'cancelar_remate', 'remates', p_remate_id::text,
    jsonb_build_object('motivo', p_motivo, 'estado_previo', v_remate.estado,
                       'devuelto', v_total, 'usuarios', v_users),
    true, null);

  return case when v_users = 0
    then 'Remate cancelado. No habia nada que devolver.'
    else 'Remate cancelado. Devueltos ' || v_total::text || ' Bs a ' || v_users::text || ' usuario(s).'
  end;
end;
$fn$;
