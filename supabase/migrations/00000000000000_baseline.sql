


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."deposit_status" AS ENUM (
    'pendiente',
    'aprobado',
    'rechazado'
);


ALTER TYPE "public"."deposit_status" OWNER TO "postgres";


CREATE TYPE "public"."race_status" AS ENUM (
    'programada',
    'en_remate',
    'cerrada',
    'finalizada'
);


ALTER TYPE "public"."race_status" OWNER TO "postgres";


CREATE TYPE "public"."remate_status" AS ENUM (
    'abierto',
    'cerrado',
    'liquidado',
    'cancelado'
);


ALTER TYPE "public"."remate_status" OWNER TO "postgres";


CREATE TYPE "public"."wallet_movement_type" AS ENUM (
    'recarga',
    'apuesta_bloqueo',
    'apuesta_liberacion',
    'premio',
    'ajuste_manual',
    'retiro'
);


ALTER TYPE "public"."wallet_movement_type" OWNER TO "postgres";


CREATE TYPE "public"."withdraw_status" AS ENUM (
    'pendiente',
    'pagado',
    'rechazado'
);


ALTER TYPE "public"."withdraw_status" OWNER TO "postgres";


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

  v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios;

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


ALTER FUNCTION "public"."admin_contabilidad_resumen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden aprobar recargas';
  end if;

  select * into v_request
  from public.deposit_requests
  where id = p_deposit_request_id;

  if not found then
    raise exception 'Solicitud de recarga no existe';
  end if;

  if v_request.estado <> 'pendiente' then
    raise exception 'La solicitud de recarga no esta pendiente (estado actual: %)', v_request.estado;
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = v_request.user_id
  for update;

  if not found then
    raise exception 'No se encontro wallet para el usuario de la recarga';
  end if;

  v_wallet.saldo_disponible := v_wallet.saldo_disponible + v_request.monto;

  update public.wallets
  set saldo_disponible = v_wallet.saldo_disponible
  where id = v_wallet.id;

  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'recarga'::wallet_movement_type,
    v_request.monto,
    'Recarga aprobada (metodo: ' || v_request.metodo || ', ref: ' || v_request.referencia || ')',
    v_request.id::text
  );

  update public.deposit_requests
  set estado = 'aprobado'::deposit_status,
      approved_at = now(),
      approved_by = v_user_id
  where id = v_request.id;

  perform public.log_admin_action(
    v_user_id,
    'aprobar_recarga',
    'deposit_requests',
    v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'aprobado'),
      'monto', v_request.monto,
      'user_id', v_request.user_id,
      'metodo', v_request.metodo,
      'referencia', v_request.referencia
    ),
    true,
    null
  );

  return 'Recarga aprobada y saldo acreditado';

exception
  when others then
    perform public.log_admin_action(
      v_user_id,
      'aprobar_recarga',
      'deposit_requests',
      coalesce(p_deposit_request_id::text, ''),
      jsonb_build_object(
        'next', jsonb_build_object('estado', 'aprobado')
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;


ALTER FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_remate public.remates%rowtype;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false)) into v_is_admin
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

  if v_remate.estado = 'abierto' then
    raise exception 'No puedes archivar un remate abierto';
  end if;

  if v_remate.archived_at is not null then
    raise exception 'Remate ya archivado';
  end if;

  update public.remates
  set archived_at = now(),
      archived_by = v_admin_id,
      archived_reason = trim(p_motivo)
  where id = p_remate_id;

  return '✅ Remate archivado';
end;
$$;


ALTER FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_cerrar_remates"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  update public.remates
  set estado = 'cerrado',
      closed_at = coalesce(closed_at, now())
  where estado = 'abierto'
    and closes_at is not null
    and closes_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."auto_cerrar_remates"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_remate public.remates%rowtype;
  r record;
  v_wallet public.wallets%rowtype;
  v_total_blocked numeric;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin,false) or coalesce(es_super_admin,false)) into v_is_admin
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

  if v_remate.estado <> 'abierto' then
    raise exception 'Solo puedes cancelar un remate abierto (estado actual: %)', v_remate.estado;
  end if;

  for r in
    select b.user_id, sum(b.monto)::numeric as total_blocked
    from public.bids b
    where b.remate_id = p_remate_id
    group by b.user_id
  loop
    v_total_blocked := coalesce(r.total_blocked,0);
    if v_total_blocked <= 0 then
      continue;
    end if;

    select * into v_wallet
    from public.wallets
    where user_id = r.user_id
    for update;

    if not found then
      raise exception 'No se encontró wallet para user_id %', r.user_id;
    end if;

    if v_wallet.saldo_bloqueado < v_total_blocked then
      raise exception 'Inconsistencia: wallet bloqueado (%) < total bloqueado remate (%) para user_id %',
        v_wallet.saldo_bloqueado, v_total_blocked, r.user_id;
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_total_blocked,
        saldo_bloqueado  = saldo_bloqueado  - v_total_blocked
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (
      v_wallet.id,
      'ajuste_manual'::wallet_movement_type,
      v_total_blocked,
      'Cancelación remate (devolución total): ' || v_remate.nombre,
      p_remate_id::text
    );
  end loop;

  update public.remates
  set estado = 'cancelado',
      cancelled_at = now(),
      cancelled_by = v_admin_id,
      cancelled_reason = trim(p_motivo)
  where id = p_remate_id;

  return '✅ Remate cancelado y saldos liberados';
end;
$$;


