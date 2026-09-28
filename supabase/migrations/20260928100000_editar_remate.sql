-- ===========================================================================
--  20260928100000_editar_remate.sql
--
--  Tarea 3.2, tajada A: cerrar la escritura directa sobre `remates`.
--
--  EL AGUJERO QUE CIERRA, Y ERA PEOR DE LO QUE DECIA EL BACKLOG
--
--  La pantalla de edicion escribe `remates.estado` con un UPDATE directo. Y
--  liquidar_remate() solo exige que el estado sea 'cerrado'. Entonces esta
--  secuencia funcionaba entera, hoy, desde la aplicacion:
--
--    1. Poner estado = 'cerrado' a mano.  NO SE LE COBRA A NADIE:
--       _cerrar_remate_interno() no corre, asi que ningun lider paga.
--    2. Elegir ganador y liquidar. La RPC ve 'cerrado', calcula el pozo y
--       PAGA EL PREMIO.
--
--  Resultado: un premio pagado con dinero que nadie aporto. Es exactamente
--  el defecto que tenia el cron antes de la tarea 1.9 -- cerrar con un UPDATE
--  plano sin cobrar -- salvo que al cron se lo arreglamos y a este boton no.
--
--  Mientras esta puerta este abierta, TODAS las guardas del bloque 2 son
--  evitables.
--
--  LA REGLA, DECIDIDA CON JOTA EL 27/09
--
--  | campo              | abierto sin pujas | abierto con pujas | cerrado |
--  |--------------------|-------------------|-------------------|---------|
--  | estado             | solo por RPC      | solo por RPC      | RPC     |
--  | porcentaje_casa    | si                | NO                | NO      |
--  | incremento_minimo  | si                | si (con aviso)    | NO      |
--  | tipo               | si                | NO                | NO      |
--  | opens_at/closes_at | si                | si                | NO      |
--
--  `porcentaje_casa` se bloquea en cuanto hay una puja porque la gente pujo
--  sabiendo que el premio era el 75% del pozo. Cambiarlo despues es cambiar
--  el trato una vez que ya apostaron.
--
--  LOS AVISOS
--
--  Jota pidio que todo cambio visible para el jugador quede anunciado. Se
--  hace con la misma idea que el asiento `resultado_remate` del libro de la
--  casa (ADR-007): **lo escribe el sistema, no el admin**. Un aviso que
--  depende de que alguien se acuerde de escribirlo no es un aviso.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  Los avisos del remate. Los ve el jugador en la pantalla del remate.
-- ---------------------------------------------------------------------------
create table if not exists public.remate_avisos (
  id          uuid primary key default gen_random_uuid(),
  remate_id   uuid not null references public.remates(id) on delete cascade,
  tipo        text not null check (tipo in (
                'porcentaje_casa', 'incremento', 'escalera', 'precio_salida', 'caballo_retirado'
              )),
  mensaje     text not null,
  detalles    jsonb,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

comment on table public.remate_avisos is
  'Avisos visibles para los jugadores. Los escribe el sistema desde las RPC de edicion, nunca el admin a mano: un aviso que depende de que alguien se acuerde de escribirlo no es un aviso.';

create index if not exists idx_remate_avisos_remate on public.remate_avisos (remate_id, created_at desc);

alter table public.remate_avisos enable row level security;

-- Los avisos son publicos a proposito: son para que los jugadores los vean.
drop policy if exists remate_avisos_lectura on public.remate_avisos;
create policy remate_avisos_lectura on public.remate_avisos
  for select to anon, authenticated using (true);

-- Nadie escribe directo. Solo entran por RPC `security definer`.
revoke all on table public.remate_avisos from anon, authenticated;
grant select on table public.remate_avisos to anon, authenticated;


-- ---------------------------------------------------------------------------
--  editar_remate(): el unico camino para tocar un remate.
--
--  Recibe NULL en lo que no se quiere cambiar. Devuelve la fila resultante.
-- ---------------------------------------------------------------------------
create or replace function public.editar_remate(
  p_remate_id         uuid,
  p_porcentaje_casa   numeric default null,
  p_incremento_minimo numeric default null,
  p_tipo              text    default null,
  p_opens_at          timestamptz default null,
  p_closes_at         timestamptz default null
)
returns public.remates
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_rem      public.remates%rowtype;
  v_hay_pujas boolean;
  v_cambios  jsonb := '{}'::jsonb;
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

  -- Candado sobre el remate. Mismo espacio (2) que usa hacer_puja para el
  -- par remate:caballo, pero aqui se toma sobre el remate entero: no puede
  -- entrar una puja a mitad de una edicion que cambia el incremento.
  perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text));

  select * into v_rem from public.remates where id = p_remate_id for update;
  if not found then
    raise exception 'El remate no existe';
  end if;

  if v_rem.estado <> 'abierto' then
    raise exception 'El remate esta %. Solo se puede editar un remate abierto.', v_rem.estado;
  end if;

  select exists (select 1 from public.bids where remate_id = p_remate_id) into v_hay_pujas;

  -- ---------------- porcentaje de la casa ----------------
  if p_porcentaje_casa is not null and p_porcentaje_casa <> v_rem.porcentaje_casa then
    if v_hay_pujas then
      raise exception 'No se puede cambiar el porcentaje de la casa: el remate ya tiene pujas. La gente pujo sabiendo cual era el reparto.';
    end if;
    if p_porcentaje_casa < 0 or p_porcentaje_casa > 100 then
      raise exception 'El porcentaje de la casa va entre 0 y 100';
    end if;

    insert into public.remate_avisos (remate_id, tipo, mensaje, detalles, created_by)
    values (p_remate_id, 'porcentaje_casa',
      'La comision de la casa paso de ' || trim(to_char(v_rem.porcentaje_casa,'FM999990.00')) ||
      '% a ' || trim(to_char(p_porcentaje_casa,'FM999990.00')) || '%.',
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa),
      v_admin_id);

    v_cambios := v_cambios || jsonb_build_object('porcentaje_casa',
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa));
    v_rem.porcentaje_casa := p_porcentaje_casa;
  end if;

  -- ---------------- incremento de respaldo ----------------
  -- Este SI se puede cambiar con el remate en marcha: fue decision explicita
  -- de Jota el 27/09. Un remate que se estanca puede necesitar que suba mas
  -- rapido. Pero no en silencio.
  if p_incremento_minimo is not null and p_incremento_minimo <> v_rem.incremento_minimo then
    if p_incremento_minimo <= 0 then
      raise exception 'El incremento tiene que ser mayor que cero';
    end if;

    if v_hay_pujas then
      insert into public.remate_avisos (remate_id, tipo, mensaje, detalles, created_by)
      values (p_remate_id, 'incremento',
        'El incremento fijo paso de ' || trim(to_char(v_rem.incremento_minimo,'FM999990.00')) ||
        ' a ' || trim(to_char(p_incremento_minimo,'FM999990.00')) || ' Bs.',
        jsonb_build_object('antes', v_rem.incremento_minimo, 'despues', p_incremento_minimo),
        v_admin_id);
    end if;

    v_cambios := v_cambios || jsonb_build_object('incremento_minimo',
      jsonb_build_object('antes', v_rem.incremento_minimo, 'despues', p_incremento_minimo));
    v_rem.incremento_minimo := p_incremento_minimo;
  end if;

  -- ---------------- tipo ----------------
  if p_tipo is not null and p_tipo <> coalesce(v_rem.tipo,'vivo') then
    if v_hay_pujas then
      raise exception 'No se puede cambiar el tipo de remate: ya tiene pujas.';
    end if;
    if p_tipo not in ('vivo','adelantado') then
      raise exception 'Tipo no valido. Es vivo o adelantado.';
    end if;
    v_cambios := v_cambios || jsonb_build_object('tipo',
      jsonb_build_object('antes', v_rem.tipo, 'despues', p_tipo));
    v_rem.tipo := p_tipo;
  end if;

  -- ---------------- horarios ----------------
  if p_opens_at is not null then
    v_cambios := v_cambios || jsonb_build_object('opens_at',
      jsonb_build_object('antes', v_rem.opens_at, 'despues', p_opens_at));
    v_rem.opens_at := p_opens_at;
  end if;

  if p_closes_at is not null then
    v_cambios := v_cambios || jsonb_build_object('closes_at',
      jsonb_build_object('antes', v_rem.closes_at, 'despues', p_closes_at));
    v_rem.closes_at := p_closes_at;
  end if;

  if v_rem.opens_at is not null and v_rem.closes_at is not null
     and v_rem.closes_at <= v_rem.opens_at then
    raise exception 'La hora de cierre tiene que ser posterior a la de apertura';
  end if;

  -- `estado` NO esta en esta lista a proposito. Se cambia por cerrar_remate,
  -- cancelar_remate o archivar_remate, que son las que mueven el dinero.
  update public.remates
     set porcentaje_casa   = v_rem.porcentaje_casa,
         incremento_minimo = v_rem.incremento_minimo,
         tipo              = v_rem.tipo,
         opens_at          = v_rem.opens_at,
         closes_at         = v_rem.closes_at
   where id = p_remate_id
  returning * into v_rem;

  perform public.log_admin_action(
    v_admin_id, 'editar_remate', 'remates', p_remate_id::text,
    v_cambios, true, null);

  return v_rem;
