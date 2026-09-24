-- ============================================================================
--  Bloque 2, tajada C - El cierre es el momento del cobro
--
--  Referencia: DISENO_SALDO_V2.md §6.2 y su correccion del 23/09/2026.
--
--  El dinero deja de moverse durante el remate (tajada B) y se mueve una sola
--  vez, aqui. A cada usuario se le debita la suma de las pujas que lidera en
--  este remate, sobre caballos no retirados.
--
--  VA EN _cerrar_remate_interno, NO EN cerrar_remate. El diseno original lo
--  ponia en cerrar_remate, pero esa funcion valida `es_admin` sobre auth.uid()
--  y el cron corre sin usuario. Desde la tarea 1.9 los dos caminos -el boton
--  del admin y auto_cerrar_remates- pasan por la interna. Si el cobro se pone
--  en la RPC con guarda, todo remate que cierre por horario (que es la mayoria)
--  queda cerrado sin cobrarle a nadie.
--
--  EL CRON PASA A MOVER DINERO. Hasta hoy solo cambiaba un estado. Por eso:
--
--  - El cambio de estado y los debitos van en la MISMA transaccion. Es una sola
--    funcion, asi que o pasa todo o no pasa nada.
--  - El cierre es idempotente por construccion: la primera linea toma el remate
--    `for update` y aborta si no esta 'abierto'. Dos ejecuciones simultaneas del
--    cron no pueden cobrar dos veces.
--  - Se toma el candado por usuario, el mismo de hacer_puja. Ver abajo.
--
--  ⚠️ NO SE APLICA SOLA. Junto con las tajadas B y D. Con B y C pero sin D,
--  liquidar_remate sigue esperando saldo_bloqueado y falla.
-- ============================================================================

-- Tipos de movimiento del modelo v2 (DISENO_SALDO_V2.md §5 y tarea 2.8).
-- `apuesta_devolucion` todavia no la usa nadie: entra aqui porque cancelar y
-- retirar caballo (tajada E) la necesitan, y agregar valores a un enum en una
-- migracion aparte solo por eso es ruido.
alter type public.wallet_movement_type add value if not exists 'apuesta_cobro';
alter type public.wallet_movement_type add value if not exists 'apuesta_devolucion';

create or replace function public._cerrar_remate_interno(p_remate_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_remate public.remates%rowtype;
  v_wallet public.wallets%rowtype;
  v_total  numeric := 0;
  v_users  int := 0;
  r        record;
begin
  select * into v_remate
  from public.remates
  where id = p_remate_id
  for update;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado <> 'abierto' then
    raise exception 'Solo puedes cerrar un remate en estado "abierto" (estado actual: %)', v_remate.estado;
  end if;

  -- COBRO A LOS LIDERES.
  --
  -- `order by lider.user_id` no es cosmetico: dos cierres simultaneos que tomen
  -- candados de usuario en orden distinto se trabarian entre si. Ordenando
  -- siempre igual, no puede haber ciclo.
  for r in
    select lider.user_id, sum(lider.monto) as total
    from (
      select distinct on (b.horse_id)
             b.user_id, b.monto
      from public.bids b
      join public.horses h on h.id = b.horse_id
      where b.remate_id = p_remate_id
        and coalesce(h.retirado, false) = false
      order by b.horse_id, b.monto desc, b.created_at asc
    ) lider
    group by lider.user_id
    order by lider.user_id
  loop
    -- Mismo candado que hacer_puja y que solicitar_retiro. Sin el, un retiro
    -- puede colarse entre la comprobacion de saldo de aqui abajo y el debito:
    -- las dos operaciones leerian el mismo estado viejo.
    perform pg_advisory_xact_lock(1, hashtext(r.user_id::text));

    select * into v_wallet
    from public.wallets
    where user_id = r.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el usuario %', r.user_id;
    end if;

    -- Esto NO deberia pasar nunca. El invariante saldo >= compromiso se valida
    -- en cada puja y en cada retiro, y entre que se puja y que se cierra el
    -- saldo de un usuario solo puede subir. Si salta, hay un bug en otra parte
    -- y lo que corresponde es enterarse, no cobrar de menos y seguir de largo.
    if v_wallet.saldo_disponible < r.total then
      raise exception 'Invariante roto al cerrar: el usuario % tiene % Bs y se le deben cobrar % Bs',
        r.user_id, v_wallet.saldo_disponible, r.total;
    end if;

    update public.wallets
       set saldo_disponible = saldo_disponible - r.total
     where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'apuesta_cobro', -r.total,
            'Cobro de pujas ganadas al cerrar el remate ' || v_remate.nombre,
            p_remate_id::text);

    v_total := v_total + r.total;
    v_users := v_users + 1;
  end loop;

  update public.remates
  set estado = 'cerrado',
      closed_at = now()
  where id = p_remate_id;

  return 'Remate cerrado. Cobrados ' || v_total::text || ' Bs a ' || v_users::text || ' usuario(s).';
end;
$fn$;

revoke all on function public._cerrar_remate_interno(uuid) from public, anon, authenticated;
