-- ===========================================================================
--  REQUISITO DE APUESTA PARA RETIRAR  (la "regla del 50%")
--  01/10/2026
--
--  EL PROBLEMA
--
--  Un usuario podia recargar 1.000 Bs y pedir el retiro de los 1.000 sin haber
--  pujado una sola vez. La solicitud llegaba al admin como cualquier otra. Eso
--  convierte la aplicacion en un canal de transferencia: entra dinero por un
--  lado y sale por el otro sin pasar por el juego.
--
--  Jota: "una persona que acaba de recargar, no puede retirar inmediatamente ni
--  toda ni parte del saldo hasta que haya apostado al menos el 50%. Es decir,
--  al haber hecho la solicitud de retiro el sistema debio haberlo rebotado, en
--  ese caso ni siquiera llega al admin."
--
--  DE DONDE SALE LA FORMA EXACTA (investigado el 01/10, no inventado)
--
--  Terminos y condiciones de Wplay.co -- operador con licencia de Coljuegos --
--  seccion 4.5.5, citando el articulo 1.4.2 del Acuerdo 08 de 2020:
--
--    "Cada recarga de creditos para la participacion realizada sera acreditada
--     al BALANCE DE CREDITOS de la cuenta del usuario y de este saldo solo sera
--     posible efectuar el retiro de fondos de la plataforma una vez el usuario
--     haya apostado minimo el 50% de la totalidad de los depositos realizados
--     para adquirir creditos de participacion."
--
--  Comprobado en dos versiones del mismo documento (dic-2020 y ago-2022): las
--  dos dicen "la totalidad de los depositos", no la ultima recarga. La version
--  de 2022 anade que "esta condicion no aplica para los premios obtenidos por
--  el jugador"; eso NO aparece en la de 2020, asi que es la parte menos firme
--  de lo investigado.
--
--  AVISO QUE CONVIENE QUE QUEDE ESCRITO: no se consiguio el texto del Acuerdo
--  08 en una fuente oficial del gobierno -- lo de arriba es la cita de un
--  operador licenciado, no la norma. Y Coljuegos no regula esta aplicacion:
--  esto se copia por higiene antilavado y porque es lo que hace el sector, no
--  por una obligacion legal del licenciatario.
--
--  LAS TRES DECISIONES DE JOTA (01/10)
--
--  1. La base es el ACUMULADO de recargas aprobadas, como Wplay. Consecuencia
--     contraintuitiva que conviene tener presente: las apuestas viejas cuentan
--     para la recarga nueva, asi que un cliente de mucho recorrido puede
--     recargar y retirar casi al instante. Es como funciona en las casas
--     reales, no un defecto de esta implementacion.
--
--  2. "Apostado" es LA PUJA MAS ALTA DE CADA CABALLO, no la suma de todas las
--     filas de `bids`. En este modelo una puja reemplaza a la anterior sobre el
--     mismo caballo: quien sube su propia puja de 100 a 150 apostó 150, no 250.
--     Sumar las filas premiaria a quien se sube su propia puja para cumplir el
--     requisito mas rapido sin arriesgar un bolivar mas.
--
--  3. LOS PREMIOS QUEDAN EXENTOS. Lo que el usuario gano no es dinero que trajo
--     de fuera, asi que no tiene por que quedar retenido. La retencion solo
--     alcanza a lo que viene de recargas.
--
--  Y EL PORCENTAJE NO VA FIJO: 50 es el numero de hoy y vive en
--  ajustes_instalacion, como los minimos (ADR-017). Un licenciatario en otra
--  jurisdiccion lo necesita en otro valor, o en cero.
--
--  DONDE VA LA REGLA: EN LA BASE, UNA SOLA VEZ
--
--  `requisito_apuesta()` es la unica fuente. La consultan `solicitar_retiro`
--  para rebotar y `mi_wallet_resumen` para que la pantalla pueda decirle al
--  usuario cuanto le falta. El frontend muestra, no calcula (ADR-015).
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  PASO 1 - El ajuste
-- ---------------------------------------------------------------------------
insert into public.ajustes_instalacion (clave, valor, tipo, descripcion) values
  ('pct_apostado_para_retirar',
   '50',
   'numero',
   'Porcentaje del total recargado que el usuario tiene que haber apostado antes de poder retirar. Los premios quedan exentos. En 0 la regla no aplica.')