ALTER FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cerrar_remate"("p_remate_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  r record;
  v_wallet public.wallets%rowtype;
  v_release numeric;
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin, es_super_admin
    into v_is_admin, v_is_super
  from public.profiles
  where id = v_admin_id;

  if coalesce(v_is_admin,false) = false and coalesce(v_is_super,false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

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

  -- Libera solo lo perdido por caballo y mantiene bloqueado el ganador por caballo
  for r in
    with winners as (
      select distinct on (b.horse_id)
        b.horse_id,
        b.user_id,
        b.monto
      from public.bids b
      where b.remate_id = p_remate_id
      order by b.horse_id, b.monto desc, b.created_at asc
    ),
    user_max as (
      select b.user_id, b.horse_id, max(b.monto)::numeric as max_monto
      from public.bids b
      where b.remate_id = p_remate_id
      group by b.user_id, b.horse_id
    ),
    agg as (
      select
        m.user_id,
        sum(m.max_monto)::numeric as total_blocked,
        coalesce(sum(w.monto),0)::numeric as total_win
      from user_max m
      left join winners w
        on w.horse_id = m.horse_id and w.user_id = m.user_id
      group by m.user_id
    )
    select * from agg
  loop
    v_release := coalesce(r.total_blocked,0) - coalesce(r.total_win,0);

    if v_release > 0 then
      select * into v_wallet
      from public.wallets
      where user_id = r.user_id
      for update;

      if not found then
        raise exception 'No se encontro wallet para user_id %', r.user_id;
      end if;

      if v_wallet.saldo_bloqueado < v_release then
        raise exception 'Inconsistencia: saldo_bloqueado (%) < liberar (%) para user_id %',
          v_wallet.saldo_bloqueado, v_release, r.user_id;
      end if;

      update public.wallets
      set saldo_disponible = saldo_disponible + v_release,
          saldo_bloqueado  = saldo_bloqueado  - v_release
      where id = v_wallet.id;

      insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
      values (
        v_wallet.id,
        'apuesta_desbloqueo',
        v_release,
        'Liberacion por cierre remate ' || v_remate.nombre,
        p_remate_id::text
      );
    end if;
  end loop;

  update public.remates
  set estado = 'cerrado',
      closed_at = now()
  where id = p_remate_id;

  return 'Remate cerrado';
end;
$$;


ALTER FUNCTION "public"."cerrar_remate"("p_remate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_usernames"("p_ids" "uuid"[]) RETURNS TABLE("id" "uuid", "username" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, coalesce(p.username, '') as username
  from public.profiles p
  where p.id = any(p_ids);
$$;


ALTER FUNCTION "public"."get_usernames"("p_ids" "uuid"[]) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."bids" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "remate_id" "uuid" NOT NULL,
    "horse_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."bids" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean DEFAULT false) RETURNS "public"."bids"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  -- 4) Regla de incremento (prioriza por caballo; fallback a default horse_id null)
  select *
    into v_rule
  from public.remate_price_rules r
  where r.remate_id = p_remate_id
    and (r.horse_id is null or r.horse_id = p_horse_id)
    and v_ultimo_monto >= r.min_precio
    and (r.max_precio is null or v_ultimo_monto < r.max_precio)
  order by (r.horse_id = p_horse_id) desc, r.min_precio desc
  limit 1;

  if found then
    v_incremento := v_rule.incremento;
  else
    v_incremento := v_remate.incremento_minimo;
  end if;

  if v_incremento is null or v_incremento <= 0 then
    raise exception 'Incremento no válido para el remate';
  end if;

  -- 5) Mínimo permitido (auto)
  v_minimo_permitido := v_ultimo_monto + v_incremento;

  if v_minimo_permitido < v_remate.apuesta_minima then
    v_minimo_permitido := v_remate.apuesta_minima;
  end if;

  -- 6) Auto vs manual
  if coalesce(p_es_manual, false) = false then
    -- auto: "Ponerle"
    p_monto := v_minimo_permitido;
  else
    -- manual: debe ser al menos auto + 10
    if p_monto is null or p_monto < (v_minimo_permitido + 10) then
      raise exception 'Oferta manual mínima: % (auto: %)', (v_minimo_permitido + 10), v_minimo_permitido;
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
$$;


ALTER FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- profiles (usa metadata del usuario)
  insert into public.profiles (id, username, telefono, es_admin)
  values (
    new.id,
    nullif(new.raw_user_meta_data->>'username',''),
    nullif(new.raw_user_meta_data->>'telefono',''),
    false
  )
  on conflict (id) do update
    set username = excluded.username,
        telefono = excluded.telefono;

  -- wallets (si no existe)
  insert into public.wallets (user_id, saldo_disponible, saldo_bloqueado)
  values (new.id, 0, 0)
  on conflict (user_id) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select (es_admin or es_super_admin) from public.profiles where id = auth.uid()),
    false
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select es_super_admin from public.profiles where id = auth.uid()), false);
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."liquidar_remate"("p_remate_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_ganador_horse_id uuid;
  v_ganador_user_id uuid;
  v_pozo_total numeric := 0;
  v_premio numeric := 0;
  r record;
  v_wallet public.wallets%rowtype;
begin
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

  select ganador_horse_id
  into v_ganador_horse_id
  from public.race_results
  where race_id = v_remate.race_id;

  if v_ganador_horse_id is null then
    raise exception 'Debes indicar el caballo ganador antes de liquidar';
  end if;

  select coalesce(sum(coalesce(b.max_monto, h.precio_salida)), 0)
  into v_pozo_total
  from public.horses h
  left join (
    select horse_id, max(monto)::numeric as max_monto
    from public.bids
    where remate_id = p_remate_id
    group by horse_id
  ) b on b.horse_id = h.id
  where h.race_id = v_remate.race_id;

  select b.user_id
  into v_ganador_user_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id = v_ganador_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  if v_ganador_user_id is null then
    v_premio := 0;
  else
    v_premio := round(v_pozo_total * 0.75, 2);
  end if;

  -- Cobra (consume) los bloqueos de los ganadores por caballo
  for r in
    with winners as (
      select distinct on (b.horse_id)
        b.user_id,
        b.horse_id,
        b.monto
      from public.bids b
      where b.remate_id = p_remate_id
      order by b.horse_id, b.monto desc, b.created_at asc
    ),
    agg as (
      select
        user_id,
        sum(monto)::numeric as total_win
      from winners
      group by user_id
    )
    select * from agg
  loop
    select * into v_wallet
    from public.wallets
    where user_id = r.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para user_id %', r.user_id;
    end if;

    if v_wallet.saldo_bloqueado < r.total_win then
      raise exception 'Inconsistencia: bloqueado (%) < a cobrar (%) para user_id %',
        v_wallet.saldo_bloqueado, r.total_win, r.user_id;
    end if;

    update public.wallets
    set saldo_bloqueado = saldo_bloqueado - r.total_win
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (
      v_wallet.id,
      'ajuste_manual'::wallet_movement_type,
      -r.total_win,
      'Cobro por puja ganadora (liquidacion remate ' || v_remate.nombre || ')',
      p_remate_id::text
    );
  end loop;

  -- Paga premio al ganador de la carrera (si existe)
  if v_ganador_user_id is not null and v_premio > 0 then
    select * into v_wallet
    from public.wallets
    where user_id = v_ganador_user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para ganador';
    end if;

    update public.wallets
    set saldo_disponible = saldo_disponible + v_premio
    where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (
      v_wallet.id,
      'premio'::wallet_movement_type,
      v_premio,
      'Premio por remate (liquidacion remate ' || v_remate.nombre || ')',
      p_remate_id::text
    );
  end if;

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado';
end;
$$;


ALTER FUNCTION "public"."liquidar_remate"("p_remate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") RETURNS TABLE("horse_id" "uuid", "monto" numeric, "created_at" timestamp with time zone, "username" "text", "is_me" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
begin
  if p_remate_id is null then
    raise exception 'remate_id requerido';
  end if;

  return query
  select
    b.horse_id,
    b.monto,
    b.created_at,
    coalesce(p.username, '') as username,
    (v_uid is not null and b.user_id = v_uid) as is_me
  from public.bids b
  left join public.profiles p on p.id = b.user_id
  where b.remate_id = p_remate_id
  order by b.created_at desc;
end;
$$;


ALTER FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_wallets_superadmin"("p_query" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 50) RETURNS TABLE("user_id" "uuid", "username" "text", "email" "text", "saldo_disponible" numeric, "saldo_bloqueado" numeric, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_is_super boolean;
begin
  if v_uid is null then
    raise exception 'No autenticado';
  end if;

  select coalesce(es_super_admin,false) into v_is_super
  from public.profiles
  where id = v_uid;

  if coalesce(v_is_super,false) = false then
    raise exception 'No autorizado';
  end if;

  return query
  select
    w.user_id::uuid,
    p.username::text,
    u.email::text,
    w.saldo_disponible::numeric,
    w.saldo_bloqueado::numeric,
    w.created_at::timestamptz
  from public.wallets w
  join public.profiles p on p.id = w.user_id
  left join auth.users u on u.id = w.user_id
  where p_query is null
     or p.username ilike '%' || p_query || '%'
     or u.email ilike '%' || p_query || '%'
  order by w.created_at desc
  limit greatest(p_limit, 1);
end;
$$;


ALTER FUNCTION "public"."listar_wallets_superadmin"("p_query" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_admin_action"("p_admin_id" "uuid", "p_action" "text", "p_target_table" "text", "p_target_id" "text", "p_details" "jsonb", "p_success" boolean DEFAULT true, "p_error" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.admin_actions (
    admin_id, action, target_table, target_id, details, success, error
  ) values (
    p_admin_id,
    p_action,
    p_target_table,
    p_target_id,
    p_details,
    coalesce(p_success, true),
    p_error
  );
exception
  when others then
    -- Evita que un fallo de auditoría rompa la operación principal
    null;
end;
$$;


ALTER FUNCTION "public"."log_admin_action"("p_admin_id" "uuid", "p_action" "text", "p_target_table" "text", "p_target_id" "text", "p_details" "jsonb", "p_success" boolean, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mi_wallet_resumen"() RETURNS TABLE("saldo_disponible" numeric, "saldo_bloqueado" numeric)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    w.saldo_disponible,
    w.saldo_bloqueado
  from public.wallets w
  where w.user_id = auth.uid()
  limit 1;
$$;


ALTER FUNCTION "public"."mi_wallet_resumen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.withdraw_requests%rowtype;
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden procesar retiros';
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

  if p_nuevo_estado = 'pagado' then
    update public.withdraw_requests
    set estado = 'pagado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id
    where id = v_request.id;

    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'pagado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true,
      null
    );

    return 'Retiro marcado como pagado';

  elsif p_nuevo_estado = 'rechazado' then
    select * into v_wallet
    from public.wallets
    where user_id = v_request.user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el usuario del retiro';
    end if;

    v_wallet.saldo_disponible := v_wallet.saldo_disponible + v_request.monto;

    update public.wallets
    set saldo_disponible = v_wallet.saldo_disponible
    where id = v_wallet.id;

    insert into public.wallet_movements (
      wallet_id, tipo, monto, descripcion, ref_externa
    ) values (
      v_wallet.id,
      'ajuste_manual'::wallet_movement_type,
      v_request.monto,
      'Devolucion de retiro rechazado',
      v_request.id::text
    );

    update public.withdraw_requests
    set estado = 'rechazado'::withdraw_status,
        processed_at = now(),
        processed_by = v_user_id
    where id = v_request.id;

    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      v_request.id::text,
      jsonb_build_object(
        'prev', jsonb_build_object('estado', v_request.estado),
        'next', jsonb_build_object('estado', 'rechazado'),
        'monto', v_request.monto,
        'user_id', v_request.user_id,
        'metodo', v_request.metodo,
        'telefono_destino', v_request.telefono_destino
      ),
      true,
      null
    );

    return 'Retiro rechazado y saldo devuelto al usuario';
  else
    raise exception 'Estado no soportado. Use ''pagado'' o ''rechazado''';
  end if;

exception
  when others then
    perform public.log_admin_action(
      v_user_id,
      'procesar_retiro',
      'withdraw_requests',
      coalesce(p_withdraw_id::text, ''),
      jsonb_build_object(
        'next', jsonb_build_object('estado', p_nuevo_estado)
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;


ALTER FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."promover_usuario"("p_target_user_id" "uuid", "p_es_admin" boolean, "p_es_super" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_caller_id uuid := auth.uid();
  v_caller_super boolean;
  v_target_super_actual boolean;
  v_supers_restantes integer;
begin
  if v_caller_id is null then
    raise exception 'No autenticado';
  end if;

  -- Serializa cambios de roles para evitar carreras
  perform pg_advisory_xact_lock(hashtext('promover_usuario_superadmin_guard'));

  -- Solo superadmin puede ejecutar
  select es_super_admin
    into v_caller_super
  from public.profiles
  where id = v_caller_id;

  if not coalesce(v_caller_super, false) then
    raise exception 'Acceso denegado: requiere superadmin';
  end if;

  -- Regla de consistencia: superadmin => admin
  if p_es_super and not p_es_admin then
    raise exception 'Inconsistencia: es_super_admin=true requiere es_admin=true';
  end if;

  -- Lock fila objetivo
  select es_super_admin
    into v_target_super_actual
  from public.profiles
  where id = p_target_user_id
  for update;

  if not found then
    raise exception 'Usuario objetivo no existe';
  end if;

  -- Evitar auto-democión accidental de superadmin
  if p_target_user_id = v_caller_id and coalesce(v_target_super_actual,false) and not p_es_super then
    raise exception 'No puedes quitarte a ti mismo el rol superadmin';
  end if;

  -- Evitar dejar el sistema sin superadmins
  if coalesce(v_target_super_actual,false) and not p_es_super then
    select count(*)
      into v_supers_restantes
    from public.profiles
    where es_super_admin = true
      and id <> p_target_user_id;

    if coalesce(v_supers_restantes, 0) = 0 then
      raise exception 'Operación bloqueada: no puedes dejar el sistema sin superadmin';
    end if;
  end if;

  update public.profiles
     set es_admin = p_es_admin,
         es_super_admin = p_es_super
   where id = p_target_user_id;
end;
$$;


ALTER FUNCTION "public"."promover_usuario"("p_target_user_id" "uuid", "p_es_admin" boolean, "p_es_super" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rechazar_recarga"("p_deposit_request_id" "uuid", "p_reason" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if v_admin_id is null then
    raise exception 'No autenticado';
  end if;

  if p_deposit_request_id is null then
    raise exception 'Parametro invalido';
  end if;

  if v_reason = '' then
    raise exception 'Motivo requerido';
  end if;

  if not public.is_admin() then
    raise exception 'No autorizado: solo administradores pueden rechazar recargas';
  end if;

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
      approved_by = v_admin_id
  where id = v_request.id;

  perform public.log_admin_action(
    v_admin_id,
    'rechazar_recarga',
    'deposit_requests',
    v_request.id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('estado', v_request.estado),
      'next', jsonb_build_object('estado', 'rechazado'),
      'reason', v_reason
    ),
    true,
    null
  );

  return 'Recarga rechazada';

exception
  when others then
    perform public.log_admin_action(
      v_admin_id,
      'rechazar_recarga',
      'deposit_requests',
      coalesce(p_deposit_request_id::text, ''),
      jsonb_build_object(
        'reason', v_reason
      ),
      false,
      sqlerrm
    );
    raise;
end;
$$;


ALTER FUNCTION "public"."rechazar_recarga"("p_deposit_request_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resumen_casa"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_is_admin boolean;

  v_total_recargas numeric(14,2);
  v_total_premios numeric(14,2);
  v_total_retiros numeric(14,2);
  v_saldo_usuarios numeric(14,2);
  v_dinero_casa numeric(14,2);
begin
  -- 0. Solo admin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  select es_admin
  into v_is_admin
  from public.profiles
  where id = v_user_id;

  if coalesce(v_is_admin, false) = false then
    raise exception 'No autorizado: solo administradores pueden ver el resumen de la casa';
  end if;

  -- 1. Totales básicos
  select coalesce(sum(monto), 0)
  into v_total_recargas
  from public.wallet_movements
  where tipo = 'recarga';

  select coalesce(sum(monto), 0)
  into v_total_premios
  from public.wallet_movements
  where tipo = 'premio';

  select coalesce(sum(monto), 0)
  into v_total_retiros
  from public.wallet_movements
  where tipo = 'retiro';

  select coalesce(sum(saldo_disponible + saldo_bloqueado), 0)
  into v_saldo_usuarios
  from public.wallets;

  -- 2. Dinero de la casa
  v_dinero_casa := v_total_recargas - v_total_premios - v_total_retiros - v_saldo_usuarios;

  -- 3. Devolver JSON
  return jsonb_build_object(
    'total_recargas', v_total_recargas,
    'total_premios',   v_total_premios,
    'total_retiros',   v_total_retiros,
    'saldo_usuarios',  v_saldo_usuarios,
    'dinero_casa',     v_dinero_casa
  );
end;
$$;


ALTER FUNCTION "public"."resumen_casa"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_admin"("p_user_id" "uuid", "p_is_admin" boolean) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_actor_id uuid := auth.uid();
  v_is_super boolean;
  v_target public.profiles%rowtype;
  v_prev_admin boolean;
begin
  if v_actor_id is null then
    raise exception 'No autenticado';
  end if;

  if p_user_id is null or p_is_admin is null then
    raise exception 'Parametros invalidos';
  end if;

  select es_super_admin into v_is_super
  from public.profiles
  where id = v_actor_id;

  if coalesce(v_is_super, false) = false then
    raise exception 'No autorizado: solo super admin';
  end if;

  select * into v_target
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Usuario no existe';
  end if;

  v_prev_admin := v_target.es_admin;

  update public.profiles
  set es_admin = p_is_admin
  where id = p_user_id;

  insert into public.admin_actions (
    admin_id, action, target_table, target_id, details, success
  ) values (
    v_actor_id,
    'set_admin',
    'profiles',
    p_user_id::text,
    jsonb_build_object(
      'prev', jsonb_build_object('es_admin', v_prev_admin),
      'next', jsonb_build_object('es_admin', p_is_admin)
    ),
    true
  );

  return case when p_is_admin then 'Admin otorgado' else 'Admin revocado' end;

exception
  when others then
    if v_actor_id is not null then
      insert into public.admin_actions (
        admin_id, action, target_table, target_id, details, success, error
      ) values (
        v_actor_id,
        'set_admin',
        'profiles',
        coalesce(p_user_id::text, ''),
        jsonb_build_object(
          'next', jsonb_build_object('es_admin', p_is_admin)
        ),
        false,
        sqlerrm
      );
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."set_admin"("p_user_id" "uuid", "p_is_admin" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_race_id uuid;
  v_horse_id uuid;
begin
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
  where id = p_remate_id;

  if not found then
    raise exception 'Remate no existe';
  end if;

  if v_remate.estado <> 'cerrado' then
    raise exception 'Para liquidar, el remate debe estar "cerrado" (estado actual: %)', v_remate.estado;
  end if;

  v_race_id := v_remate.race_id;

  select id into v_horse_id
  from public.horses
  where race_id = v_race_id
    and numero = p_horse_num;

  if not found then
    raise exception 'No existe un caballo con ese numero en esta carrera';
  end if;

  update public.race_results
  set ganador_horse_id = v_horse_id,
      created_at = now()
  where race_id = v_race_id;

  if not found then
    insert into public.race_results (race_id, ganador_horse_id)
    values (v_race_id, v_horse_id);
  end if;

  return v_horse_id;
end;
$$;


ALTER FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_support_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_support_settings_updated_at"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deposit_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "metodo" "text" NOT NULL,
    "telefono_pago" "text" NOT NULL,
    "referencia" "text" NOT NULL,
    "fecha_pago" "date" NOT NULL,
    "estado" "public"."deposit_status" DEFAULT 'pendiente'::"public"."deposit_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "approved_at" timestamp with time zone,
    "approved_by" "uuid"
);


ALTER TABLE "public"."deposit_requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") RETURNS "public"."deposit_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_request public.deposit_requests%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a 0';
  end if;

  if p_metodo is null or length(trim(p_metodo)) = 0 then
    raise exception 'Debe especificar el método de pago';
  end if;

  if p_telefono_pago is null or length(trim(p_telefono_pago)) = 0 then
    raise exception 'Debe especificar el teléfono desde el que se realizó el pago';
  end if;

  if p_referencia is null or length(trim(p_referencia)) = 0 then
    raise exception 'Debe especificar la referencia del pago';
  end if;

  if p_fecha_pago is null then
    raise exception 'Debe especificar la fecha del pago';
  end if;

  insert into public.deposit_requests (
    user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado
  ) values (
    v_user_id, p_monto, p_metodo, p_telefono_pago, p_referencia, p_fecha_pago, 'pendiente'::deposit_status
  )
  returning * into v_request;

  return v_request;
end;
$$;


ALTER FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."withdraw_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "metodo" "text" NOT NULL,
    "telefono_destino" "text" NOT NULL,
    "comentario" "text",
    "estado" "public"."withdraw_status" DEFAULT 'pendiente'::"public"."withdraw_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "processed_at" timestamp with time zone,
    "processed_by" "uuid"
);


ALTER TABLE "public"."withdraw_requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text" DEFAULT NULL::"text") RETURNS "public"."withdraw_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_wallet public.wallets%rowtype;
  v_request public.withdraw_requests%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a 0';
  end if;

  if p_metodo is null or length(trim(p_metodo)) = 0 then
    raise exception 'Debe especificar el método de retiro';
  end if;

  if p_telefono_destino is null or length(trim(p_telefono_destino)) = 0 then
    raise exception 'Debe especificar el teléfono destino';
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontró wallet para el usuario';
  end if;

  if v_wallet.saldo_disponible < p_monto then
    raise exception 'Saldo insuficiente para retirar (disponible: %, solicitado: %)',
      v_wallet.saldo_disponible, p_monto;
  end if;

  v_wallet.saldo_disponible := v_wallet.saldo_disponible - p_monto;

  update public.wallets
  set saldo_disponible = v_wallet.saldo_disponible
  where id = v_wallet.id;

  insert into public.withdraw_requests (
    user_id, monto, metodo, telefono_destino, comentario, estado
  ) values (
    v_user_id, p_monto, p_metodo, p_telefono_destino, p_comentario, 'pendiente'::withdraw_status
  )
  returning * into v_request;

  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'retiro'::wallet_movement_type,
    -p_monto,
    'Solicitud de retiro (método: ' || p_metodo || ')',
    v_request.id::text
  );

  return v_request;
end;
$$;


ALTER FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tr_check_admin_immutability"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if new.es_admin is distinct from old.es_admin
     or new.es_super_admin is distinct from old.es_super_admin then

    -- Solo roles internos de BD pueden tocar flags directamente.
    if current_user not in ('postgres', 'supabase_admin') then
      raise exception 'Modificación de roles restringida.';
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."tr_check_admin_immutability"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "target_table" "text" NOT NULL,
    "target_id" "text" NOT NULL,
    "details" "jsonb",
    "success" boolean DEFAULT true NOT NULL,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."admin_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."horses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "race_id" "uuid" NOT NULL,
    "numero" integer NOT NULL,
    "nombre" "text" NOT NULL,
    "jinete" "text",
    "entrenador" "text",
    "comentarios" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "precio_salida" numeric DEFAULT 60 NOT NULL,
    "retirado" boolean DEFAULT false
);


