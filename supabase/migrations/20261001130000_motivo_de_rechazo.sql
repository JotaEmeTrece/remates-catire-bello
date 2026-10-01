-- ===========================================================================
--  MOTIVO DE RECHAZO, Y UNA CORRECCION A LA REGLA DEL 50%
--  01/10/2026
--
--  EL PROBLEMA, QUE RESULTARON SER DOS DISTINTOS
--
--  Jota rechazo una recarga escribiendo el motivo y el cliente no lo vio.
--  Al buscarlo aparecieron dos cosas, no una:
--
--  1. La RECARGA si captura el motivo. `rechazar_recarga` lo exige
--     ("Motivo requerido") y lo guarda... en `admin_actions.detalles->>'reason'`
--     via log_admin_action. Esa es la BITACORA DE AUDITORIA: el sitio correcto
--     para el rastro de quien hizo que, y el equivocado para algo que el
--     cliente tiene que leer. El motivo nunca se perdio: esta escrito donde el
--     cliente no puede verlo, y `deposit_requests` no tiene columna para el.
--
--  2. El RETIRO no captura nada. `procesar_retiro(uuid, withdraw_status)` tiene
--     dos parametros y ninguno es un motivo. Rechazas un retiro y no queda ni
--     en la bitacora.
--
--  LA DECISION (Jota, 01/10): lista de motivos + nota opcional
--
--  No texto libre. Ese motivo lo escribe un admin y lo lee el cliente, y un
--  licenciatario va a tener empleados: con texto libre el cliente queda
--  expuesto a lo que se le ocurra escribir a un operador a las 2 de la
--  manana. Con lista, al cliente le llega siempre un motivo entendible.
--
--  Los motivos viven en una tabla de ESTA instalacion, no en el codigo: cada
--  licenciatario opera distinto y va a querer los suyos.
--
--  POR QUE SE GUARDA LA ETIQUETA Y NO SOLO EL CODIGO
--
--  `motivo_etiqueta` es una FOTO del texto en el momento del rechazo. Si el
--  licenciatario manana renombra "Referencia no encontrada" o desactiva ese
--  motivo, el rechazo viejo tiene que seguir diciendole al cliente lo que se
--  le dijo entonces. Un documento que el cliente puede volver a leer no puede
--  cambiar de contenido a sus espaldas. Por eso tampoco hay clave foranea: el
--  historico no se rompe porque alguien limpie la lista.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  PASO 0 - CORRECCION A requisito_apuesta (la regla del 50%, de hoy mismo)
--
--  El defecto lo destapo leer `procesar_retiro` para esta tanda: cuando el
--  admin RECHAZA un retiro, la funcion devuelve el dinero con un movimiento
--  `ajuste_manual`, pero el movimiento `retiro` original se queda ahi.
--
--  `requisito_apuesta` calculaba los premios libres como
--  "premios acreditados menos la suma de los movimientos de tipo retiro", asi
--  que un retiro RECHAZADO seguia contando como premio ya consumido: el
--  usuario pedia sus 300 Bs de premio, el admin se los rechazaba, le volvia el
--  dinero al saldo... y ya no los podia volver a pedir.
--
--  Se cambia la fuente: los retiros se cuentan de `withdraw_requests`,
--  excluyendo los rechazados. Es la tabla que manda sobre el estado de un
--  retiro, y asi no hay que adivinar la intencion de un `ajuste_manual` --
--  que tambien se usa para otras cosas.
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

  select coalesce(sum(d.monto), 0) into v_recargado
  from public.deposit_requests d
  where d.user_id = p_user_id
    and d.estado = 'aprobado'::public.deposit_status;

  -- La puja MAS ALTA de cada caballo, sin los remates cancelados.
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

  select coalesce(sum(m.monto), 0) into v_premios
  from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id
  where w.user_id = p_user_id and m.tipo = 'premio'::public.wallet_movement_type;

  -- Los retiros, de withdraw_requests y SIN los rechazados. Ver la cabecera
  -- del paso 0: un retiro rechazado se devuelve, asi que no consumio nada.
  select coalesce(sum(wr.monto), 0) into v_retirado
  from public.withdraw_requests wr
  where wr.user_id = p_user_id
    and wr.estado <> 'rechazado'::public.withdraw_status;

  v_libres := greatest(v_premios - v_retirado, 0);

  return query select
    v_pct, v_recargado, v_apostado, v_requerido,
    greatest(v_requerido - v_apostado, 0),
    (v_apostado >= v_requerido),
    v_libres,
    case when v_apostado >= v_requerido then v_saldo else least(v_libres, v_saldo) end;
end $fn$;


