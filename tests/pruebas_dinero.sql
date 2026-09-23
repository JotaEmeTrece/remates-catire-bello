-- ============================================================================
--  PRUEBAS DE DINERO -> Remates Catire Bello
--
--  Corre contra la base LOCAL, nunca contra produccion.
--
--    supabase start
--    psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/pruebas_dinero.sql
--
--  Cada prueba es independiente: limpia, arma su escenario, y verifica.
--  Al final imprime un resumen. Ninguna prueba tumba a las demas.
--
--  IMPORTANTE: varias FALLAN a proposito contra el codigo actual. Esas fallas
--  son el defecto reproducido. Cuando se aplique la correccion, pasan a OK.
-- ============================================================================

\set ON_ERROR_STOP off
\set QUIET on
set client_min_messages to warning;

-- ---------------------------------------------------------------- andamiaje
create schema if not exists _p;

drop table if exists _p.resultado;
create table _p.resultado (
  n        int,
  nombre   text,
  esperado text,
  estado   text,
  detalle  text
);

create or replace function _p.limpiar() returns void language plpgsql as $$
begin
  delete from public.wallet_movements;
  delete from public.bids;
  delete from public.race_results;
  delete from public.remate_price_rules;
  delete from public.remates;
  delete from public.horses;
  delete from public.races;
  delete from public.withdraw_requests;
  delete from public.deposit_requests;
  delete from public.wallets;
  delete from public.profiles;
  delete from auth.users;
end $$;

create or replace function _p.usuario(p_nombre text, p_saldo numeric default 0, p_admin boolean default false)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_id);
  insert into public.profiles (id, username, es_admin, es_super_admin)
    values (v_id, p_nombre, p_admin, p_admin)
  on conflict (id) do update set username = excluded.username,
                                 es_admin = excluded.es_admin,
                                 es_super_admin = excluded.es_super_admin;
  insert into public.wallets (user_id, saldo_disponible, saldo_bloqueado)
    values (v_id, p_saldo, 0)
  on conflict (user_id) do update set saldo_disponible = excluded.saldo_disponible,
                                      saldo_bloqueado = 0;
  return v_id;
end $$;

create or replace function _p.actuar_como(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_id)::text, false);
end $$;

-- carrera + remate + N caballos, todos al mismo precio de salida
create or replace function _p.escenario(p_n_caballos int, p_precio numeric, p_pct_casa numeric default 25)
returns uuid language plpgsql as $$
declare v_race uuid := gen_random_uuid(); v_rem uuid := gen_random_uuid(); i int;
begin
  insert into public.races (id, nombre, fecha, estado)
    values (v_race, 'Carrera de prueba', current_date, 'programada');
  insert into public.remates (id, race_id, nombre, estado, incremento_minimo, apuesta_minima, porcentaje_casa, opens_at, closes_at)
    values (v_rem, v_race, 'Remate de prueba', 'abierto', 10, 1, p_pct_casa, now() - interval '1 hour', now() + interval '1 hour');
  for i in 1..p_n_caballos loop
    insert into public.horses (race_id, numero, nombre, precio_salida)
      values (v_race, i, 'Caballo ' || i, p_precio);
  end loop;
  return v_rem;
end $$;

create or replace function _p.caballo(p_remate uuid, p_numero int) returns uuid language sql stable as $$
  select h.id from public.horses h
  join public.remates r on r.race_id = h.race_id
  where r.id = p_remate and h.numero = p_numero;
$$;

create or replace function _p.saldo(p_user uuid) returns numeric language sql stable as $$
  select saldo_disponible from public.wallets where user_id = p_user;
$$;

create or replace function _p.anotar(p_n int, p_nombre text, p_esperado text, p_ok boolean, p_detalle text default '')
returns void language sql as $$
  insert into _p.resultado values (p_n, p_nombre, p_esperado, case when p_ok then 'OK' else 'FALLA' end, p_detalle);
$$;