ALTER TABLE "public"."horses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text",
    "telefono" "text",
    "pais" "text",
    "es_admin" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "es_super_admin" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."race_results" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "race_id" "uuid" NOT NULL,
    "ganador_horse_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."race_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."races" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre" "text" NOT NULL,
    "hipodromo" "text",
    "numero_carrera" integer,
    "fecha" "date" NOT NULL,
    "hora_programada" time without time zone,
    "estado" "public"."race_status" DEFAULT 'programada'::"public"."race_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "dia" "text",
    "numero_carrera_text" "text",
    "distancia_m" numeric
);


ALTER TABLE "public"."races" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."remate_price_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "remate_id" "uuid" NOT NULL,
    "min_precio" numeric(12,2) NOT NULL,
    "max_precio" numeric(12,2),
    "incremento" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "horse_id" "uuid"
);


ALTER TABLE "public"."remate_price_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."remates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "race_id" "uuid" NOT NULL,
    "nombre" "text" NOT NULL,
    "estado" "public"."remate_status" DEFAULT 'abierto'::"public"."remate_status" NOT NULL,
    "incremento_minimo" numeric(12,2) DEFAULT 1 NOT NULL,
    "apuesta_minima" numeric(12,2) DEFAULT 40 NOT NULL,
    "porcentaje_casa" numeric(5,2) DEFAULT 20.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "closed_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "cancelled_by" "uuid",
    "cancelled_reason" "text",
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "archived_reason" "text",
    "opens_at" timestamp with time zone DEFAULT "now"(),
    "closes_at" timestamp with time zone,
    "tipo" "text" DEFAULT 'vivo'::"text",
    CONSTRAINT "remates_tipo_check" CHECK (("tipo" = ANY (ARRAY['vivo'::"text", 'adelantado'::"text"])))
);


