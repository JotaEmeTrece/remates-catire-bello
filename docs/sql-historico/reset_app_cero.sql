-- Reseteo TOTAL a "CERO" (para empezar limpio)
-- ✅ Borra data de remates + recargas/retiros + movimientos de wallet
-- ✅ Pone wallets en 0 (disponible/bloqueado)
-- ❗ NO borra usuarios (auth.users) ni profiles (roles/admins)
--
-- Úsalo SOLO si quieres arrancar desde cero sin historial financiero.

begin;

-- =========================
-- 1) BORRAR REMATES (TODO)
-- =========================
create temporary table _remates_to_delete as
select id as remate_id, race_id
from public.remates;

delete from public.bids b
using _remates_to_delete t
where b.remate_id = t.remate_id;

delete from public.remate_price_rules r
using _remates_to_delete t
where r.remate_id = t.remate_id;

delete from public.horses h
using _remates_to_delete t
where h.race_id = t.race_id;

delete from public.remates r
using _remates_to_delete t
where r.id = t.remate_id;

delete from public.races rc
using _remates_to_delete t
where rc.id = t.race_id;

-- ==================================
-- 2) BORRAR OPERACIONES FINANCIERAS
-- ==================================
delete from public.deposit_requests;
delete from public.withdraw_requests;
delete from public.wallet_movements;

-- =========================
-- 3) WALLET EN CERO
-- =========================
update public.wallets
set saldo_disponible = 0,
    saldo_bloqueado  = 0;

commit;

