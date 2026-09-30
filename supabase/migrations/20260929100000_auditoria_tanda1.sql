-- ===========================================================================
--  20260929100000_auditoria_tanda1.sql
--
--  Los ocho arreglos quirurgicos de la auditoria del 28/09. Ninguno pasa de
--  unas pocas lineas, y los ocho son de dinero o de acceso.
--
--    A2  hacer_puja: `for share` sobre el remate
--    A3  cancelar_remate: netear las apuesta_devolucion
--    A4  liquidar_remate y registrar_movimiento_casa: candado de caja
--    A5  deposit_requests: cerrar la escritura directa
--    A6  ALTER DEFAULT PRIVILEGES: que lo nuevo NO nazca abierto
--    A7  dinero_casa_disponible: cerrar a authenticated
--    B5  admin_contabilidad_resumen: sumar el capital propio
--    D1  race_results: unicidad por carrera
--    D3  wallets: saldo no negativo
--
--  LO QUE NO ESTA AQUI, A PROPOSITO: los `revoke insert, update` sobre
--  `horses` y `remate_price_rules`. Esas dos las escribe hoy la pantalla de
--  edicion directamente, y cerrarlas antes de tener sus RPC romperia el panel.
--  Van en la tanda 4 junto con `guardar_remate_completo()`.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  A6 - QUE LO NUEVO NO NAZCA ABIERTO
--
--  La baseline trae esto:
--
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON TABLES    TO anon, authenticated;
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON FUNCTIONS TO anon, authenticated;
--
--  O sea que **no hace falta un grant para quedar expuesto: hace falta un
--  revoke para no estarlo.** Cada tabla y cada funcion que cree cualquier
--  migracion futura nace escribible/ejecutable por cualquiera con sesion.
--
--  Esto explica el hallazgo A7 y explica por que house_ledger y
--  remate_avisos tuvieron que revocar explicitamente. Para un producto que se
--  licencia es la mina estructural del esquema: la proxima tabla que anada
--  cualquiera nace abierta y nadie lo va a ver en el diff.
--
--  Va PRIMERO en este archivo a proposito: lo que venga despues ya nace
--  cerrado.
-- ---------------------------------------------------------------------------
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

