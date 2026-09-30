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
--
--  ---------------------------------------------------------------------------
--  REGLA, APRENDIDA A GOLPES EL 28/09
--
--  Cuando el exito de una prueba consiste en "salto una excepcion", hay que
--  comprobar CUAL excepcion.
--
--  P39 pasaba en verde SIN la migracion aplicada. Llamaba a una funcion que
--  todavia no existia, saltaba `function does not exist`, y su
--  `exception when others` lo contaba como el rechazo que buscaba. Las dos
--  mitades de la prueba aprobaban por la misma razon: no habia nada que
--  probar. Es lo contrario de lo que dice el ADR-009, y estaba dentro del
--  propio arnes.
--
--  Un `when others` se traga tanto el rechazo que buscas como el error que
--  significa que no estas probando nada. Los dos que importan:
--
--    P0001 = raise_exception     -> NUESTRO codigo rechazo, a proposito
--    42883 = undefined_function  -> la migracion no esta aplicada
--    23503 = foreign_key_violation -> lo freno una clave foranea
--    42501 = insufficient_privilege -> lo freno un permiso
--
--  Y no basta con que rechace: hay que comprobar ADEMAS que no escribio nada.
--  Ver P39 como patron.
--
--  PENDIENTE: hay 66 bloques con `exception when others` en este archivo. Los
--  demas prueban funciones que llevan tiempo existiendo, asi que el riesgo es
--  menor, pero la trampa es la misma el dia que una migracion renombre algo.
--  Retrofit anotado en el backlog; las pruebas NUEVAS siguen la regla ya.
--  ---------------------------------------------------------------------------
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
  -- ANTES que profiles: house_ledger.created_by apunta ahi. Es el mismo
  -- problema de orden que tenia reset_app_cero.sql con race_results.
  delete from public.house_ledger;
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

  -- Registra la recarga aprobada que respalda ese saldo.
  --
  -- Sin esto el andamiaje crea dinero de la nada: la wallet tiene saldo pero la
  -- casa no recibio nunca ese deposito, asi que dinero_casa_disponible() da
  -- negativo desde el primer momento. La guarda de solvencia de la tarea 1.3
  -- saltaba en TODAS las pruebas, y parecia un defecto del codigo cuando el
  -- problema era el escenario.
  --
  -- En la aplicacion real el dinero solo entra por aprobar_recarga, que deja su
  -- fila en deposit_requests. El arnes tiene que reflejar eso o no esta
  -- probando el sistema, esta probando una ficcion.
  if p_saldo > 0 then
    insert into public.deposit_requests
      (user_id, monto, metodo, telefono_pago, referencia, fecha_pago, estado, approved_at)
    values
      (v_id, p_saldo, 'pago_movil', '04120000000', 'ANDAMIAJE-' || p_nombre,
       current_date, 'aprobado', now());
  end if;

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
declare v_admin uuid; v_u uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_premio_real numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);           -- 3 caballos a 100
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  v_h3    := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u);  perform public.hacer_puja(v_rem, v_h1, 200, true);  -- juan el 1 en 200
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false); -- pedro el 3 en 100

  update public.horses set retirado = true where id = v_h2;  -- se retira el 2

  -- Pozo correcto: 200 (caballo 1) + 100 (caballo 3) = 300. El caballo 2 esta
  -- retirado y NO debe sumar; si sumara, el pozo daria 400 y el premio 300.
  --
  -- Pedro puja el tercer caballo a proposito: si quedara a la casa, la casa
  -- aportaria 100 al pozo sin que ese dinero haya entrado por caja, y la guarda
  -- de solvencia bloquearia la liquidacion antes de que esta prueba pueda medir
  -- nada. Ese hueco es real y esta anotado como tarea 2.18 (capital de la casa);
  -- aqui se evita a proposito para que la prueba mida lo suyo.

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
declare v_admin uuid; v_u uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_premio numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(2, 100, 30);      -- porcentaje_casa = 30
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);  perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, null, false);
  -- Pozo = 200 + 100 = 300. Con la casa al 30%, el premio debe ser 210, no 225.
  -- El 30 no es lo que cobra la casa: es un valor distinto del 25 por defecto,
  -- elegido para que la prueba detecte si el codigo ignora la columna. Con 25
  -- pasaria en verde aunque el 0.75 siguiera clavado.

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
--  P4 - La casa no puede acreditar un premio que no puede pagar
--
--  REESCRITA EN LA TAJADA D. El escenario anterior le daba 100 Bs al usuario y
--  le hacia pujar 510: desde la tajada B esa puja la rechaza la guarda de
--  exposicion, asi que no habia pujas, no habia premio, y la liquidacion pasaba
--  sin probar nada. La prueba se habia vuelto ciega.
--
--  ESCENARIO NUEVO, y es el riesgo real del negocio:
--  juan recarga 600 y toma UN caballo de 500. Los otros NUEVE quedan a la casa
--  y entran al pozo por su precio de salida, sin que ese dinero haya entrado
--  nunca por caja. Pozo 5.000, premio 3.750. La casa recibio 500 de verdad.
--  Acreditar 3.750 es prometer un saldo que no se puede pagar cuando el usuario
--  lo vaya a retirar.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_fallo boolean := false; v_saldo numeric; v_premios int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 600);
  v_rem   := _p.escenario(10, 500);          -- 10 caballos a 500
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);   -- toma el 1 en 500

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);                   -- le cobra 500, le quedan 100
  perform public.set_ganador_carrera(v_rem, 1);
  begin
    perform public.liquidar_remate(v_rem);
  exception when others then v_fallo := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_premios from public.wallet_movements where tipo = 'premio';

  perform _p.anotar(4, 'La casa no acredita un premio que no puede pagar',
    'la liquidacion falla y no se acredita nada; el saldo de juan sigue en 100',
    v_fallo and v_saldo = 100 and v_premios = 0,
    'fallo: ' || v_fallo::text || ' | saldo de juan: ' || v_saldo::text ||
    ' (esperado 100) | movimientos de premio: ' || v_premios::text || ' (esperado 0)');
exception when others then
  perform _p.anotar(4, 'La casa no acredita un premio que no puede pagar',
    'la liquidacion falla y no acredita', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P5 - Escenario mas comun del remate: a alguien lo superan
--
--  REESCRITA EN LA TAJADA D. Antes medía `saldo_bloqueado = 400`. Esa columna
--  ya no se usa y vale 0 siempre por diseño, asi que el assert se volvio falso
--  sin que el sistema tuviera nada malo. El equivalente correcto en el modelo
--  v2 es `compromiso_usuario() = 400`: lo mismo que antes se guardaba, ahora se
--  calcula.
--
--  juan puja el caballo 1, pedro lo supera, juan se va al caballo 2 y lo lidera.
--  Al cerrar deben cobrarle a juan 400 (solo el caballo que lidera, no los 600
--  de las dos pujas) y a pedro 300.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_error text := ''; v_comp numeric; v_juan numeric; v_pedro numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  v_h3    := _p.caballo(v_rem, 3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);  -- supera a juan
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);  -- juan lidera el 2
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false); -- pedro el 3 en 100

  v_comp := public.compromiso_usuario(v_u1);

  perform _p.actuar_como(v_admin);
  begin
    perform public.cerrar_remate(v_rem);
    perform public.set_ganador_carrera(v_rem, 2);   -- gana el caballo de juan
    perform public.liquidar_remate(v_rem);
  exception when others then v_error := sqlerrm;
  end;

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;

  -- juan: 10000 - 400 (cobro) + 600 (premio: 75% de un pozo de 800) = 10200
  -- pedro: 10000 - 300 - 100 = 9600
  perform _p.anotar(5, 'Usuario superado: compromiso, cobro y premio correctos',
    'compromiso de juan = 400 (no 600); sin error; juan 10200 y pedro 9600',
    v_error = '' and v_comp = 400 and v_juan = 10200 and v_pedro = 9600,
    case when v_error <> '' then 'error: ' || v_error
         else 'compromiso: ' || v_comp::text || ' (esperado 400) | juan: ' || v_juan::text ||
              ' (esperado 10200) | pedro: ' || v_pedro::text || ' (esperado 9600)' end);
exception when others then
  perform _p.anotar(5, 'Usuario superado: compromiso, cobro y premio correctos',
    'compromiso 400, sin error', false, 'excepcion: ' || sqlerrm);
end $$;

-- ============================================================================
--  P6 - El libro de movimientos reconstruye los saldos, SIN listas a mano
--
--  VERSION DE LA TAJADA C. La anterior tenia que enumerar a mano que tipos de
--  movimiento contaban para cada invariante:
--
--      where m.tipo in ('recarga','premio','retiro','ajuste_manual')
--
--  Esa lista era el defecto 2.19 hecho codigo: `monto` no era un delta con
--  signo, porque apuesta_bloqueo y apuesta_desbloqueo solo movian dinero entre
--  columnas sin cambiar el saldo total. La prueba se rompio sola en cuanto
--  aparecio `apuesta_cobro`, que no estaba en la lista.
--
--  Con el modelo v2 ya no hay bloqueo durante el remate, asi que TODO
--  movimiento es un delta con signo sobre el saldo real. Por eso ahora el
--  invariante se puede escribir como debe ser:
--
--      saldo_disponible + saldo_bloqueado = suma de TODOS los movimientos
--
--  Sin `where tipo in (...)`. Ese es el criterio de aceptacion de la tarea 2.19,
--  y esta prueba es lo que lo verifica. Si alguien vuelve a introducir un tipo
--  que no sea un delta con signo, esto se pone rojo.
--
--  Invariante B: saldo_bloqueado tiene que ser 0 en todas las wallets. La
--  columna sigue existiendo a proposito (DISENO_SALDO_V2.md §9: se verifica
--  unas semanas en 0 y despues se borra). Esta prueba es la verificacion.
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
  begin perform public.cerrar_remate(v_rem);          exception when others then null; end;
  begin perform public.set_ganador_carrera(v_rem, 2); exception when others then null; end;
  begin perform public.liquidar_remate(v_rem);        exception when others then null; end;

  perform _p.actuar_como(v_u1);
  begin perform public.solicitar_retiro(100, 'pago_movil', '04121234567'); exception when others then null; end;

  -- A: el libro completo, sin filtrar por tipo
  select count(*) into v_desc_a from (
    select w.id,
           w.saldo_disponible + w.saldo_bloqueado as saldo,
           coalesce((select sum(m.monto) from public.wallet_movements m
                     where m.wallet_id = w.id), 0) as libro
    from public.wallets w
  ) x where abs(saldo - libro) > 0.001;

  -- B: saldo_bloqueado debe estar muerto
  select count(*) into v_desc_b
  from public.wallets where coalesce(saldo_bloqueado, 0) <> 0;

  select string_agg(p.username || ': saldo ' || (w.saldo_disponible + w.saldo_bloqueado)::text ||
                    ' / libro ' || coalesce((select sum(m.monto) from public.wallet_movements m
                                             where m.wallet_id = w.id), 0)::text,
                    ' | ' order by p.username)
    into v_detalle
  from public.wallets w join public.profiles p on p.id = w.user_id;

  perform _p.anotar(6, 'El libro reconstruye los saldos sin listas a mano',
    'saldo = suma de TODOS los movimientos, y saldo_bloqueado en 0',
    v_desc_a = 0 and v_desc_b = 0,
    'descuadres A(libro): ' || v_desc_a::text || ', B(bloqueado<>0): ' || v_desc_b::text ||
    ' | ' || coalesce(v_detalle,''));
exception when others then
  perform _p.anotar(6, 'El libro reconstruye los saldos sin listas a mano',
    'saldo = suma de todos los movimientos', false, 'excepcion: ' || sqlerrm);
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
        v_sumA numeric; v_sumB numeric;
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
  -- ACTUALIZADA EN LA TAJADA C. Antes exigia 0 movimientos, porque cerrar solo
  -- cambiaba un estado. Desde C, cerrar COBRA, asi que 0 movimientos ya no es
  -- lo correcto: lo correcto es que los dos caminos cobren LO MISMO.
  -- El assert nuevo es mas fuerte que el viejo: compara cantidad Y monto, y
  -- exige cobro distinto de cero, asi que tampoco pasaria si el cierre dejara
  -- de cobrar por los dos lados a la vez.
  select count(*), coalesce(sum(monto),0) into v_movA, v_sumA
    from public.wallet_movements where ref_externa = v_remA::text;
  select count(*), coalesce(sum(monto),0) into v_movB, v_sumB
    from public.wallet_movements where ref_externa = v_remB::text;

  perform _p.anotar(11, 'Cron y boton cobran exactamente lo mismo',
    'ambos cerrados; mismo numero de movimientos y mismo monto, y distinto de cero',
    v_errA = '' and v_estA = 'cerrado' and v_estB = 'cerrado'
      and v_movA = v_movB and v_sumA = v_sumB and v_movA > 0,
    case when v_errA <> '' then 'el boton fallo: ' || v_errA
         else 'boton: ' || v_estA || ' con ' || v_movA::text || ' mov por ' || v_sumA::text ||
              ' | cron: ' || v_estB || ' con ' || v_movB::text || ' mov por ' || v_sumB::text end);
