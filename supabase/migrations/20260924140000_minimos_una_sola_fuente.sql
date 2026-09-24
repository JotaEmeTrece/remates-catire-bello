-- ============================================================================
--  Bloque 2, tajada F (parte SQL) - Una sola fuente para los minimos de puja
--
--  Referencia: DISENO_SALDO_V2.md §6bis R4 y tarea 2.20.
--
--  EL PROBLEMA QUE RESUELVE
--  `app/remates/[id]/page.tsx` reimplementa en TypeScript la escalera de
--  precios: recorre remate_price_rules, elige la que aplica, y calcula el
--  minimo automatico y el manual de cada caballo. La base hace lo mismo por su
--  cuenta dentro de hacer_puja. Son dos implementaciones de la misma regla, y
--  el 23/09 se demostro que se separan sin que nadie se entere: la pantalla
--  elegia bien la regla del caballo y la base elegia la general (tarea 1.10).
--  El usuario leia un numero y la base cobraba otro.
--
--  LA SOLUCION, EN DOS PIEZAS
--  1. _incremento_aplicable(): la seleccion de la regla, en UN solo lugar.
--     hacer_puja la usa, y la RPC de abajo tambien. Si alguien cambia la regla,
--     cambia para los dos a la vez porque es el mismo codigo.
--  2. remate_minimos(): devuelve, por caballo, todo lo que la pantalla necesita
--     para dibujar los botones. La pantalla deja de calcular y pasa a mostrar.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Que incremento aplica a este caballo, con el precio en que va ahora.
-- La regla del caballo manda; si no tiene, la general del remate; si no hay
-- ninguna, el incremento_minimo del remate.
-- ---------------------------------------------------------------------------
create or replace function public._incremento_aplicable(
  p_remate_id uuid, p_horse_id uuid, p_monto_actual numeric)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(
    (
      select r.incremento
      from public.remate_price_rules r
      where r.remate_id = p_remate_id
        and (r.horse_id is null or r.horse_id = p_horse_id)
        and p_monto_actual >= r.min_precio
        and (r.max_precio is null or p_monto_actual < r.max_precio)
      -- `horse_id is not null` y no `horse_id = p_horse_id`: el WHERE ya dejo
      -- pasar solo las dos clases, y asi la expresion nunca da NULL. Con NULL,
      -- un ORDER BY DESC los pone PRIMERO y gana la regla general. Ese era el
      -- defecto 1.10.
      order by (r.horse_id is not null) desc, r.min_precio desc
      limit 1
    ),
    (select rm.incremento_minimo from public.remates rm where rm.id = p_remate_id)
  );
$fn$;

comment on function public._incremento_aplicable(uuid, uuid, numeric) is
  'Unica fuente de verdad del incremento que aplica a un caballo. La usan hacer_puja y remate_minimos.';

-- ---------------------------------------------------------------------------
-- Todo lo que la pantalla de remate necesita por caballo, calculado en la base.
-- ---------------------------------------------------------------------------
create or replace function public.remate_minimos(p_remate_id uuid)
returns table(
  horse_id      uuid,
  numero        integer,
  retirado      boolean,
  precio_salida numeric,
  hay_pujas     boolean,
  monto_actual  numeric,   -- la puja lider, o el precio de salida si no hay
  lider_user_id uuid,
  soy_lider     boolean,
  incremento    numeric,
  minimo_auto   numeric,   -- lo que cobra el boton "Ponerle"
  minimo_manual numeric    -- lo minimo que acepta el campo manual
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with rem as (
    select * from public.remates where id = p_remate_id
  ),
  lider as (
    select distinct on (b.horse_id) b.horse_id, b.user_id, b.monto
    from public.bids b
    where b.remate_id = p_remate_id
    order by b.horse_id, b.monto desc, b.created_at asc
  ),
  base as (
    select
      h.id as horse_id,
      h.numero,
      coalesce(h.retirado, false) as retirado,
      h.precio_salida,
      (l.monto is not null) as hay_pujas,
      coalesce(l.monto, h.precio_salida) as monto_actual,
      l.user_id as lider_user_id
    from public.horses h
    join rem on rem.race_id = h.race_id
    left join lider l on l.horse_id = h.id
  )
  select
    b.horse_id,
    b.numero,
    b.retirado,
    b.precio_salida,
    b.hay_pujas,
    b.monto_actual,
    b.lider_user_id,
    (b.lider_user_id is not null and b.lider_user_id = auth.uid()) as soy_lider,
    inc.incremento,
    -- Caballo virgen: se toma AL precio de salida. Con pujas: hay que superar
    -- la de arriba por el incremento. Mismas reglas que hacer_puja porque es el
    -- mismo _incremento_aplicable().
    case when b.hay_pujas then b.monto_actual + inc.incremento else b.precio_salida end as minimo_auto,
    -- La manual acepta DESDE el minimo automatico. Ya no hay +10 clavado.
    case when b.hay_pujas then b.monto_actual + inc.incremento else b.precio_salida end as minimo_manual
  from base b
  cross join lateral (
    select public._incremento_aplicable(p_remate_id, b.horse_id, b.monto_actual) as incremento
  ) inc
  order by b.numero;
$fn$;

comment on function public.remate_minimos(uuid) is
  'Minimos de puja por caballo, calculados en la base. La pantalla de remate los muestra, no los recalcula (tarea 2.20).';

grant execute on function public.remate_minimos(uuid) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- hacer_puja pasa a usar el helper compartido.
-- ---------------------------------------------------------------------------
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
  --    Desde la tajada F esta seleccion vive en _incremento_aplicable(), para
  --    que la RPC que alimenta la pantalla use EXACTAMENTE la misma regla. Dos
  --    implementaciones de la misma regla es como llegamos al defecto 1.10.
  v_incremento := public._incremento_aplicable(p_remate_id, p_horse_id, v_ultimo_monto);

  if v_incremento is null or v_incremento <= 0 then
    raise exception 'Incremento no valido para el remate';
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
