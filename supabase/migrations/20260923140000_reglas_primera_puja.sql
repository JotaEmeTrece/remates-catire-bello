-- ============================================================================
--  Tarea 2.17 - Reglas de la primera puja y del minimo manual
--
--  Tres cambios, los tres en el mismo bloque de hacer_puja. Van juntos porque
--  separarlos seria tocar el mismo codigo tres veces.
--
--  (a) PRIMERA PUJA AL PRECIO DE SALIDA EXACTO
--      Antes: caballo virgen -> cobraba precio_salida + incremento.
--      Ahora: caballo virgen -> cobra precio_salida.
--      El caballo que nadie puja se queda con la casa por su precio_salida y
--      entra al pozo por ese monto. O sea que el sistema YA trataba
--      precio_salida como precio de compra real, pero solo para la casa.
--
--  (b) FUERA EL PISO `apuesta_minima`
--      Se aplicaba despues de elegir la regla, encima del resultado, para
--      cualquier caballo. Era el unico parametro que no se podia sobreescribir
--      por caballo. Reproducido: salida 100 + incremento 10 + apuesta_minima
--      500 -> el primer clic cobraba 500.
--
--      LA COLUMNA NO SE BORRA EN ESTA MIGRACION. El frontend todavia la
--      escribe al crear un remate (`apuesta_minima: n(apuestaMinima)`), y es
--      NOT NULL. Borrarla ahora rompe la creacion de carreras hasta que el
--      deploy salga. Queda huerfana, sin efecto, y se borra despues del deploy.
--
--  (c) FUERA EL `+10` DEL MINIMO MANUAL
--      La puja manual acepta desde el minimo automatico.
--
--  CONSECUENCIA QUE CONVIENE TENER PRESENTE: sobre un caballo virgen de
--  precio_salida 100 con incremento 50, una puja manual de 120 ahora se acepta,
--  porque el minimo automatico de un caballo virgen es 100. La primera oferta
--  no es un escalon de la escalera: es la compra al precio de salida, y de ahi
--  para arriba vale cualquier monto. Si esto no es lo que se quiere, se cambia
--  con una linea, pero es lo que se deduce de las reglas decididas.
--
--  EL FRONTEND TIENE QUE SALIR CON ESTA MIGRACION. `app/remates/[id]/page.tsx`
--  recalcula los minimos por su cuenta en TypeScript. Si la base cambia y la
--  pantalla no, muestra un numero y la base cobra otro. Ver tarea 2.20, que es
--  la que mata esa duplicacion de raiz.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.hacer_puja(p_remate_id uuid, p_horse_id uuid, p_monto numeric, p_es_manual boolean DEFAULT false)
 RETURNS bids
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();

  v_remate public.remates%rowtype;
  v_horse  public.horses%rowtype;

  v_wallet public.wallets%rowtype;

  -- top actual (antes de esta puja)
  v_top_user_id uuid;
  v_top_monto   numeric;
  v_top_bid_id  uuid;

  v_ultimo_monto numeric;
  v_incremento numeric;
  v_minimo_permitido numeric;

  v_rule public.remate_price_rules%rowtype;
  v_bid  public.bids%rowtype;

  v_delta numeric;

  v_prev_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  -- (Opcional pero recomendado) Serializa pujas por remate+caballo para evitar carreras
  perform pg_advisory_xact_lock(
    ('x' || substr(md5(p_remate_id::text || ':' || p_horse_id::text), 1, 16))::bit(64)::bigint
  );

  -- 1) Remate
  select *
    into v_remate
  from public.remates
  where id = p_remate_id;

  if not found then raise exception 'Remate no existe'; end if;
  if v_remate.estado <> 'abierto' then raise exception 'El remate no está abierto'; end if;

  if v_remate.opens_at is not null and now() < v_remate.opens_at then
    raise exception 'El remate aún no está abierto';
  end if;
  if v_remate.closes_at is not null and now() >= v_remate.closes_at then
    raise exception 'El remate ya cerró';
  end if;

  -- 2) Caballo
  select *
    into v_horse
  from public.horses
  where id = p_horse_id
    and race_id = v_remate.race_id;

  if not found then
    raise exception 'Caballo no pertenece a la carrera de este remate';
  end if;
  if coalesce(v_horse.retirado, false) then
    raise exception 'Caballo retirado';
  end if;

  -- 3) Top actual (si existe)
  select b.user_id, b.monto, b.id
    into v_top_user_id, v_top_monto, v_top_bid_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id  = p_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  if found then
    v_ultimo_monto := v_top_monto;
  else
    v_top_user_id := null;
    v_top_monto   := null;
    v_top_bid_id  := null;
    v_ultimo_monto := v_horse.precio_salida;
  end if;

  -- 4) Regla de incremento: la del caballo manda; si no tiene, la general del remate.
  --    El WHERE ya deja pasar solo dos clases de fila: horse_id null (general) o
  --    horse_id = p_horse_id (individual). Por eso `horse_id is not null` alcanza
  --    para separarlas, y ademas nunca da NULL, que era justo el problema.
  select *
    into v_rule
  from public.remate_price_rules r
  where r.remate_id = p_remate_id
    and (r.horse_id is null or r.horse_id = p_horse_id)
    and v_ultimo_monto >= r.min_precio
    and (r.max_precio is null or v_ultimo_monto < r.max_precio)
  order by (r.horse_id is not null) desc, r.min_precio desc
  limit 1;

  if found then
    v_incremento := v_rule.incremento;
  else
    v_incremento := v_remate.incremento_minimo;
  end if;

  if v_incremento is null or v_incremento <= 0 then
    raise exception 'Incremento no válido para el remate';
  end if;

  -- 5) Minimo permitido (auto)
  --
  --    Caballo virgen: se compra AL precio de salida, exacto. Es la pizarra de
  --    toda la vida: el caballo sale en X y el primero que lo quiera lo toma en
  --    X. Antes se cobraba salida + incremento, y eso ademas contradecia al
  --    propio sistema, que al liquidar le adjudica a la casa el caballo que
  --    nadie pujo por su precio_salida pelado. La casa compraba a 100 lo que al
  --    usuario le costaba 110.
  --
  --    Caballo con pujas: la siguiente tiene que superar a la de arriba por el
  --    incremento que mande la regla (la del caballo si tiene, si no la general).
  --
  --    Ya NO existe el piso `apuesta_minima` del remate. Era el unico mecanismo
  --    que no se podia sobreescribir por caballo: se aplicaba DESPUES de elegir
  --    la regla, encima del resultado, sin importar de que caballo se tratara.
  --    Un caballo configurado en 100 con incremento 10, en un remate con
  --    apuesta_minima 500, cobraba 500 en el primer clic. El admin configuraba
  --    una cosa y el sistema cobraba otra.
  if v_top_monto is null then
    v_minimo_permitido := v_horse.precio_salida;
  else
    v_minimo_permitido := v_top_monto + v_incremento;
  end if;

  -- 6) Auto vs manual
  if coalesce(p_es_manual, false) = false then
    -- auto: "Ponerle"
    p_monto := v_minimo_permitido;
  else
    -- manual: debe ser al menos auto + 10
    -- La manual acepta DESDE el minimo automatico. Antes exigia +10 clavado en
    -- el codigo, un numero que no significaba nada y que la inflacion dejo sin
    -- sentido hace rato.
    if p_monto is null or p_monto < v_minimo_permitido then
      raise exception 'Oferta manual minima: %', v_minimo_permitido;
    end if;
  end if;

  -- 7) Calcula cuánto bloquear realmente
  -- Si el usuario ya era el top -> solo delta (p_monto - top_monto)
  -- Si NO era el top -> bloquea p_monto completo
  if v_top_user_id = v_user_id then
    v_delta := p_monto - coalesce(v_top_monto, 0);
    if v_delta <= 0 then
      raise exception 'La puja debe superar el monto actual';
    end if;
  else
    v_delta := p_monto;
  end if;

  -- 8) Lock wallet del que está pujando
  select *
    into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontró wallet para el usuario';
  end if;

  if v_wallet.saldo_disponible < v_delta then
    raise exception 'Saldo insuficiente (disponible: %, requerido: %)',
      v_wallet.saldo_disponible, v_delta;
  end if;

  -- 9) Si el top anterior era otro usuario, desbloquea su monto
  if v_top_user_id is not null and v_top_user_id <> v_user_id then
    select *
      into v_prev_wallet
    from public.wallets
    where user_id = v_top_user_id
    for update;

    if found then
      if v_prev_wallet.saldo_bloqueado < coalesce(v_top_monto,0) then
        raise exception 'Inconsistencia: bloqueado anterior insuficiente (bloqueado: %, a liberar: %)',
          v_prev_wallet.saldo_bloqueado, v_top_monto;
      end if;

      update public.wallets
         set saldo_disponible = saldo_disponible + v_top_monto,
             saldo_bloqueado  = saldo_bloqueado  - v_top_monto
       where id = v_prev_wallet.id;

      insert into public.wallet_movements (
        wallet_id, tipo, monto, descripcion, ref_externa
      ) values (
        v_prev_wallet.id,
        'apuesta_desbloqueo',
        v_top_monto,
        'Desbloqueo por ser superado en remate ' || v_remate.nombre || ' caballo ' || v_horse.numero,
        coalesce(v_top_bid_id::text,'')
      );
    end if;
  end if;

  -- 10) Bloquear delta al pujador
  update public.wallets
     set saldo_disponible = saldo_disponible - v_delta,
         saldo_bloqueado  = saldo_bloqueado  + v_delta
   where id = v_wallet.id;

  -- 11) Insertar puja
  insert into public.bids (remate_id, horse_id, user_id, monto)
  values (p_remate_id, p_horse_id, v_user_id, p_monto)
  returning * into v_bid;

  -- 12) Movimiento de bloqueo (solo delta)
  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'apuesta_bloqueo',
    v_delta,
    'Bloqueo por puja en remate ' || v_remate.nombre || ' caballo ' || v_horse.numero,
    v_bid.id::text
  );

  return v_bid;
end;
$function$;
