-- ============================================================================
--  PRUEBAS DE CONCURRENCIA -> Remates Catire Bello
--
--  Corre contra la base LOCAL, nunca contra produccion, y DESPUES del arnes:
--
--    pnpm db:reset
--    $db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
--    Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres
--    Get-Content tests/concurrencia.sql  | docker exec -i $db psql -U postgres -d postgres
--
--  POR QUE EXISTE ESTE ARCHIVO
--
--  El arnes corre con UNA sola conexion. Tres de los arreglos de dinero de la
--  auditoria del 28/09 son condiciones de carrera, y una carrera no se
--  reproduce con una conexion:
--
--    A2  `for share` en hacer_puja      -> una puja entrando en un remate que
--                                          se esta cerrando
--    A4  candado de caja (3,0)          -> dos liquidaciones gastando la misma
--                                          caja a la vez
--    D1  unique en race_results         -> dos set_ganador_carrera simultaneos
--
--  De los tres tenemos pruebas en el arnes, pero prueban la VALLA, no la
--  carrera: P45 comprueba que el unique rechaza una segunda fila insertada a
--  mano, no que dos admins simultaneos no puedan insertarla. Es una distincion
--  que importa: los tres se desplegaron a produccion el 29/09 sin una sola
--  prueba de que funcionan bajo concurrencia.
--
--  COMO FUNCIONA
--
--  Con `dblink`, esta misma sesion abre una SEGUNDA conexion a la base. La
--  sesion principal (A) toma un candado dentro de una transaccion abierta y no
--  la cierra; la segunda (B) lanza la operacion de verdad -- hacer_puja,
--  liquidar_remate, set_ganador_carrera -- de forma asincrona. Si el arreglo
--  esta puesto, B se queda esperando y `dblink_is_busy` lo dice. Si no lo
--  esta, B pasa de largo.
--
--  Las funciones son las REALES, no una imitacion. Lo unico simulado es el
--  momento: A se queda con el candado tomado el tiempo que haga falta para
--  que B llegue en medio.
--
--  DEPENDE DEL ARNES a proposito: usa `_p.usuario`, `_p.escenario`,
--  `_p.caballo` y `_p.actuar_como`. Duplicar ese andamiaje aqui seria crear
--  una segunda implementacion del mismo escenario, que es justo el defecto
--  que llevamos todo el mes persiguiendo. El arnes deja esas funciones en la
--  base al terminar; solo limpia los datos.
-- ============================================================================

\set ON_ERROR_STOP off
\set QUIET on
set client_min_messages to warning;

create extension if not exists dblink;

-- ---------------------------------------------------------------- andamiaje
create schema if not exists _c;

drop table if exists _c.resultado;
create table _c.resultado (n int, nombre text, esperado text, estado text, detalle text);

create table if not exists _c.ctx (clave text primary key, valor text);
delete from _c.ctx;

create or replace function _c.anotar(p_n int, p_nombre text, p_esperado text, p_ok boolean, p_detalle text default '')
returns void language sql as $fn$
  insert into _c.resultado values (p_n, p_nombre, p_esperado, case when p_ok then 'OK' else 'FALLA' end, p_detalle);
$fn$;

create or replace function _c.set(p_clave text, p_valor text) returns void language sql as $fn$
  insert into _c.ctx values (p_clave, p_valor)
  on conflict (clave) do update set valor = excluded.valor;
$fn$;

create or replace function _c.get(p_clave text) returns text language sql stable as $fn$
  select valor from _c.ctx where clave = p_clave;
$fn$;

create or replace function _c.uuid(p_clave text) returns uuid language sql stable as $fn$
  select (select valor from _c.ctx where clave = p_clave)::uuid;
$fn$;