-- ============================================================================
--  P1 - El caballo retirado no debe entrar al pozo
--  Defecto C1 -> se espera FALLA contra el codigo actual (tarea 1.1)
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_pozo_esperado numeric; v_premio_real numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);           -- 3 caballos a 100
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);   -- juan compra el 1 en 200

  update public.horses set retirado = true where id = v_h2;  -- se retira el 2

  -- pozo correcto: 200 (caballo 1) + 100 (caballo 3, queda a la casa) = 300
  -- el caballo 2 esta retirado y NO debe sumar
  v_pozo_esperado := 300;

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);
  perform public.liquidar_remate(v_rem);

  select monto into v_premio_real
  from public.wallet_movements wm
  join public.wallets w on w.id = wm.wallet_id
  where w.user_id = v_u and wm.tipo = 'premio';

  perform _p.anotar(1, 'Caballo retirado fuera del pozo', 'premio = 225 (75% de 300)',
    round(coalesce(v_premio_real,0),2) = 225,
    'premio real: ' || coalesce(v_premio_real,0)::text || ' -> si da 300, el retirado sumo 100 al pozo');
exception when others then
  perform _p.anotar(1, 'Caballo retirado fuera del pozo', 'premio = 225 (75% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P2 - La comision debe salir de porcentaje_casa, no de un 0.75 clavado
--  Defecto C2 -> se espera FALLA contra el codigo actual (tarea 1.2)
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_premio numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 30);      -- porcentaje_casa = 30
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);
  -- pozo = 200 + 100 = 300. Con casa 30% el premio debe ser 210, no 225.

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);
  perform public.liquidar_remate(v_rem);

  select monto into v_premio from public.wallet_movements wm
  join public.wallets w on w.id = wm.wallet_id
  where w.user_id = v_u and wm.tipo = 'premio';

  perform _p.anotar(2, 'porcentaje_casa se respeta', 'premio = 210 (70% de 300)',
    round(coalesce(v_premio,0),2) = 210,
    'premio real: ' || coalesce(v_premio,0)::text || ' -> si da 225, uso el 0.75 clavado');
exception when others then
  perform _p.anotar(2, 'porcentaje_casa se respeta', 'premio = 210 (70% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P3 - Si gana un caballo de la casa, no se paga premio
--  Se espera OK -> esta regla ya funciona
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_n int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 3);   -- gana un caballo SIN puja
  perform public.liquidar_remate(v_rem);

  select count(*) into v_n from public.wallet_movements where tipo = 'premio';
  perform _p.anotar(3, 'Gana caballo de la casa: sin premio', '0 movimientos de premio',
    v_n = 0, 'movimientos de premio: ' || v_n::text);
exception when others then
  perform _p.anotar(3, 'Gana caballo de la casa: sin premio', '0 movimientos de premio', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P4 - No se puede acreditar un premio que la casa no puede pagar
--  Defecto C1.3 -> se espera FALLA (no hay guarda de solvencia) (tarea 1.3)
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_fallo boolean := false; v_casa numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 100);
  v_rem   := _p.escenario(10, 500);     -- 10 caballos a 500: la casa banca 4500
  v_h1    := _p.caballo(v_rem, 1);

  -- el usuario solo tiene 100; nadie recargo nada, asi que la caja real es 0
  perform _p.actuar_como(v_u);
  begin perform public.hacer_puja(v_rem, v_h1, 510, true); exception when others then null; end;

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);
  begin
    perform public.liquidar_remate(v_rem);
  exception when others then v_fallo := true;
  end;

  select coalesce(sum(saldo_disponible),0) into v_casa from public.wallets;
  perform _p.anotar(4, 'Guarda de solvencia al liquidar', 'la liquidacion falla, no acredita',
    v_fallo, 'liquido sin comprobar la caja; saldo total de usuarios quedo en ' || v_casa::text);
exception when others then
  perform _p.anotar(4, 'Guarda de solvencia al liquidar', 'la liquidacion falla, no acredita', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P5 - Escenario mas comun del remate: alguien es superado
--  Defecto en cerrar_remate -> se espera FALLA (tarea 1.8)
--  U1 puja al caballo 1 -> U2 lo supera -> U1 puja al caballo 2 y queda lider
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_error text := ''; v_bloq1 numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);  -- supera a juan
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);  -- juan lidera el 2

  select saldo_bloqueado into v_bloq1 from public.wallets where user_id = v_u1;

  perform _p.actuar_como(v_admin);
  begin
    perform public.cerrar_remate(v_rem);
    perform public.set_ganador_carrera(v_rem, 2);
    perform public.liquidar_remate(v_rem);
  exception when others then v_error := sqlerrm;
  end;

  perform _p.anotar(5, 'Usuario superado: cerrar y liquidar', 'sin error; bloqueado de juan = 400',
    v_error = '' and v_bloq1 = 400,
    case when v_error <> '' then 'error: ' || v_error
         else 'bloqueado de juan antes de cerrar: ' || v_bloq1::text || ' (deberia ser 400)' end);