-- ---------------------------------------------------------------------------
--  PASO 1 - La lista de motivos de esta instalacion
-- ---------------------------------------------------------------------------
create table if not exists public.motivos_rechazo (
  codigo     text primary key,
  ambito     text not null check (ambito in ('recarga', 'retiro', 'ambos')),
  etiqueta   text not null,
  activo     boolean not null default true,
  orden      int not null default 0,
  created_at timestamptz not null default now()
);

comment on table public.motivos_rechazo is
  'Motivos de rechazo de ESTA instalacion. El rechazo guarda el codigo Y una foto de la etiqueta, para que el historico no cambie si se renombra o desactiva un motivo.';

insert into public.motivos_rechazo (codigo, ambito, etiqueta, orden) values
  ('referencia_no_encontrada', 'recarga', 'No encontramos la referencia del pago',                10),
  ('monto_no_coincide',        'recarga', 'El monto no coincide con el comprobante',              20),
  ('comprobante_ilegible',     'recarga', 'El comprobante no se puede leer',                      30),
  ('titular_no_coincide',      'recarga', 'Los datos del titular no coinciden',                   40),
  ('pago_duplicado',           'recarga', 'Este pago ya fue registrado en otra solicitud',        50),
  ('datos_destino_incorrectos','retiro',  'Los datos de destino no son correctos',                10),
  ('titular_distinto',         'retiro',  'La cuenta de destino no esta a nombre del titular',    20),
  ('solicitud_duplicada',      'retiro',  'Ya hay otra solicitud de retiro en proceso',           30),
  ('pedido_por_el_cliente',    'ambos',   'Anulado a pedido del cliente',                         80),
  ('otro',                     'ambos',   'Otro motivo (ver la nota)',                            90)
on conflict (codigo) do nothing;


-- ---------------------------------------------------------------------------
--  PASO 2 - Las columnas. Nullables: solo se llenan al rechazar, y las
--  solicitudes que ya existen se quedan como estan.
-- ---------------------------------------------------------------------------
alter table public.deposit_requests
  add column if not exists motivo_codigo   text,
  add column if not exists motivo_etiqueta text,
  add column if not exists motivo_nota     text;

alter table public.withdraw_requests
  add column if not exists motivo_codigo   text,
  add column if not exists motivo_etiqueta text,
  add column if not exists motivo_nota     text;

comment on column public.deposit_requests.motivo_etiqueta is
  'Foto del texto del motivo en el momento del rechazo. No se recalcula desde motivos_rechazo: lo que el cliente leyo no puede cambiar despues.';
comment on column public.withdraw_requests.motivo_etiqueta is
  'Foto del texto del motivo en el momento del rechazo. No se recalcula desde motivos_rechazo: lo que el cliente leyo no puede cambiar despues.';


-- ---------------------------------------------------------------------------
--  PASO 3 - Una sola puerta para validar un motivo y sacar su etiqueta
-- ---------------------------------------------------------------------------
create or replace function public._motivo_etiqueta(p_codigo text, p_ambito text)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare v_etiqueta text;
begin
  if p_codigo is null or length(trim(p_codigo)) = 0 then
    raise exception 'Hay que indicar el motivo del rechazo';
  end if;

  select m.etiqueta into v_etiqueta
  from public.motivos_rechazo m
  where m.codigo = trim(p_codigo)
    and m.activo
    and m.ambito in (p_ambito, 'ambos');

  if v_etiqueta is null then
    raise exception 'El motivo "%" no existe, esta desactivado, o no aplica a un rechazo de %',
      trim(p_codigo), p_ambito;
  end if;

  return v_etiqueta;
end $fn$;


-- ---------------------------------------------------------------------------
--  PASO 4 - rechazar_recarga
--
--  Cambia la firma, asi que hay drop: si se dejaran las dos versiones, una
--  llamada de dos argumentos quedaria ambigua entre la vieja (uuid, text) y la
--  nueva con nota por defecto.
--
--  El asiento en admin_actions se CONSERVA. La bitacora sigue siendo la
--  bitacora; lo que se anade es la copia que el cliente puede leer.
-- ---------------------------------------------------------------------------
drop function if exists public.rechazar_recarga(uuid, text);

create or replace function public.rechazar_recarga(
  p_deposit_request_id uuid,
  p_motivo_codigo text,
  p_nota text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_etiqueta text;
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  if p_deposit_request_id is null then
    raise exception 'Parametro invalido';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden rechazar recargas';
  end if;

  v_etiqueta := public._motivo_etiqueta(p_motivo_codigo, 'recarga');

  select * into v_request
  from public.deposit_requests
  where id = p_deposit_request_id;

  if not found then
    raise exception 'Solicitud de recarga no existe';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de recarga no esta pendiente (estado actual: %)', v_request.estado;
  end if;

  update public.deposit_requests
  set estado = 'rechazado'::deposit_status,
      approved_at = now(),
      approved_by = v_admin_id,
      motivo_codigo = trim(p_motivo_codigo),
      motivo_etiqueta = v_etiqueta,
      motivo_nota = v_nota
  where id = v_request.id
    and estado = 'pendiente'::deposit_status;

  if not found then
    raise exception 'La solicitud cambio de estado mientras se procesaba';
  end if;

  perform public.log_admin_action(
    v_admin_id, 'rechazar_recarga', 'deposit_requests', v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'rechazado'),
      'motivo_codigo', trim(p_motivo_codigo),
      'motivo_etiqueta', v_etiqueta,
      'motivo_nota', v_nota
    ),
    true, null
  );

  return 'Recarga rechazada';