exception when others then
  perform _p.anotar(11, 'Cron y boton cobran exactamente lo mismo', 'mismo cobro por los dos caminos', false, 'excepcion: ' || sqlerrm);
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
--  P13 - La escalera del caballo le gana al incremento del remate
--
--  REESCRITA EL 30/09. La version original probaba la precedencia entre la
--  regla GENERAL (horse_id nulo) y la del caballo: hacer_puja ordenaba por
--  `(r.horse_id = p_horse_id) desc`, y como `NULL = <uuid>` da NULL y un
--  ORDER BY DESC pone los NULL primero, la general ganaba siempre.
--
--  Esa precedencia ya no existe: la migracion 20260930100000 elimino la regla
--  general de la base entera -- `horse_id` es NOT NULL -- porque era una
--  segunda fuente invisible del mismo numero y le ganaba a
--  `remates.incremento_minimo` sin que nadie lo viera.
--
--  La prueba no se parchea, se reescribe: mide la precedencia que SI queda en
--  pie, que es la del caballo sobre el incremento del remate. Mismos importes
--  esperados, misma logica de dos sentidos.
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
  -- caso A: remate 20, caballo 100 -> la segunda puja debe ser 100 + 100 = 200
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 20 where id = v_rem;   -- el del remate
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 100);                                 -- el del caballo
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- primera: compra en 100
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- segunda: aqui manda la regla
  select max(monto) into v_caso_a from public.bids where horse_id = v_h;

  -- caso B: remate 100, caballo 20 -> la segunda puja debe ser 100 + 20 = 120
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 100 where id = v_rem;  -- el del remate
  v_h := _p.caballo(v_rem, 1);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h, 0, null, 20);                                  -- el del caballo
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h, null, false);
  perform _p.actuar_como(v_u2);
  perform public.hacer_puja(v_rem, v_h, null, false);
  select max(monto) into v_caso_b from public.bids where horse_id = v_h;

  perform _p.anotar(13, 'La escalera del caballo le gana al incremento del remate',
    'segunda puja: A = 200 (escalera del caballo 100) y B = 120 (escalera del caballo 20)',
    v_caso_a = 200 and v_caso_b = 120,
    'A: cobro ' || v_caso_a::text || ' (esperado 200) | B: cobro ' || v_caso_b::text || ' (esperado 120)');
exception when others then
  perform _p.anotar(13, 'La escalera del caballo le gana al incremento del remate',
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


-- ============================================================================
--  P16 - compromiso_usuario: si te superan, esa puja deja de contar
--  DISENO_SALDO_V2.md §7bis, escenario 1
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_hA uuid; v_hB uuid; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(2, 100);
  update public.remates set incremento_minimo = 100 where id = v_rem;
  v_hA := _p.caballo(v_rem, 1);
  v_hB := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_hA, null, false);  -- 100
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_hA, null, false);  -- 200, supera a juan
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_hB, 200, true);    -- juan lidera B en 200

  v_comp := public.compromiso_usuario(v_u1);
  perform _p.anotar(16, 'Compromiso: la puja superada deja de contar',
    'compromiso de juan = 200 (no 300)',
    v_comp = 200, 'compromiso: ' || v_comp::text || ' (si da 300, sumo la puja superada)');
exception when others then
  perform _p.anotar(16, 'Compromiso: la puja superada deja de contar', '200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P17 - compromiso_usuario: subirse la propia puja reemplaza, no suma
--  DISENO_SALDO_V2.md §7bis, escenario 2. El "delta" sale gratis.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(2, 200);
  update public.remates set incremento_minimo = 10 where id = v_rem;
  v_h := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);   -- toma el caballo en 200
  perform public.hacer_puja(v_rem, v_h, 260, true);     -- se sube a si mismo a 260

  v_comp := public.compromiso_usuario(v_u);
  perform _p.anotar(17, 'Compromiso: subirse la propia puja reemplaza',
    'compromiso = 260 (no 460)',
    v_comp = 260, 'compromiso: ' || v_comp::text || ' (si da 460, sumo las dos pujas)');
exception when others then
  perform _p.anotar(17, 'Compromiso: subirse la propia puja reemplaza', '260', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P18 - compromiso_usuario: retirar el caballo lo saca del compromiso
--  DISENO_SALDO_V2.md §7bis, escenario 3. Sin tocar un solo peso.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_antes numeric; v_despues numeric; v_movs int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000000);
  v_rem   := _p.escenario(2, 300);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);
  v_antes := public.compromiso_usuario(v_u);

  update public.horses set retirado = true where id = v_h;
  v_despues := public.compromiso_usuario(v_u);

  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(18, 'Compromiso: el caballo retirado sale solo',
    'antes 300, despues 0, y sin movimientos nuevos de wallet',
    v_antes = 300 and v_despues = 0,
    'antes: ' || v_antes::text || ' | despues: ' || v_despues::text ||
    ' | movimientos de wallet en total: ' || v_movs::text);
exception when others then
  perform _p.anotar(18, 'Compromiso: el caballo retirado sale solo', 'antes 300, despues 0', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P19 - dinero_casa_disponible() y el panel de contabilidad dan lo mismo
--
--  Si estos dos numeros se separan, la guarda de solvencia protege contra una
--  caja distinta a la que el admin ve en pantalla.
--
--  SE MIDE EN DOS MOMENTOS A PROPOSITO. El punto que discrimina es el primero:
--  con el remate cerrado y sin liquidar, parte del dinero de juan esta en
--  saldo_bloqueado. Si dinero_casa_disponible() restara solo saldo_disponible
--  (como decia el diseno original), ahi daria 100 mientras el panel da 0.
--  El segundo momento comprueba ademas que el numero no es cero por casualidad.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_dep uuid; v_rem uuid; v_h uuid;
        v_f1 numeric; v_p1 numeric; v_f2 numeric; v_p2 numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);

  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF1', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);

  v_rem := _p.escenario(2, 100);
  v_h   := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);      -- juan toma el 1 en 100

  -- MOMENTO 1: cerrado y sin liquidar. Juan tiene 900 disponible y 100 bloqueado.
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  v_f1 := public.dinero_casa_disponible();
  v_p1 := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  -- MOMENTO 2: gana el caballo 2, que es de la casa. No hay premio, y la
  -- liquidacion le cobra a juan los 100. La casa se queda con ellos.
  perform public.set_ganador_carrera(v_rem, 2);
  perform public.liquidar_remate(v_rem);
  v_f2 := public.dinero_casa_disponible();
  v_p2 := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  perform _p.anotar(19, 'La caja de la funcion y la del panel coinciden',
    'iguales en los dos momentos, y 100 al final (no cero por casualidad)',
    v_f1 = v_p1 and v_f2 = v_p2 and v_f2 = 100,
    'cerrado sin liquidar -> funcion: ' || v_f1::text || ' / panel: ' || v_p1::text ||
    ' | liquidado -> funcion: ' || v_f2::text || ' / panel: ' || v_p2::text || ' (esperado 100)');
exception when others then
  perform _p.anotar(19, 'La caja de la funcion y la del panel coinciden',
    'iguales en los dos momentos y 100 al final', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P20 - La guarda de exposicion: el compromiso cruza todos los remates
--
--  Un usuario con 500 Bs no puede liderar dos caballos de 300. El modelo viejo
--  lo impedia porque descontaba del saldo al pujar; el v2 no descuenta nada,
--  asi que la unica defensa es esta guarda.
--
--  Se comprueba ademas que pujar NO escribe en wallets ni en wallet_movements.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_hA uuid; v_hB uuid;
        v_err text := ''; v_comp numeric; v_saldo numeric; v_movs int;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 500);
  v_rem   := _p.escenario(2, 300);
  v_hA := _p.caballo(v_rem, 1);
  v_hB := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_hA, null, false);        -- 300, entra
  begin
    perform public.hacer_puja(v_rem, v_hB, null, false);      -- otros 300, no caben
  exception when others then v_err := sqlerrm;
  end;

  v_comp  := public.compromiso_usuario(v_u);
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(20, 'Guarda de exposicion entre remates',
    'la 2da puja se rechaza; compromiso 300, saldo intacto en 500, 0 movimientos',
    v_err <> '' and v_comp = 300 and v_saldo = 500 and v_movs = 0,
    'compromiso: ' || v_comp::text || ' | saldo: ' || v_saldo::text ||
    ' | movimientos: ' || v_movs::text ||
    ' | 2da puja: ' || coalesce(nullif(v_err,''), 'ACEPTADA (mal)'));
exception when others then
  perform _p.anotar(20, 'Guarda de exposicion entre remates', 'la 2da se rechaza', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P21 - hacer_puja toma el candado por USUARIO, no solo por caballo
--
--  Es el punto critico del modelo v2. La guarda de P20 cruza TODOS los remates
--  abiertos de un usuario, asi que serializar por caballo no alcanza: dos pujas
--  simultaneas del mismo usuario a caballos distintos leen el mismo compromiso
--  viejo y pasan las dos.
--
--  REPRODUCIDO el 24/09/2026 con dos conexiones reales a PostgreSQL 16,
--  usuario con 500 Bs y dos pujas simultaneas de 300:
--
--    sin candado por usuario -> 2 pujas aceptadas, 600 comprometidos ❌
--    con candado por usuario -> 1 aceptada, 1 rechazada, 300 comprometidos ✅
--
--  Esa prueba necesita dos conexiones y no cabe en este arnes. Lo que SI cabe,
--  y es una guarda de regresion de verdad, es comprobar en pg_locks que los dos
--  candados quedan efectivamente tomados: espacio 1 (usuario) y espacio 2
--  (remate+caballo). Si alguien reescribe la funcion y se lleva por delante el
--  primero, esta prueba se pone roja.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_usuario boolean; v_caballo boolean;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);

  select exists (select 1 from pg_locks
                 where locktype = 'advisory' and pid = pg_backend_pid()
                   and classid = 1 and objsubid = 2)
    into v_usuario;
  select exists (select 1 from pg_locks
                 where locktype = 'advisory' and pid = pg_backend_pid()
                   and classid = 2 and objsubid = 2)
    into v_caballo;

  perform _p.anotar(21, 'La puja toma el candado por usuario y por caballo',
    'los dos candados advisory tomados (espacio 1 y espacio 2)',
    v_usuario and v_caballo,
    'candado de usuario: ' || v_usuario::text || ' | candado de caballo: ' || v_caballo::text);
exception when others then
  perform _p.anotar(21, 'La puja toma el candado por usuario y por caballo',
    'los dos candados tomados', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P22 - Cancelar un remate CERRADO devuelve exactamente lo cobrado
--
--  Es la ruta de salida de la tarea 2.13. Hasta hoy, un remate que se cerraba y
--  no se podia liquidar -carrera suspendida, el admin no alcanza a cargar el
--  ganador, la liquidacion falla- dejaba el dinero cobrado sin forma de
--  devolverlo salvo metiendo mano en la base de datos.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_juan numeric; v_pedro numeric; v_estado text; v_segunda boolean := false;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000);
  v_u2    := _p.usuario('pedro', 1000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, 300, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);                       -- cobra 200 y 300
  perform public.cancelar_remate(v_rem, 'Carrera suspendida');

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;
  select estado::text into v_estado from public.remates where id = v_rem;

  begin
    perform public.cancelar_remate(v_rem, 'otra vez');
  exception when others then v_segunda := true;
  end;

  perform _p.anotar(22, 'Cancelar un remate cerrado devuelve lo cobrado',
    'juan y pedro vuelven a 1000, estado cancelado, y no se puede cancelar dos veces',
    v_juan = 1000 and v_pedro = 1000 and v_estado = 'cancelado' and v_segunda,
    'juan: ' || v_juan::text || ' | pedro: ' || v_pedro::text || ' | estado: ' || v_estado ||
    ' | segunda cancelacion rechazada: ' || v_segunda::text);
exception when others then
  perform _p.anotar(22, 'Cancelar un remate cerrado devuelve lo cobrado',
    'los dos vuelven a 1000', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P23 - Cancelar un remate ABIERTO no mueve un solo peso
--
--  En el modelo anterior habia que localizar cada bloqueo y revertirlo, con el
--  riesgo de descuadre que eso traia. En el v2 no se cobro nada todavia, asi
--  que no hay nada que devolver: el compromiso baja solo porque el remate deja
--  de estar abierto.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_saldo numeric; v_comp numeric; v_movs int; v_estado text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);

  perform _p.actuar_como(v_admin);
  perform public.cancelar_remate(v_rem, 'Se cayo la jornada');

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  v_comp := public.compromiso_usuario(v_u);
  select count(*) into v_movs from public.wallet_movements;
  select estado::text into v_estado from public.remates where id = v_rem;

  perform _p.anotar(23, 'Cancelar un remate abierto no mueve dinero',
    'saldo intacto en 1000, compromiso 0, cero movimientos de wallet',
    v_saldo = 1000 and v_comp = 0 and v_movs = 0 and v_estado = 'cancelado',
    'saldo: ' || v_saldo::text || ' | compromiso: ' || v_comp::text ||
    ' | movimientos: ' || v_movs::text || ' | estado: ' || v_estado);