exception when others then
  perform _p.anotar(5, 'Usuario superado: cerrar y liquidar', 'sin error', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P6 - El libro de movimientos reconstruye los saldos
--
--  Ciclo completo con dinero que entra SOLO por recarga aprobada, para que el
--  saldo inicial sea 0 y cada bolivar tenga su asiento.
--
--  Dos invariantes por wallet:
--    A) disponible + bloqueado = suma de los movimientos que mueven caja
--       (recarga, premio, retiro, ajuste_manual)
--    B) bloqueado = apuesta_bloqueo - apuesta_desbloqueo + ajuste_manual
--       (el cobro al ganador es un ajuste_manual negativo que sale de bloqueado)
--
--  OJO: que esta prueba tenga que listar los tipos a mano es en si mismo el
--  hallazgo. Ver tarea 2.19 del backlog: `monto` no es un delta con signo,
--  `ajuste_manual` se usa para tres cosas distintas (cobro al ganador,
--  devolucion por cancelacion, devolucion por retiro rechazado) y dos de ellas
--  tienen el mismo signo pero tocan columnas distintas. Con la tabla asi, el
--  saldo de una wallet NO se puede reconstruir desde su libro sin conocer el
--  codigo que lo escribio.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_dep uuid; v_desc_a int; v_desc_b int; v_detalle text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  0);
  v_u2    := _p.usuario('pedro', 0);

  -- el dinero entra por la puerta de siempre
  perform _p.actuar_como(v_u1);
  perform public.solicitar_recarga(5000, 'pago_movil', '04121234567', 'REFJ', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u1;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  perform _p.actuar_como(v_u2);
  perform public.solicitar_recarga(5000, 'pago_movil', '04127654321', 'REFP', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u2;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  v_rem := _p.escenario(3, 100);
  v_h1  := _p.caballo(v_rem, 1);
  v_h2  := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);

  perform _p.actuar_como(v_admin);
  begin perform public.cerrar_remate(v_rem);        exception when others then null; end;
  begin perform public.set_ganador_carrera(v_rem, 2); exception when others then null; end;
  begin perform public.liquidar_remate(v_rem);      exception when others then null; end;

  -- y un retiro, para ejercitar el tipo `retiro`
  perform _p.actuar_como(v_u1);
  begin perform public.solicitar_retiro(100, 'pago_movil', '04121234567'); exception when others then null; end;

  select count(*) into v_desc_a from (
    select w.id,
           w.saldo_disponible + w.saldo_bloqueado as saldo,
           coalesce((select sum(m.monto) from public.wallet_movements m
                     where m.wallet_id = w.id
                       and m.tipo in ('recarga','premio','retiro','ajuste_manual')), 0) as caja
    from public.wallets w
  ) x where abs(saldo - caja) > 0.001;

  select count(*) into v_desc_b from (
    select w.id,
           w.saldo_bloqueado as bloq,
           coalesce((select sum(case when m.tipo = 'apuesta_desbloqueo' then -m.monto else m.monto end)
                     from public.wallet_movements m
                     where m.wallet_id = w.id
                       and m.tipo in ('apuesta_bloqueo','apuesta_desbloqueo','ajuste_manual')), 0) as calc
    from public.wallets w
  ) y where abs(bloq - calc) > 0.001;

  select string_agg(p.username || ': saldo ' || (w.saldo_disponible + w.saldo_bloqueado)::text ||
                    ' / bloq ' || w.saldo_bloqueado::text, ' | ' order by p.username)
    into v_detalle
  from public.wallets w join public.profiles p on p.id = w.user_id;

  perform _p.anotar(6, 'El libro reconstruye los saldos', 'A y B sin descuadres',
    v_desc_a = 0 and v_desc_b = 0,
    'descuadres A(caja): ' || v_desc_a::text || ', B(bloqueado): ' || v_desc_b::text ||
    ' | ' || coalesce(v_detalle,''));
exception when others then
  perform _p.anotar(6, 'El libro reconstruye los saldos', 'A y B sin descuadres', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P7 - Borrar un caballo con pujas debe ser rechazado por la base
--  Tarea 3.1 - se espera FALLA mientras las FK esten en CASCADE
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_rechazado boolean := false; v_pujas_antes int; v_pujas_despues int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  select count(*) into v_pujas_antes from public.bids;

  begin
    delete from public.horses where id = v_h1;   -- lo que hace el boton del admin
  exception when others then v_rechazado := true;
  end;

  select count(*) into v_pujas_despues from public.bids;

  perform _p.anotar(7, 'FK protege las pujas al borrar un caballo',
    'la base rechaza el borrado',
    v_rechazado and v_pujas_despues = v_pujas_antes,
    case when v_rechazado then 'rechazado correctamente'
         else 'BORRO el caballo y se llevo ' || (v_pujas_antes - v_pujas_despues)::text ||
              ' puja(s) por delante; ese saldo bloqueado queda huerfano' end);
exception when others then
  perform _p.anotar(7, 'FK protege las pujas al borrar un caballo', 'la base rechaza el borrado', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P8 - Borrar una carrera con remates y pujas tambien debe ser rechazado
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_race uuid;
        v_rechazado boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);
  select race_id into v_race from public.remates where id = v_rem;

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  begin
    delete from public.races where id = v_race;
  exception when others then v_rechazado := true;
  end;

  perform _p.anotar(8, 'FK protege la cadena al borrar una carrera',
    'la base rechaza el borrado', v_rechazado,
    case when v_rechazado then 'rechazado correctamente'
         else 'BORRO la carrera y arrastro remates, caballos y pujas' end);
exception when others then
  perform _p.anotar(8, 'FK protege la cadena al borrar una carrera', 'la base rechaza el borrado', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P9 - Los retiros pendientes se restan del dinero de la casa
--  Tarea 1.4 - se espera FALLA antes de la correccion
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_res jsonb; v_casa numeric; v_pend numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  -- recarga de 1000 aprobada: la casa tiene 1000 en el banco
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF1', current_date);
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga((select id from public.deposit_requests limit 1));

  -- el usuario pide retirar los 1000: salen de su wallet, pero siguen en el banco
  perform _p.actuar_como(v_u);
  perform public.solicitar_retiro(1000, 'pago_movil', '04121234567');

  perform _p.actuar_como(v_admin);
  v_res  := public.admin_contabilidad_resumen();
  v_casa := (v_res->>'dinero_casa')::numeric;
  v_pend := (v_res->>'retiros_pendientes')::numeric;

  -- La casa tiene 1000 en el banco pero le debe 1000 al usuario: neto 0.
  perform _p.anotar(9, 'Retiros pendientes restados del dinero de la casa',
    'dinero_casa = 0', v_casa = 0,
    'dinero_casa: ' || v_casa::text || ' con ' || v_pend::text || ' pendientes de pago');
exception when others then
  perform _p.anotar(9, 'Retiros pendientes restados del dinero de la casa', 'dinero_casa = 0', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P10 - Aprobar dos veces la misma recarga no duplica el saldo
--  Tarea 1.7 - hoy ya pasa por el chequeo de estado; la guarda del UPDATE es
--  la segunda red. Esta prueba protege contra regresiones.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric; v_fallo2 boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(500, 'pago_movil', '04121234567', 'REF1', current_date);
  select id into v_dep from public.deposit_requests limit 1;

  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  begin
    perform public.aprobar_recarga(v_dep);   -- segundo intento
  exception when others then v_fallo2 := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  perform _p.anotar(10, 'Doble aprobacion de recarga no duplica saldo',
    'saldo = 500 y el segundo intento falla',
    v_saldo = 500 and v_fallo2,
    'saldo: ' || v_saldo::text || ' | segundo intento rechazado: ' || v_fallo2::text);
exception when others then
  perform _p.anotar(10, 'Doble aprobacion de recarga no duplica saldo', 'saldo = 500', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P11 - El cron y el boton dejan el remate en el MISMO estado
--  Tareas 1.8 + 1.9
--  El escenario necesita un usuario SUPERADO: es ahi donde el bucle de
--  liberacion del boton se dispara y el cron (UPDATE plano) no hace nada.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid;
        v_remA uuid; v_remB uuid; v_hA1 uuid; v_hA2 uuid; v_hB1 uuid; v_hB2 uuid;
        v_movA int; v_movB int; v_estA text; v_estB text; v_n int; v_errA text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  20000);
  v_u2    := _p.usuario('pedro', 20000);

  v_remA := _p.escenario(3, 100); v_hA1 := _p.caballo(v_remA,1); v_hA2 := _p.caballo(v_remA,2);
  v_remB := _p.escenario(3, 100); v_hB1 := _p.caballo(v_remB,1); v_hB2 := _p.caballo(v_remB,2);

  -- en ambos: juan es superado en el caballo 1 y queda lider del caballo 2
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remA, v_hA1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_remA, v_hA1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remA, v_hA2, 400, true);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remB, v_hB1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_remB, v_hB1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_remB, v_hB2, 400, true);

  update public.remates set closes_at = now() - interval '1 minute' where id in (v_remA, v_remB);

  -- A cierra por BOTON
  perform _p.actuar_como(v_admin);
  begin perform public.cerrar_remate(v_remA); exception when others then v_errA := sqlerrm; end;

  -- B cierra por CRON (sin usuario autenticado)
  perform set_config('request.jwt.claims', '', false);
  v_n := public.auto_cerrar_remates();
  perform _p.actuar_como(v_admin);

  select estado::text into v_estA from public.remates where id = v_remA;
  select estado::text into v_estB from public.remates where id = v_remB;
  select count(*) into v_movA from public.wallet_movements where ref_externa = v_remA::text;
  select count(*) into v_movB from public.wallet_movements where ref_externa = v_remB::text;

  perform _p.anotar(11, 'Cron y boton dejan el mismo estado',
    'ambos cerrados, 0 movimientos, sin error',
    v_errA = '' and v_estA = 'cerrado' and v_estB = 'cerrado' and v_movA = 0 and v_movB = 0,
    case when v_errA <> '' then 'el boton fallo: ' || v_errA
         else 'boton: ' || v_estA || ' con ' || v_movA::text || ' mov | cron: ' || v_estB ||
              ' con ' || v_movB::text || ' mov' end);
exception when others then
  perform _p.anotar(11, 'Cron y boton dejan el mismo estado', 'ambos cerrados, 0 movimientos', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P12 - El cron puede auditar sus propios fallos
--
--  auto_cerrar_remates captura el error de cada remate y lo manda a
--  log_admin_action con admin_id null, porque el cron corre sin usuario.
--  admin_actions.admin_id era NOT NULL y log_admin_action se traga sus propias
--  excepciones: el error del cron se perdia en silencio.
-- ============================================================================
do $$
declare v_antes int; v_despues int; v_fila record;
begin
  perform _p.limpiar();
  delete from public.admin_actions;
  select count(*) into v_antes from public.admin_actions;

  perform public.log_admin_action(
    null, 'auto_cerrar_remates', 'remates', gen_random_uuid()::text,
    jsonb_build_object('prueba', true), false, 'error simulado');

  select count(*) into v_despues from public.admin_actions;
  select * into v_fila from public.admin_actions limit 1;

  perform _p.anotar(12, 'El cron puede auditar sus propios fallos',
    '1 fila en admin_actions con admin_id null',
    v_despues = v_antes + 1 and v_fila.admin_id is null and v_fila.success = false,
    'filas: ' || v_despues::text || ' | error guardado: ' || coalesce(v_fila.error, '(ninguno)'));
exception when others then
  perform _p.anotar(12, 'El cron puede auditar sus propios fallos',
    '1 fila en admin_actions', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P13 - La regla individual del caballo le gana a la general del remate
--
--  hacer_puja ordenaba por `(r.horse_id = p_horse_id) desc`. Para la regla
--  general horse_id es NULL, `NULL = <uuid>` da NULL, y un ORDER BY DESC pone
--  los NULL primero: la general le ganaba a la individual, siempre.
--
--  OJO CON EL ESCENARIO: desde la tarea 2.17 la PRIMERA puja compra al precio
--  de salida exacto, sin sumar ningun incremento. O sea que en la primera puja
--  no interviene ninguna regla. La precedencia solo importa a partir de la
--  SEGUNDA. Por eso aqui se puja dos veces y se mide la segunda.
--
--  Se prueban los dos sentidos a proposito. Con un solo caso no se distingue
--  "tomo la general" de "tomo la mas chica" (o la mas grande).
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h uuid;
        v_caso_a numeric; v_caso_b numeric;
begin
  -- caso A: general 20, individual 100 -> la segunda puja debe ser 100 + 100 = 200
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 5 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, null, 0, null, 20);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 100);
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- primera: compra en 100
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- segunda: aqui manda la regla
  select max(monto) into v_caso_a from public.bids where horse_id = v_h;

  -- caso B: general 100, individual 20 -> la segunda puja debe ser 100 + 20 = 120
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 5 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, null, 0, null, 100);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 20);
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_caso_b from public.bids where horse_id = v_h;

  perform _p.anotar(13, 'La regla del caballo le gana a la del remate',
    'segunda puja: A = 200 (aumento individual 100) y B = 120 (aumento individual 20)',
    v_caso_a = 200 and v_caso_b = 120,
    'A: cobro ' || v_caso_a::text || ' (esperado 200) | B: cobro ' || v_caso_b::text || ' (esperado 120)');