end $fn$;


-- ---------------------------------------------------------------------------
--  PASO 5 - procesar_retiro
--
--  Se conserva TODO lo que ya hacia, y lo que mas importa conservar es la
--  DEVOLUCION del dinero al rechazar: el `for update` sobre la wallet, el
--  movimiento `ajuste_manual` y el update condicionado a que siga pendiente.
--  Lo unico que se anade es el motivo.
-- ---------------------------------------------------------------------------
drop function if exists public.procesar_retiro(uuid, public.withdraw_status);

create or replace function public.procesar_retiro(
  p_withdraw_id uuid,
  p_nuevo_estado public.withdraw_status,
  p_motivo_codigo text default null,
  p_nota text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_request public.withdraw_requests%rowtype;
  v_wallet public.wallets%rowtype;
  v_etiqueta text;
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden procesar retiros';
  end if;

  -- El motivo se valida ANTES de tocar dinero. Si el codigo esta mal, que
  -- reviente aqui y no a mitad de la devolucion.
  if p_nuevo_estado = 'rechazado'::withdraw_status then
    v_etiqueta := public._motivo_etiqueta(p_motivo_codigo, 'retiro');
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

  if p_nuevo_estado = 'pagado'::withdraw_status then
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
      v_user_id, 'procesar_retiro', 'withdraw_requests', v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'pagado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true, null
    );

    return 'Retiro marcado como pagado';

  elsif p_nuevo_estado = 'rechazado'::withdraw_status then
    select * into v_wallet
    from public.wallets
    where user_id = v_request.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el usuario del retiro';
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_request.monto
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'ajuste_manual'::wallet_movement_type, v_request.monto,
            'Devolucion de retiro rechazado', v_request.id::text);

    update public.withdraw_requests
    set estado = 'rechazado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id,
        motivo_codigo = trim(p_motivo_codigo),
        motivo_etiqueta = v_etiqueta,
        motivo_nota = v_nota
    where id = v_request.id
      and estado = 'pendiente'::withdraw_status;

    if not found then
      raise exception 'La solicitud cambio de estado mientras se procesaba';
    end if;

    perform public.log_admin_action(
      v_user_id, 'procesar_retiro', 'withdraw_requests', v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'rechazado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'motivo_codigo', trim(p_motivo_codigo),
        'motivo_etiqueta', v_etiqueta,
        'motivo_nota', v_nota,
        'devuelto', true
      ),
      true, null
    );

    return 'Retiro rechazado y saldo devuelto';
  end if;

  raise exception 'Estado no soportado: %', p_nuevo_estado;
end $fn$;


-- ---------------------------------------------------------------------------
--  PASO 6 - PERMISOS. ADR-016.
--
--  La tabla de motivos la LEE el panel de admin para armar el desplegable, y
--  tambien el cliente sin problema: son etiquetas, no datos de nadie. Nadie la
--  escribe desde la aplicacion salvo el super admin.
--
--  Sin insert y sin delete a nivel de tabla: los codigos los crean las
--  migraciones. Un licenciatario cambia etiquetas y activa o desactiva, no
--  inventa codigos que el codigo no conoce.
-- ---------------------------------------------------------------------------
revoke all on table public.motivos_rechazo from public, anon, authenticated;
grant select, update on table public.motivos_rechazo to authenticated;

alter table public.motivos_rechazo enable row level security;

drop policy if exists motivos_lee_con_sesion on public.motivos_rechazo;
create policy motivos_lee_con_sesion on public.motivos_rechazo
  for select to authenticated
  using (true);

drop policy if exists motivos_cambia_superadmin on public.motivos_rechazo;
create policy motivos_cambia_superadmin on public.motivos_rechazo
  for update to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

revoke all on function public._motivo_etiqueta(text, text) from public, anon, authenticated;

revoke all on function public.rechazar_recarga(uuid, text, text)                              from public, anon, authenticated;
revoke all on function public.procesar_retiro(uuid, public.withdraw_status, text, text)       from public, anon, authenticated;
grant execute on function public.rechazar_recarga(uuid, text, text)                           to authenticated;
grant execute on function public.procesar_retiro(uuid, public.withdraw_status, text, text)    to authenticated;
