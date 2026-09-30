-- ===========================================================================
--  20260930110000_admin_no_puja.sql
--
--  "Los admins no pueden participar en remates" -- regla de Jota desde el
--  primer dia del proyecto, y hasta hoy escrita en un solo sitio: el
--  frontend.
--
--  `app/remates/[id]/page.tsx:188` lee `es_admin` y esconde el formulario de
--  puja. `hacer_puja` no tenia ni una linea al respecto: de sus doce
--  excepciones, ninguna mencionaba el rol. Un admin abre la consola del
--  navegador, llama a la RPC, y puja en su propio remate viendo todas las
--  pujas de todos los caballos desde el panel.
--
--  Es el caso mas caro del ADR-015. No es un numero que se muestra mal: es
--  que la frase con la que un licenciatario defiende su honradez -- "la casa
--  no juega" -- no era verdad, y no habia forma de demostrarla.
--
--  SE REESCRIBE LA FUNCION ENTERA porque un cuerpo PL/pgSQL no se parchea.
--  Respecto a 20260929100000 cambia exactamente esto: una variable declarada
--  y una guarda de nueve lineas despues de la de autenticacion. Todo lo
--  demas -- candados, `for share`, escalera, guarda de exposicion -- es
--  identico, byte a byte.
--
--  LO QUE ESTA GUARDA NO HACE, Y ES A PROPOSITO:
--  no toca las pujas que un admin ya tenga hechas. Si alguien puja y despues
--  lo ascienden a admin, sus pujas viejas siguen vivas y cobran o pagan como
--  las de cualquiera. Anular dinero ya comprometido por un cambio de rol
--  seria peor que el problema que arregla.
-- ===========================================================================


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
  v_es_admin boolean;

begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  -- LA CASA NO JUEGA EN SU PROPIO REMATE. (30/09/2026)
  --
  -- Esta regla existe desde el primer dia del proyecto, por decision de Jota,
  -- y por un motivo que no es tecnico: un admin ve todas las pujas de todos
  -- los caballos desde el panel, decide cuando cierra el remate y fija el
  -- porcentaje de la casa. Si ademas pudiera pujar, estaria jugando contra
  -- sus propios clientes con las cartas boca arriba.
  --
  -- Pero hasta hoy la regla vivia SOLO en el frontend
  -- (app/remates/[id]/page.tsx:188, que lee es_admin y esconde el formulario).
  -- Esconder un boton no es una regla: cualquier admin abre la consola del
  -- navegador y llama supabase.rpc('hacer_puja', {...}) igual. La base no
  -- tenia ni una linea sobre esto.
  --
  -- Es el ADR-015 en su forma mas cara: una regla de negocio implementada en
  -- la pantalla. Y aqui no se trata de un numero que se ve mal -- se trata de
  -- que el argumento con el que un licenciatario defiende su honradez no era
  -- cierto.
  --
  -- El frontend CONSERVA su comprobacion, y esta bien que la conserve: sirve
  -- para no ensenarle un formulario inutil a quien no puede usarlo. Lo que
  -- cambia es que ya no es la unica.
  select (coalesce(es_admin, false) or coalesce(es_super_admin, false))
    into v_es_admin
  from public.profiles
  where id = v_user_id;

  if coalesce(v_es_admin, false) then
    raise exception 'Los administradores no pueden pujar en los remates de la casa';
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
  --
  -- `for share` ANADIDO EL 28/09 (hallazgo A2 de la auditoria). Antes era un
  -- select plano, y eso abria un agujero silencioso:
  --
  --   _cerrar_remate_interno toma `for update` sobre esta misma fila, pero en
  --   READ COMMITTED un select SIN clausula de bloqueo no espera a nadie: lee
  --   'abierto' mientras el cierre aun no ha confirmado. Y los candados
  --   advisory tampoco se cruzan -- la puja toma espacio 2 con clave
  --   remate:caballo, el cierre solo toma espacio 1 por lider.
  --
  --   Resultado: la puja pasa todas las validaciones, y su `insert into bids`
  --   se queda esperando en la comprobacion de la clave foranea (FOR KEY
  --   SHARE). Cuando el cierre confirma, la FK solo exige que la fila exista
  --   -> el insert se completa. Queda una puja dentro de un remate CERRADO
  --   cuyo autor NO fue debitado. Si ese caballo gana, se le paga el premio.
  --
  --   Y el descuadre no lo detecta, porque el asiento `resultado_remate` se
  --   calcula leyendo los mismos wallet_movements: las dos mitades del cuadre
  --   mienten igual.
  --
  -- `for share` choca con el `for update` del cierre, NO choca entre pujas de
  -- caballos distintos, y se toma ANTES del insert -- asi que respeta el mismo
  -- orden que el cierre y elimina tambien el interbloqueo de la variante B.
  select *
    into v_remate
  from public.remates
  where id = p_remate_id
  for share;

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

--  `create or replace function` conserva los permisos, pero se redeclaran por
--  la regla del 29/09: lo que no se nombra, queda fuera. Si esto quedara mal,
--  P47 se pone rojo.
revoke all on function public.hacer_puja(uuid, uuid, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.hacer_puja(uuid, uuid, numeric, boolean)
  to authenticated;
