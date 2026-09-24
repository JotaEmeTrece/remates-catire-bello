-- ============================================================================
--  Bloque 2, tajada B - hacer_puja deja de mover dinero
--
--  Referencia: DISENO_SALDO_V2.md §6.1 y §7bis.
--
--  QUE CAMBIA
--  Se eliminan las secciones 7 a 12 de la funcion: el calculo del delta, el
--  `for update` sobre la wallet, el desbloqueo del lider anterior, el bloqueo
--  al nuevo lider y los dos movimientos de wallet. Pujar deja de escribir una
--  sola fila en `wallets` o en `wallet_movements`.
--
--  En su lugar entra una guarda que valida contra `compromiso_usuario()`, que
--  se calcula en vez de guardarse. El invariante es uno solo:
--
--      saldo_disponible >= compromiso_usuario(),  para todo usuario, siempre.
--
--  QUE SE GANA
--  - Cero escrituras sobre `wallets` durante el remate, que es la tabla mas
--    caliente del sistema en pleno remate en vivo.
--  - Desaparece la clase entera de defecto del descuadre: si no hay numero
--    guardado, no hay numero que se pueda descuadrar.
--  - Que te superen, que retiren un caballo o que se cancele un remate dejan
--    de ser ramas de codigo con dinero de por medio: pasan a ser consecuencias
--    de la definicion de compromiso.
--
--  ⚠️ ESTA MIGRACION NO SE PUEDE APLICAR SOLA A PRODUCCION.
--  Al dejar de bloquear saldo, `saldo_bloqueado` se queda en 0. Pero
--  `liquidar_remate` todavia cobra desde ahi y valida
--  `if saldo_bloqueado < a_cobrar then raise 'Inconsistencia'`. Con solo esta
--  migracion aplicada, TODA liquidacion falla. Las tajadas B, C y D son una
--  sola unidad desplegable aunque sean tres migraciones.
--
--  LO QUE NO SE TOCA: validacion de autenticacion, ventana de apertura y
--  cierre, caballo retirado, reglas de incremento, precio de la primera puja y
--  minimo manual. Todo eso quedo como lo dejo el bloque 1.
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

  v_saldo      numeric;
  v_compromiso numeric;

  -- top actual (antes de esta puja)
  v_top_user_id uuid;
  v_top_monto   numeric;
  v_top_bid_id  uuid;

  v_ultimo_monto numeric;
  v_incremento numeric;
  v_minimo_permitido numeric;

  v_rule public.remate_price_rules%rowtype;
  v_bid  public.bids%rowtype;

begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  -- CANDADOS. El orden importa y no se puede alterar.
  --
  -- El candado por USUARIO es el punto critico de todo el modelo v2. La guarda
  -- de mas abajo cruza TODOS los remates abiertos de UN usuario, asi que no
  -- alcanza con serializar por caballo. Sin el candado por usuario, alguien con
  -- 500 Bs abre dos pestanas, puja 400 a dos caballos distintos al mismo
  -- tiempo, las dos validaciones leen el mismo compromiso viejo, y las dos
  -- pasan: 800 comprometidos contra un saldo de 500.
  --
  -- El modelo ANTERIOR no tenia este problema por accidente: el `for update`
  -- sobre la wallet serializaba las pujas del mismo usuario. Al quitar ese
  -- bloqueo, hay que reponer la serializacion a proposito. Sin este candado,
  -- el modelo v2 es PEOR que el que reemplaza.
  --
  -- Espacio 1 = usuarios, espacio 2 = remate+caballo. SIEMPRE usuario primero,
  -- para que dos transacciones no se tomen los candados en orden cruzado y se
  -- traben entre si.
  perform pg_advisory_xact_lock(1, hashtext(v_user_id::text));
  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text || ':' || p_horse_id::text));

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

  -- 7) GUARDA DE EXPOSICION
  --
  -- El invariante de todo el modelo: saldo_disponible >= compromiso, siempre.
  --
  -- El compromiso ya NO es un numero guardado que haya que mantener: se calcula
  -- a partir de las pujas que el usuario lidera ahora mismo. Por eso aqui no se
  -- escribe nada en wallets. El dinero se mueve una sola vez, al cerrar.
  if v_top_user_id = v_user_id and p_monto <= coalesce(v_top_monto, 0) then
    raise exception 'La puja debe superar el monto actual';
  end if;

  v_compromiso := public.compromiso_usuario(v_user_id);

  -- Si el usuario YA lidera este caballo, su puja actual no se suma: se
  -- reemplaza. Subir de 100 a 150 compromete 150, no 250. El "delta" que el
  -- modelo anterior calculaba a mano sale gratis de aqui.
  if v_top_user_id = v_user_id then
    v_compromiso := v_compromiso - coalesce(v_top_monto, 0);
  end if;

  select saldo_disponible into v_saldo
  from public.wallets
  where user_id = v_user_id;

  if v_saldo is null then
    raise exception 'No se encontro wallet para el usuario';
  end if;

  if v_saldo < (v_compromiso + p_monto) then
    raise exception 'Saldo insuficiente. Tienes % Bs, ya comprometidos % Bs en pujas que lideras, y esta puja son % Bs.',
      v_saldo, v_compromiso, p_monto;
  end if;

  -- 8) La puja. Es lo unico que se escribe.
  insert into public.bids (remate_id, horse_id, user_id, monto)
  values (p_remate_id, p_horse_id, v_user_id, p_monto)
  returning * into v_bid;

  return v_bid;
end;
$function$;
