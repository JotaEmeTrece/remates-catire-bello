-- ===========================================================================
--  diagnostico_compromiso.sql   -   SOLO LECTURA
--
--  Para que: la pantalla dice "En pujas: 0,00 Bs" a usuarios que lideran
--  pujas. compromiso_usuario() se ve correcta al leerla y mi_wallet_resumen()
--  tiene execute para authenticated, asi que el 0 no se explica con el codigo
--  a la vista. Esto mide la base en vez de suponer.
--
--  Donde: SQL Editor del panel de Supabase, contra PRODUCCION.
--  No escribe nada. Se puede correr con el remate abierto.
-- ===========================================================================

-- 1) EL RELOJ Y LOS REMATES. Si estado no es 'abierto', compromiso_usuario()
--    devuelve 0 por definicion, aunque la pantalla siga pintando el remate.
select
  'A- remates' as bloque,
  r.id,
  r.nombre,
  r.estado,
  r.opens_at,
  r.closes_at,
  now()                                   as ahora,
  (r.closes_at is not null and now() >= r.closes_at) as ya_paso_el_cierre,
  r.closed_at,
  r.archived_at
from public.remates r
order by r.created_at desc
limit 10;

-- 2) LAS PUJAS CRUDAS, con quien es lider segun la MISMA cuenta que hace
--    compromiso_usuario(). Si una puja sale es_lider = false y tu crees que
--    deberia liderar, ahi esta el defecto.
with lideres as (
  select distinct on (b.remate_id, b.horse_id)
         b.id as bid_id
  from public.bids b
  join public.remates r on r.id = b.remate_id
  join public.horses  h on h.id = b.horse_id
  where r.estado = 'abierto'
    and coalesce(h.retirado, false) = false
  order by b.remate_id, b.horse_id, b.monto desc, b.created_at asc
)
select
  'B- pujas' as bloque,
  b.created_at,
  r.nombre                      as remate,
  r.estado                      as remate_estado,
  h.numero                      as caballo,
  h.nombre                      as caballo_nombre,
  coalesce(h.retirado,false)    as retirado,
  p.username,
  b.monto,
  (l.bid_id is not null)        as es_lider_y_cuenta
from public.bids b
join public.remates r  on r.id = b.remate_id
join public.horses  h  on h.id = b.horse_id
left join public.profiles p on p.id = b.user_id
left join lideres l on l.bid_id = b.id
order by r.created_at desc, h.numero, b.monto desc;

-- 3) LO QUE VE CADA CLIENTE. Esta es, literalmente, la cuenta que
--    mi_wallet_resumen() le entrega a la pantalla.
select
  'C- saldos' as bloque,
  p.username,
  w.saldo_disponible,
  public.compromiso_usuario(w.user_id)                                        as comprometido,
  greatest(w.saldo_disponible - public.compromiso_usuario(w.user_id), 0)      as disponible_para_retirar
from public.wallets w
join public.profiles p on p.id = w.user_id
where coalesce(p.es_admin,false) = false and coalesce(p.es_super_admin,false) = false
order by p.username;

-- 4) DESCARTAR UNA BILLETERA DUPLICADA. mi_wallet_resumen() hace `limit 1`
--    sin `order by`: con dos filas para el mismo usuario, elige una al azar.
--    Esto debe devolver CERO filas.
select 'D- billeteras duplicadas' as bloque, user_id, count(*) as filas
from public.wallets
group by user_id
having count(*) > 1;

-- 5) LA ESCALERA. Con la expansion, cada caballo tiene reglas propias y
--    entonces remates.incremento_minimo no gobierna a nadie. Si
--    caballos_con_regla = caballos_del_remate, el incremento general es
--    decorativo y eso explica lo del incremento que no se aplica.
select
  'E- escalera' as bloque,
  r.nombre                                            as remate,
  r.incremento_minimo,
  (select count(*) from public.horses h where h.race_id = r.race_id)                     as caballos_del_remate,
  (select count(distinct pr.horse_id) from public.remate_price_rules pr
    where pr.remate_id = r.id)                                                           as caballos_con_regla,
  (select count(*) from public.remate_price_rules pr
    where pr.remate_id = r.id and pr.horse_id is null)                                   as reglas_generales_huerfanas
from public.remates r
order by r.created_at desc
limit 10;

-- 6) LOS MINIMOS QUE LA BASE VA A COBRAR, caballo por caballo, del remate mas
--    reciente. Aqui se ve si el "de 250 bajo a 200" viene de la base o de la
--    pantalla.
select 'F- minimos' as bloque, m.*
from public.remate_minimos(
  (select id from public.remates order by created_at desc limit 1)
) m;
