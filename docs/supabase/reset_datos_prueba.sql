-- ============================================================================
--  Vaciar los datos de prueba, dejando el esquema y los usuarios intactos
--
--  Reemplaza a docs/sql-historico/reset_app_cero.sql, que YA NO FUNCIONA.
--  Comprobado el 23/09/2026 contra PostgreSQL 16:
--
--    ERROR: update or delete on table "horses" violates foreign key
--    constraint "race_results_ganador_horse_id_fkey" on table "race_results"
--
--  El script viejo borra `horses` sin borrar antes `race_results`. Funcionaba
--  cuando esa FK era CASCADE; desde la tarea 3.1 es RESTRICT, justamente para
--  que nadie pueda borrar un caballo que ya figura como ganador de una carrera.
--  La FK esta haciendo su trabajo: el script es el que quedo viejo.
--
--  QUE BORRA
--    - remates, carreras, caballos, pujas y reglas de precio
--    - race_results
--    - recargas, retiros y movimientos de wallet
--    - el libro de la casa (house_ledger)
--    - deja las wallets en 0
--
--  QUE NO TOCA
--    - auth.users ni profiles: NO pierdes tu cuenta de admin
--    - admin_actions: es la bitacora de auditoria. Borrarla es una decision
--      aparte; si se quiere limpiar antes de entregarle la instalacion a un
--      cliente, se hace a mano y con conocimiento de causa.
--    - app_settings y cualquier configuracion de instalacion
--
--  Todo va en UNA transaccion: o se borra completo, o no se borra nada.
-- ============================================================================

begin;

-- 1) Resultados de carrera. VA PRIMERO: apunta a horses con RESTRICT.
delete from public.race_results;

-- 2) Pujas y reglas de precio. Antes que remates y caballos (RESTRICT).
delete from public.bids;
delete from public.remate_price_rules;

-- 3) Remates. Antes que races y horses (RESTRICT).
delete from public.remates;

-- 4) Caballos y carreras.
delete from public.horses;
delete from public.races;

-- 5) Libro de la casa (tarea 2.18).
--    Va aqui por dos razones. Sus asientos `resultado_remate` apuntan a
--    remates que ya se borraron arriba, asi que dejarlos seria guardar el
--    resultado de partidas que ya no existen. Y `created_by` referencia a
--    profiles: si algun dia este script llega a borrar usuarios, tiene que
--    irse antes que ellos.
delete from public.house_ledger;

-- 6) Operaciones financieras.
delete from public.wallet_movements;
delete from public.deposit_requests;
delete from public.withdraw_requests;

-- 7) Wallets a cero. No se borran: siguen atadas a los usuarios que quedan.
update public.wallets
   set saldo_disponible = 0,
       saldo_bloqueado  = 0;

commit;

-- Comprobante: todo en 0 menos usuarios y wallets.
select 'races' as tabla, count(*) from public.races
union all select 'remates',          count(*) from public.remates
union all select 'horses',           count(*) from public.horses
union all select 'bids',             count(*) from public.bids
union all select 'remate_price_rules', count(*) from public.remate_price_rules
union all select 'race_results',     count(*) from public.race_results
union all select 'wallet_movements', count(*) from public.wallet_movements
union all select 'deposit_requests', count(*) from public.deposit_requests
union all select 'withdraw_requests', count(*) from public.withdraw_requests
union all select 'house_ledger',      count(*) from public.house_ledger
union all select 'wallets con saldo <> 0',
       (select count(*) from public.wallets where saldo_disponible <> 0 or saldo_bloqueado <> 0)
union all select 'profiles (NO se tocan)', count(*) from public.profiles
order by 1;
