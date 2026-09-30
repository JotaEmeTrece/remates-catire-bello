-- ===========================================================================
--  DIAGNOSTICO DE UN REMATE -> no modifica nada, solo mira.
--
--    $db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
--    Get-Content supabase/snippets/diagnostico_remate.sql | docker exec -i $db psql -U postgres -d postgres
--
--  Responde: que incremento tiene el remate, que caballos llevan reglas
--  propias, que dice la RPC de minimos AHORA MISMO, y de quien es cada puja.
-- ===========================================================================
\pset pager off

\echo ''
\echo '=== 1. Remates y su incremento general ==='
select r.id, r.nombre, r.estado, r.incremento_minimo, r.porcentaje_casa, r.apuesta_minima
from public.remates r order by r.created_at desc nulls last;

\echo ''
\echo '=== 2. Caballos y si tienen reglas propias ==='
select h.numero, h.nombre, h.precio_salida, coalesce(h.retirado,false) as retirado,
       count(pr.id) as reglas_propias
from public.horses h
left join public.remates r on r.race_id = h.race_id
left join public.remate_price_rules pr on pr.remate_id = r.id and pr.horse_id = h.id
group by h.id, h.numero, h.nombre, h.precio_salida, h.retirado
order by h.numero;

\echo ''
\echo '=== 3. TODAS las reglas: las del caballo Y la escalera general ==='
--  Las de horse_id NULL son la escalera general del remate, y GANAN sobre
--  remates.incremento_minimo. Ahi esta el 50 que no se deja cambiar.
select coalesce(h.numero::text, '(GENERAL del remate)') as aplica_a,
       pr.min_precio, pr.max_precio, pr.incremento
from public.remate_price_rules pr
left join public.horses h on h.id = pr.horse_id
order by (h.numero is null) desc, h.numero, pr.min_precio;

\echo ''
\echo '=== 4. Lo que dice la RPC de minimos AHORA (es lo que cobra hacer_puja) ==='
select m.* from public.remates r
cross join lateral public.remate_minimos(r.id) m
where r.estado = 'abierto';

\echo ''
\echo '=== 5. Pujas: de quien es cada una de verdad ==='
select h.numero as caballo, b.monto, p.username as la_hizo, b.created_at
from public.bids b
join public.horses h on h.id = b.horse_id
join public.profiles p on p.id = b.user_id
order by b.created_at;

\echo ''
\echo '=== 6. Saldos y compromiso de cada usuario ==='
select p.username, w.saldo_disponible, public.compromiso_usuario(p.id) as comprometido,
       w.saldo_disponible - public.compromiso_usuario(p.id) as puede_pujar_hasta
from public.profiles p join public.wallets w on w.user_id = p.id
order by p.username;