-- CONECTAR LA SEGUNDA SESION: POR QUE NO VALE 127.0.0.1
--
-- En Supabase el rol `postgres` NO es superusuario (`rolsuper = f`). Y la
-- documentacion de dblink dice, literal:
--
--   "Only superusers may use dblink_connect to create non-password-
--    authenticated and non-GSSAPI-authenticated connections."
--
-- El `pg_hba` del contenedor confia en las conexiones locales, asi que por
-- socket o por 127.0.0.1 la contrasena NO SE USA aunque se mande, y
-- dblink_connect lo rechaza con 2F003 -- "password or GSSAPI delegated
-- credentials required". No es que la clave sea incorrecta: es que no se
-- llego a pedir.
--
-- `dblink_connect_u`, la variante para no-superusuarios, tampoco sirve: su
-- ACL en Supabase es `{supabase_admin=X/supabase_admin}` y `postgres` no
-- puede ni ejecutarla ni concederse el permiso.
--
-- Lo que SI funciona: conectar al NOMBRE DE RED del contenedor. Esa conexion
-- sale por una direccion que no es loopback, ahi el pg_hba exige scram, la
-- contrasena se usa de verdad, y la comprobacion de seguridad de dblink pasa.
-- `db` es el alias generico del servicio en la red de Supabase y no lleva el
-- nombre del proyecto dentro, asi que vale en cualquier instalacion local.
--
-- Comprobado el 30/09 contra el contenedor real. Las demas quedan de reserva.
--
-- Y CADA FALLO SE ANOTA. La primera version de esta funcion se tragaba los
-- errores con `exception when others then null`, asi que cuando no conectaba
-- no decia por que: un diagnostico ciego, el mismo defecto que llevamos dos
-- dias arreglando en otros sitios.
create or replace function _c.conectar() returns text language plpgsql as $fn$
declare
  v_cad text;
  v_errores text := '';
  v_candidatas text[] := array[
    'dbname=postgres user=postgres host=db port=5432 password=postgres',
    'dbname=postgres user=postgres host=supabase_db port=5432 password=postgres',
    'dbname=postgres user=postgres host=127.0.0.1 port=5432 password=postgres',
    'dbname=postgres user=postgres host=/var/run/postgresql'
  ];
begin
  begin perform dblink_disconnect('b'); exception when others then null; end;
  foreach v_cad in array v_candidatas loop
    begin
      perform dblink_connect('b', v_cad);
      perform _c.set('conexion_errores', v_errores);
      return v_cad;
    exception when others then
      v_errores := v_errores || ' | ' || split_part(v_cad, ' ', 3) ||
                   ' -> [' || sqlstate || '] ' || sqlerrm;
    end;
  end loop;
  perform _c.set('conexion_errores', v_errores);
  return null;
end $fn$;

create or replace function _c.desconectar() returns void language plpgsql as $fn$
begin
  begin perform dblink_disconnect('b'); exception when others then null; end;
end $fn$;

-- B se hace pasar por un usuario, igual que _p.actuar_como en la sesion A.
create or replace function _c.b_actuar_como(p_id uuid) returns void language plpgsql as $fn$
begin
  perform * from dblink('b', format(
    'select set_config(%L, %L, false)',
    'request.jwt.claims',
    json_build_object('sub', p_id)::text
  )) as r(x text);
end $fn$;

create or replace function _c.b_enviar(p_sql text) returns void language plpgsql as $fn$
begin
  perform dblink_send_query('b', p_sql);
end $fn$;

create or replace function _c.b_esperando() returns boolean language sql as $fn$
  select dblink_is_busy('b') = 1;
$fn$;

-- Devuelve 'OK:<resultado>' si B termino bien, o el SQLSTATE si lanzo error.
--
-- Y DRENA LA CONEXION ANTES DE DEVOLVER. Esto no es opcional: despues de un
-- `dblink_send_query` hay que llamar a `dblink_get_result` hasta que devuelva
-- CERO filas. Con una sola llamada la conexion se queda con el comando a
-- medias, y la siguiente operacion sobre ella revienta con
-- "another command is already in progress".
--
-- La primera version salia por el `exception` sin drenar, asi que un error en
-- C1 -- que es el resultado ESPERADO de C1 -- dejaba la conexion inservible y
-- tumbaba C2. El sintoma aparecia en una prueba distinta de la que lo causaba,
-- que es la peor forma de fallar.
--
-- Comprobado el 30/09 en un Postgres real: sin drenar, "conexion SUCIA"; con
-- una vuelta de drenaje, limpia.
create or replace function _c.b_recoger() returns text language plpgsql as $fn$
declare
  v text;
  v_salida text;
  v_filas int;
  v_vueltas int := 0;
