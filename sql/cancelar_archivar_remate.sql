-- Cancelar y archivar remates (soft delete) con auditoría y devolución de saldos
-- ✅ Cancela remate activo (estado = 'abierto') y libera todo saldo bloqueado de ese remate
-- ✅ Archiva remate no abierto (cerrado/liquidado/cancelado) y lo oculta de vistas públicas

begin;

-- 1) Extiende enum de estado para permitir "cancelado"
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'remate_status'
      and e.enumlabel = 'cancelado'
  ) then
    alter type public.remate_status add value 'cancelado';
  end if;
end $$;

-- 2) Campos de auditoría
alter table public.remates
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancelled_reason text,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid,
  add column if not exists archived_reason text;

-- 3) RPC: cancelar remate activo (devuelve todo lo bloqueado)
create or replace function public.cancelar_remate(p_remate_id uuid, p_motivo text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;

-- 4) RPC: archivar remate (soft delete)
create or replace function public.archivar_remate(p_remate_id uuid, p_motivo text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;

revoke all on function public.cancelar_remate(uuid,text) from public;
grant execute on function public.cancelar_remate(uuid,text) to authenticated;
revoke all on function public.archivar_remate(uuid,text) from public;
grant execute on function public.archivar_remate(uuid,text) to authenticated;

commit;
