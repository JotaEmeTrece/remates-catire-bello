-- ============================================================================
--  Tarea 2.18 - El libro de la casa
--
--  EL PROBLEMA QUE DESTAPO LA TAJADA D
--  La casa aporta al pozo los caballos que nadie puja, pero ese aporte no es
--  dinero que haya entrado por caja. Un pozo de 300 donde los usuarios pusieron
--  200 paga 225 de premio: 25 salen del bolsillo de la casa. Hasta hoy el
--  sistema no tenia donde registrar que la casa tuviera capital propio, asi que
--  dinero_casa_disponible() daba negativo siempre y la guarda de solvencia
--  bloqueaba toda liquidacion con caballos no pujados, que son la mayoria.
--  La guarda estaba bien; lo que faltaba era la puerta de entrada del capital.
--
--  LO QUE ESTE LIBRO NO ES
--  No es un mecanismo de control sobre el licenciatario. El dinero esta en su
--  cuenta bancaria y nada le impide pagarle el premio a uno con el saldo de
--  otro. Eso no se puede evitar desde el software y no se pretende.
--  Lo que SI se consigue: que el sistema sepa en todo momento de quien es cada
--  peso, y que el operador honesto no pueda estar pagando premios con depositos
--  de usuarios sin darse cuenta -que es el caso frecuente, mas que el fraude-.
--
--  LOS CUATRO ASIENTOS
--    aporte_capital     (+)  el licenciatario mete dinero propio    [a mano]
--    retiro_utilidad    (-)  se lleva ganancia                      [a mano]
--    ajuste             (+-) correccion, con motivo obligatorio     [a mano]
--    resultado_remate   (+-) lo que dejo cada remate      [EL SISTEMA, al liquidar]
--
--  El cuarto NO lo toca el admin. Decidido asi a proposito: que el 25% o el
--  pozo ganado vayan donde tienen que ir no puede quedar al criterio de nadie.
--
--  EL CUADRE, QUE ES LO MAS VALIOSO DE TODO ESTO
--  Con el libro existen dos formas independientes de calcular lo mismo, y
--  tienen que coincidir:
--
--    suma de los `resultado_remate`   (lo que la casa gano segun su libro)
--    ==
--    recargas - retiros pagados - retiros pendientes - saldo de usuarios
--                                     (lo que los usuarios perdieron, en neto)
--
--  Si no coinciden, hay un bug o alguien metio mano. Lo verifica la prueba P31.
--
--  OJO CON EL DOBLE CONTEO: `resultado_remate` NO entra en
--  dinero_casa_disponible(), porque ese resultado ya esta implicito en los
--  saldos -los usuarios perdieron ese dinero, asi que su saldo ya bajo-.
--  Solo entran los tres asientos manuales, que si mueven caja sin tocar saldos.
-- ============================================================================

create table if not exists public.house_ledger (
  id          uuid primary key default gen_random_uuid(),
  tipo        text not null check (tipo in ('aporte_capital','retiro_utilidad','ajuste','resultado_remate')),
  monto       numeric(14,2) not null,
  motivo      text not null,
  ref_externa text,
  detalles    jsonb,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now(),

  -- El signo tiene que ser coherente con el tipo. Un aporte negativo o un
  -- retiro de utilidad positivo son errores de dedo que descuadran el libro
  -- en silencio; aqui se rechazan.
  constraint house_ledger_signo check (
    (tipo = 'aporte_capital'  and monto > 0) or
    (tipo = 'retiro_utilidad' and monto < 0) or
    (tipo in ('ajuste','resultado_remate'))
  ),
  -- Un remate no puede quedar asentado dos veces.
  constraint house_ledger_resultado_unico unique (tipo, ref_externa)
);

comment on table public.house_ledger is
  'Libro de la casa: capital propio, utilidades retiradas, ajustes y el resultado de cada remate liquidado.';

create index if not exists idx_house_ledger_tipo on public.house_ledger (tipo);
create index if not exists idx_house_ledger_fecha on public.house_ledger (created_at desc);

alter table public.house_ledger enable row level security;

-- Solo los admin lo leen. Nadie lo escribe directo: se escribe por RPC.
drop policy if exists house_ledger_admin_select on public.house_ledger;
create policy house_ledger_admin_select on public.house_ledger
  for select to authenticated using (public.is_admin());

revoke all on table public.house_ledger from anon, authenticated;
grant select on table public.house_ledger to authenticated;

-- ---------------------------------------------------------------------------
-- Los tres asientos manuales. El cuarto lo pone liquidar_remate.
-- ---------------------------------------------------------------------------
create or replace function public.registrar_movimiento_casa(
  p_tipo text, p_monto numeric, p_motivo text)
