-- ============================================================================
--  Bloque 2, tajada E - Retiros con compromiso, resumen de wallet, y
--                       retirar_caballo
--
--  Referencia: DISENO_SALDO_V2.md §6.5, §6.6 y §7.
--
--  Cierra el hueco que abrieron B, C y D: hasta ahora solicitar_retiro solo
--  comprobaba `saldo_disponible >= monto`. En el modelo anterior eso bastaba,
--  porque pujar descontaba del saldo. En el v2 el dinero se queda en
--  saldo_disponible hasta que cierra el remate, asi que un usuario con 1000 Bs
--  comprometidos en 800 podia retirar los 1000 y dejar el cierre sin fondos.
--  Reproducido en la prueba P24.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- solicitar_retiro: retirable = saldo - compromiso
-- ---------------------------------------------------------------------------
create or replace function public.solicitar_retiro(
  p_monto numeric, p_metodo text, p_telefono_destino text, p_comentario text default null)
returns withdraw_requests
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_wallet public.wallets%rowtype;
  v_request public.withdraw_requests%rowtype;
  v_compromiso numeric;
  v_retirable numeric;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a 0';
  end if;

  if p_metodo is null or length(trim(p_metodo)) = 0 then
    raise exception 'Debe especificar el metodo de retiro';
  end if;

  if p_telefono_destino is null or length(trim(p_telefono_destino)) = 0 then
    raise exception 'Debe especificar el telefono destino';
  end if;

  -- MISMO candado que hacer_puja y que el cierre. Sin el, un usuario puja y
  -- pide el retiro al mismo tiempo desde dos pestanas: las dos operaciones leen
  -- el mismo compromiso viejo y las dos pasan. Es el defecto de §6.1 entrando
  -- por la otra puerta.
  perform pg_advisory_xact_lock(1, hashtext(v_user_id::text));

  select * into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario';
  end if;

  v_compromiso := public.compromiso_usuario(v_user_id);
  v_retirable  := v_wallet.saldo_disponible - v_compromiso;

  if p_monto > v_retirable then
    raise exception 'Solo puedes retirar % Bs. Tienes % Bs en total, y % Bs comprometidos en pujas que lideras ahora mismo.',
      greatest(v_retirable, 0), v_wallet.saldo_disponible, v_compromiso;
  end if;

  update public.wallets
     set saldo_disponible = saldo_disponible - p_monto
   where id = v_wallet.id;

  insert into public.withdraw_requests (
    user_id, monto, metodo, telefono_destino, comentario, estado
  ) values (
    v_user_id, p_monto, p_metodo, p_telefono_destino, p_comentario, 'pendiente'::withdraw_status
  )
  returning * into v_request;

  insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
  values (v_wallet.id, 'retiro', -p_monto,
          'Solicitud de retiro (metodo: ' || p_metodo || ')',
          v_request.id::text);

  return v_request;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- mi_wallet_resumen: los tres numeros que el usuario tiene que ver.
--
-- Se conservan saldo_disponible y saldo_bloqueado con sus nombres de siempre
-- para no romper el frontend actual, que todavia los lee. saldo_bloqueado vale
-- 0 permanentemente desde la tajada B; se borra cuando se borre la columna.
-- El frontend pasa a usar los dos nuevos en la tajada F.
-- ---------------------------------------------------------------------------
drop function if exists public.mi_wallet_resumen();