end;
$fn$;

comment on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz) is
  'Unico camino para editar un remate. NO toca `estado`: eso es de cerrar/cancelar/archivar, que son las que mueven dinero. Escribe los avisos que ven los jugadores.';

revoke all on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz)
  to authenticated;


-- ---------------------------------------------------------------------------
--  Y AHORA LO QUE DE VERDAD CIERRA LA PUERTA
--
--  De nada sirve la RPC si el frontend puede seguir haciendo
--  supabase.from('remates').update({estado:'cerrado'}). Se revoca la
--  escritura directa. Las RPC son `security definer` y corren como postgres,
--  asi que siguen funcionando.
-- ---------------------------------------------------------------------------
revoke update, delete on table public.remates from anon, authenticated;
grant select on table public.remates to anon, authenticated;

-- ---------------------------------------------------------------------------
--  POR QUE NO SE REVOCA TAMBIEN `insert`
--
--  `app/admin/crear-remate/page.tsx` crea el remate con un insert directo.
--  Revocarlo aqui romperia la pantalla de crear, que es otra tarea (bloque 4,
--  `crear_remate_completo`). Se deja abierto A PROPOSITO y queda anotado.
--
--  El riesgo de dejarlo abierto es bajo y conviene decir por que, no solo que
--  lo es: un remate recien insertado no tiene pujas, asi que aunque alguien lo
--  creara ya con estado 'cerrado' y lo liquidara, todos los caballos serian de
--  la casa y el premio no saldria de ningun sitio. No mueve dinero de nadie.
--
--  El de `update` si lo movia, y ese es el que se cierra hoy.
-- ---------------------------------------------------------------------------
