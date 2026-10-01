-- ===========================================================================
--  20260930120000_realtime_senales.sql
--
--  EL PROBLEMA
--
--  La aplicacion no tiene realtime. Ni una tabla en la publicacion, ni una
--  suscripcion en el frontend, ni siquiera un polling: cada pantalla carga
--  una vez y se queda quieta. En un remate EN VIVO eso significa que un
--  jugador puede estar mirando un precio que ya no existe. Y el admin no se
--  entera de una solicitud de recarga hasta que recarga la pagina a mano --
--  con el jugador esperando al otro lado.
--
--  POR QUE BROADCAST Y NO postgres_changes
--
--  Supabase recomienda Broadcast desde la base: "the recommended method for
--  scalability and security". De postgres_changes dice que "does not scale as
--  well as Broadcast".
--
--  Pero aqui hay ademas una razon que no es de escala: postgres_changes
--  filtra los eventos con la RLS de la tabla, y `bids` NO TIENE ninguna
--  politica que deje leer a un jugador -- por eso existe
--  listar_pujas_publicas, que es `definer`. Un jugador no recibiria nada. Y
--  para arreglarlo habria que abrirle la tabla, justo lo contrario de la
--  tanda de permisos del 29/09.
--
--  LA DECISION: EL EVENTO ES UNA SENAL, NO EL DATO
--
--  El trigger no manda la puja. Manda "algo cambio en el remate X". El
--  cliente, al recibirlo, vuelve a llamar a remate_minimos() y
--  listar_pujas_publicas(), que ya son la unica fuente de verdad de lo que esa
--  pantalla muestra.
--
--  Tres razones, y la primera es la que manda:
--
--  1. NO ROMPE EL ADR-015. Si el evento trajera la puja, el frontend tendria
--     que recalcular el minimo, quien lidera y el precio actual a partir de
--     ella. Eso es reimplementar _incremento_aplicable en TypeScript: el
--     defecto exacto que costo la tarea 2.20, cuando la pantalla mostraba un
--     numero y la base cobraba otro.
--  2. NO ABRE NINGUNA LECTURA. El payload es un id. No hace falta publicar
--     ninguna tabla ni ablandar una sola politica.
--  3. NO SE PUEDE DESINCRONIZAR. La pantalla siempre ensena lo que dice la
--     base, porque se lo va a preguntar.
--
--  El coste es una ida y vuelta por evento. En un remate con decenas de pujas
--  por minuto es irrelevante, y es el precio de que el numero sea el correcto.
--
--  DOS CANALES, CON DISTINTO REGIMEN
--
--    remate:<uuid>   publico para el mundo: lo reciben anon y authenticated.
--                    Payload: el id del remate. Las pujas ya son publicas por
--                    listar_pujas_publicas, asi que no revela nada nuevo.
--
--    admin:caja      recargas y retiros solicitados. SOLO admins. Que a un
--                    jugador le llegue "alguien pidio una recarga" no tiene
--                    por que pasar.
--
--  Los dos son canales PRIVADOS de Supabase -- `private => true` -- para que
--  nadie pueda inyectar eventos falsos desde fuera. La autorizacion se hace
--  con RLS sobre realtime.messages.
--
--  COMPROBADO EN LA BASE ANTES DE ESCRIBIR ESTO (30/09):
--    realtime.send(payload jsonb, event text, topic text, private boolean default true)
--    realtime.topic() existe
--    realtime.messages tiene RLS activa y CERO politicas: hoy no recibe nadie
--    anon y authenticated YA tienen usage sobre el esquema y select sobre
--    la tabla, asi que solo faltan las politicas
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  PASO 1 - Quien puede recibir
--
--  `realtime.messages` es de Supabase, no nuestra. Si este rol no puede crear
--  politicas ahi, la migracion ABORTA ENTERA con un mensaje claro, en vez de
--  aplicar los triggers y dejar un sistema que emite eventos que nadie recibe.
-- ---------------------------------------------------------------------------
do $$
begin
  drop policy if exists remate_recibe_cualquiera on realtime.messages;
  drop policy if exists caja_recibe_solo_admin   on realtime.messages;

  -- Canal del remate: lo recibe cualquiera, con sesion o sin ella.
  -- `extension = 'broadcast'` acota la politica a los mensajes de broadcast y
  -- deja fuera presence y cualquier otro uso futuro del mismo canal.
  create policy remate_recibe_cualquiera on realtime.messages
    for select to anon, authenticated
    using (
      realtime.messages.extension = 'broadcast'
      and realtime.topic() like 'remate:%'
    );

  -- Canal de caja: solo admins.
  create policy caja_recibe_solo_admin on realtime.messages
    for select to authenticated
    using (
      realtime.messages.extension = 'broadcast'
      and realtime.topic() = 'admin:caja'
      and public.is_admin()
    );