exception when others then
  perform _p.anotar(23, 'Cancelar un remate abierto no mueve dinero',
    'nada se mueve', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P24 - No se puede retirar dinero que esta comprometido en pujas
--
--  🔴 SE ESPERA ROJA hasta la tajada E. Es el hueco que abren B, C y D juntas,
--  y esta escrito como prueba para que no se olvide.
--
--  En el modelo anterior, pujar descontaba de saldo_disponible, asi que el
--  retiro no podia tocar ese dinero: ya no estaba ahi. En el v2 el dinero se
--  queda en saldo_disponible hasta que cierra el remate, y solicitar_retiro
--  sigue comprobando solo `saldo_disponible >= monto`. Resultado: un usuario
--  con 1000 comprometidos en 800 puede pedir el retiro de los 1000, y cuando
--  el remate cierre, el cobro va a reventar con "Invariante roto".
--
--  La correccion es §7 del diseño: retirable = saldo - compromiso, con el mismo
--  candado por usuario que hacer_puja.
--
--  ⚠️ MIENTRAS ESTA PRUEBA SIGA ROJA, la aplicacion NO puede tener usuarios
--  reales pujando, aunque las migraciones esten en produccion.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_rechazado boolean := false; v_saldo numeric; v_comp numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 800);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);    -- toma el caballo en 800
  v_comp := public.compromiso_usuario(v_u);

  begin
    perform public.solicitar_retiro(1000, 'pago_movil', '04121234567');
  exception when others then v_rechazado := true;
  end;

  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;

  perform _p.anotar(24, 'No se retira dinero comprometido en pujas',
    'el retiro de 1000 se rechaza: solo 200 son retirables',
    v_rechazado and v_saldo = 1000,
    'compromiso: ' || v_comp::text || ' | retiro de 1000 rechazado: ' || v_rechazado::text ||
    ' | saldo tras el intento: ' || v_saldo::text || ' (si bajo a 0, se llevo dinero comprometido)');
exception when others then
  perform _p.anotar(24, 'No se retira dinero comprometido en pujas',
    'el retiro se rechaza', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P25 - mi_wallet_resumen devuelve los tres numeros
--
--  Que el usuario vea "tienes 1000, 800 comprometidos en pujas, puedes retirar
--  200" evita la mitad de los mensajes a soporte, y sobre todo evita que
--  intente el retiro y reciba un error que no entiende.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h uuid;
        v_total numeric; v_comp numeric; v_retirable numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 800);
  v_h     := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);      -- compromete 800

  select saldo_disponible, comprometido, disponible_para_retirar
    into v_total, v_comp, v_retirable
  from public.mi_wallet_resumen();

  perform _p.anotar(25, 'mi_wallet_resumen devuelve los tres numeros',
    'total 1000, comprometido 800, retirable 200',
    v_total = 1000 and v_comp = 800 and v_retirable = 200,
    'total: ' || v_total::text || ' | comprometido: ' || v_comp::text ||
    ' | retirable: ' || v_retirable::text);
exception when others then
  perform _p.anotar(25, 'mi_wallet_resumen devuelve los tres numeros',
    'total 1000, comprometido 800, retirable 200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P26 - Retirar un caballo con el remate ABIERTO no toca el dinero
--
--  Este es el argumento a favor de todo el rediseno. En el modelo anterior
--  habia que localizar el bloqueo del lider y revertirlo con cuidado. Aqui la
--  puja deja de contar sola, porque compromiso_usuario() excluye los retirados.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_antes numeric; v_despues numeric; v_saldo numeric; v_movs int; v_msg text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 300);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);   -- 300
  perform public.hacer_puja(v_rem, v_h2, null, false);   -- 300 mas, total 600
  v_antes := public.compromiso_usuario(v_u);

  perform _p.actuar_como(v_admin);
  v_msg := public.retirar_caballo(v_h1, 'Se lesiono en el paddock');

  v_despues := public.compromiso_usuario(v_u);
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;
  select count(*) into v_movs from public.wallet_movements;

  perform _p.anotar(26, 'Retirar un caballo con el remate abierto no mueve dinero',
    'compromiso baja de 600 a 300 solo, saldo intacto en 1000, 0 movimientos',
    v_antes = 600 and v_despues = 300 and v_saldo = 1000 and v_movs = 0,
    'compromiso: ' || v_antes::text || ' -> ' || v_despues::text ||
    ' | saldo: ' || v_saldo::text || ' | movimientos: ' || v_movs::text || ' | ' || v_msg);
exception when others then
  perform _p.anotar(26, 'Retirar un caballo con el remate abierto no mueve dinero',
    'nada se mueve', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P27 - Retirar un caballo con el remate YA CERRADO devuelve lo cobrado
--
--  Aqui si hubo cobro, asi que hay que devolver. Se devuelve exactamente la
--  puja mas alta sobre ese caballo, que es lo que se cobro por el al cerrar.
--  Se comprueba ademas que retirarlo dos veces se rechaza: si no, cada clic
--  devolveria el dinero otra vez.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
        v_juan numeric; v_pedro numeric; v_segunda boolean := false; v_msg text;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000);
  v_u2    := _p.usuario('pedro', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h1 := _p.caballo(v_rem, 1); v_h2 := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h2, 300, true);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);        -- cobra 200 a juan y 300 a pedro
  v_msg := public.retirar_caballo(v_h1, 'Retirado despues del cierre');

  begin
    perform public.retirar_caballo(v_h1, 'otra vez');
  exception when others then v_segunda := true;
  end;

  select saldo_disponible into v_juan  from public.wallets where user_id = v_u1;
  select saldo_disponible into v_pedro from public.wallets where user_id = v_u2;

  perform _p.anotar(27, 'Retirar un caballo ya cobrado devuelve exactamente lo suyo',
    'juan vuelve a 1000, pedro sigue en 700, y no se puede retirar dos veces',
    v_juan = 1000 and v_pedro = 700 and v_segunda,
    'juan: ' || v_juan::text || ' (esperado 1000) | pedro: ' || v_pedro::text ||
    ' (esperado 700) | segundo retiro rechazado: ' || v_segunda::text || ' | ' || v_msg);
exception when others then
  perform _p.anotar(27, 'Retirar un caballo ya cobrado devuelve exactamente lo suyo',
    'juan 1000, pedro 700', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P28 - La RPC de minimos dice EXACTAMENTE lo que cobra hacer_puja
--
--  Esta es la prueba de la tarea 2.20 y la mas importante de la tajada F.
--
--  Hasta hoy el frontend recalculaba la escalera de precios en TypeScript y la
--  base la calculaba por su cuenta. El 23/09 se demostro que se habian separado
--  sin que nadie se enterara: la pantalla elegia la regla del caballo y la base
--  la general. El usuario leia un numero y la base cobraba otro.
--
--  Ahora las dos salen de _incremento_aplicable(). Esta prueba lo verifica caso
--  por caballo, en un escenario con dos escaleras propias distintas, un caballo
--  sin escalera que cae al incremento del remate, caballos ya pujados y uno
--  virgen.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid;
        v_h1 uuid; v_h2 uuid; v_h3 uuid;
        r record; v_dicho numeric; v_cobrado numeric;
        v_fallos int := 0; v_detalle text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  1000000);
  v_u2    := _p.usuario('pedro', 1000000);
  v_rem   := _p.escenario(3, 100);
  update public.remates set incremento_minimo = 7 where id = v_rem;   -- fallback raro a proposito
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  -- Escalera propia para el 1 y para el 2, con incrementos distintos; el 3 se
  -- queda sin ninguna y tiene que caer al incremento_minimo del remate (7).
  -- Antes del 30/09 esto se montaba con una regla general para todos; esa
  -- clase de fila ya no existe (migracion 20260930100000).
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h1, 0, null, 25);
  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, v_h2, 0, null, 150);

  -- el 1 y el 2 ya tienen puja; el 3 queda virgen
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, null, false);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, null, false);

  -- para cada caballo: lo que dice la RPC contra lo que cobra la puja
  for r in select horse_id, numero, minimo_auto from public.remate_minimos(v_rem) order by numero
  loop
    v_dicho := r.minimo_auto;
    perform _p.actuar_como(v_u2);
    perform public.hacer_puja(v_rem, r.horse_id, null, false);
    select max(monto) into v_cobrado from public.bids where horse_id = r.horse_id;

    if v_cobrado <> v_dicho then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || 'caballo ' || r.numero::text ||
                   ': RPC dijo ' || v_dicho::text || ' y cobro ' || v_cobrado::text || '; ';
    else
      v_detalle := v_detalle || 'c' || r.numero::text || '=' || v_cobrado::text || ' ';
    end if;
  end loop;

  perform _p.anotar(28, 'La RPC de minimos coincide con lo que cobra la puja',
    'para cada caballo, minimo_auto de la RPC = monto que registra hacer_puja',
    v_fallos = 0,
    case when v_fallos > 0 then 'DIVERGENCIAS -> ' || v_detalle
         else 'coinciden en los 3 caballos -> ' || v_detalle end);
exception when others then
  perform _p.anotar(28, 'La RPC de minimos coincide con lo que cobra la puja',
    'coinciden', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P29 - Liquidar asienta el resultado en el libro de la casa, solo
--
--  El admin no lo escribe ni lo puede escribir: registrar_movimiento_casa
--  rechaza el tipo 'resultado_remate'. Que el 25% o el pozo ganado vayan donde
--  tienen que ir no puede quedar al criterio de nadie.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        v_asientos int; v_monto numeric; v_gano_casa boolean; v_manual boolean := false;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);          -- cobra 400 a juan y 400 a pedro
  perform public.set_ganador_carrera(v_rem, 2); -- gana el caballo de juan
  perform public.liquidar_remate(v_rem);        -- pozo 800, premio 600

  select count(*), max(monto), bool_or((detalles->>'gano_la_casa')::boolean)
    into v_asientos, v_monto, v_gano_casa
  from public.house_ledger where tipo = 'resultado_remate' and ref_externa = v_rem::text;

  -- y que el admin no pueda escribirlo a mano
  begin
    perform public.registrar_movimiento_casa('resultado_remate', 999, 'a mano');
  exception when others then v_manual := true;
  end;

  -- cobrado 800, premio 600 -> a la casa le quedaron 200 (el 25% de 800)
  perform _p.anotar(29, 'Liquidar asienta el resultado en el libro de la casa',
    'un asiento de 200 (800 cobrados - 600 de premio), y el admin no lo puede crear a mano',
    v_asientos = 1 and v_monto = 200 and v_gano_casa = false and v_manual,
    'asientos: ' || v_asientos::text || ' | monto: ' || coalesce(v_monto,0)::text ||
    ' (esperado 200) | creacion manual rechazada: ' || v_manual::text);
exception when others then
  perform _p.anotar(29, 'Liquidar asienta el resultado en el libro de la casa',
    'un asiento de 200', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P30 - El capital propio desbloquea la liquidacion
--
--  Es el escenario que destapo la tajada D y la razon de ser de esta tarea.
--  Juan recarga 600 y toma UN caballo de 500. Los otros nueve quedan a la casa
--  y entran al pozo sin que ese dinero haya entrado por caja: pozo 5.000,
--  premio 3.750, caja 500. La guarda lo bloquea, y hace bien.
--
--  Con el libro, el licenciatario aporta capital propio y la liquidacion pasa.
--  Antes de 2.18 esto no tenia salida: la guarda bloqueaba y no habia forma de
--  decirle al sistema que la casa tenia dinero.
-- ============================================================================
do $$
declare v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid;
        v_fallo1 boolean := false; v_fallo2 boolean := false;
        v_caja_antes numeric; v_caja_despues numeric; v_saldo numeric;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 600);
  v_rem   := _p.escenario(10, 500);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);

  v_caja_antes := public.dinero_casa_disponible();
  begin perform public.liquidar_remate(v_rem); exception when others then v_fallo1 := true; end;

  -- el licenciatario aporta capital propio
  perform public.registrar_movimiento_casa('aporte_capital', 5000, 'Capital de trabajo de la casa');
  v_caja_despues := public.dinero_casa_disponible();

  begin perform public.liquidar_remate(v_rem); exception when others then v_fallo2 := true; end;
  select saldo_disponible into v_saldo from public.wallets where user_id = v_u;

  -- juan: 600 - 500 (cobro) + 3750 (premio) = 3850
  perform _p.anotar(30, 'El capital propio desbloquea la liquidacion',
    'antes falla con caja 500; tras aportar 5000 la caja sube a 5500 y liquida',
    v_fallo1 and not v_fallo2 and v_caja_antes = 500 and v_caja_despues = 5500 and v_saldo = 3850,
    'caja antes: ' || v_caja_antes::text || ' (bloqueo: ' || v_fallo1::text ||
    ') | caja despues: ' || v_caja_despues::text || ' (bloqueo: ' || v_fallo2::text ||
    ') | saldo de juan: ' || v_saldo::text || ' (esperado 3850)');