--  LO QUE ESTO **NO** ARREGLA, Y HAY QUE TENERLO CLARO (29/09)
--
--  Las tres lineas de arriba cierran TABLAS y SECUENCIAS. Con las FUNCIONES
--  no alcanzan, y no hay forma de que alcancen desde aqui.
--
--  PostgreSQL le da EXECUTE a PUBLIC en toda funcion nueva, de fabrica, desde
--  antes de que existiera Supabase (doc 17, 5.8: "EXECUTE privilege for
--  functions and procedures"). Y `authenticated` es un rol como cualquier
--  otro: hereda de PUBLIC. Asi que quitarselo a anon y a authenticated deja
--  la puerta abierta por debajo.
--
--  Lo intente con:
--
--    alter default privileges for role postgres in schema public
--      revoke all on functions from public;
--
--  No hace nada. La documentacion del propio comando lo dice con ese ejemplo
--  exacto (doc 17, ALTER DEFAULT PRIVILEGES, Examples):
--
--    "Note however that you cannot accomplish that effect with a command
--     limited to a single schema. This command has no effect, unless it is
--     undoing a matching GRANT: ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC; That's because per-schema
--     default privileges can only add privileges to the global setting, not
--     remove privileges granted by it."
--
--  Solo funciona la entrada GLOBAL, sin `IN SCHEMA`. Y esa aplica a TODOS los
--  esquemas: comprobado en un Postgres real, tras ponerla, un
--  `create extension citext` deja sus 23 funciones sin EXECUTE para
--  authenticated, y eso rompe hasta un `where columna = 'x'`. Para un
--  producto que corre en bases que nosotros no operamos, es una mina.
--
--  DECISION DE JOTA (29/09): no ponemos la entrada global. En su lugar, el
--  arnes lleva un censo -- P47 -- que enumera TODAS las funciones de `public`
--  y se pone rojo si alguna es ejecutable por anon o authenticated sin estar
--  en la lista blanca. La base no falla cerrada; falla RUIDOSA, que en este
--  caso protege igual y no deja minas en casa del licenciatario.
--
--  Lo que la lista blanca implica: toda RPC nueva tiene que anadirse ahi a
--  mano, con su grant explicito. Ese es el punto. Lo que no se nombra, sale
--  en rojo.


-- ---------------------------------------------------------------------------
--  A7 - dinero_casa_disponible() a cualquier usuario logueado
--
--  El revoke original (20260923150000:100) omitio `authenticated`:
--
--    revoke all on function public.dinero_casa_disponible() from public, anon;
--
--  Y por A6 la funcion ya tenia el execute desde el momento de crearse. El
--  resultado: cualquier usuario registrado abre la consola del navegador,
--  llama supabase.rpc('dinero_casa_disponible') y recibe la caja del
--  licenciatario -- recargas, retiros, saldo agregado de todos los usuarios y
--  capital propio.
--
--  Es el mismo defecto que la tarea 2.22 (casa_resumen), en la misma
--  migracion que lo arreglo, en la funcion de al lado.
--
--  No necesita guarda interna: solo la llaman liquidar_remate y casa_resumen,
--  que son `definer` y corren como postgres.
-- ---------------------------------------------------------------------------
revoke all on function public.dinero_casa_disponible() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  A5 - Un admin podia acunar saldo de la nada
--
--    GRANT SELECT, INSERT, UPDATE ON deposit_requests TO authenticated;
--    CREATE POLICY deposit_admin_all ... FOR ALL USING (is_admin()) WITH CHECK (is_admin());
--
--  El WITH CHECK solo comprueba is_admin(): ni user_id, ni estado, ni nada.
--  Combinado con el grant, cualquier admin podia, desde la consola del
--  navegador, sin pasar por ninguna RPC y sin dejar una linea en
--  admin_actions:
--
--    - insertar un deposito para cualquier usuario y llamar aprobar_recarga
--      -> acreditar el saldo que quisiera;
--    - marcar estado = 'aprobado' sin acreditar nada -> SUBIR
--      dinero_casa_disponible(), que es el numero del que depende la guarda de
--      solvencia de liquidar_remate. Un admin que quiera pagar un premio que
--      la casa no cubre solo tenia que aprobar a mano una recarga inventada.
--
--  Es el agujero de `remates.estado` que se cerro el 28/09, en otra tabla. Y
--  desactivaba por completo el proposito del libro de la casa.
--
--  solicitar_recarga, aprobar_recarga y rechazar_recarga son `definer` y
--  corren como postgres: siguen funcionando.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on table public.deposit_requests from anon, authenticated;

--  Y el select de `anon`, que aparecio en el diagnostico del 29/09 y no lo
--  da ninguna migracion de este repo. Hoy es inofensivo porque las cuatro
--  politicas de la tabla son `to authenticated`, asi que un visitante sin
--  sesion no ve ni una fila. Pero el dia que alguien anada una politica
--  `to public` o toque la RLS, ese permiso deja de ser decorativo. Un usuario
--  sin sesion no tiene ninguna recarga que consultar: es superficie gratis.
revoke select on table public.deposit_requests from anon;

drop policy if exists deposit_admin_all on public.deposit_requests;
create policy deposit_admin_select on public.deposit_requests
  for select to authenticated using (public.is_admin());


-- ---------------------------------------------------------------------------
--  D3 - Nada impedia un saldo negativo
--
--  El invariante `saldo_disponible >= compromiso_usuario()` -- que implica
--  saldo >= 0 -- vivia EXCLUSIVAMENTE en el cuerpo de tres funciones
--  PL/pgSQL. Cualquier ruta que no pasara por ellas podia dejar el saldo en
--  negativo sin que la base dijera nada: service_role, un psql de
--  mantenimiento, una migracion futura, o el propio agujero A2.
--
--  Un check no es redundante con las guardas de aplicacion: es la ultima red,
--  y es la unica que no se puede saltar.
--
--  `not valid` + `validate` a proposito: si hubiera alguna fila negativa en
--  produccion, el validate falla y nos enteramos en vez de que la migracion
--  reviente a medias.
-- ---------------------------------------------------------------------------
alter table public.wallets
  drop constraint if exists wallets_saldo_no_negativo;
alter table public.wallets
  add constraint wallets_saldo_no_negativo
  check (saldo_disponible >= 0 and saldo_bloqueado >= 0) not valid;
alter table public.wallets validate constraint wallets_saldo_no_negativo;


-- ---------------------------------------------------------------------------
--  D1 - El ganador de una carrera podia quedar indeterminado
--
--  set_ganador_carrera es un update-then-insert SIN candado sobre una tabla
--  SIN restriccion unica en race_id:
--
--    update race_results set ganador_horse_id = ... where race_id = ...;
--    if not found then insert into race_results (...) values (...); end if;
--
--  Dos llamadas simultaneas -- dos admins, un doble clic, el reintento de un
--  fetch que no respondio -- hacen las dos un update que afecta 0 filas, las
--  dos entran al `if not found`, y las dos insertan. Quedan DOS filas para la
--  misma carrera, posiblemente con ganadores distintos.
--
--  Y liquidar_remate lee con `select ... into` sin `limit` y sin `strict`:
--  PL/pgSQL toma la primera fila que devuelva el plan, sin error y sin aviso.
--  El premio completo se paga a un usuario indeterminado.
--
--  El unique convierte la carrera en imposible: la segunda insercion choca.
-- ---------------------------------------------------------------------------
do $$
declare v_dups integer;
begin
  select count(*) into v_dups
  from (select race_id from public.race_results group by race_id having count(*) > 1) d;

  if v_dups > 0 then
    raise exception 'Hay % carreras con mas de un resultado. Hay que resolverlas a mano ANTES de poner el unique: select race_id, count(*) from race_results group by race_id having count(*) > 1;', v_dups;
  end if;
end $$;

alter table public.race_results
  drop constraint if exists race_results_race_id_key;
alter table public.race_results
  add constraint race_results_race_id_key unique (race_id);


-- ---------------------------------------------------------------------------
--  A2 - Una puja podia entrar en un remate ya cerrado, sin cobrar
--
--  El detalle esta en el comentario del propio `for share`, dentro de la
--  funcion. Resumen: `hacer_puja` leia `remates` con un select PLANO, y los
--  candados advisory con el cierre nunca se cruzaban.
--
--  Se reescribe la funcion entera porque no hay forma de parchear un cuerpo
--  de PL/pgSQL: el resto es identico a 20260924140000.
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


-- ---------------------------------------------------------------------------
--  A4 - Dos liquidaciones gastaban la misma caja
--
--  liquidar_remate no tomaba NINGUN pg_advisory_xact_lock. Su unico candado
--  era el `for update` sobre su propia fila de remates. Pero
--  dinero_casa_disponible() es una agregacion global: NO HAY NINGUNA FILA que
--  represente "la caja", asi que dos liquidaciones de remates distintos no se
--  excluian en absoluto.
--
--    Caja 1.000. Se liquidan R1 (premio 800) y R2 (premio 800) a la vez, o
--    con un doble clic. Las dos leen 1.000, las dos pasan la guarda, las dos
--    acreditan. 1.600 acreditados contra 1.000 de caja.
--
--  El dano no se ve al liquidar: se ve cuando los dos ganadores piden el
--  retiro. solicitar_retiro no mira la caja, asi que las dos solicitudes se
--  aceptan y el licenciatario queda corto 600 frente a sus jugadores.
--
--  ESPACIO 3 = LA CAJA. Un candado global, sin objeto, porque la caja es
--  global. Lo toman las dos unicas funciones que la consumen: liquidar_remate
--  y registrar_movimiento_casa. Se toma DESPUES del espacio 1 y 2 en las
--  funciones que tambien los toman, para no invertir el orden.
--
--  Se serializan las liquidaciones entre si, que es lo correcto: liquidar es
--  un acto contable global, no una operacion por remate.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
--  A4 + D1 (segunda red) - liquidar_remate
--
--  Se reescribe entera porque no hay forma de parchear un cuerpo PL/pgSQL.
--  Respecto a 20260924150000 cambian DOS cosas, las dos comentadas dentro:
--  el candado de caja al entrar, y `limit 1` al leer el ganador.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.liquidar_remate(p_remate_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_resultado numeric;
begin
  -- CANDADO DE CAJA (espacio 3), anadido el 29/09 por el hallazgo A4.
  --
  -- Esta funcion no tomaba NINGUN advisory lock. Su unico candado era el
  -- `for update` sobre su propia fila de remates. Pero la guarda de solvencia
  -- compara el premio contra dinero_casa_disponible(), que es una agregacion
  -- GLOBAL: no hay ninguna fila que represente "la caja", asi que dos
  -- liquidaciones de remates distintos no se excluian.
  --
  --   Caja 1.000. R1 (premio 800) y R2 (premio 800) liquidados a la vez, o
  --   con un doble clic. Las dos leen 1.000, las dos pasan la guarda, las dos
  --   acreditan. 1.600 contra 1.000.
  --
  -- El dano se materializa cuando los dos ganadores piden el retiro:
  -- solicitar_retiro no mira la caja.
  --
  -- Espacio 3 = la caja. Global y sin objeto, porque la caja es global. Lo
  -- toman las dos unicas funciones que la consumen: esta y
  -- registrar_movimiento_casa.
  perform pg_advisory_xact_lock(3, 0);

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
  where rr.race_id = v_remate.race_id
  -- `limit 1` anadido el 29/09: segunda red del hallazgo D1. Con el unique
  -- sobre race_id no puede haber dos filas, pero un `select ... into` sin
  -- limit toma la primera que devuelva el plan SIN error ni aviso, y de eso
  -- depende a quien se le paga el premio.
  limit 1;

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

  -- ASIENTO EN EL LIBRO DE LA CASA (tarea 2.18).
  --
  -- Lo crea el sistema, no el admin. El resultado se LEE de los movimientos
  -- reales de este remate en vez de recalcularse:
  --
  --   apuesta_cobro      negativo (sale de los usuarios)  -> entra a la casa
  --   apuesta_devolucion positivo (vuelve a los usuarios)  -> sale de la casa
  --   premio             positivo (va al ganador)          -> sale de la casa
  --
  -- Por eso el signo va invertido. Al salir de los movimientos y no de una
  -- cuenta aparte, no se puede despegar de la realidad: si se retiro un caballo
  -- despues del cierre y se devolvio dinero, eso ya esta contado.
  --
  -- Cubre los dos casos sin distinguirlos: si gana un caballo de la casa el
  -- premio es 0 y el resultado es todo lo cobrado; si gana un usuario, el
  -- resultado es la comision.
  select -coalesce(sum(m.monto), 0)
    into v_resultado
  from public.wallet_movements m
  where m.ref_externa = p_remate_id::text
    and m.tipo in ('apuesta_cobro', 'apuesta_devolucion', 'premio');

  insert into public.house_ledger (tipo, monto, motivo, ref_externa, created_by, detalles)
  values ('resultado_remate', v_resultado,
          'Resultado del remate ' || v_remate.nombre,
          p_remate_id::text, null,
          jsonb_build_object(
            'pozo_total', v_pozo_total,
            'premio_pagado', v_premio,
            'porcentaje_casa', coalesce(v_remate.porcentaje_casa, 25),
            'gano_la_casa', (v_ganador_user_id is null)));

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado. Pozo ' || v_pozo_total::text || ' Bs, premio ' || v_premio::text || ' Bs.';
end;
$function$;


-- ---------------------------------------------------------------------------
--  A4 (segunda mitad) - registrar_movimiento_casa toma el mismo candado
-- ---------------------------------------------------------------------------
create or replace function public.registrar_movimiento_casa(
  p_tipo text, p_monto numeric, p_motivo text)
returns public.house_ledger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_row public.house_ledger%rowtype;
begin
  -- Mismo candado de caja (espacio 3) que liquidar_remate. Ver A4: es la otra
  -- funcion que mueve la magnitud global, y sin el un aporte de capital y una
  -- liquidacion concurrentes no se ven.
  perform pg_advisory_xact_lock(3, 0);

  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false))
    into v_is_admin
  from public.profiles where id = v_admin_id;

  if coalesce(v_is_admin,false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  -- resultado_remate queda fuera a proposito: lo escribe el sistema al
  -- liquidar. Si un admin pudiera crearlo a mano, el cuadre dejaria de
  -- significar nada.
  if p_tipo not in ('aporte_capital','retiro_utilidad','ajuste') then
    raise exception 'Tipo no valido. Los asientos manuales son: aporte_capital, retiro_utilidad, ajuste';
  end if;

  if p_monto is null or p_monto = 0 then
    raise exception 'El monto no puede ser cero';
  end if;

  if p_motivo is null or length(trim(p_motivo)) < 3 then
    raise exception 'Motivo obligatorio';
  end if;

  insert into public.house_ledger (tipo, monto, motivo, created_by)
  values (p_tipo, p_monto, trim(p_motivo), v_admin_id)
  returning * into v_row;

  perform public.log_admin_action(
    v_admin_id, 'registrar_movimiento_casa', 'house_ledger', v_row.id::text,
    jsonb_build_object('tipo', p_tipo, 'monto', p_monto, 'motivo', trim(p_motivo)),
    true, null);

  return v_row;
end;
$fn$;


-- ---------------------------------------------------------------------------
--  A3 - Doble reembolso: retirar un caballo y despues cancelar el remate
--
--  El detalle esta dentro, junto al filtro. Se reescribe entera por lo mismo
--  de siempre: no se puede parchear un cuerpo PL/pgSQL.
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
        -- ARREGLADO EL 29/09 (hallazgo A3). Antes decia solo 'apuesta_cobro',
      -- e ignoraba las devoluciones ya emitidas sobre este mismo remate:
      --
      --   U lidera dos caballos -> al cerrar se le cobran 800.
      --   Se retira uno -> retirar_caballo le devuelve 500 (neto pagado: 300).
      --   Se suspende la carrera -> cancelar_remate le devolvia OTROS 800.
      --   U recibe 1.300 por 800 cobrados.
      --
      -- liquidar_remate, de la misma tajada, SI las neteaba, y su comentario
      -- lo decia textualmente. Esta se quedo con el conjunto incompleto.
      --
      -- El `having sum(-m.monto) > 0` que ya existe abajo se encarga del caso
      -- en que la devolucion cubrio todo lo cobrado.
      and m.tipo in ('apuesta_cobro', 'apuesta_devolucion')
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


-- ---------------------------------------------------------------------------
--  B5 - La caja de la guarda y la del panel habian divergido
--
--  Se reescribe entera. Respecto a 20260923110000 cambia UNA linea, comentada
--  dentro: el calculo de `dinero_casa`.
-- ---------------------------------------------------------------------------
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
  -- ARREGLADO EL 29/09 (hallazgo B5). Faltaba el capital propio.
  --
  -- La tarea 2.18 anadio el libro de la casa y actualizo
  -- dinero_casa_disponible() para que sumara los asientos manuales (capital
  -- aportado, utilidades retiradas, ajustes). A esta funcion no.
  --
  -- Resultado: la guarda de solvencia y la pantalla que el admin mira daban
  -- numeros distintos sobre la misma caja. Visible en el propio arnes: en P30,
  -- tras un aporte de 5.000, la funcion daba 5.500 y el panel seguia diciendo
  -- 500. La tajada A habia declarado "se usa la del panel" y la 2.18 rompio
  -- ese invariante sin darse cuenta.
  --
  -- Decision de Jota (28/09): suma el panel. La guarda de solvencia TIENE que
  -- ver el capital propio -- si no, volvemos al problema que abrio la 2.18,
  -- donde la casa no podia liquidar nada porque su aporte no contaba.
  --
  -- Los `resultado_remate` quedan fuera a proposito: ese resultado ya esta
  -- implicito en los saldos de los usuarios, y contarlo aqui seria contarlo
  -- dos veces. Mismo criterio que dinero_casa_disponible().
  v_dinero_casa := v_recargas_aprobadas
                 - v_retiros_pagados
                 - v_saldo_usuarios
                 - v_retiros_pendientes
                 + coalesce((select sum(monto) from public.house_ledger
                             where tipo <> 'resultado_remate'), 0);

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
