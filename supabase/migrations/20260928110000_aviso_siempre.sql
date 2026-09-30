-- ===========================================================================
--  20260928110000_aviso_siempre.sql
--
--  ARREGLA UNA INCONSISTENCIA MIA DE LA MIGRACION ANTERIOR
--
--  En 20260928100000 los dos avisos quedaron con reglas distintas sin que
--  eso fuera una decision:
--
--    porcentaje_casa -> escribia el aviso SIEMPRE
--    incremento      -> escribia el aviso SOLO si ya habia pujas
--
--  Jota lo encontro probando en produccion: cambio el incremento en un
--  remate sin pujas, guardo sin error, y no aparecio ningun aviso. Espero uno
--  y tenia razon en esperarlo.
--
--  Y la inconsistencia va al reves de lo que tendria sentido: el porcentaje
--  SOLO se puede cambiar cuando NO hay pujas, asi que su aviso siempre sale
--  en un remate sin pujas. El incremento se puede cambiar siempre, y era el
--  que se callaba en ese mismo caso.
--
--  LA REGLA, AHORA UNA SOLA: si el remate esta abierto, todo cambio visible
--  para el jugador deja aviso. Haya pujas o no.
--
--  Un remate abierto es un remate que la gente esta mirando. Alguien puede
--  estar leyendo las condiciones justo antes de pujar, y "todavia nadie ha
--  pujado" no es lo mismo que "nadie esta mirando". Ademas, guardar silencio
--  hasta la primera puja le da al admin una ventana para cambiar las
--  condiciones sin dejar rastro, que es justo lo contrario de para lo que
--  existe esta tabla.
-- ===========================================================================

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
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa,
                         'habia_pujas', v_hay_pujas),
      v_admin_id);

    v_cambios := v_cambios || jsonb_build_object('porcentaje_casa',
      jsonb_build_object('antes', v_rem.porcentaje_casa, 'despues', p_porcentaje_casa));
    v_rem.porcentaje_casa := p_porcentaje_casa;
  end if;

  -- ---------------- incremento de respaldo ----------------
  -- CAMBIO DEL 28/09: el aviso sale SIEMPRE, no solo si hay pujas. Un remate
  -- abierto es un remate que la gente esta mirando.
  if p_incremento_minimo is not null and p_incremento_minimo <> v_rem.incremento_minimo then
    if p_incremento_minimo <= 0 then
      raise exception 'El incremento tiene que ser mayor que cero';
    end if;

    insert into public.remate_avisos (remate_id, tipo, mensaje, detalles, created_by)
    values (p_remate_id, 'incremento',
      'El incremento fijo paso de ' || trim(to_char(v_rem.incremento_minimo,'FM999990.00')) ||
      ' a ' || trim(to_char(p_incremento_minimo,'FM999990.00')) || ' Bs.',
      jsonb_build_object('antes', v_rem.incremento_minimo, 'despues', p_incremento_minimo,
                         'habia_pujas', v_hay_pujas),
      v_admin_id);

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