exception when others then
  perform _p.anotar(30, 'El capital propio desbloquea la liquidacion',
    'el aporte desbloquea', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P31 - El libro de la casa cuadra contra los saldos
--
--  LA PRUEBA MAS IMPORTANTE DE LA TAREA 2.18, y la razon por la que vale la
--  pena tener el libro. Hay dos formas independientes de calcular lo mismo:
--
--    suma de los `resultado_remate`  (lo que la casa gano, segun su libro)
--    recargas - retiros - saldos     (lo que los usuarios perdieron, en neto)
--
--  Tienen que dar identico. Un descuadre significa que el libro y los saldos
--  no cuentan la misma historia: o hay un bug, o alguien metio mano.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; v_u2 uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_h3 uuid;
        r record;
begin
  perform _p.limpiar();
  delete from public.house_ledger;
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan',  10000);
  v_u2    := _p.usuario('pedro', 10000);
  v_rem   := _p.escenario(3, 100);
  v_h1 := _p.caballo(v_rem,1); v_h2 := _p.caballo(v_rem,2); v_h3 := _p.caballo(v_rem,3);

  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h1, 300, true);
  perform _p.actuar_como(v_u1); perform public.hacer_puja(v_rem, v_h2, 400, true);
  perform _p.actuar_como(v_u2); perform public.hacer_puja(v_rem, v_h3, null, false);

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 2);
  perform public.liquidar_remate(v_rem);

  -- y un retiro, para que el calculo tenga que lidiar con obligaciones
  perform _p.actuar_como(v_u1);
  perform public.solicitar_retiro(500, 'pago_movil', '04121234567');
  perform _p.actuar_como(v_admin);

  select * into r from public.casa_resumen();

  perform _p.anotar(31, 'El libro de la casa cuadra contra los saldos',
    'descuadre = 0; resultado del libro = perdida neta de los usuarios = 200',
    r.descuadre = 0 and r.resultado_operativo = 200 and r.perdida_usuarios = 200 and r.cubierto,
    'libro: ' || r.resultado_operativo::text || ' | saldos: ' || r.perdida_usuarios::text ||
    ' | descuadre: ' || r.descuadre::text || ' | patrimonio: ' || r.patrimonio::text ||
    ' | cubierto: ' || r.cubierto::text);
exception when others then
  perform _p.anotar(31, 'El libro de la casa cuadra contra los saldos',
    'descuadre = 0', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P32 - La foto contable de la casa solo la ve un admin
--
--  casa_resumen() es `security definer`: lee house_ledger por encima de la
--  RLS. Si no comprueba quien llama, la RLS de la tabla no sirve de nada y
--  cualquier apostador logueado ve el patrimonio de la casa desde la consola
--  del navegador. Esta prueba mira las dos mitades: que al usuario normal lo
--  rechace, y que al admin le siga respondiendo.
-- ============================================================================
do $$
declare v_admin uuid; v_u1 uuid; r record;
        v_rechazado boolean := false; v_admin_ok boolean := false; v_msg text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 1000);

  perform _p.actuar_como(v_u1);
  begin
    select * into r from public.casa_resumen();
    v_msg := 'usuario normal la leyo: patrimonio ' || coalesce(r.patrimonio::text, 'null');
  exception when others then
    v_rechazado := true;
    v_msg := 'rechazo al usuario normal (' || sqlerrm || ')';
  end;

  perform _p.actuar_como(v_admin);
  begin
    select * into r from public.casa_resumen();
    v_admin_ok := r.caja_total is not null;
    v_msg := v_msg || ' | admin: caja ' || coalesce(r.caja_total::text, 'null');
  exception when others then
    v_msg := v_msg || ' | admin tambien rechazado: ' || sqlerrm;
  end;

  perform _p.anotar(32, 'La foto contable de la casa solo la ve un admin',
    'usuario normal: excepcion; admin: responde',
    v_rechazado and v_admin_ok, v_msg);
exception when others then
  perform _p.anotar(32, 'La foto contable de la casa solo la ve un admin',
    'usuario normal: excepcion; admin: responde', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P33 - Ninguna RPC peligrosa queda al alcance de anon ni de authenticated
--
--  Esta prueba NO ejercita los permisos: el arnes corre como `postgres`, que
--  es superusuario y se salta cualquier ACL. Lo que hace es CONSULTAR el ACL
--  con has_function_privilege(), que si funciona desde postgres.
--
--  Es la unica forma de probar esto sin abrir una conexion con otro rol. Vale
--  la pena porque `create or replace function` NO toca los permisos: los
--  grants de la baseline sobrevivieron intactos a todo el bloque 1 y 2 aunque
--  los cuerpos se reescribieron enteros. Revisar el cuerpo no basta.
-- ============================================================================
do $$
declare
  v_auto_anon   boolean; v_auto_auth   boolean;
  v_log_anon    boolean; v_log_auth    boolean;
  v_comp_auth   boolean;
  v_resumen_existe boolean;
  v_min_anon    boolean;
begin
  v_auto_anon := has_function_privilege('anon',          'public.auto_cerrar_remates()', 'execute');
  v_auto_auth := has_function_privilege('authenticated', 'public.auto_cerrar_remates()', 'execute');

  v_log_anon  := has_function_privilege('anon',
    'public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)', 'execute');
  v_log_auth  := has_function_privilege('authenticated',
    'public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)', 'execute');

  v_comp_auth := has_function_privilege('authenticated', 'public.compromiso_usuario(uuid)', 'execute');

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resumen_casa'
  ) into v_resumen_existe;

  -- esta SI tiene que seguir abierta: es informacion publica del remate
  v_min_anon := has_function_privilege('anon', 'public.remate_minimos(uuid)', 'execute');

  perform _p.anotar(33, 'Ninguna RPC peligrosa queda al alcance de anon ni authenticated',
    'auto_cerrar_remates y log_admin_action cerradas a los dos; compromiso_usuario cerrada a authenticated; resumen_casa borrada; remate_minimos sigue publica',
    (not v_auto_anon) and (not v_auto_auth)
      and (not v_log_anon) and (not v_log_auth)
      and (not v_comp_auth)
      and (not v_resumen_existe)
      and v_min_anon,
    'auto_cerrar[anon=' || v_auto_anon::text || ',auth=' || v_auto_auth::text || ']' ||
    ' log_admin[anon=' || v_log_anon::text || ',auth=' || v_log_auth::text || ']' ||
    ' compromiso[auth=' || v_comp_auth::text || ']' ||
    ' resumen_casa_existe=' || v_resumen_existe::text ||
    ' remate_minimos[anon=' || v_min_anon::text || ']');
exception when others then
  perform _p.anotar(33, 'Ninguna RPC peligrosa queda al alcance de anon ni authenticated',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P34 - Las claves foraneas del dinero estan en RESTRICT
--
--  Consulta el catalogo, no ejercita el borrado (eso lo hace P35). Vale la
--  pena tenerla aparte porque una clave foranea se puede perder sin que nada
--  se ponga rojo: basta con que alguien recree la tabla o vuelva a correr un
--  `add constraint` viejo.
--
--  confdeltype: 'r' = RESTRICT, 'c' = CASCADE, 'a' = NO ACTION
-- ============================================================================
do $$
declare
  r record;
  v_todas_ok boolean := true;
  v_detalle text := '';
begin
  for r in
    select * from (values
      -- (nombre, esperado)  't' = restrict a proposito, 'c' = cascade a proposito
      ('wallet_movements_wallet_id_fkey',      'r'),
      ('bids_user_id_fkey',                    'r'),
      ('deposit_requests_user_id_fkey',        'r'),
      ('withdraw_requests_user_id_fkey',       'r'),
      ('race_results_race_id_fkey',            'r'),
      -- las de la primera mitad (20260923100000), que no se deben perder
      ('bids_horse_id_fkey',                   'r'),
      ('bids_remate_id_fkey',                  'r'),
      ('horses_race_id_fkey',                  'r'),
      ('remates_race_id_fkey',                 'r'),
      ('race_results_ganador_horse_id_fkey',   'r'),
      -- las que se quedan en CASCADE A PROPOSITO
      ('wallets_user_id_fkey',                 'c'),
      ('remate_price_rules_horse_id_fkey',     'c'),
      ('remate_price_rules_remate_id_fkey',    'c')
    ) as t(nombre, esperado)
  loop
    declare v_real char;
    begin
      select confdeltype into v_real from pg_constraint where conname = r.nombre;
      if v_real is null then
        v_todas_ok := false;
        v_detalle := v_detalle || r.nombre || '=NO EXISTE ';
      elsif v_real <> r.esperado then
        v_todas_ok := false;
        v_detalle := v_detalle || r.nombre || '=' || v_real || '(esperado ' || r.esperado || ') ';
      end if;
    end;
  end loop;

  perform _p.anotar(34, 'Las claves foraneas del dinero estan en RESTRICT',
    '5 nuevas + 5 de la primera mitad en restrict; 3 en cascade a proposito',
    v_todas_ok,
    case when v_todas_ok then 'las 13 como deben' else 'mal: ' || v_detalle end);
exception when others then
  perform _p.anotar(34, 'Las claves foraneas del dinero estan en RESTRICT',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P35 - Borrar un usuario: bloqueado si tiene dinero, permitido si no
--
--  LA PRUEBA QUE DE VERDAD IMPORTA DE 3.1. No mira el catalogo: intenta el
--  borrado y comprueba que Postgres lo frena, bajando por la cascada
--  auth.users -> profiles -> wallets -> wallet_movements.
--
--  Las dos mitades importan igual:
--    - si no bloquea al que tiene dinero, la tarea no sirve de nada
--    - si bloquea TAMBIEN al que no tiene nada, ninguna cuenta de prueba se
--      podria borrar jamas, porque handle_new_user le crea un wallet a todo
--      el mundo al registrarse
-- ============================================================================
do $$
declare
  v_con_dinero uuid; v_limpio uuid; v_rem uuid; v_h1 uuid;
  v_bloqueado boolean := false;
  v_limpio_borrado boolean := false;
  v_msg text := '';
begin
  perform _p.limpiar();

  -- usuario CON rastro: _p.usuario ya le deja una recarga aprobada, y ademas
  -- le hacemos pujar para que tenga una puja en un remate abierto
  v_con_dinero := _p.usuario('con_dinero', 5000);
  v_rem := _p.escenario(2, 100);
  v_h1  := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_con_dinero);
  perform public.hacer_puja(v_rem, v_h1, 100, true);

  -- usuario LIMPIO: se registra y no hace nada mas.
  --
  -- Basta con la fila en auth.users: el trigger `on_auth_user_created` llama a
  -- handle_new_user(), que crea el perfil Y el wallet. Esto NO es un atajo del
  -- arnes, es literalmente lo que pasa cuando alguien se registra en la app.
  --
  -- (La primera version de esta prueba insertaba perfil y wallet a mano y
  -- reventaba con `duplicate key ... profiles_pkey`, porque el trigger ya los
  -- habia creado. Por eso _p.usuario lleva `on conflict do update`.)
  v_limpio := gen_random_uuid();
  insert into auth.users (id) values (v_limpio);
  update public.profiles set username = 'recien_llegado' where id = v_limpio;

  -- Si el trigger no hizo su trabajo, esta prueba no esta probando lo que cree.
  if not exists (select 1 from public.profiles where id = v_limpio)
     or not exists (select 1 from public.wallets where user_id = v_limpio) then
    perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
      'ver arriba', false,
      'el trigger on_auth_user_created no creo perfil o wallet: el escenario es invalido');
    return;
  end if;

  -- mitad 1: el que tiene dinero NO se puede borrar
  begin
    delete from auth.users where id = v_con_dinero;
    v_msg := 'con_dinero SE BORRO (mal) | ';
  exception when others then
    v_bloqueado := true;
    v_msg := 'con_dinero bloqueado (' || sqlstate || ') | ';
  end;

  -- mitad 2: el limpio SI se puede borrar
  begin
    delete from auth.users where id = v_limpio;
    v_limpio_borrado := not exists (select 1 from public.profiles where id = v_limpio);
    v_msg := v_msg || 'limpio borrado=' || v_limpio_borrado::text;
  exception when others then
    v_msg := v_msg || 'limpio NO se pudo borrar (' || sqlerrm || ')';
  end;

  perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
    'con rastro de dinero o pujas: error; sin nada: se borra',
    v_bloqueado and v_limpio_borrado, v_msg);