ALTER TABLE "public"."remates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "label" "text" NOT NULL,
    "value" "text" NOT NULL,
    "type" "text" NOT NULL,
    "href" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "support_settings_type_check" CHECK (("type" = ANY (ARRAY['email'::"text", 'whatsapp'::"text", 'phone'::"text", 'social'::"text"])))
);


ALTER TABLE "public"."support_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_movements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "wallet_id" "uuid" NOT NULL,
    "tipo" "public"."wallet_movement_type" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "descripcion" "text",
    "ref_externa" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."wallet_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "saldo_disponible" numeric(12,2) DEFAULT 0 NOT NULL,
    "saldo_bloqueado" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."wallets" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_actions"
    ADD CONSTRAINT "admin_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deposit_requests"
    ADD CONSTRAINT "deposit_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."horses"
    ADD CONSTRAINT "horses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."horses"
    ADD CONSTRAINT "horses_race_id_numero_key" UNIQUE ("race_id", "numero");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."race_results"
    ADD CONSTRAINT "race_results_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."races"
    ADD CONSTRAINT "races_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."remate_price_rules"
    ADD CONSTRAINT "remate_price_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."remates"
    ADD CONSTRAINT "remates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_settings"
    ADD CONSTRAINT "support_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallet_movements"
    ADD CONSTRAINT "wallet_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."withdraw_requests"
    ADD CONSTRAINT "withdraw_requests_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_bids_horse_id" ON "public"."bids" USING "btree" ("horse_id");