on conflict (clave) do nothing;


-- ---------------------------------------------------------------------------
--  PASO 2 - La cuenta, en un solo sitio
--
--  Devuelve todo lo que hace falta para decidir Y para explicarselo al usuario.
--  Un mensaje de "no puedes retirar" sin los numeros detras es un mensaje que
--  genera un reclamo por soporte.
-- ---------------------------------------------------------------------------
create or replace function public.requisito_apuesta(p_user_id uuid)
returns table (
  pct              numeric,
  recargado        numeric,
  apostado         numeric,
  requerido        numeric,
  falta_apostar    numeric,
  cumplido         boolean,
  premios_libres   numeric,
  tope_por_regla   numeric
)
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_pct       numeric;
  v_recargado numeric;
  v_apostado  numeric;
  v_requerido numeric;
  v_premios   numeric;
  v_retirado  numeric;
  v_libres    numeric;
  v_saldo     numeric;
begin
  v_pct := public.ajuste_numero('pct_apostado_para_retirar');

  select coalesce(w.saldo_disponible, 0) into v_saldo
  from public.wallets w where w.user_id = p_user_id;
  v_saldo := coalesce(v_saldo, 0);

  -- Recargado: el acumulado de recargas APROBADAS. Una recarga pendiente no
  -- ha entrado al saldo, asi que tampoco exige nada.
  select coalesce(sum(d.monto), 0) into v_recargado
  from public.deposit_requests d
  where d.user_id = p_user_id
    and d.estado = 'aprobado'::public.deposit_status;

  -- Apostado: la puja MAS ALTA de cada caballo de cada remate. Ver la
  -- decision 2 de la cabecera.
  --
  -- Se excluyen los remates cancelados: en una cancelacion se devuelve el
  -- dinero, asi que contar esas pujas regalaria avance en el requisito por
  -- algo que al final no ocurrio. La cancelacion es una accion del admin, no
  -- del usuario, asi que tampoco se le castiga: simplemente no cuenta.
  select coalesce(sum(t.mayor), 0) into v_apostado
  from (
    select max(b.monto) as mayor
    from public.bids b
    join public.remates r on r.id = b.remate_id
    where b.user_id = p_user_id
      and r.estado <> 'cancelado'::public.remate_status
    group by b.remate_id, b.horse_id
  ) t;

  v_requerido := round(v_recargado * v_pct / 100.0, 2);

  -- Premios libres: lo acreditado por premios menos lo que ya se llevo en
  -- retiros. Tratar cada retiro pasado como si hubiera consumido premio
  -- primero es conservador a proposito: deja MENOS disponible, nunca mas.
  select coalesce(sum(m.monto), 0) into v_premios
  from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id
  where w.user_id = p_user_id and m.tipo = 'premio'::public.wallet_movement_type;

  select coalesce(sum(-m.monto), 0) into v_retirado
  from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id
  where w.user_id = p_user_id and m.tipo = 'retiro'::public.wallet_movement_type;

  v_libres := greatest(v_premios - v_retirado, 0);

  return query select
    v_pct,
    v_recargado,
    v_apostado,
    v_requerido,
    greatest(v_requerido - v_apostado, 0),
    (v_apostado >= v_requerido),
    v_libres,
    case when v_apostado >= v_requerido then v_saldo else least(v_libres, v_saldo) end;
end $fn$;

comment on function public.requisito_apuesta(uuid) is
  'La regla del 50%: cuanto ha recargado, cuanto ha apostado (la puja mas alta de cada caballo) y cuanto puede retirar. Unica fuente; la usan solicitar_retiro y mi_wallet_resumen.';