exception when insufficient_privilege then
  raise exception
    'No se pueden crear politicas sobre realtime.messages con el rol %. Sin ellas los eventos se emiten y no los recibe nadie, asi que esta migracion no se aplica a medias. Crealas a mano desde el SQL Editor del panel de Supabase con el contenido de este archivo.', current_user;
end $$;


-- ---------------------------------------------------------------------------
--  PASO 2 - El emisor
--
--  UNA sola funcion para emitir. Si manana cambia la forma de los eventos,
--  cambia en un sitio. Mismo criterio que _incremento_aplicable.
--
--  Y UNA DECISION QUE HAY QUE VER ESCRITA: si realtime.send falla, NO se
--  propaga el error. Un aviso perdido no puede tumbar una puja ni un cierre.
--  El `exception when others` de aqui no es pereza -- es lo contrario del que
--  corregimos en P39: alli el swallow escondia un defecto, aqui la
--  consecuencia del fallo es que una pantalla tarde en refrescarse, y a cambio
--  el dinero no depende de que el servicio de realtime este vivo.
--
--  Se deja un `raise warning` para que quede en el log del servidor. Un fallo
--  silencioso de verdad seria no enterarse nunca.
-- ---------------------------------------------------------------------------
create or replace function public._avisar(p_topico text, p_evento text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  perform realtime.send(p_payload, p_evento, p_topico, true);
exception when others then
  raise warning 'realtime: no se pudo emitir % en % -> [%] %', p_evento, p_topico, sqlstate, sqlerrm;
end $fn$;

comment on function public._avisar(text, text, jsonb) is
  'Emisor unico de senales de realtime. El payload es una SENAL, nunca el dato: el cliente vuelve a preguntarle a la base. Nunca propaga errores: una notificacion perdida no puede tumbar una operacion de dinero.';

revoke all on function public._avisar(text, text, jsonb) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  PASO 3 - Los disparadores del canal del remate
-- ---------------------------------------------------------------------------

-- Una puja nueva. Es el evento que mas importa: cambia el precio actual, el
-- minimo siguiente y quien lidera.
create or replace function public.tr_avisar_puja() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
begin
  perform public._avisar(
    'remate:' || new.remate_id::text,
    'puja',
    jsonb_build_object('remate_id', new.remate_id, 'horse_id', new.horse_id));
  return null;
end $fn$;

drop trigger if exists avisar_puja on public.bids;
create trigger avisar_puja after insert on public.bids
  for each row execute function public.tr_avisar_puja();


-- El remate cambio: se cerro, se cancelo, se liquidó, o el admin le movio el
-- incremento o el porcentaje. Solo se avisa si cambio algo que el jugador ve;
-- un update que no toca nada de eso no despierta a nadie.
create or replace function public.tr_avisar_remate() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
begin
  if new.estado            is distinct from old.estado
  or new.incremento_minimo is distinct from old.incremento_minimo
  or new.porcentaje_casa   is distinct from old.porcentaje_casa
  or new.opens_at          is distinct from old.opens_at
  or new.closes_at         is distinct from old.closes_at then
    perform public._avisar(
      'remate:' || new.id::text,
      'remate',
      jsonb_build_object('remate_id', new.id, 'estado', new.estado));
  end if;
  return null;
end $fn$;

drop trigger if exists avisar_remate on public.remates;
create trigger avisar_remate after update on public.remates
  for each row execute function public.tr_avisar_remate();


-- Un aviso al jugador: cambio de porcentaje o de incremento. La tabla existe
-- desde el 28/09 y hasta hoy el jugador solo la veia si recargaba.
create or replace function public.tr_avisar_aviso() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
begin
  perform public._avisar(
    'remate:' || new.remate_id::text,
    'aviso',
    jsonb_build_object('remate_id', new.remate_id, 'tipo', new.tipo));
  return null;
end $fn$;

drop trigger if exists avisar_aviso on public.remate_avisos;
create trigger avisar_aviso after insert on public.remate_avisos
  for each row execute function public.tr_avisar_aviso();


-- Un caballo retirado o cambiado de precio. Los caballos cuelgan de la
-- CARRERA, no del remate, y una carrera puede tener varios remates: hay que
-- avisar a todos los que la usan.
create or replace function public.tr_avisar_caballo() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
declare r record;
begin
  if new.retirado is distinct from old.retirado
  or new.precio_salida is distinct from old.precio_salida
  or new.nombre is distinct from old.nombre then
    for r in select id from public.remates where race_id = new.race_id loop
      perform public._avisar(
        'remate:' || r.id::text,
        'caballo',
        jsonb_build_object('remate_id', r.id, 'horse_id', new.id));
    end loop;
  end if;
  return null;
end $fn$;

drop trigger if exists avisar_caballo on public.horses;
create trigger avisar_caballo after update on public.horses
  for each row execute function public.tr_avisar_caballo();


-- ---------------------------------------------------------------------------
--  PASO 4 - Los disparadores del canal de caja
--
--  Insert: alguien pidio una recarga o un retiro.
--  Update: alguien la aprobo o la rechazo -- para que si hay dos admins
--  mirando, al segundo se le caiga de la lista sola.
-- ---------------------------------------------------------------------------
create or replace function public.tr_avisar_recarga() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
begin
  perform public._avisar('admin:caja', 'recarga',
    jsonb_build_object('id', new.id, 'estado', new.estado));
  return null;
end $fn$;

drop trigger if exists avisar_recarga on public.deposit_requests;
create trigger avisar_recarga after insert or update on public.deposit_requests
  for each row execute function public.tr_avisar_recarga();


create or replace function public.tr_avisar_retiro() returns trigger
language plpgsql security definer set search_path to ''
as $fn$
begin
  perform public._avisar('admin:caja', 'retiro',
    jsonb_build_object('id', new.id, 'estado', new.estado));
  return null;
end $fn$;

drop trigger if exists avisar_retiro on public.withdraw_requests;
create trigger avisar_retiro after insert or update on public.withdraw_requests
  for each row execute function public.tr_avisar_retiro();


-- ---------------------------------------------------------------------------
--  PASO 5 - Las funciones de trigger, cerradas
--
--  Comprobado el 30/09: un trigger dispara aunque el rol que hace el insert no
--  tenga EXECUTE sobre su funcion. PostgreSQL comprueba ese permiso al CREAR
--  el trigger, no al dispararlo. Asi que se cierran, y ademas hay que
--  declararlas en el censo P47 o se pone rojo.
-- ---------------------------------------------------------------------------
revoke all on function public.tr_avisar_puja()    from public, anon, authenticated;
revoke all on function public.tr_avisar_remate()  from public, anon, authenticated;
revoke all on function public.tr_avisar_aviso()   from public, anon, authenticated;
revoke all on function public.tr_avisar_caballo() from public, anon, authenticated;
revoke all on function public.tr_avisar_recarga() from public, anon, authenticated;
revoke all on function public.tr_avisar_retiro()  from public, anon, authenticated;