CREATE INDEX "idx_bids_remate_id" ON "public"."bids" USING "btree" ("remate_id");



CREATE INDEX "idx_bids_user_id" ON "public"."bids" USING "btree" ("user_id");



CREATE INDEX "idx_deposit_requests_user_id" ON "public"."deposit_requests" USING "btree" ("user_id");



CREATE INDEX "idx_horses_race_id" ON "public"."horses" USING "btree" ("race_id");



CREATE INDEX "idx_race_results_race_id" ON "public"."race_results" USING "btree" ("race_id");



CREATE INDEX "idx_remate_price_rules_remate_id" ON "public"."remate_price_rules" USING "btree" ("remate_id");



CREATE INDEX "idx_remates_race_id" ON "public"."remates" USING "btree" ("race_id");



CREATE INDEX "idx_wallet_movements_wallet_id" ON "public"."wallet_movements" USING "btree" ("wallet_id");



CREATE INDEX "idx_withdraw_requests_user_id" ON "public"."withdraw_requests" USING "btree" ("user_id");



CREATE INDEX "remate_price_rules_lookup_idx" ON "public"."remate_price_rules" USING "btree" ("remate_id", "horse_id", "min_precio");



CREATE OR REPLACE TRIGGER "enforce_admin_immutability" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."tr_check_admin_immutability"();