exception when others then
  perform _p.anotar(35, 'Borrar usuario: bloqueado con dinero, permitido sin nada',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P36 - Nadie escribe `remates` directo
--
--  LA PRUEBA MAS IMPORTANTE DE 3.2. No comprueba la RPC nueva: comprueba que
--  la puerta vieja esta cerrada. De nada sirve editar_remate() si el frontend
--  puede seguir haciendo update sobre la tabla.
--
--  Como el arnes corre como `postgres` (superusuario, se salta cualquier ACL),
--  esto se consulta con has_table_privilege, igual que P33 con las funciones.
-- ============================================================================
do $$
declare
  v_auth_upd boolean; v_auth_ins boolean; v_auth_del boolean;
  v_anon_upd boolean; v_auth_sel boolean;
begin
  v_auth_upd := has_table_privilege('authenticated', 'public.remates', 'update');
  v_auth_ins := has_table_privilege('authenticated', 'public.remates', 'insert');
  v_auth_del := has_table_privilege('authenticated', 'public.remates', 'delete');
  v_anon_upd := has_table_privilege('anon',          'public.remates', 'update');
  -- leer si tiene que poder: la pantalla del remate la ve todo el mundo
  v_auth_sel := has_table_privilege('authenticated', 'public.remates', 'select');

  -- OJO CON `insert`: se queda abierto A PROPOSITO hasta el bloque 4, porque
  -- la pantalla de crear remate lo usa. No se comprueba aqui para que esta
  -- prueba no se ponga roja por algo que decidimos dejar asi. Cuando exista
  -- `crear_remate_completo`, se cierra y se anade a esta linea.
  perform _p.anotar(36, 'Nadie escribe la tabla remates directo',
    'authenticated y anon sin update ni delete; select si; insert abierto hasta el bloque 4',
    (not v_auth_upd) and (not v_auth_del) and (not v_anon_upd) and v_auth_sel,
    'auth[upd=' || v_auth_upd::text || ',del=' || v_auth_del::text ||
    ',sel=' || v_auth_sel::text || ',ins=' || v_auth_ins::text || ' (abierto a proposito)' ||
    '] anon[upd=' || v_anon_upd::text || ']');
exception when others then
  perform _p.anotar(36, 'Nadie escribe la tabla remates directo',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P37 - El porcentaje de la casa se congela en cuanto hay una puja
--
--  La gente pujo sabiendo que el premio era el 75% del pozo. Cambiarlo
--  despues es cambiar el trato una vez que ya apostaron.
--
--  Las dos mitades: antes de la primera puja SI se puede (y deja aviso),
--  despues NO.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_rem uuid; v_h1 uuid;
  v_antes_ok boolean := false; v_despues_bloqueado boolean := false;
  v_avisos integer := 0; v_msg text := '';
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_admin);

  -- mitad 1: sin pujas todavia, el cambio pasa
  begin
    perform public.editar_remate(v_rem, 30, null, null, null, null);
    v_antes_ok := (select porcentaje_casa from public.remates where id = v_rem) = 30;
    v_msg := 'sin pujas: cambio a ' ||
      (select porcentaje_casa::text from public.remates where id = v_rem) || ' | ';
  exception when others then
    v_msg := 'sin pujas NO dejo cambiar (' || sqlerrm || ') | ';
  end;

  -- llega una puja
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h1, 100, true);
  perform _p.actuar_como(v_admin);

  -- mitad 2: ahora tiene que rechazar
  begin
    perform public.editar_remate(v_rem, 40, null, null, null, null);
    v_msg := v_msg || 'con pujas DEJO cambiar (mal)';
  exception when others then
    v_despues_bloqueado := true;
    v_msg := v_msg || 'con pujas bloqueado';
  end;

  -- y el cambio valido tiene que haber dejado su aviso
  select count(*) into v_avisos
  from public.remate_avisos
  where remate_id = v_rem and tipo = 'porcentaje_casa';

  perform _p.anotar(37, 'El porcentaje de la casa se congela con la primera puja',
    'sin pujas se puede y deja 1 aviso; con pujas se rechaza',
    v_antes_ok and v_despues_bloqueado and v_avisos = 1,
    v_msg || ' | avisos=' || v_avisos::text);
exception when others then
  perform _p.anotar(37, 'El porcentaje de la casa se congela con la primera puja',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P38 - Cambiar el incremento deja aviso SIEMPRE, haya pujas o no
--
--  La primera version solo comprobaba el caso CON pujas, porque asi lo habia
--  escrito yo en la migracion. Jota probo en produccion el caso sin pujas
--  -- cambio el incremento, guardo, y no salio ningun aviso -- y tenia razon
--  en esperar uno.
--
--  Peor: la inconsistencia iba al reves de lo que tendria sentido. El
--  porcentaje SOLO se puede cambiar cuando NO hay pujas, asi que su aviso
--  siempre salia en remates sin pujas. El incremento, que se puede cambiar
--  siempre, era el que se callaba en ese mismo caso.
--
--  Un remate abierto es un remate que la gente esta mirando. Y callar hasta
--  la primera puja le da al admin una ventana para cambiar las condiciones
--  sin dejar rastro, que es lo contrario de para lo que existe la tabla.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid;
  v_rem_sin uuid; v_rem_con uuid; v_h1 uuid; v_h2 uuid;
  v_avisos_sin integer := 0; v_avisos_con integer := 0;
  v_existe boolean;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
      'un aviso en el remate sin pujas y otro en el que tiene',
      false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);

  -- mitad 1: remate SIN pujas
  v_rem_sin := _p.escenario(2, 100, 25);
  v_h1 := _p.caballo(v_rem_sin, 1);
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem_sin, null, 75, null, null, null);

  select count(*) into v_avisos_sin
  from public.remate_avisos where remate_id = v_rem_sin and tipo = 'incremento';

  -- mitad 2: remate CON pujas
  v_rem_con := _p.escenario(2, 100, 25);
  v_h2 := _p.caballo(v_rem_con, 1);
  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem_con, v_h2, 100, true);
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem_con, null, 80, null, null, null);

  select count(*) into v_avisos_con
  from public.remate_avisos where remate_id = v_rem_con and tipo = 'incremento';

  perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
    'un aviso en el remate sin pujas y otro en el que tiene',
    v_avisos_sin = 1 and v_avisos_con = 1,
    'sin pujas: ' || v_avisos_sin::text || ' aviso(s) | con pujas: ' || v_avisos_con::text || ' aviso(s)');
exception when others then
  perform _p.anotar(38, 'Cambiar el incremento deja aviso siempre, haya pujas o no',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;


-- ============================================================================
--  P39 - editar_remate no toca el estado ni edita remates cerrados
--
--  REESCRITA EL 28/09. La primera version PASABA EN VERDE sin la migracion
--  aplicada, que es el peor resultado posible para una prueba:
--
--    - `sin_param_estado` buscaba una funcion con parametro `estado`. Sin la
--      migracion no hay NINGUNA funcion, asi que el NOT EXISTS daba true.
--    - `cerrado_bloqueado` llamaba a la funcion; saltaba "function does not
--      exist", y un `exception when others` la contaba como rechazo correcto.
--
--  Las dos mitades aprobaban porque la funcion no existia.
--
--  LA REGLA QUE SALE DE AQUI, Y VALE PARA TODO EL ARNES:
--  cuando el exito de una prueba consiste en "salto una excepcion", hay que
--  comprobar CUAL excepcion. Un `when others` se traga tanto el rechazo que
--  buscas como el error que significa que no estas probando nada.
--
--    42883 = undefined_function  -> la migracion NO esta aplicada
--    P0001 = raise_exception     -> nuestro codigo rechazo a proposito
-- ============================================================================
do $$
declare
  v_admin uuid; v_u1 uuid; v_rem uuid; v_h1 uuid;
  v_existe boolean;
  v_sin_param_estado boolean;
  v_cerrado_bloqueado boolean := false;
  v_estado_sigue boolean := false;
  v_msg text := '';
  v_sqlstate text;
begin
  perform _p.limpiar();

  -- 0) LO PRIMERO: la funcion tiene que existir. Sin esto, todo lo demas
  --    aprueba por omision.
  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
      'sin parametro de estado; un remate cerrado se rechaza con P0001',
      false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  -- 1) ninguna sobrecarga acepta un parametro de estado
  select not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
      and pg_get_function_arguments(p.oid) ilike '%estado%'
  ) into v_sin_param_estado;

  v_admin := _p.usuario('admin', 0, true);
  v_u1    := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);

  perform _p.actuar_como(v_u1);
  perform public.hacer_puja(v_rem, v_h1, 100, true);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);

  -- 2) un remate cerrado no se edita, y tiene que rechazarlo NUESTRO codigo
  begin
    perform public.editar_remate(v_rem, null, 999, null, null, null);
    v_msg := 'dejo editar un remate CERRADO (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = 'P0001' then
      v_cerrado_bloqueado := true;
      v_msg := 'remate cerrado rechazado por nuestro codigo (P0001)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  -- 3) y el incremento no se movio: que rechace no basta, tiene que no escribir
  v_estado_sigue := (select incremento_minimo from public.remates where id = v_rem) <> 999;

  perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
    'sin parametro de estado; un remate cerrado se rechaza con P0001 y no se escribe nada',
    v_sin_param_estado and v_cerrado_bloqueado and v_estado_sigue,
    'sin_param_estado=' || v_sin_param_estado::text ||
    ' | ' || v_msg ||
    ' | no escribio=' || v_estado_sigue::text);
exception when others then
  perform _p.anotar(39, 'editar_remate no toca el estado ni edita remates cerrados',
    'ver arriba', false, 'excepcion: ' || sqlerrm);
end $$;



-- ============================================================================
--  P40 a P46 - LA AUDITORIA DEL 28/09, TANDA 1
--
--  Siete pruebas para los nueve arreglos de
--  20260929100000_auditoria_tanda1.sql. Todas se escribieron ANTES de aplicar
--  la migracion y todas tienen que salir en ROJO primero. Una prueba que nace
--  verde no prueba nada: ver la cabecera de este archivo y P39.
--
--  Los tres arreglos de concurrencia -- A2 (`for share` en hacer_puja), A4
--  (candado de caja) y la carrera de set_ganador_carrera -- NO estan aqui.
--  No se pueden reproducir con una sola conexion: hacen falta dos sesiones
--  intercaladas. Van en tests/concurrencia.sql.
--  Lo que SI se puede probar aqui de D1 es la red que lo hace imposible: el
--  unique. Es exactamente la diferencia entre probar la carrera y probar la
--  valla.
-- ============================================================================


-- ============================================================================
--  P40 - Retirar un caballo y DESPUES cancelar el remate no paga dos veces
--
--  Hallazgo A3. cancelar_remate sumaba solo los movimientos 'apuesta_cobro' e
--  ignoraba las 'apuesta_devolucion' ya emitidas sobre el mismo remate:
--
--    juan lidera dos caballos -> al cerrar se le cobran 800
--    se retira uno           -> retirar_caballo le devuelve 300 (neto: 500)
--    se suspende la carrera  -> cancelar_remate le devolvia OTROS 800
--
--  juan terminaba con 10.300 habiendo puesto 10.000. Los 300 salian de la
--  caja del licenciatario y ninguna pantalla lo decia.
--
--  liquidar_remate, de la misma tajada y con el mismo problema delante, SI
--  los neteaba. Su comentario lo explicaba. cancelar_remate se quedo con el
--  conjunto incompleto.
--
--  Se mide el saldo en los CUATRO momentos a proposito. Si solo se midiera el
--  final, la prueba pasaria en verde tambien en el caso de que ni el cierre ni
--  el retiro hubieran hecho nada: 10.000 - 0 + 0 + 0 = 10.000.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
  v_s0 numeric; v_s1 numeric; v_s2 numeric; v_s3 numeric;
  v_devoluciones numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(3, 100, 25);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 500, true);
  perform public.hacer_puja(v_rem, v_h2, 300, true);
  v_s0 := _p.saldo(v_u);                      -- 10000: pujar no cobra (modelo v2)

  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  v_s1 := _p.saldo(v_u);                      -- 9200: se cobran los dos, 800

  perform public.retirar_caballo(v_h2, 'Lesion en el paddock');
  v_s2 := _p.saldo(v_u);                      -- 9500: devuelve 300, neto 500

  perform public.cancelar_remate(v_rem, 'Carrera suspendida por lluvia');
  v_s3 := _p.saldo(v_u);                      -- 10000: devuelve los 500 que faltan

  select coalesce(sum(m.monto),0) into v_devoluciones
  from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id
  where w.user_id = v_u and m.tipo = 'apuesta_devolucion';

  perform _p.anotar(40, 'Retirar un caballo y luego cancelar no reembolsa dos veces',
    '10000 -> 9200 (cierre) -> 9500 (retiro) -> 10000 (cancelacion), devuelto total 800',
    v_s0 = 10000 and v_s1 = 9200 and v_s2 = 9500 and v_s3 = 10000 and v_devoluciones = 800,
    'pujas: ' || v_s0::text || ' | cierre: ' || v_s1::text ||
    ' | retiro: ' || v_s2::text || ' | cancelacion: ' || v_s3::text ||
    ' (esperado 10000; si da 10300 cancelar_remate ignoro la devolucion previa)' ||
    ' | devuelto total: ' || v_devoluciones::text || ' (esperado 800)');
