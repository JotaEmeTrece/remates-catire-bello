-- ============================================================================
--  Bloque 2, tajada A - Las dos funciones de calculo y los indices
--
--  Esta migracion NO cambia ningun comportamiento. Solo agrega objetos que
--  todavia nadie usa. Las tajadas B en adelante los van a consumir.
--
--  Referencia: DISENO_SALDO_V2.md, secciones 3, 6.3 y 8.
--
--  DOS DESVIACIONES RESPECTO DEL DISENO, las dos a proposito:
--
--  1) El diseno pide un indice `idx_bids_user on bids (user_id)`. YA EXISTE,
--     con el nombre `idx_bids_user_id`. Crearlo seria un indice duplicado:
--     ocupa espacio, encarece cada insert de puja y no acelera nada. No se crea.
--
--  2) El diseno define dinero_casa_disponible() restando solo
--     `sum(saldo_disponible)`. Pero admin_contabilidad_resumen() (tarea 1.4)
--     resta `sum(saldo_disponible + saldo_bloqueado)`. Dejarlos distintos
--     significaria que el panel de contabilidad y la guarda de solvencia dan
--     numeros distintos sobre la misma caja. Se usa la del panel.
--     Nota: cuando el bloque 2 termine, saldo_bloqueado sera siempre 0, asi que
--     la formula da lo mismo en los dos mundos. Durante la transicion, solo la
--     del panel es correcta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- compromiso_usuario(): lo que se le debitaria a este usuario si todos los
-- remates abiertos cerraran ahora mismo.
--
-- Es la suma de las pujas que LIDERA en este momento, en remates abiertos,
-- sobre caballos no retirados.
--
-- Por que esto reemplaza a wallets.saldo_bloqueado: al no ser un numero
-- guardado, no puede descuadrarse. Si te superan, tu puja deja de ser lider y
-- tu compromiso baja solo, sin que nadie escriba nada. Si subes tu propia puja
-- de 100 a 150, sigues siendo el unico lider de ese caballo: tu compromiso
-- pasa a 150, no a 250. Si retiran el caballo, deja de contar. Si el remate se
-- cancela, deja de estar abierto. Todo eso, que hoy son ramas de codigo con
-- dinero de por medio, pasa a ser consecuencia de la definicion.
--
-- OJO con el orden: primero se busca el lider de CADA caballo, y despues se
-- filtra por usuario. Al reves daria la mejor puja del usuario aunque lo hayan
-- superado, que es justo lo que no queremos contar.
-- ---------------------------------------------------------------------------
create or replace function public.compromiso_usuario(p_user_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(sum(lider.monto), 0)
  from (
    select distinct on (b.remate_id, b.horse_id)
           b.user_id,
           b.monto
    from public.bids b
    join public.remates r on r.id = b.remate_id
    join public.horses  h on h.id = b.horse_id
    where r.estado = 'abierto'
      and coalesce(h.retirado, false) = false
    order by b.remate_id, b.horse_id, b.monto desc, b.created_at asc
  ) lider
  where lider.user_id = p_user_id;
$fn$;

comment on function public.compromiso_usuario(uuid) is
  'Suma de las pujas que el usuario lidera ahora en remates abiertos, sobre caballos no retirados. Reemplaza a wallets.saldo_bloqueado: se calcula, no se guarda.';

-- ---------------------------------------------------------------------------
-- dinero_casa_disponible(): la caja real de la casa.
--
-- Misma identidad que usa admin_contabilidad_resumen(), para que el panel y la
-- guarda de solvencia no puedan contradecirse.
--
--   recargas aprobadas
--   - retiros pagados
--   - retiros pendientes      (ya se descontaron de la wallet, pero el dinero
--                              sigue en la caja hasta que se transfiere)
--   - saldo total de usuarios (lo que se les debe)
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
    - (select coalesce(sum(saldo_disponible + saldo_bloqueado), 0) from public.wallets);
$fn$;

comment on function public.dinero_casa_disponible() is
  'Caja de la casa: recargas aprobadas menos retiros pagados, retiros pendientes y saldo total de usuarios. Misma formula que admin_contabilidad_resumen().';

-- Ninguna de las dos se expone a anon.
revoke all on function public.compromiso_usuario(uuid)  from public, anon;
revoke all on function public.dinero_casa_disponible()  from public, anon;
grant execute on function public.compromiso_usuario(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Indices. compromiso_usuario() se llama en CADA puja, asi que la consulta
-- tiene que volar.
-- ---------------------------------------------------------------------------

-- Sostiene el `distinct on (remate_id, horse_id) ... order by monto desc`.
create index if not exists idx_bids_lider
  on public.bids (remate_id, horse_id, monto desc, created_at asc);

-- Parcial: los remates abiertos son pocos por definicion, y son los unicos que
-- cuentan para el compromiso.
create index if not exists idx_remates_abiertos
  on public.remates (estado) where estado = 'abierto';