CREATE OR REPLACE TRIGGER "trg_support_settings_updated_at" BEFORE UPDATE ON "public"."support_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_support_settings_updated_at"();



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_horse_id_fkey" FOREIGN KEY ("horse_id") REFERENCES "public"."horses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_remate_id_fkey" FOREIGN KEY ("remate_id") REFERENCES "public"."remates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bids"
    ADD CONSTRAINT "bids_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."deposit_requests"
    ADD CONSTRAINT "deposit_requests_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."deposit_requests"
    ADD CONSTRAINT "deposit_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."horses"
    ADD CONSTRAINT "horses_race_id_fkey" FOREIGN KEY ("race_id") REFERENCES "public"."races"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."race_results"
    ADD CONSTRAINT "race_results_ganador_horse_id_fkey" FOREIGN KEY ("ganador_horse_id") REFERENCES "public"."horses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."race_results"
    ADD CONSTRAINT "race_results_race_id_fkey" FOREIGN KEY ("race_id") REFERENCES "public"."races"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."remate_price_rules"
    ADD CONSTRAINT "remate_price_rules_horse_id_fkey" FOREIGN KEY ("horse_id") REFERENCES "public"."horses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."remate_price_rules"
    ADD CONSTRAINT "remate_price_rules_remate_id_fkey" FOREIGN KEY ("remate_id") REFERENCES "public"."remates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."remates"
    ADD CONSTRAINT "remates_race_id_fkey" FOREIGN KEY ("race_id") REFERENCES "public"."races"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallet_movements"
    ADD CONSTRAINT "wallet_movements_wallet_id_fkey" FOREIGN KEY ("wallet_id") REFERENCES "public"."wallets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."withdraw_requests"
    ADD CONSTRAINT "withdraw_requests_processed_by_fkey" FOREIGN KEY ("processed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."withdraw_requests"
    ADD CONSTRAINT "withdraw_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE "public"."admin_actions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_actions_admin_select" ON "public"."admin_actions" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."bids" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bids_admin_all" ON "public"."bids" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "deposit_admin_all" ON "public"."deposit_requests" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "deposit_insert_own_pendiente" ON "public"."deposit_requests" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("estado" = 'pendiente'::"public"."deposit_status") AND ("approved_by" IS NULL) AND ("approved_at" IS NULL)));