exception when others then
  perform _p.anotar(40, 'Retirar un caballo y luego cancelar no reembolsa dos veces',
    'saldo final = 10000', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P41 - Un admin no puede acunar saldo escribiendo deposit_requests
--
--  Hallazgo A5. La baseline daba `GRANT SELECT, INSERT, UPDATE` sobre la
--  tabla a `authenticated`, y la politica `deposit_admin_all` era FOR ALL con
--  `USING is_admin() WITH CHECK is_admin()`. Las dos cosas juntas: cualquier
--  admin podia insertar una fila 'aprobado' desde la consola del navegador, o
--  pasar a 'aprobado' una pendiente, sin pasar por aprobar_recarga.
--
--  Es la misma forma exacta del agujero de `remates.estado` que cerro la 3.2:
--  una RPC bien hecha al lado de una puerta abierta.
--
--  Igual que P33 y P36, esto se consulta con has_table_privilege en vez de
--  ejercitarlo: el arnes corre como `postgres`, que se salta cualquier ACL.
--
--  La segunda mitad importa tanto como la primera: cerrar la puerta sin
--  romper la RPC. solicitar_recarga y aprobar_recarga son `definer`, asi que
--  tienen que seguir funcionando.
-- ============================================================================
do $$
declare
  v_auth_ins boolean; v_auth_upd boolean; v_auth_del boolean; v_auth_sel boolean;
  v_anon_ins boolean; v_anon_upd boolean; v_anon_sel boolean;
  v_pol_all boolean; v_pol_select boolean; v_pol_own boolean;
  v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric;
begin
  perform _p.limpiar();

  v_auth_ins := has_table_privilege('authenticated', 'public.deposit_requests', 'insert');
  v_auth_upd := has_table_privilege('authenticated', 'public.deposit_requests', 'update');
  v_auth_del := has_table_privilege('authenticated', 'public.deposit_requests', 'delete');
  -- leer SI: el usuario ve sus recargas y el admin las suyas, cada uno por su politica
  v_auth_sel := has_table_privilege('authenticated', 'public.deposit_requests', 'select');
  v_anon_ins := has_table_privilege('anon', 'public.deposit_requests', 'insert');
  v_anon_upd := has_table_privilege('anon', 'public.deposit_requests', 'update');
  v_anon_sel := has_table_privilege('anon', 'public.deposit_requests', 'select');

  -- la politica FOR ALL tiene que haber desaparecido, no basta con el revoke:
  -- las politicas permisivas se SUMAN con OR, y dejarla ahi seria dejar puesta
  -- la mitad del agujero esperando a que alguien reponga el grant.
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_admin_all') into v_pol_all;
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_admin_select' and cmd='SELECT') into v_pol_select;
  select exists (select 1 from pg_policies
                 where schemaname='public' and tablename='deposit_requests'
                   and policyname='deposit_select_own') into v_pol_own;

  -- y la via legitima tiene que seguir viva
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(1000, 'pago_movil', '04121234567', 'REF-A5', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  v_saldo := _p.saldo(v_u);

  perform _p.anotar(41, 'deposit_requests no se escribe directo, ni por un admin',
    'authenticated y anon sin insert/update/delete; select sigue; deposit_admin_all borrada; la recarga por RPC sigue funcionando',
    (not v_auth_ins) and (not v_auth_upd) and (not v_auth_del) and v_auth_sel
      and (not v_anon_ins) and (not v_anon_upd) and (not v_anon_sel)
      and (not v_pol_all) and v_pol_select and v_pol_own
      and v_saldo = 1000,
    'auth[ins=' || v_auth_ins::text || ',upd=' || v_auth_upd::text ||
    ',del=' || v_auth_del::text || ',sel=' || v_auth_sel::text || ']' ||
    ' anon[ins=' || v_anon_ins::text || ',upd=' || v_anon_upd::text ||
    ',sel=' || v_anon_sel::text || ']' ||
    ' politicas[admin_all=' || v_pol_all::text || ',admin_select=' || v_pol_select::text ||
    ',select_own=' || v_pol_own::text || ']' ||
    ' | saldo tras recarga por RPC: ' || coalesce(v_saldo,-1)::text || ' (esperado 1000)');
exception when others then
  perform _p.anotar(41, 'deposit_requests no se escribe directo, ni por un admin',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P42 - Una tabla nueva nace CERRADA (y una funcion nueva, no)
--
--  Hallazgo A6, y la mina estructural del esquema. La baseline trae:
--
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON TABLES    TO anon, authenticated;
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON FUNCTIONS TO anon, authenticated;
--
--  No hace falta un grant para quedar expuesto: hace falta un revoke para no
--  estarlo. Y eso no sale en ningun diff, porque el diff de la migracion que
--  crea la tabla no dice nada de permisos.
--
--  Esta prueba no mira el texto de la migracion: crea de verdad una tabla y
--  una funcion en `public` como postgres -- que es exactamente lo que hace
--  cada migracion -- y pregunta por su ACL. Luego las borra.
--
--  LA FUNCION SE MIDE PERO NO SE EXIGE, Y NO ES PEREZA.
--
--  PostgreSQL le da EXECUTE a PUBLIC en toda funcion nueva, de fabrica, y
--  `authenticated` hereda de PUBLIC. Eso solo se quita con una entrada GLOBAL
--  de default privileges, sin `IN SCHEMA`, que aplica a todos los esquemas y
--  deja sin EXECUTE tambien a cualquier extension que se instale despues
--  (comprobado: `create extension citext` con esa entrada puesta deja sus 23
--  funciones cerradas y rompe hasta un `where columna = 'x'`). En una base que
--  opera el licenciatario, eso es una mina.
--
--  Decision de Jota (29/09): la base no falla cerrada en funciones; el arnes
--  falla ruidoso. El censo esta en P47, que enumera TODAS las funciones de
--  `public` contra una lista blanca. Aqui se deja medido para que el numero
--  quede a la vista y nadie crea que A6 cubrio algo que no cubre.
-- ============================================================================
do $$
declare
  v_tabla_sel_auth boolean; v_tabla_ins_auth boolean; v_tabla_sel_anon boolean;
  v_sec_auth boolean;
  v_fn_auth boolean;
begin
  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';

  execute 'create table public._p_acl_tabla (id serial primary key, x int)';
  execute 'create function public._p_acl_funcion() returns int language sql as ''select 1''';

  v_tabla_sel_auth := has_table_privilege('authenticated', 'public._p_acl_tabla', 'select');
  v_tabla_ins_auth := has_table_privilege('authenticated', 'public._p_acl_tabla', 'insert');
  v_tabla_sel_anon := has_table_privilege('anon',          'public._p_acl_tabla', 'select');
  v_sec_auth       := has_sequence_privilege('authenticated', 'public._p_acl_tabla_id_seq', 'usage');
  v_fn_auth        := has_function_privilege('authenticated', 'public._p_acl_funcion()', 'execute');

  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';

  perform _p.anotar(42, 'Una tabla nueva y su secuencia nacen cerradas',
    'sin privilegios para anon ni authenticated en la tabla ni en la secuencia',
    (not v_tabla_sel_auth) and (not v_tabla_ins_auth) and (not v_tabla_sel_anon)
      and (not v_sec_auth),
    'tabla[auth_sel=' || v_tabla_sel_auth::text || ',auth_ins=' || v_tabla_ins_auth::text ||
    ',anon_sel=' || v_tabla_sel_anon::text || ']' ||
    ' secuencia[auth_usage=' || v_sec_auth::text || ']' ||
    ' | funcion nueva ejecutable por authenticated=' || v_fn_auth::text ||
    ' (NO se exige aqui: PostgreSQL se lo da a PUBLIC de fabrica y solo se quita' ||
    ' con una entrada global que romperia las extensiones. El censo es P47)');
exception when others then
  execute 'drop table if exists public._p_acl_tabla';
  execute 'drop function if exists public._p_acl_funcion()';
  perform _p.anotar(42, 'Una tabla nueva y su secuencia nacen cerradas',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P43 - La caja del licenciatario no la lee un usuario cualquiera
--
--  Hallazgo A7. El revoke de 20260923150000:100 decia:
--
--    revoke all on function public.dinero_casa_disponible() from public, anon;
--
--  Faltaba `authenticated`, y por A6 la funcion ya tenia el execute desde que
--  se creo. Cualquier registrado podia abrir la consola, llamar
--  supabase.rpc('dinero_casa_disponible') y ver recargas, retiros, el saldo
--  agregado de todos los usuarios y el capital propio del licenciatario.
--
--  Mismo defecto que la 2.22 (casa_resumen), en la misma migracion que lo
--  arreglo, en la funcion de al lado.
--
--  La segunda mitad comprueba que cerrarla no rompio a quien la usa de
--  verdad: liquidar_remate y casa_resumen son `definer` y corren como
--  postgres, asi que la guarda de solvencia tiene que seguir funcionando.
-- ============================================================================
do $$
declare
  v_anon boolean; v_auth boolean; v_publico boolean;
  v_admin uuid; v_u uuid; v_rem uuid; v_h uuid; v_caja numeric; v_liquido boolean := false;
begin
  perform _p.limpiar();

  v_anon := has_function_privilege('anon',          'public.dinero_casa_disponible()', 'execute');
  v_auth := has_function_privilege('authenticated', 'public.dinero_casa_disponible()', 'execute');
  -- el ACL de PUBLIC se mira aparte: authenticated hereda de el, y si quedara
  -- ahi el revoke a authenticated no serviria de nada
  --
  --  OJO CON COMO SE PREGUNTA ESTO. La primera version que escribi hacia
  --  `array_to_string(proacl, ',') like '=X/%'`, y solo habria acertado si la
  --  entrada de PUBLIC fuera la PRIMERA del arreglo. Ademas, `proacl` nulo
  --  significa "ACL por defecto", que para una funcion incluye EXECUTE para
  --  PUBLIC: el like habria dado false justo en el caso mas abierto posible.
  --  aclexplode + grantee = 0 (PUBLIC) es la forma correcta, y acldefault
  --  cubre el nulo.
  select coalesce(
    (select bool_or(a.privilege_type = 'EXECUTE')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where n.nspname = 'public' and p.proname = 'dinero_casa_disponible'
       and a.grantee = 0),
    false) into v_publico;

  -- y la via interna tiene que seguir viva
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);
  v_rem   := _p.escenario(2, 100);
  v_h     := _p.caballo(v_rem, 1);
  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h, null, false);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 2);     -- gana un caballo de la casa
  perform public.liquidar_remate(v_rem);
  v_liquido := (select estado from public.remates where id = v_rem) = 'liquidado';
  v_caja := public.dinero_casa_disponible();

  perform _p.anotar(43, 'dinero_casa_disponible() cerrada a anon y a authenticated',
    'sin execute para anon, authenticated ni PUBLIC; la liquidacion sigue funcionando',
    (not v_anon) and (not v_auth) and (not v_publico) and v_liquido and v_caja = 100,
    'anon=' || v_anon::text || ' authenticated=' || v_auth::text ||
    ' PUBLIC=' || v_publico::text ||
    ' | liquido=' || v_liquido::text || ' caja=' || coalesce(v_caja,-1)::text || ' (esperado 100)');
exception when others then
  perform _p.anotar(43, 'dinero_casa_disponible() cerrada a anon y a authenticated',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P44 - La base rechaza un saldo negativo, venga de donde venga
--
--  Hallazgo D3. El invariante `saldo_disponible >= compromiso_usuario()` --
--  que implica saldo >= 0 -- vivia EXCLUSIVAMENTE dentro de tres cuerpos
--  PL/pgSQL. Cualquier ruta que no pasara por ellos dejaba el saldo en
--  negativo sin una sola queja: service_role, un psql de mantenimiento, una
--  migracion futura, o el propio agujero A2.
--
--  Un check no es redundante con las guardas de aplicacion. Es la ultima red,
--  y es la unica que no se puede saltar: ni siquiera `postgres` la esquiva.
--  Por eso esta prueba puede ejercitarla de verdad en vez de consultarla.
--
--  23514 = check_violation. Si saltara cualquier otro codigo, la prueba tiene
--  que decirlo: seria otro problema disfrazado de exito.
-- ============================================================================
do $$
declare
  v_u uuid; v_constraint_existe boolean; v_constraint_validada boolean;
  v_disp_bloqueado boolean := false; v_bloq_bloqueado boolean := false;
  v_saldo_final numeric; v_sqlstate text; v_msg text := '';
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_constraint
    where conrelid = 'public.wallets'::regclass
      and conname = 'wallets_saldo_no_negativo'),
    coalesce((select convalidated from pg_constraint
      where conrelid = 'public.wallets'::regclass
        and conname = 'wallets_saldo_no_negativo'), false)
  into v_constraint_existe, v_constraint_validada;

  if not v_constraint_existe then
    perform _p.anotar(44, 'La base rechaza un saldo negativo',
      'check wallets_saldo_no_negativo, validado, rechaza con 23514',
      false, 'el check NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_u := _p.usuario('juan', 500);

  begin
    update public.wallets set saldo_disponible = -1 where user_id = v_u;
    v_msg := 'dejo poner saldo_disponible en -1 (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = '23514' then
      v_disp_bloqueado := true;
      v_msg := 'saldo_disponible negativo rechazado (23514)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  begin
    update public.wallets set saldo_bloqueado = -1 where user_id = v_u;
  exception when others then
    if sqlstate = '23514' then v_bloq_bloqueado := true; end if;
  end;

  -- que rechace no basta: tiene que no haber escrito nada
  v_saldo_final := _p.saldo(v_u);

  perform _p.anotar(44, 'La base rechaza un saldo negativo',
    'check validado; los dos saldos rechazan con 23514 y no se escribe nada',
    v_constraint_validada and v_disp_bloqueado and v_bloq_bloqueado and v_saldo_final = 500,
    'validado=' || v_constraint_validada::text || ' | ' || v_msg ||
    ' | bloqueado negativo rechazado=' || v_bloq_bloqueado::text ||
    ' | saldo sigue en ' || coalesce(v_saldo_final,-1)::text || ' (esperado 500)');
exception when others then
  perform _p.anotar(44, 'La base rechaza un saldo negativo',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P45 - Una carrera no puede tener dos ganadores
--
--  Hallazgo D1. set_ganador_carrera es un update-then-insert sin candado
--  sobre una tabla sin restriccion unica:
--
--    update race_results set ganador_horse_id = ... where race_id = ...;
--    if not found then insert into race_results (...) values (...); end if;
--
--  Dos llamadas simultaneas -- dos admins, un doble clic, el reintento de un
--  fetch que no respondio -- hacen las dos un update que afecta 0 filas, las
--  dos entran al `if not found`, y las dos insertan. Quedan dos filas para la
--  misma carrera, posiblemente con ganadores distintos. Y liquidar_remate lee
--  con `select ... into` sin `limit` y sin `strict`: toma la primera que
--  devuelva el plan, sin error y sin aviso. El premio entero se paga a un
--  usuario indeterminado.
--
--  ESTO NO PRUEBA LA CARRERA: probarla hace falta dos conexiones, y eso va en
--  tests/concurrencia.sql. Prueba la VALLA que la vuelve imposible. Es una
--  distincion que conviene no perder de vista: aqui se comprueba que la
--  segunda fila no cabe, no que dos sesiones no lleguen a la vez.
--
--  23505 = unique_violation.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid; v_rem uuid; v_h1 uuid; v_h2 uuid; v_race uuid;
  v_existe boolean; v_segunda_bloqueada boolean := false;
  v_filas integer; v_ganador uuid; v_sqlstate text; v_msg text := '';
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_constraint
    where conrelid = 'public.race_results'::regclass
      and contype = 'u'
      and conkey = (select array_agg(attnum) from pg_attribute
                    where attrelid = 'public.race_results'::regclass and attname = 'race_id')
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
      'unique sobre race_id; el segundo insert se rechaza con 23505',
      false, 'el unique sobre race_id NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 10000);
  v_rem   := _p.escenario(2, 100);
  v_h1    := _p.caballo(v_rem, 1);
  v_h2    := _p.caballo(v_rem, 2);
  select race_id into v_race from public.remates where id = v_rem;

  perform _p.actuar_como(v_u);
  perform public.hacer_puja(v_rem, v_h1, 200, true);
  perform _p.actuar_como(v_admin);
  perform public.cerrar_remate(v_rem);
  perform public.set_ganador_carrera(v_rem, 1);

  -- la segunda fila es lo que dejaba entrar la carrera. Tiene que rebotar.
  begin
    insert into public.race_results (race_id, ganador_horse_id) values (v_race, v_h2);
    v_msg := 'dejo insertar un SEGUNDO resultado para la misma carrera (mal)';
  exception when others then
    v_sqlstate := sqlstate;
    if v_sqlstate = '23505' then
      v_segunda_bloqueada := true;
      v_msg := 'segundo resultado rechazado por el unique (23505)';
    else
      v_msg := 'rechazado, pero por el motivo EQUIVOCADO (' || v_sqlstate || '): ' || sqlerrm;
    end if;
  end;

  -- y llamar dos veces a la RPC tiene que seguir siendo legitimo: corrige, no duplica
  perform public.set_ganador_carrera(v_rem, 2);
  select count(*) into v_filas from public.race_results where race_id = v_race;
  select ganador_horse_id into v_ganador from public.race_results where race_id = v_race;

  perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
    'el insert directo rebota con 23505; llamar dos veces a la RPC corrige el ganador sin duplicar',
    v_segunda_bloqueada and v_filas = 1 and v_ganador = v_h2,
    v_msg || ' | filas para la carrera: ' || v_filas::text || ' (esperado 1)' ||
    ' | la segunda llamada corrigio el ganador: ' || (v_ganador = v_h2)::text);
exception when others then
  perform _p.anotar(45, 'Una carrera no puede tener dos resultados',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P46 - El panel de contabilidad ve el capital propio, igual que la guarda
--
--  Hallazgo B5. La tarea 2.18 anadio el libro de la casa y actualizo
--  dinero_casa_disponible() para que sumara los asientos manuales. A
--  admin_contabilidad_resumen() no. Desde ese dia la guarda de solvencia y la
--  pantalla que el admin mira daban numeros distintos sobre la misma caja.
--
--  Estaba a la vista en el propio arnes: en P30, tras un aporte de 5.000, la
--  funcion daba 5.500 y el panel seguia diciendo 500. Nadie los comparo
--  DESPUES de un aporte.
--
--  Y P19, que es la prueba que existe para comparar estos dos numeros, no lo
--  detectaba: su escenario no tiene ningun asiento manual, asi que el termino
--  que faltaba valia cero en los dos momentos que mide. Una prueba que compara
--  dos cosas iguales en el unico caso en que no pueden diferir.
--
--  Esta lo mide justo donde duele: con un aporte de capital encima.
-- ============================================================================
do $$
declare
  v_admin uuid; v_u uuid;
  v_funcion numeric; v_panel numeric;
begin
  perform _p.limpiar();
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 1000);     -- recarga aprobada de 1000, wallet 1000

  -- sin asientos manuales la caja es 1000 - 1000 = 0: es el caso ciego de P19
  perform _p.actuar_como(v_admin);
  perform public.registrar_movimiento_casa('aporte_capital', 5000, 'Capital inicial del licenciatario');

  v_funcion := public.dinero_casa_disponible();
  v_panel   := (public.admin_contabilidad_resumen() ->> 'dinero_casa')::numeric;

  perform _p.anotar(46, 'El panel de contabilidad suma el capital propio',
    'funcion y panel dan lo mismo, y los dos dan 5000',
    v_funcion = v_panel and v_funcion = 5000,
    'funcion: ' || coalesce(v_funcion,-1)::text ||
    ' | panel: ' || coalesce(v_panel,-1)::text ||
    ' (esperado 5000 en los dos; si el panel da 0 no esta sumando el libro de la casa)');
exception when others then
  perform _p.anotar(46, 'El panel de contabilidad suma el capital propio',
    'funcion y panel dan 5000 los dos', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P47 - CENSO DE FUNCIONES: ninguna queda abierta sin estar declarada
--
--  Esta prueba existe por lo que paso el 29/09 y no por una teoria.
--
--  A6 quiso que "lo nuevo nazca cerrado" y resulto que en funciones no se
--  puede: PostgreSQL le da EXECUTE a PUBLIC de fabrica y eso solo se quita
--  con una entrada global de default privileges que rompe las extensiones
--  (comprobado con citext). Decision de Jota: la base no falla cerrada, el
--  arnes falla ruidoso.
--
--  Esto es el ruido. Enumera TODAS las funciones de `public` y compara con lo
--  declarado. Tres cosas se ponen rojas:
--
--    - una funcion declarada `cerrada` que alguien puede ejecutar
--    - una funcion declarada abierta que ya no lo esta (grant perdido)
--    - una funcion que NO ESTA DECLARADA. Esa es la importante: es la RPC
--      nueva que nacio abierta y que nadie iba a ver en el diff.
--
--  La lista de abajo no es una foto de como esta la base: es como TIENE que
--  estar. Se saco de cruzar las 19 RPC que llama `app/` y `lib/` con el
--  inventario real de funciones del 29/09.
--
--  OJO AL ANADIR UNA RPC: hay que anadirla aqui Y darle su grant. Si solo se
--  le da el grant, esta prueba se pone roja. Es a proposito.
-- ============================================================================
do $$
declare
  r record;
  v_total int := 0; v_fallos int := 0; v_sin_declarar int := 0;
  v_detalle text := '';
begin
  for r in
    with esperado(nombre, quien) as (values
      -- internas: solo las llaman otras funciones definer, que corren como postgres
      ('_cerrar_remate_interno',          'cerrada'),
      ('_incremento_aplicable',           'cerrada'),
      ('compromiso_usuario',              'cerrada'),
      ('dinero_casa_disponible',          'cerrada'),
      ('log_admin_action',                'cerrada'),
      -- el cron, con clave de servicio
      ('auto_cerrar_remates',             'cerrada'),
      -- funciones de trigger: disparan sin EXECUTE (comprobado 29/09)
      ('handle_new_user',                 'cerrada'),
      ('tr_check_admin_immutability',     'cerrada'),
      ('set_support_settings_updated_at', 'cerrada'),
      -- sin uso en la aplicacion
      ('get_usernames',                   'cerrada'),
      ('promover_usuario',                'cerrada'),
      ('set_admin',                       'cerrada'),
      -- RPC de usuario con sesion
      ('admin_contabilidad_resumen',      'auth'),
      ('aprobar_recarga',                 'auth'),
      ('archivar_remate',                 'auth'),
      ('cancelar_remate',                 'auth'),
      ('casa_resumen',                    'auth'),
      ('cerrar_remate',                   'auth'),
      ('editar_remate',                   'auth'),
      ('hacer_puja',                      'auth'),
      ('liquidar_remate',                 'auth'),
      ('listar_wallets_superadmin',       'auth'),
      ('mi_wallet_resumen',               'auth'),
      ('procesar_retiro',                 'auth'),
      ('rechazar_recarga',                'auth'),
      ('registrar_movimiento_casa',       'auth'),
      ('retirar_caballo',                 'auth'),
      ('set_ganador_carrera',             'auth'),
      ('solicitar_recarga',               'auth'),
      ('solicitar_retiro',                'auth'),
      -- las invocan las politicas RLS, que corren con los permisos de quien consulta
      ('is_admin',                        'auth'),
      ('is_super_admin',                  'auth'),
      -- informacion publica del remate: la pantalla se ve sin sesion
      ('remate_minimos',                  'anon'),
      ('listar_pujas_publicas',           'anon')
    )
    select p.proname as nombre,
           has_function_privilege('authenticated', p.oid, 'execute') as auth,
           has_function_privilege('anon',          p.oid, 'execute') as anon,
           e.quien
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    left join esperado e on e.nombre = p.proname
    where n.nspname = 'public' and p.prokind = 'f'
    order by p.proname
  loop
    v_total := v_total + 1;

    if r.quien is null then
      v_sin_declarar := v_sin_declarar + 1;
      v_detalle := v_detalle || ' | SIN DECLARAR: ' || r.nombre ||
                   '(auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'cerrada' and (r.auth or r.anon) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ABIERTA de mas: ' || r.nombre ||
                   '(auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'auth' and ((not r.auth) or r.anon) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ' || r.nombre || ' deberia ser solo authenticated' ||
                   ' (auth=' || r.auth::text || ',anon=' || r.anon::text || ')';

    elsif r.quien = 'anon' and ((not r.auth) or (not r.anon)) then
      v_fallos := v_fallos + 1;
      v_detalle := v_detalle || ' | ' || r.nombre || ' deberia ser publica' ||
                   ' (auth=' || r.auth::text || ',anon=' || r.anon::text || ')';
    end if;
  end loop;

  perform _p.anotar(47, 'Censo de funciones: ninguna abierta sin declarar',
    'las 34 funciones de public coinciden con lo declarado, y no hay ninguna sin declarar',
    v_fallos = 0 and v_sin_declarar = 0 and v_total > 0,
    'funciones en public: ' || v_total::text ||
    ' | desajustes: ' || v_fallos::text ||
    ' | sin declarar: ' || v_sin_declarar::text || v_detalle);
exception when others then
  perform _p.anotar(47, 'Censo de funciones: ninguna abierta sin declarar',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P48 - CENSO DE TABLAS: quien puede escribir que, y TRUNCATE en cero
--
--  El hallazgo del 29/09: las quince tablas de `public` nacieron con GRANT ALL
--  para `anon` y `authenticated`, por el ALTER DEFAULT PRIVILEGES de la imagen
--  de Supabase. Ninguna migracion lo escribio; se aplico solo.
--
--  Y el privilegio que mas importa de esa lista es el que menos se mira:
--  TRUNCATE. Doc 17, 5.9: "Operations that apply to the whole table, such as
--  TRUNCATE and REFERENCES, are not subject to row security." Vaciar una tabla
--  no pasa por ninguna politica. La RLS no defiende de eso, y no puede.
--
--  Por eso el censo no pregunta "hay alguna politica que lo tape": pregunta
--  por el PRIVILEGIO, uno a uno, para los siete verbos.
--
--  Lo declarado abajo es el estado correcto. Las dos excepciones vivas llevan
--  su razon y su fecha de caducidad escritas al lado.
-- ============================================================================
do $$
declare
  r record; v_priv text;
  v_total int := 0; v_fallos int := 0; v_sin_declarar int := 0;
  v_detalle text := '';
  v_real boolean; v_esperado boolean;
begin
  for r in
    with esperado(tabla, auth_privs, anon_privs) as (values
      -- dinero y rastro: nadie escribe a mano, todo pasa por funciones definer
      ('wallets',            'select',                        ''),
      ('wallet_movements',   'select',                        ''),
      ('bids',               'select',                        ''),
      ('race_results',       'select',                        ''),
      ('profiles',           'select',                        ''),
      ('withdraw_requests',  'select',                        ''),
      ('deposit_requests',   'select',                        ''),
      ('admin_actions',      'select',                        ''),
      ('house_ledger',       'select',                        ''),
      -- catalogo del remate: lo escribe la pantalla de admin HASTA LA TANDA 4,
      -- cuando existan crear_remate_completo() y guardar_remate_completo().
      -- Ese dia estas cuatro bajan a 'select' y se quitan del panel a la vez.
      ('horses',             'select,insert,update,delete',   'select'),
      ('races',              'select,insert,update,delete',   'select'),
      ('remate_price_rules', 'select,insert,update,delete',   'select'),
      ('support_settings',   'select,insert,update,delete',   'select'),
      -- remates: update y delete ya cayeron en la 3.2. El insert sigue vivo
      -- porque lo usa la pantalla de crear remate; cae en la tanda 4.
      ('remates',            'select,insert',                 'select'),
      -- avisos al jugador: los escribe editar_remate, los lee todo el mundo
      ('remate_avisos',      'select',                        'select')
    )
    select c.relname as tabla, c.oid, e.auth_privs, e.anon_privs
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    left join esperado e on e.tabla = c.relname
    where n.nspname = 'public' and c.relkind = 'r'
    order by c.relname
  loop
    v_total := v_total + 1;

    if r.auth_privs is null then
      v_sin_declarar := v_sin_declarar + 1;
      v_detalle := v_detalle || ' | TABLA SIN DECLARAR: ' || r.tabla;
      continue;
    end if;

    foreach v_priv in array array['select','insert','update','delete','truncate','references','trigger']
    loop
      -- authenticated
      v_real     := has_table_privilege('authenticated', r.oid, v_priv);
      v_esperado := (',' || r.auth_privs || ',') like ('%,' || v_priv || ',%');
      if v_real <> v_esperado then
        v_fallos := v_fallos + 1;
        v_detalle := v_detalle || ' | ' || r.tabla || '.' || v_priv ||
                     ' authenticated=' || v_real::text || ' (esperado ' || v_esperado::text || ')';
      end if;

      -- anon
      v_real     := has_table_privilege('anon', r.oid, v_priv);
      v_esperado := (',' || r.anon_privs || ',') like ('%,' || v_priv || ',%');
      if v_real <> v_esperado then
        v_fallos := v_fallos + 1;
        v_detalle := v_detalle || ' | ' || r.tabla || '.' || v_priv ||
                     ' anon=' || v_real::text || ' (esperado ' || v_esperado::text || ')';
      end if;
    end loop;
  end loop;

  perform _p.anotar(48, 'Censo de tablas: privilegios declarados y TRUNCATE en cero',
    'las 15 tablas de public coinciden con lo declarado en los 7 verbos, para anon y authenticated',
    v_fallos = 0 and v_sin_declarar = 0 and v_total > 0,
    'tablas en public: ' || v_total::text ||
    ' | desajustes: ' || v_fallos::text ||
    ' | sin declarar: ' || v_sin_declarar::text ||
    case when v_detalle = '' then ' | todo en su sitio' else left(v_detalle, 1400) end);
exception when others then
  perform _p.anotar(48, 'Censo de tablas: privilegios declarados y TRUNCATE en cero',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P49 - Un admin no puede tocar el saldo ni el libro a mano
--
--  P47 y P48 miran el ACL. Esta ejercita la consecuencia, que es lo que de
--  verdad importa y lo que hay que poder contarle a un licenciatario:
--
--    un admin NO puede subirse el saldo desde la consola del navegador,
--    y NO puede escribir ni borrar filas de wallet_movements.
--
--  Eso ultimo es lo grave del hallazgo original: wallet_movements es lo que
--  lee el cuadre de P31. Un admin que pudiera escribir ahi falsearia los
--  libros Y la auditoria que comprueba los libros con la misma sesion.
--
--  El arnes corre como `postgres`, que se salta ACL y RLS, asi que aqui no
--  vale `actuar_como`: hay que preguntar por el privilegio. Lo que SI se
--  ejercita de verdad es que la via legitima sigue viva -- una recarga
--  aprobada por RPC mueve el saldo -- porque cerrar la puerta sin romper la
--  escalera es la mitad del trabajo.
-- ============================================================================
do $$
declare
  v_upd_wallets boolean; v_ins_movs boolean; v_del_movs boolean; v_upd_movs boolean;
  v_pol_wallets_all boolean; v_pol_movs_all boolean;
  v_admin uuid; v_u uuid; v_dep uuid; v_saldo numeric; v_movs int;
begin
  perform _p.limpiar();

  v_upd_wallets := has_table_privilege('authenticated', 'public.wallets', 'update');
  v_ins_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'insert');
  v_upd_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'update');
  v_del_movs    := has_table_privilege('authenticated', 'public.wallet_movements', 'delete');

  -- el segundo cerrojo: la politica FOR ALL tiene que haber dejado de existir
  select exists (select 1 from pg_policies where schemaname='public'
                   and tablename='wallets' and policyname='wallets_admin_all') into v_pol_wallets_all;
  select exists (select 1 from pg_policies where schemaname='public'
                   and tablename='wallet_movements' and policyname='wallet_movements_admin_all') into v_pol_movs_all;

  -- y la via legitima, ejercitada de verdad
  v_admin := _p.usuario('admin', 0, true);
  v_u     := _p.usuario('juan', 0);
  perform _p.actuar_como(v_u);
  perform public.solicitar_recarga(500, 'pago_movil', '04121234567', 'REF-P49', current_date);
  select id into v_dep from public.deposit_requests where user_id = v_u;
  perform _p.actuar_como(v_admin);
  perform public.aprobar_recarga(v_dep);
  v_saldo := _p.saldo(v_u);
  select count(*) into v_movs from public.wallet_movements m
  join public.wallets w on w.id = m.wallet_id where w.user_id = v_u;

  perform _p.anotar(49, 'Un admin no toca el saldo ni el libro a mano',
    'sin update sobre wallets ni escritura sobre wallet_movements; politicas FOR ALL retiradas; la recarga por RPC sigue moviendo el saldo',
    (not v_upd_wallets) and (not v_ins_movs) and (not v_upd_movs) and (not v_del_movs)
      and (not v_pol_wallets_all) and (not v_pol_movs_all)
      and v_saldo = 500 and v_movs = 1,
    'wallets.update=' || v_upd_wallets::text ||
    ' movimientos[ins=' || v_ins_movs::text || ',upd=' || v_upd_movs::text ||
    ',del=' || v_del_movs::text || ']' ||
    ' politicas_for_all[wallets=' || v_pol_wallets_all::text || ',movimientos=' || v_pol_movs_all::text || ']' ||
    ' | via legitima -> saldo ' || coalesce(v_saldo,-1)::text || ' (esperado 500)' ||
    ', movimientos ' || v_movs::text || ' (esperado 1)');
exception when others then
  perform _p.anotar(49, 'Un admin no toca el saldo ni el libro a mano',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;



-- ============================================================================
--  P50 - La escalera general no existe, y cambiar el incremento surte efecto
--
--  EL DEFECTO QUE REPRODUCE (30/09)
--
--  `remate_price_rules` admitia filas con `horse_id` nulo -- una escalera
--  "general" del remate -- y esas filas GANABAN sobre
--  `remates.incremento_minimo`. Jota cambio el incremento de un remate de 50
--  a 80, la columna quedo en 80, y el caballo sin escalera propia siguio
--  subiendo de 50 en 50 porque el tramo general lo decia.
--
--  El admin cambia un numero, la pantalla le confirma el cambio, y la base
--  cobra otra cosa. Dos fuentes para el mismo numero, y manda la que no se ve.
--
--  LA PRUEBA MIDE TRES COSAS, Y LAS TRES IMPORTAN:
--
--    1. Una regla general ya no se puede escribir  -> 23502 (not_null_violation)
--    2. Un caballo SIN escalera propia obedece a remates.incremento_minimo,
--       y lo sigue obedeciendo despues de cambiarlo con editar_remate
--    3. Un caballo CON escalera propia conserva la suya
--
--  La tercera es la que evita el arreglo bruto: cerrar la general a costa de
--  romper las escaleras por caballo seria cambiar un defecto por otro.
--
--  23502 = not_null_violation
-- ============================================================================
do $$
declare
  v_admin uuid; v_rem uuid; v_h1 uuid; v_h2 uuid;
  v_general_entro boolean := false; v_sqlstate text := '';
  v_inc1_antes numeric; v_inc2_antes numeric;
  v_inc1_despues numeric; v_inc2_despues numeric;
  v_existe boolean;
begin
  perform _p.limpiar();

  select exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'editar_remate'
  ) into v_existe;

  if not v_existe then
    perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
      'ver arriba', false, 'editar_remate NO EXISTE: la migracion no esta aplicada');
    return;
  end if;

  v_admin := _p.usuario('admin', 0, true);
  v_rem   := _p.escenario(2, 100, 25);          -- incremento_minimo = 10
  v_h1    := _p.caballo(v_rem, 1);              -- SIN escalera propia
  v_h2    := _p.caballo(v_rem, 2);              -- CON escalera propia

  insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
  values (v_rem, v_h2, 100, 1000, 30);

  -- 1) la regla general tiene que rebotar
  begin
    insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
    values (v_rem, null, 0, null, 50);
    v_general_entro := true;
  exception when others then
    v_sqlstate := sqlstate;
  end;

  select incremento into v_inc1_antes from public.remate_minimos(v_rem) where numero = 1;
  select incremento into v_inc2_antes from public.remate_minimos(v_rem) where numero = 2;

  -- 2) y cambiar el incremento del remate tiene que llegar al caballo 1
  perform _p.actuar_como(v_admin);
  perform public.editar_remate(v_rem, null, 80, null, null, null);

  select incremento into v_inc1_despues from public.remate_minimos(v_rem) where numero = 1;
  select incremento into v_inc2_despues from public.remate_minimos(v_rem) where numero = 2;

  perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
    'la regla general se rechaza con 23502; el caballo sin escalera pasa de 10 a 80; el que tiene escalera sigue en 30',
    (not v_general_entro) and v_sqlstate = '23502'
      and v_inc1_antes = 10 and v_inc1_despues = 80
      and v_inc2_antes = 30 and v_inc2_despues = 30,
    'regla general entro=' || v_general_entro::text ||
    case when v_sqlstate = '' then '' else ' (sqlstate ' || v_sqlstate || ')' end ||
    ' | caballo 1 (sin escalera): ' || coalesce(v_inc1_antes,-1)::text ||
    ' -> ' || coalesce(v_inc1_despues,-1)::text || ' (esperado 10 -> 80; si da 50 gano la general)' ||
    ' | caballo 2 (con escalera): ' || coalesce(v_inc2_antes,-1)::text ||
    ' -> ' || coalesce(v_inc2_despues,-1)::text || ' (esperado 30 en los dos)');