create or replace function public.mi_wallet_resumen()
returns table(
  saldo_disponible numeric,
  saldo_bloqueado numeric,
  comprometido numeric,
  disponible_para_retirar numeric
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select
    w.saldo_disponible,
    w.saldo_bloqueado,
    public.compromiso_usuario(w.user_id) as comprometido,
    greatest(w.saldo_disponible - public.compromiso_usuario(w.user_id), 0) as disponible_para_retirar
  from public.wallets w
  where w.user_id = auth.uid()
  limit 1;
$fn$;

grant execute on function public.mi_wallet_resumen() to authenticated;

-- ---------------------------------------------------------------------------
-- retirar_caballo: RPC nueva.
--
-- Es el mejor argumento a favor de todo el rediseno. En el modelo anterior
-- habria que localizar el bloqueo del lider y revertirlo con cuidado. Aqui el
-- caso frecuente -retirar durante un remate abierto- NO TOCA EL DINERO: la
-- puja de ese caballo deja de contar para el compromiso de su lider sola,
-- porque compromiso_usuario() excluye los retirados, y el caballo sale del pozo
-- porque liquidar_remate tambien los excluye.
--
-- Solo hay que mover dinero si el remate ya cerro, porque ahi ya se cobro.
-- ---------------------------------------------------------------------------
create or replace function public.retirar_caballo(p_horse_id uuid, p_motivo text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_horse public.horses%rowtype;
  v_wallet public.wallets%rowtype;
  v_devuelto numeric := 0;
  r record;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false))
    into v_is_admin
  from public.profiles where id = v_admin_id;

  if coalesce(v_is_admin,false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  if p_motivo is null or length(trim(p_motivo)) = 0 then
    raise exception 'Motivo obligatorio';
  end if;

  select * into v_horse from public.horses where id = p_horse_id for update;
  if not found then
    raise exception 'El caballo no existe';
  end if;

  if coalesce(v_horse.retirado, false) then
    raise exception 'Ese caballo ya estaba retirado';
  end if;

  -- Si algun remate de esta carrera ya se liquido, es tarde: el premio se pago
  -- sobre un pozo que incluia a este caballo.
  if exists (select 1 from public.remates
             where race_id = v_horse.race_id and estado = 'liquidado') then
    raise exception 'No se puede retirar un caballo de una carrera con remates ya liquidados';
  end if;

  update public.horses set retirado = true where id = p_horse_id;

  -- Devolucion SOLO en los remates ya cerrados: ahi el cobro ya ocurrio.
  -- Lo cobrado por este caballo fue la puja mas alta sobre el, que es lo mismo
  -- que se le devuelve a quien la hizo.
  for r in
    select b.user_id, b.monto, rm.nombre as remate_nombre, rm.id as remate_id
    from public.remates rm
    join lateral (
      select b2.user_id, b2.monto
      from public.bids b2
      where b2.remate_id = rm.id and b2.horse_id = p_horse_id
      order by b2.monto desc, b2.created_at asc
      limit 1
    ) b on true
    where rm.race_id = v_horse.race_id
      and rm.estado = 'cerrado'
    order by b.user_id
  loop
    perform pg_advisory_xact_lock(1, hashtext(r.user_id::text));

    select * into v_wallet from public.wallets where user_id = r.user_id for update;
    if not found then
      raise exception 'No se encontro wallet para el usuario %', r.user_id;
    end if;

    update public.wallets
       set saldo_disponible = saldo_disponible + r.monto
     where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'apuesta_devolucion', r.monto,
            'Devolucion por retiro del caballo ' || v_horse.numero::text ||
            ' en el remate ' || r.remate_nombre,
            r.remate_id::text);

    v_devuelto := v_devuelto + r.monto;
  end loop;

  perform public.log_admin_action(
    v_admin_id, 'retirar_caballo', 'horses', p_horse_id::text,
    jsonb_build_object('motivo', p_motivo, 'numero', v_horse.numero,
                       'race_id', v_horse.race_id, 'devuelto', v_devuelto),
    true, null);

  return case when v_devuelto = 0
    then 'Caballo retirado. No habia nada que devolver.'
    else 'Caballo retirado. Devueltos ' || v_devuelto::text || ' Bs.'
  end;
end;
$fn$;

revoke all on function public.retirar_caballo(uuid, text) from public, anon;
grant execute on function public.retirar_caballo(uuid, text) to authenticated;