ALTER TABLE "public"."deposit_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "deposit_select_own" ON "public"."deposit_requests" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."horses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "horses_admin_all" ON "public"."horses" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "horses_admin_insert_v1" ON "public"."horses" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "horses_admin_select_v1" ON "public"."horses" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "horses_admin_update_v1" ON "public"."horses" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "horses_public_select" ON "public"."horses" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "horses_select_auth" ON "public"."horses" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_admin_all" ON "public"."profiles" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."race_results" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."races" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "races_admin_all" ON "public"."races" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "races_admin_insert_v1" ON "public"."races" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "races_admin_select_v1" ON "public"."races" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "races_admin_update_v1" ON "public"."races" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "races_public_select" ON "public"."races" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "races_select_auth" ON "public"."races" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."remate_price_rules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "remate_price_rules_public_select" ON "public"."remate_price_rules" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."remates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "remates_admin_all" ON "public"."remates" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "remates_admin_insert_v1" ON "public"."remates" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "remates_admin_select_v1" ON "public"."remates" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "remates_admin_update_v1" ON "public"."remates" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "remates_public_select" ON "public"."remates" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "remates_select_auth" ON "public"."remates" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "results_admin_all" ON "public"."race_results" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "results_select_auth" ON "public"."race_results" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "rules_admin_all" ON "public"."remate_price_rules" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "rules_select_auth" ON "public"."remate_price_rules" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."support_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "support_settings_public_read" ON "public"."support_settings" FOR SELECT TO "authenticated", "anon" USING (("is_active" = true));



CREATE POLICY "support_settings_superadmin_write" ON "public"."support_settings" TO "authenticated" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."wallet_movements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wallet_movements_admin_all" ON "public"."wallet_movements" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "wallet_movements_select_own" ON "public"."wallet_movements" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."wallets" "w"
  WHERE (("w"."id" = "wallet_movements"."wallet_id") AND ("w"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."wallets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wallets_admin_all" ON "public"."wallets" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "wallets_select_own" ON "public"."wallets" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "withdraw_admin_all" ON "public"."withdraw_requests" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "withdraw_insert_own_pendiente" ON "public"."withdraw_requests" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND ("estado" = 'pendiente'::"public"."withdraw_status") AND ("processed_by" IS NULL) AND ("processed_at" IS NULL)));



