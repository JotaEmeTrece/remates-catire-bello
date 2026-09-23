-- ============================================================================
--  PRUEBAS DE DINERO — Remates Catire Bello
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
--  P1 · El caballo retirado no debe entrar al pozo
--  Defecto C1 — se espera FALLA contra el codigo actual (tarea 1.1)
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
    'premio real: ' || coalesce(v_premio_real,0)::text || ' — si da 300, el retirado sumo 100 al pozo');
exception when others then
  perform _p.anotar(1, 'Caballo retirado fuera del pozo', 'premio = 225 (75% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P2 · La comision debe salir de porcentaje_casa, no de un 0.75 clavado
--  Defecto C2 — se espera FALLA contra el codigo actual (tarea 1.2)
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
    'premio real: ' || coalesce(v_premio,0)::text || ' — si da 225, uso el 0.75 clavado');
exception when others then
  perform _p.anotar(2, 'porcentaje_casa se respeta', 'premio = 210 (70% de 300)', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P3 · Si gana un caballo de la casa, no se paga premio
--  Se espera OK — esta regla ya funciona
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
--  P4 · No se puede acreditar un premio que la casa no puede pagar
--  Defecto C1.3 — se espera FALLA (no hay guarda de solvencia) (tarea 1.3)
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
--  P5 · Escenario mas comun del remate: alguien es superado
--  Defecto en cerrar_remate — se espera FALLA (tarea 1.8)
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
--  P6 · El libro cuadra con los saldos
-- ============================================================================
do $$
declare v_desc int;
begin
  select count(*) into v_desc from (
    select w.user_id, w.saldo_disponible + w.saldo_bloqueado as saldo,
           coalesce((select sum(m.monto) from public.wallet_movements m where m.wallet_id = w.id), 0) as libro
    from public.wallets w
  ) x where abs(saldo - libro) > 0.001 and libro <> 0;
  perform _p.anotar(6, 'Libro de movimientos cuadra con saldos', '0 wallets descuadradas',
    v_desc = 0, 'wallets descuadradas: ' || v_desc::text);
exception when others then
  perform _p.anotar(6, 'Libro de movimientos cuadra con saldos', '0 descuadres', false, 'excepcion: ' || sqlerrm);
end $$;

-- ---------------------------------------------------------------- resumen
\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _p.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _p.resultado;
