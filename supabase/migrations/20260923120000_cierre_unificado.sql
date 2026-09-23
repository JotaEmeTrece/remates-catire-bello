-- ============================================================================
--  Tareas 1.8 + 1.9 - Una sola ruta de cierre, sin liberacion de saldos
--
--  1.8  cerrar_remate tenia un bucle que liberaba saldo usando `user_max`, que
--       cuenta los caballos donde al usuario YA lo superaron y ya se le
--       devolvio el dinero. Reproducido: liberaba de mas, y despues
--       liquidar_remate fallaba con "Inconsistencia" dejando el remate trabado
--       en `cerrado`, sin ruta de salida.
--
--       Bajo el modelo de bloqueo actual, lo que un usuario tiene bloqueado al
--       cerrar ES exactamente la suma de sus pujas lideres: hacer_puja ya le
--       devolvio todo lo demas en el momento del sobrepuje. `v_release`
--       deberia ser siempre 0. El bucle no aporta nada y si rompe: se elimina.
--
--  1.9  auto_cerrar_remates hacia un UPDATE plano y no llamaba a cerrar_remate.
--       Dos comportamientos distintos para la misma transicion de estado.
--       Ahora ambos pasan por _cerrar_remate_interno.
--
--  Nota de diseno: cerrar_remate valida auth.uid(), y el cron corre SIN
--  usuario. Por eso la logica se extrae a _cerrar_remate_interno, sin guarda
--  de rol, y se le revoca el execute a anon y authenticated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Logica interna del cierre, SIN guarda de rol.
-- El cron corre sin usuario (auth.uid() es null), asi que no puede pasar por
-- cerrar_remate directamente. Ambos caminos llaman aqui.
-- ---------------------------------------------------------------------------
create or replace function public._cerrar_remate_interno(p_remate_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_remate public.remates%rowtype;
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

  update public.remates
  set estado = 'cerrado',
      closed_at = now()
  where id = p_remate_id;

  return 'Remate cerrado';
end;
$fn$;

revoke all on function public._cerrar_remate_interno(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- cerrar_remate: valida el rol y delega. Ya NO libera saldos (tarea 1.8).
-- ---------------------------------------------------------------------------
create or replace function public.cerrar_remate(p_remate_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
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

  return public._cerrar_remate_interno(p_remate_id);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- auto_cerrar_remates: MISMA ruta que el boton (tarea 1.9).
-- Antes hacia un UPDATE plano, saltandose cerrar_remate por completo. Hoy da
-- igual porque cerrar es solo un cambio de estado, pero a partir del bloque 2
-- el cierre COBRA, y un cron que se salte la RPC dejaria remates cerrados sin
-- cobrarle a nadie.
--
-- Un remate que falle queda registrado y no impide que el resto del lote cierre.
-- ---------------------------------------------------------------------------
create or replace function public.auto_cerrar_remates()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id from public.remates
    where estado = 'abierto'
      and closes_at is not null
      and closes_at <= now()
    order by closes_at
  loop
    begin
      perform public._cerrar_remate_interno(r.id);
      v_count := v_count + 1;
    exception when others then
      perform public.log_admin_action(
        null, 'auto_cerrar_remates', 'remates', r.id::text,
        jsonb_build_object('closes_at_vencido', true), false, sqlerrm);
    end;
  end loop;
  return v_count;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Correccion detectada al probar el manejador de errores del cron.
--
-- admin_actions.admin_id era NOT NULL, y log_admin_action se traga sus propias
-- excepciones. Resultado: la llamada de auditoria del cron (que corre SIN
-- usuario, admin_id null) fallaba y no dejaba rastro de nada. Verificado:
-- log_admin_action(null, ...) devuelve sin error e inserta 0 filas.
--
-- admin_id null pasa a significar "lo hizo el sistema", que es exactamente lo
-- que ocurre cuando actua el cron.
-- ---------------------------------------------------------------------------
alter table public.admin_actions alter column admin_id drop not null;

comment on column public.admin_actions.admin_id is
  'Admin que ejecuto la accion. NULL = la ejecuto el sistema (cron, tarea programada).';

-- Sigue sin romper la operacion principal, pero ahora al menos grita en el log
-- de Postgres en vez de desaparecer en silencio.
create or replace function public.log_admin_action(
  p_admin_id uuid, p_action text, p_target_table text, p_target_id text,
  p_details jsonb, p_success boolean default true, p_error text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  insert into public.admin_actions (
    admin_id, action, target_table, target_id, details, success, error
  ) values (
    p_admin_id, p_action, p_target_table, p_target_id, p_details,
    coalesce(p_success, true), p_error
  );
exception when others then
  raise warning 'log_admin_action no pudo auditar "%": %', p_action, sqlerrm;
end;
$fn$;