begin
  begin
    select x into v from dblink_get_result('b') as r(x text) limit 1;
    v_salida := 'OK:' || coalesce(v, '');
  exception when others then
    v_salida := sqlstate;
  end;

  loop
    v_vueltas := v_vueltas + 1;
    begin
      select count(*) into v_filas from dblink_get_result('b') as r(x text);
    exception when others then
      v_filas := 1;    -- otro error pendiente: seguir drenando
    end;
    exit when v_filas = 0 or v_vueltas > 10;
  end loop;

  return v_salida;
end $fn$;


-- ---------------------------------------------------------------- requisitos
do $$
declare v_arnes boolean; v_cad text;
begin
  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = '_p' and p.proname = 'escenario'
  ) into v_arnes;

  if not v_arnes then
    perform _c.anotar(0, 'Requisitos', 'el andamiaje del arnes (_p) tiene que existir',
      false, 'FALTA _p.escenario: corre primero tests/pruebas_dinero.sql sobre esta misma base');
    return;
  end if;

  v_cad := _c.conectar();
  perform _c.set('conexion', coalesce(v_cad, ''));

  perform _c.anotar(0, 'Requisitos', 'arnes cargado y segunda conexion abierta',
    v_arnes and v_cad is not null,
    'andamiaje _p: ' || v_arnes::text ||
    ' | segunda conexion: ' || coalesce(v_cad, 'NINGUNA CADENA FUNCIONO') ||
    case when v_cad is null
      then ' | intentos: ' || coalesce(_c.get('conexion_errores'), '(sin registro)')
      else '' end);
end $$;


-- ============================================================================
--  C1 - Una puja no puede colarse en un remate que se esta cerrando
--
--  Hallazgo A2. `hacer_puja` leia el remate con un select plano: no tomaba
--  ningun candado sobre la fila. `_cerrar_remate_interno` la toma con
--  `for update`, pero eso no frena a quien no pide nada.
--
--  La carrera: el cierre empieza, lee quien lidera cada caballo y les cobra.
--  Mientras tanto entra una puja que ese cierre ya no va a ver. Cuando el
--  cierre termina, el remate queda cerrado con una puja LIDER que nadie
--  cobro. Y si ese caballo gana, se le paga el premio sobre un pozo al que
--  nunca aporto.
--
--  Lo peor: el descuadre no lo detecta. Las dos mitades de la reconciliacion
--  leen `wallet_movements`, y de esa puja no hay ningun movimiento.
--
--  El arreglo fue `for share` sobre la fila del remate. Esta prueba lo mide:
--  con A dentro del cierre sin hacer commit, B tiene que QUEDARSE ESPERANDO.
-- ============================================================================
do $$
declare v_admin uuid; v_juan uuid; v_rem uuid;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then return; end if;

  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_juan  := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);

  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_rem, _p.caballo(v_rem, 1), null, false);

  perform _c.set('rem', v_rem::text);
  perform _c.set('h2',  _p.caballo(v_rem, 2)::text);
  perform _c.set('juan', v_juan::text);
  perform _c.set('admin', v_admin::text);

  perform _p.actuar_como(v_admin);   -- la sesion A cierra como admin
  perform _c.conectar();             -- conexion limpia para este escenario
  perform _c.b_actuar_como(v_juan);  -- la sesion B puja como juan
end $$;

-- A entra al cierre y se queda dentro. B intenta pujar en medio.
begin;
  select public.cerrar_remate(_c.uuid('rem'));
  select _c.b_enviar(format(
    'select (public.hacer_puja(%L::uuid, %L::uuid, null, false))::text',
    _c.get('rem'), _c.get('h2')));
  select pg_sleep(1.5);
  select _c.set('c1_bloqueada', _c.b_esperando()::text);
commit;