exception when others then
  perform _p.anotar(13, 'La regla del caballo le gana a la del remate',
    'A = 200 y B = 120', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P14 - La primera puja compra el caballo AL precio de salida
--
--  Antes cobraba precio_salida + incremento. La casa se quedaba el caballo que
--  nadie pujo por su precio_salida pelado, asi que compraba a 100 lo que al
--  usuario le costaba 110.
--
--  Se comprueba ademas que la SEGUNDA puja si sube por el incremento: el fix no
--  puede romper la escalera.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h uuid;
        v_primera numeric; v_segunda numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 500);                 -- caballos a 500
  update public.remates set incremento_minimo = 100 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_primera from public.bids where horse_id = v_h;

  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_segunda from public.bids where horse_id = v_h;

  perform _p.anotar(14, 'La primera puja compra al precio de salida',
    'primera = 500 (salida exacta) y segunda = 600 (salida + incremento)',
    v_primera = 500 and v_segunda = 600,
    'primera: ' || v_primera::text || ' (esperado 500) | segunda: ' || v_segunda::text || ' (esperado 600)');
exception when others then
  perform _p.anotar(14, 'La primera puja compra al precio de salida',
    'primera = 500 y segunda = 600', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P15 - apuesta_minima ya no pisa nada, y la manual acepta desde el automatico
--
--  apuesta_minima se aplicaba DESPUES de elegir la regla, encima del resultado,
--  para cualquier caballo: era el unico parametro que no se podia sobreescribir
--  por caballo. Y la puja manual exigia el automatico + 10, un numero clavado.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_auto numeric; v_manual_ok boolean := false; v_manual_bajo_rechazado boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(3, 100);
  -- remate con un piso alto: antes, este 500 se comia al caballo de 100
  update public.remates set incremento_minimo = 10, apuesta_minima = 500 where id = v_rem;
  v_h1 := _p.caballo(v_rem, 1);
  v_h2 := _p.caballo(v_rem, 2);
  v_h3 := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u);

  perform public.hacer_puja(v_rem, v_h1, null, false);
  select max(monto) into v_auto from public.bids where horse_id = v_h1;

  -- manual EXACTAMENTE en el minimo automatico (100): debe aceptarse
  begin
    perform public.hacer_puja(v_rem, v_h2, 100, true);
    v_manual_ok := true;
  exception when others then v_manual_ok := false;
  end;

  -- manual por debajo (99): debe rechazarse
  begin
    perform public.hacer_puja(v_rem, v_h3, 99, true);
    v_manual_bajo_rechazado := false;
  exception when others then v_manual_bajo_rechazado := true;
  end;

  perform _p.anotar(15, 'Sin piso apuesta_minima y manual desde el automatico',
    'auto = 100 (no 500), manual de 100 aceptada, manual de 99 rechazada',
    v_auto = 100 and v_manual_ok and v_manual_bajo_rechazado,
    'auto: ' || v_auto::text || ' (esperado 100) | manual 100 aceptada: ' || v_manual_ok::text ||
    ' | manual 99 rechazada: ' || v_manual_bajo_rechazado::text);
exception when others then
  perform _p.anotar(15, 'Sin piso apuesta_minima y manual desde el automatico',
    'auto = 100, manual 100 ok, manual 99 no', false, 'excepcion: ' || sqlerrm);
end $$;


-- ---------------------------------------------------------------- resumen
\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _p.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _p.resultado;