returns public.house_ledger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_row public.house_ledger%rowtype;
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

  -- resultado_remate queda fuera a proposito: lo escribe el sistema al
  -- liquidar. Si un admin pudiera crearlo a mano, el cuadre dejaria de
  -- significar nada.
  if p_tipo not in ('aporte_capital','retiro_utilidad','ajuste') then
    raise exception 'Tipo no valido. Los asientos manuales son: aporte_capital, retiro_utilidad, ajuste';
  end if;

  if p_monto is null or p_monto = 0 then
    raise exception 'El monto no puede ser cero';
  end if;

  if p_motivo is null or length(trim(p_motivo)) < 3 then
    raise exception 'Motivo obligatorio';
  end if;

  insert into public.house_ledger (tipo, monto, motivo, created_by)
  values (p_tipo, p_monto, trim(p_motivo), v_admin_id)
  returning * into v_row;

  perform public.log_admin_action(
    v_admin_id, 'registrar_movimiento_casa', 'house_ledger', v_row.id::text,
    jsonb_build_object('tipo', p_tipo, 'monto', p_monto, 'motivo', trim(p_motivo)),
    true, null);

  return v_row;
end;
$fn$;

revoke all on function public.registrar_movimiento_casa(text, numeric, text) from public, anon;
grant execute on function public.registrar_movimiento_casa(text, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- dinero_casa_disponible(): ahora incluye el capital propio.
--
-- Entran los tres asientos manuales. NO entra resultado_remate: ese resultado
-- ya esta reflejado en los saldos de los usuarios, y sumarlo seria contarlo
-- dos veces.
-- ---------------------------------------------------------------------------
create or replace function public.dinero_casa_disponible()
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select
      (select coalesce(sum(monto), 0) from public.deposit_requests  where estado = 'aprobado')
    - (select coalesce(sum(monto), 0) from public.withdraw_requests where estado = 'pagado')
    - (select coalesce(sum(monto), 0) from public.withdraw_requests where estado = 'pendiente')
    - (select coalesce(sum(saldo_disponible + saldo_bloqueado), 0) from public.wallets)
    + (select coalesce(sum(monto), 0) from public.house_ledger where tipo <> 'resultado_remate');
$fn$;

-- ---------------------------------------------------------------------------
-- casa_resumen(): la foto completa, con el cuadre incluido.
-- ---------------------------------------------------------------------------
create or replace function public.casa_resumen()
returns table(
  caja_total          numeric,  -- lo que deberia haber en el banco
  obligaciones        numeric,  -- lo que se le debe a los usuarios
  patrimonio          numeric,  -- lo que de verdad es de la casa
  capital_aportado    numeric,
  utilidades_retiradas numeric,
  ajustes             numeric,
  resultado_operativo numeric,  -- lo ganado en remates, segun el libro
  perdida_usuarios    numeric,  -- lo mismo, calculado desde los saldos
  descuadre           numeric,  -- resultado_operativo - perdida_usuarios
  cubierto            boolean   -- false = se estan pagando premios con dinero ajeno
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with d as (
    select coalesce(sum(monto),0) as recargas from public.deposit_requests where estado='aprobado'
  ),
  wp as (
    select coalesce(sum(monto),0) as pagados from public.withdraw_requests where estado='pagado'
  ),
  wq as (
    select coalesce(sum(monto),0) as pendientes from public.withdraw_requests where estado='pendiente'
  ),
  s as (
    select coalesce(sum(saldo_disponible + saldo_bloqueado),0) as saldos from public.wallets
  ),
  l as (
    select
      coalesce(sum(monto) filter (where tipo='aporte_capital'),0)   as aportes,
      coalesce(sum(monto) filter (where tipo='retiro_utilidad'),0)  as utilidades,
      coalesce(sum(monto) filter (where tipo='ajuste'),0)           as ajustes,
      coalesce(sum(monto) filter (where tipo='resultado_remate'),0) as resultados
    from public.house_ledger
  )
  select
    (d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)            as caja_total,
    (s.saldos + wq.pendientes)                                                  as obligaciones,
    (d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)
      - (s.saldos + wq.pendientes)                                              as patrimonio,
    l.aportes,
    l.utilidades,
    l.ajustes,
    l.resultados                                                                as resultado_operativo,
    (d.recargas - wp.pagados - wq.pendientes - s.saldos)                        as perdida_usuarios,
    l.resultados - (d.recargas - wp.pagados - wq.pendientes - s.saldos)         as descuadre,
    ((d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)
      - (s.saldos + wq.pendientes)) >= 0                                        as cubierto
  from d, wp, wq, s, l;
$fn$;

comment on function public.casa_resumen() is
  'Foto contable de la casa. `descuadre` distinto de cero significa que el libro y los saldos no cuentan la misma historia. `cubierto` false significa que se estan pagando premios con dinero de los usuarios.';

revoke all on function public.casa_resumen() from public, anon;
grant execute on function public.casa_resumen() to authenticated;

-- ---------------------------------------------------------------------------
-- liquidar_remate: asienta el resultado en el libro.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.liquidar_remate(p_remate_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin_id uuid := auth.uid();
  v_is_admin boolean;
  v_is_super boolean;
  v_remate public.remates%rowtype;
  v_ganador_horse_id uuid;
  v_ganador_retirado boolean;
  v_ganador_user_id uuid;
  v_pozo_total numeric := 0;
  v_premio numeric := 0;
  v_caja numeric;
  v_wallet public.wallets%rowtype;
  v_resultado numeric;
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

  select rr.ganador_horse_id, coalesce(h.retirado, false)
    into v_ganador_horse_id, v_ganador_retirado
  from public.race_results rr
  left join public.horses h on h.id = rr.ganador_horse_id
  where rr.race_id = v_remate.race_id;

  if v_ganador_horse_id is null then
    raise exception 'Debes indicar el caballo ganador antes de liquidar';
  end if;

  -- Un caballo retirado no corre, asi que no puede ganar. Sin esta guarda, a su
  -- lider se le pagaria el premio sin haberle cobrado nada al cerrar (los
  -- retirados quedan fuera del cobro y fuera del pozo): dinero de la nada.
  if v_ganador_retirado then
    raise exception 'El caballo marcado como ganador esta retirado. Corrige el resultado de la carrera antes de liquidar.';
  end if;

  -- POZO. Cada caballo aporta su puja mas alta, y si nadie lo pujo aporta su
  -- precio_salida, porque queda con la casa por ese monto.
  -- TAREA 1.1: los retirados quedan fuera de los dos terminos.
  select coalesce(sum(coalesce(t.max_monto, h.precio_salida)), 0)
    into v_pozo_total
  from public.horses h
  left join (
    select horse_id, max(monto)::numeric as max_monto
    from public.bids
    where remate_id = p_remate_id
    group by horse_id
  ) t on t.horse_id = h.id
  where h.race_id = v_remate.race_id
    and coalesce(h.retirado, false) = false;

  select b.user_id
    into v_ganador_user_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id = v_ganador_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  -- PREMIO. TAREA 1.2: sale de porcentaje_casa, no de un 0.75 clavado.
  if v_ganador_user_id is null then
    -- Gano un caballo de la casa: no hay premio que pagar, la casa se queda el
    -- pozo completo.
    v_premio := 0;
  else
    v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa, 25) / 100.0), 2);
  end if;

  -- GUARDA DE SOLVENCIA. TAREA 1.3.
  -- La casa banca los caballos que nadie pujo, y esos entran al pozo sin que
  -- nadie haya puesto ese dinero. Un remate de 10 caballos donde solo se puja
  -- uno genera un premio muy superior a lo que entro por caja. Acreditar eso
  -- es prometer un saldo que no se puede pagar cuando el usuario lo retire.
  if v_premio > 0 then
    v_caja := public.dinero_casa_disponible();
    if v_premio > v_caja then
      raise exception 'La casa no puede pagar este premio: son % Bs y la caja disponible es % Bs. Revisa la contabilidad antes de liquidar.',
        v_premio, v_caja;
    end if;
  end if;

  if v_ganador_user_id is not null and v_premio > 0 then
    select * into v_wallet
    from public.wallets
    where user_id = v_ganador_user_id
    for update;

    if not found then
      raise exception 'No se encontro wallet para el ganador';
    end if;

    update public.wallets
       set saldo_disponible = saldo_disponible + v_premio
     where id = v_wallet.id;

    insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
    values (v_wallet.id, 'premio', v_premio,
            'Premio del remate ' || v_remate.nombre,
            p_remate_id::text);
  end if;

  -- ASIENTO EN EL LIBRO DE LA CASA (tarea 2.18).
  --
  -- Lo crea el sistema, no el admin. El resultado se LEE de los movimientos
  -- reales de este remate en vez de recalcularse:
  --
  --   apuesta_cobro      negativo (sale de los usuarios)  -> entra a la casa
  --   apuesta_devolucion positivo (vuelve a los usuarios)  -> sale de la casa
  --   premio             positivo (va al ganador)          -> sale de la casa
  --
  -- Por eso el signo va invertido. Al salir de los movimientos y no de una
  -- cuenta aparte, no se puede despegar de la realidad: si se retiro un caballo
  -- despues del cierre y se devolvio dinero, eso ya esta contado.
  --
  -- Cubre los dos casos sin distinguirlos: si gana un caballo de la casa el
  -- premio es 0 y el resultado es todo lo cobrado; si gana un usuario, el
  -- resultado es la comision.
  select -coalesce(sum(m.monto), 0)
    into v_resultado
  from public.wallet_movements m
  where m.ref_externa = p_remate_id::text
    and m.tipo in ('apuesta_cobro', 'apuesta_devolucion', 'premio');

  insert into public.house_ledger (tipo, monto, motivo, ref_externa, created_by, detalles)
  values ('resultado_remate', v_resultado,
          'Resultado del remate ' || v_remate.nombre,
          p_remate_id::text, null,
          jsonb_build_object(
            'pozo_total', v_pozo_total,
            'premio_pagado', v_premio,
            'porcentaje_casa', coalesce(v_remate.porcentaje_casa, 25),
            'gano_la_casa', (v_ganador_user_id is null)));

  update public.remates
  set estado = 'liquidado'
  where id = p_remate_id;

  return 'Remate liquidado. Pozo ' || v_pozo_total::text || ' Bs, premio ' || v_premio::text || ' Bs.';
end;
$function$;