-- ---------------------------------------------------------------------------
--  PASO 3 - solicitar_retiro rebota antes de llegar al admin
--
--  Se conserva TODO lo que ya hacia: el candado por usuario, el `for update`
--  sobre la wallet, el descuento del saldo y el movimiento de rastro. Lo unico
--  que cambia es que `v_retirable` ahora tiene dos techos en vez de uno.
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
  v_req record;
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
  -- el mismo compromiso viejo y las dos pasan.
  perform pg_advisory_xact_lock(1, hashtext(v_user_id::text));

  select * into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario';
  end if;

  v_compromiso := public.compromiso_usuario(v_user_id);
  select * into v_req from public.requisito_apuesta(v_user_id);

  -- DOS TECHOS, y el mensaje tiene que decir cual de los dos choco. Un
  -- "no puedes retirar" sin motivo se convierte en un mensaje de soporte.
  v_retirable := least(v_wallet.saldo_disponible - v_compromiso, v_req.tope_por_regla);

  if p_monto > v_retirable then
    if not v_req.cumplido and p_monto > v_req.tope_por_regla then
      -- OJO con el porcentaje literal: en `raise`, `%%%` se lee como `%%`
      -- (porcentaje literal) y luego `%` (sustitucion), asi que sale "%50" en
      -- vez de "50%". Se escribe con palabras y se acaba la ambiguedad.
      raise exception
        'Para retirar tienes que haber apostado al menos el % por ciento de lo que has recargado. Has recargado % Bs y has apostado % Bs: te faltan % Bs por apostar. Puedes retirar % Bs, que es lo que llevas ganado en premios.',
        v_req.pct, v_req.recargado, v_req.apostado, v_req.falta_apostar,
        greatest(least(v_req.premios_libres, v_wallet.saldo_disponible - v_compromiso), 0);
    end if;

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
--  PASO 4 - mi_wallet_resumen dice cuanto falta
--
--  Si la pantalla no puede explicar la retencion, el usuario intenta retirar,
--  recibe un error y escribe a soporte. El dato tiene que estar ANTES.
--
--  Cambia el tipo de retorno, asi que hay drop. Las columnas viejas se
--  conservan con su nombre: el frontend y P25 leen por nombre, no por posicion.
-- ---------------------------------------------------------------------------
drop function if exists public.mi_wallet_resumen();

create or replace function public.mi_wallet_resumen()
returns table(
  saldo_disponible numeric,
  saldo_bloqueado numeric,
  comprometido numeric,
  disponible_para_retirar numeric,
  pct_requerido numeric,
  recargado numeric,
  apostado numeric,
  falta_apostar numeric,
  requisito_cumplido boolean
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select
    w.saldo_disponible,
    w.saldo_bloqueado,
    public.compromiso_usuario(w.user_id)                                   as comprometido,
    greatest(
      least(
        w.saldo_disponible - public.compromiso_usuario(w.user_id),
        r.tope_por_regla
      ), 0)                                                                as disponible_para_retirar,
    r.pct                                                                  as pct_requerido,
    r.recargado,
    r.apostado,
    r.falta_apostar,
    r.cumplido                                                             as requisito_cumplido
  from public.wallets w
  cross join lateral public.requisito_apuesta(w.user_id) r
  where w.user_id = auth.uid()
  limit 1;
$fn$;


-- ---------------------------------------------------------------------------
--  PASO 5 - PERMISOS. ADR-016: lo nuevo se declara.
--
--  `requisito_apuesta` recibe un uuid, asi que un usuario con sesion podria
--  preguntar por otro. Se cierra, igual que compromiso_usuario. Lo que el
--  usuario necesita saber de si mismo se lo da mi_wallet_resumen, que no
--  recibe parametros y filtra por auth.uid().
-- ---------------------------------------------------------------------------
revoke all on function public.requisito_apuesta(uuid)  from public, anon, authenticated;
revoke all on function public.mi_wallet_resumen()      from public, anon, authenticated;
grant execute on function public.mi_wallet_resumen()   to authenticated;
