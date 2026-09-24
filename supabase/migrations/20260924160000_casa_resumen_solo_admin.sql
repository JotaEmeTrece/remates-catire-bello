-- ===========================================================================
--  20260924160000_casa_resumen_solo_admin.sql
--
--  FALLA QUE ARREGLA (mia, de la migracion 20260924150000):
--
--  casa_resumen() quedo `security definer` y con `grant execute to
--  authenticated`, pero SIN comprobar que quien llama sea admin. Resultado:
--  cualquier usuario logueado podia abrir la consola del navegador, llamar
--  supabase.rpc('casa_resumen') y ver el patrimonio de la casa, el capital
--  aportado y las utilidades retiradas.
--
--  La tabla house_ledger si estaba protegida (RLS + is_admin()), pero eso no
--  sirve de nada cuando una funcion `definer` lee la tabla por encima de la
--  RLS y devuelve el total. La guarda tiene que estar en la funcion.
--
--  Va en migracion aparte y no editando la 150000 a proposito: si esa ya
--  se empujo a produccion, editarla no la vuelve a ejecutar nunca.
--
--  El mismo patron de guarda que ya usa admin_contabilidad_resumen().
-- ===========================================================================

create or replace function public.casa_resumen()
returns table(
  caja_total          numeric,
  obligaciones        numeric,
  patrimonio          numeric,
  capital_aportado    numeric,
  utilidades_retiradas numeric,
  ajustes             numeric,
  resultado_operativo numeric,
  perdida_usuarios    numeric,
  descuadre           numeric,
  cubierto            boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_is_admin boolean;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

  select (coalesce(es_admin, false) or coalesce(es_super_admin, false))
    into v_is_admin
  from public.profiles
  where id = v_user_id;

  if coalesce(v_is_admin, false) = false then
    raise exception 'No autorizado: solo administradores';
  end if;

  return query
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
    l.aportes                                                                   as capital_aportado,
    l.utilidades                                                                as utilidades_retiradas,
    l.ajustes                                                                   as ajustes,
    l.resultados                                                                as resultado_operativo,
    (d.recargas - wp.pagados - wq.pendientes - s.saldos)                        as perdida_usuarios,
    l.resultados - (d.recargas - wp.pagados - wq.pendientes - s.saldos)         as descuadre,
    ((d.recargas - wp.pagados + l.aportes + l.utilidades + l.ajustes)
      - (s.saldos + wq.pendientes)) >= 0                                        as cubierto
  from d, wp, wq, s, l;
end;
$fn$;

comment on function public.casa_resumen() is
  'Foto contable de la casa. Solo admin. `descuadre` distinto de cero significa que el libro y los saldos no cuentan la misma historia. `cubierto` false significa que se estan pagando premios con dinero de los usuarios.';

revoke all on function public.casa_resumen() from public, anon;
grant execute on function public.casa_resumen() to authenticated;
