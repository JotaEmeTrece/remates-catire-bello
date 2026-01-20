-- Reseteo SOLO de data de remates (demo/pruebas)
-- ✅ Borra remates, caballos, pujas y reglas de precio asociadas.
-- ❗ NO toca wallets / recargas / retiros / movimientos.
--
-- Úsalo si solo quieres limpiar remates de prueba, pero mantener saldos e historial financiero.

begin;

create temporary table _remates_to_delete as
select id as remate_id, race_id
from public.remates;

-- 1) Pujas y reglas del remate
delete from public.bids b
using _remates_to_delete t
where b.remate_id = t.remate_id;

delete from public.remate_price_rules r
using _remates_to_delete t
where r.remate_id = t.remate_id;

-- 2) Caballos y remates
delete from public.horses h
using _remates_to_delete t
where h.race_id = t.race_id;

delete from public.remates r
using _remates_to_delete t
where r.id = t.remate_id;

-- 3) Carreras asociadas a esos remates
delete from public.races rc
using _remates_to_delete t
where rc.id = t.race_id;

commit;