ALTER TABLE "public"."withdraw_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "withdraw_select_own" ON "public"."withdraw_requests" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_contabilidad_resumen"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_contabilidad_resumen"() TO "anon";
GRANT ALL ON FUNCTION "public"."admin_contabilidad_resumen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_contabilidad_resumen"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."aprobar_recarga"("p_deposit_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."archivar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_cerrar_remates"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_cerrar_remates"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_cerrar_remates"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancelar_remate"("p_remate_id" "uuid", "p_motivo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cerrar_remate"("p_remate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cerrar_remate"("p_remate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cerrar_remate"("p_remate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_usernames"("p_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_usernames"("p_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_usernames"("p_ids" "uuid"[]) TO "service_role";



GRANT ALL ON TABLE "public"."bids" TO "service_role";
GRANT SELECT ON TABLE "public"."bids" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hacer_puja"("p_remate_id" "uuid", "p_horse_id" "uuid", "p_monto" numeric, "p_es_manual" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."liquidar_remate"("p_remate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."liquidar_remate"("p_remate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."liquidar_remate"("p_remate_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_pujas_publicas"("p_remate_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_wallets_superadmin"("p_query" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_wallets_superadmin"("p_query" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."listar_wallets_superadmin"("p_query" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_wallets_superadmin"("p_query" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."log_admin_action"("p_admin_id" "uuid", "p_action" "text", "p_target_table" "text", "p_target_id" "text", "p_details" "jsonb", "p_success" boolean, "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."log_admin_action"("p_admin_id" "uuid", "p_action" "text", "p_target_table" "text", "p_target_id" "text", "p_details" "jsonb", "p_success" boolean, "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_admin_action"("p_admin_id" "uuid", "p_action" "text", "p_target_table" "text", "p_target_id" "text", "p_details" "jsonb", "p_success" boolean, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mi_wallet_resumen"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mi_wallet_resumen"() TO "anon";
GRANT ALL ON FUNCTION "public"."mi_wallet_resumen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mi_wallet_resumen"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") TO "anon";
GRANT ALL ON FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") TO "authenticated";
GRANT ALL ON FUNCTION "public"."procesar_retiro"("p_withdraw_id" "uuid", "p_nuevo_estado" "public"."withdraw_status") TO "service_role";



REVOKE ALL ON FUNCTION "public"."promover_usuario"("p_target_user_id" "uuid", "p_es_admin" boolean, "p_es_super" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."promover_usuario"("p_target_user_id" "uuid", "p_es_admin" boolean, "p_es_super" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."promover_usuario"("p_target_user_id" "uuid", "p_es_admin" boolean, "p_es_super" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."rechazar_recarga"("p_deposit_request_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rechazar_recarga"("p_deposit_request_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rechazar_recarga"("p_deposit_request_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resumen_casa"() TO "anon";
GRANT ALL ON FUNCTION "public"."resumen_casa"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."resumen_casa"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_admin"("p_user_id" "uuid", "p_is_admin" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_admin"("p_user_id" "uuid", "p_is_admin" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_admin"("p_user_id" "uuid", "p_is_admin" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_ganador_carrera"("p_remate_id" "uuid", "p_horse_num" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_support_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_support_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_support_settings_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."deposit_requests" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."deposit_requests" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."solicitar_recarga"("p_monto" numeric, "p_metodo" "text", "p_telefono_pago" "text", "p_referencia" "text", "p_fecha_pago" "date") TO "service_role";



GRANT ALL ON TABLE "public"."withdraw_requests" TO "service_role";
GRANT SELECT ON TABLE "public"."withdraw_requests" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."solicitar_retiro"("p_monto" numeric, "p_metodo" "text", "p_telefono_destino" "text", "p_comentario" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tr_check_admin_immutability"() TO "anon";
GRANT ALL ON FUNCTION "public"."tr_check_admin_immutability"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tr_check_admin_immutability"() TO "service_role";



GRANT ALL ON TABLE "public"."admin_actions" TO "service_role";
GRANT SELECT ON TABLE "public"."admin_actions" TO "authenticated";



GRANT ALL ON TABLE "public"."horses" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."horses" TO "authenticated";
GRANT SELECT ON TABLE "public"."horses" TO "anon";



GRANT ALL ON TABLE "public"."profiles" TO "service_role";
GRANT SELECT ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("username") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("telefono") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("pais") ON TABLE "public"."profiles" TO "authenticated";



GRANT ALL ON TABLE "public"."race_results" TO "service_role";
GRANT SELECT ON TABLE "public"."race_results" TO "authenticated";



GRANT ALL ON TABLE "public"."races" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."races" TO "authenticated";
GRANT SELECT ON TABLE "public"."races" TO "anon";



GRANT ALL ON TABLE "public"."remate_price_rules" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."remate_price_rules" TO "authenticated";
GRANT SELECT ON TABLE "public"."remate_price_rules" TO "anon";



GRANT ALL ON TABLE "public"."remates" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."remates" TO "authenticated";
GRANT SELECT ON TABLE "public"."remates" TO "anon";



GRANT ALL ON TABLE "public"."support_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."support_settings" TO "anon";
GRANT SELECT ON TABLE "public"."support_settings" TO "authenticated";



GRANT ALL ON TABLE "public"."wallet_movements" TO "service_role";
GRANT SELECT ON TABLE "public"."wallet_movements" TO "authenticated";



GRANT ALL ON TABLE "public"."wallets" TO "service_role";
GRANT SELECT ON TABLE "public"."wallets" TO "authenticated";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







