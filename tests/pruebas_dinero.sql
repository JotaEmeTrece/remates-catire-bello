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


-- ---------------------------------------------------------------- resumen
\set QUIET off
select n as "#", nombre, esperado, estado, detalle from _p.resultado order by n;
select count(*) filter (where estado='OK') as "en verde",
       count(*) filter (where estado='FALLA') as "en rojo",
       count(*) as total
from _p.resultado;