exception when others then
  perform _p.anotar(50, 'La escalera general no existe y el incremento del remate manda',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ============================================================================
--  P51 - La columna que hace imposible la regla invisible
--
--  P50 comprueba el comportamiento; esta comprueba la valla. Son cosas
--  distintas: el comportamiento correcto se puede conseguir por casualidad
--  -- no habiendo generales en la base -- y seguir siendo posible escribirlas.
--
--  Mientras `horse_id` admita nulos, el defecto de P50 se puede reintroducir
--  con un insert de mantenimiento, una migracion futura o un service_role
--  distraido, y no lo veria nadie hasta que un remate cobrara de menos.
-- ============================================================================
do $$
declare v_not_null boolean;
begin
  select a.attnotnull into v_not_null
  from pg_attribute a
  where a.attrelid = 'public.remate_price_rules'::regclass
    and a.attname = 'horse_id'
    and a.attnum > 0;

  perform _p.anotar(51, 'remate_price_rules.horse_id es obligatorio',
    'la columna es NOT NULL: una regla siempre es de un caballo concreto',
    coalesce(v_not_null, false),
    'horse_id not null = ' || coalesce(v_not_null, false)::text ||
    ' -> mientras admita nulos, la escalera general se puede reintroducir sin que nadie lo vea');
exception when others then
  perform _p.anotar(51, 'remate_price_rules.horse_id es obligatorio',
    'ver arriba', false, 'excepcion (' || sqlstate || '): ' || sqlerrm);
end $$;


-- ---------------------------------------------------------------- resumen
\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _p.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _p.resultado;


-- ---------------------------------------------------------------- limpieza
--  EL ARNES DEJA LA BASE COMO LA ENCONTRO (anadido el 29/09)
--
--  Cada prueba llama a _p.limpiar() ANTES de armar su escenario, nunca
--  despues. Consecuencia: la ultima prueba que corre deja su mundo montado en
--  la base -- usuarios, saldos, recargas aprobadas.
--
--  Hasta hoy no importaba, porque nadie abria la aplicacion contra la base del
--  arnes. Desde que existe .env.development.local si, y Jota se encontro a
--  "juan" con 500 Bs de recarga aprobada en la pantalla de recargas: el
--  residuo de P49.
--
--  En una app cuyo argumento de venta es que las cuentas cuadran, un usuario
--  fantasma con dinero fantasma en la pantalla del admin es veneno. Se limpia.
--
--  _p.resultado NO se borra: el resumen ya se imprimio arriba, pero la tabla
--  queda por si quieres consultarla. Si alguna vez necesitas inspeccionar el
--  estado que dejo una prueba en rojo, comenta este bloque y vuelve a correr.
do $$
begin
  delete from public.admin_actions;   -- _p.limpiar() no lo toca
  perform _p.limpiar();
end $$;