do $$
declare
  v_bloqueada boolean; v_res text; v_pujas int;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then
    perform _c.anotar(1, 'Una puja no entra en un remate que se esta cerrando',
      'ver requisitos', false, 'sin segunda conexion no se puede probar');
    return;
  end if;

  v_bloqueada := _c.get('c1_bloqueada') = 'true';
  v_res := _c.b_recoger();      -- ya con el cierre confirmado

  select count(*) into v_pujas
  from public.bids where horse_id = _c.uuid('h2');

  perform _c.anotar(1, 'Una puja no entra en un remate que se esta cerrando',
    'B se queda esperando mientras A cierra; al soltar, la puja se rechaza (P0001) y no queda ninguna',
    v_bloqueada and v_res = 'P0001' and v_pujas = 0,
    'B esperaba mientras A cerraba: ' || v_bloqueada::text ||
    ' (si es false, hacer_puja no tomo el `for share`)' ||
    ' | resultado de B: ' || v_res || ' (esperado P0001)' ||
    ' | pujas sobre el caballo 2: ' || v_pujas::text || ' (esperado 0)');
exception when others then
  perform _c.anotar(1, 'Una puja no entra en un remate que se esta cerrando',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  C2 - Dos liquidaciones no gastan la misma caja
--
--  Hallazgo A4. `liquidar_remate` comprueba que la casa tiene con que pagar
--  -- `dinero_casa_disponible()` -- y despues paga. Entre lo uno y lo otro no
--  tomaba ningun candado global, asi que dos liquidaciones simultaneas leian
--  la MISMA caja, las dos se veian solventes, y las dos pagaban. La casa
--  pagaba dos premios con dinero para uno.
--
--  El arreglo fue `pg_advisory_xact_lock(3, 0)` -- el espacio 3, la caja --
--  al principio de liquidar_remate y de registrar_movimiento_casa, que son
--  las dos funciones que mueven esa magnitud global.
--
--  Se usan DOS remates distintos a proposito: si fueran el mismo, el `for
--  update` sobre su fila ya los serializaria y la prueba pasaria en verde sin
--  que el candado de caja existiera. Remates distintos, caja compartida: solo
--  el candado del espacio 3 los puede cruzar.
-- ============================================================================
do $$
declare v_admin uuid; v_juan uuid; v_remA uuid; v_remB uuid;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then return; end if;

  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_juan  := _p.usuario('juan', 10000);

  -- dos remates independientes, cada uno con su puja y ya cerrados.
  -- Gana en los dos un caballo SIN pujas: la casa se queda el pozo y no hay
  -- premio que pagar, asi que la guarda de solvencia no estorba a la medicion.
  v_remA := _p.escenario(2, 100, 25);
  v_remB := _p.escenario(2, 100, 25);

  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_remA, _p.caballo(v_remA, 1), null, false);
  perform public.hacer_puja(v_remB, _p.caballo(v_remB, 1), null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_remA);
  perform public.cerrar_remate(v_remB);
  perform public.set_ganador_carrera(v_remA, 2);
  perform public.set_ganador_carrera(v_remB, 2);

  perform _c.set('remA', v_remA::text);
  perform _c.set('remB', v_remB::text);
  perform _c.conectar();             -- conexion limpia para este escenario
  perform _c.b_actuar_como(v_admin);
end $$;

begin;
  select public.liquidar_remate(_c.uuid('remA'));
  select _c.b_enviar(format('select (public.liquidar_remate(%L::uuid))::text', _c.get('remB')));
  select pg_sleep(1.5);
  select _c.set('c2_bloqueada', _c.b_esperando()::text);
commit;

do $$
declare v_bloqueada boolean; v_res text; v_liquidados int;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then
    perform _c.anotar(2, 'Dos liquidaciones no gastan la misma caja',
      'ver requisitos', false, 'sin segunda conexion no se puede probar');
    return;
  end if;

  v_bloqueada := _c.get('c2_bloqueada') = 'true';
  v_res := _c.b_recoger();

  select count(*) into v_liquidados from public.remates where estado = 'liquidado';

  perform _c.anotar(2, 'Dos liquidaciones no gastan la misma caja',
    'la segunda liquidacion espera al candado de caja; al soltarlo, termina y quedan los dos remates liquidados',
    v_bloqueada and v_res like 'OK:%' and v_liquidados = 2,
    'B esperaba al candado de caja: ' || v_bloqueada::text ||
    ' (si es false, liquidar_remate no toma pg_advisory_xact_lock(3,0))' ||
    ' | resultado de B: ' || v_res ||
    ' | remates liquidados: ' || v_liquidados::text || ' (esperado 2)');
exception when others then
  perform _c.anotar(2, 'Dos liquidaciones no gastan la misma caja',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  C3 - Una carrera no puede quedar con dos ganadores
--
--  Hallazgo D1. `set_ganador_carrera` es un update-then-insert sin candado:
--
--    update race_results set ganador_horse_id = ... where race_id = ...;
--    if not found then insert into race_results (...) values (...); end if;
--
--  Dos llamadas a la vez -- dos admins, un doble clic, el reintento de un
--  fetch que no respondio -- hacen las dos un update que afecta 0 filas,
--  porque ninguna ve la fila que la otra todavia no confirmo. Las dos entran
--  al `if not found` y las dos insertan.
--
--  Y liquidar_remate lee el ganador con `select ... into` sin `limit` y sin
--  `strict`: con dos filas toma la primera que devuelva el plan, sin error y
--  sin aviso. El premio entero a un usuario indeterminado.
--
--  El arreglo fue el `unique (race_id)`. Aqui se mide contra la carrera de
--  verdad: B tiene que quedarse esperando en el indice mientras A no confirme,
--  y al confirmarse A, rebotar con 23505.
--
--  P45 comprueba que un insert a mano rebota. Esto comprueba que dos sesiones
--  simultaneas no pueden. No es lo mismo.
-- ============================================================================
do $$
declare v_admin uuid; v_juan uuid; v_rem uuid;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then return; end if;

  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_juan  := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);

  perform _p.actuar_como(v_juan);
  perform public.hacer_puja(v_rem, _p.caballo(v_rem, 1), null, false);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);       -- cerrado y SIN resultado todavia

  perform _c.set('rem', v_rem::text);
  perform _c.set('race', (select race_id from public.remates where id = v_rem)::text);
  perform _c.conectar();             -- conexion limpia para este escenario
  perform _c.b_actuar_como(v_admin);
end $$;

begin;
  select public.set_ganador_carrera(_c.uuid('rem'), 1);
  select _c.b_enviar(format('select (public.set_ganador_carrera(%L::uuid, 2))::text', _c.get('rem')));
  select pg_sleep(1.5);
  select _c.set('c3_bloqueada', _c.b_esperando()::text);
commit;

do $$
declare v_bloqueada boolean; v_res text; v_filas int; v_ganador uuid; v_num int;
begin
  if (select estado from _c.resultado where n = 0) <> 'OK' then
    perform _c.anotar(3, 'Una carrera no queda con dos ganadores',
      'ver requisitos', false, 'sin segunda conexion no se puede probar');
    return;
  end if;

  v_bloqueada := _c.get('c3_bloqueada') = 'true';
  v_res := _c.b_recoger();

  select count(*) into v_filas from public.race_results where race_id = _c.uuid('race');
  select rr.ganador_horse_id into v_ganador
  from public.race_results rr where rr.race_id = _c.uuid('race');
  select h.numero into v_num from public.horses h where h.id = v_ganador;

  perform _c.anotar(3, 'Una carrera no queda con dos ganadores',
    'la segunda llamada espera en el indice y rebota con 23505; queda UNA fila, la del caballo 1',
    v_bloqueada and v_res = '23505' and v_filas = 1 and v_num = 1,
    'B esperaba en el unique: ' || v_bloqueada::text ||
    ' | resultado de B: ' || v_res || ' (esperado 23505)' ||
    ' | filas de resultado: ' || v_filas::text || ' (esperado 1)' ||
    ' | ganador: caballo ' || coalesce(v_num, -1)::text || ' (esperado 1, el que puso A)');
exception when others then
  perform _c.anotar(3, 'Una carrera no queda con dos ganadores',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ---------------------------------------------------------------- cierre
select _c.desconectar();

do $$
begin
  perform _p.limpiar();
exception when others then null;
end $$;

\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _c.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _c.resultado;
