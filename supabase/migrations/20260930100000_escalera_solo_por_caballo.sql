-- ===========================================================================
--  20260930100000_escalera_solo_por_caballo.sql
--
--  EL DEFECTO (encontrado el 29/09 probando en local)
--
--  `remate_price_rules` admitia dos clases de fila:
--
--    horse_id = <caballo>  -> la escalera propia de ese caballo
--    horse_id = NULL       -> una escalera "general" del remate
--
--  Y la general GANABA sobre `remates.incremento_minimo`, porque
--  `_incremento_aplicable` la incluia en su busqueda y la columna solo se
--  consultaba si ninguna regla encajaba:
--
--    where r.remate_id = p_remate_id
--      and (r.horse_id is null or r.horse_id = p_horse_id)   <- la general cuenta
--    ...
--    coalesce(<esa regla>, remates.incremento_minimo)        <- la columna, solo si no hubo
--
--  Consecuencia medida: Jota cambio el incremento de un remate de 50 a 80 con
--  `editar_remate`, la columna quedo en 80, y el caballo 1 -- que no tenia
--  escalera propia -- siguio subiendo de 50 en 50, porque el tramo general
--  100-500 decia 50. El admin cambia un numero, la pantalla confirma el
--  cambio, y la base cobra otra cosa.
--
--  Es la misma familia que el pozo calculado en cinco sitios y que los
--  minimos duplicados en TypeScript: dos fuentes para el mismo numero, y la
--  que manda es la que no se ve. ADR-015.
--
--  LA DECISION (Jota, 30/09)
--
--  Una sola clase de regla en la base: la del caballo. La escalera general
--  sigue existiendo en el FORMULARIO como atajo, pero al guardar se expande a
--  una escalera identica por caballo, con su `horse_id`. Lo que el admin ve
--  en la pantalla de edicion es, a partir de ahora, exactamente lo que la
--  base va a aplicar.
--
--  El `not null` del paso 3 es la pieza que importa. Sin el, esto se arregla
--  hoy y vuelve el dia que alguien escriba un insert sin pensarlo. Con el, la
--  regla invisible es imposible de escribir.
--
--  ORDEN DE DESPLIEGUE, AL REVES DE LO HABITUAL:
--  primero el frontend, despues esta migracion. Si la base cierra antes de
--  que la pantalla deje de escribir nulos, crear un remate con la escalera
--  general marcada falla con 23502.
--
--  En produccion, a 30/09, hay CERO reglas generales (comprobado en el SQL
--  Editor). Los pasos 1 y 2 no tienen nada que hacer alli. Se escriben de
--  todos modos porque en local si las hay, y porque la base de un
--  licenciatario puede tenerlas.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  PASO 1 - Expandir cada regla general a los caballos que NO tienen escalera
--           propia. Copia identica: mismos tramos, mismos incrementos.
--
--  Se excluyen a proposito los caballos que ya tienen escalera propia: hoy la
--  suya manda sobre la general (el `order by (horse_id is not null) desc` lo
--  garantiza), asi que copiarle la general encima le cambiaria el
--  comportamiento en vez de conservarlo.
-- ---------------------------------------------------------------------------
insert into public.remate_price_rules (remate_id, horse_id, min_precio, max_precio, incremento)
select g.remate_id, h.id, g.min_precio, g.max_precio, g.incremento
from public.remate_price_rules g
join public.remates rm on rm.id = g.remate_id
join public.horses h on h.race_id = rm.race_id
where g.horse_id is null
  and not exists (
    select 1 from public.remate_price_rules propia
    where propia.remate_id = g.remate_id
      and propia.horse_id = h.id
  );


-- ---------------------------------------------------------------------------
--  PASO 2 - Fuera las generales, ya expandidas.
-- ---------------------------------------------------------------------------
delete from public.remate_price_rules where horse_id is null;


-- ---------------------------------------------------------------------------
--  PASO 3 - Que no se puedan volver a escribir.
--
--  Si por lo que sea quedara alguna fila nula, este `set not null` aborta la
--  migracion entera y nos enteramos, que es justo lo que queremos. Nunca
--  "arreglar a medias y seguir".
-- ---------------------------------------------------------------------------
alter table public.remate_price_rules
  alter column horse_id set not null;

comment on column public.remate_price_rules.horse_id is
  'Obligatorio desde el 30/09/2026. Una regla SIEMPRE es de un caballo concreto. La escalera general del formulario se expande a una escalera por caballo al guardar; en la base no existe la regla general. Ver ADR-015 y la migracion 20260930100000.';


-- ---------------------------------------------------------------------------
--  PASO 4 - La funcion deja de buscar reglas generales.
--
--  Con el `not null` de arriba esto ya es equivalente, pero prefiero que la
--  regla este ESCRITA y no implicita en una restriccion de columna. Quien lea
--  esta funcion dentro de un ano tiene que poder saber que la general no
--  existe sin ir a mirar el esquema.
--
--  Desaparece tambien el `order by (r.horse_id is not null) desc`, que existia
--  solo para que la propia del caballo le ganara a la general. Sin generales,
--  no hay a quien ganarle.
-- ---------------------------------------------------------------------------
create or replace function public._incremento_aplicable(
  p_remate_id uuid, p_horse_id uuid, p_monto_actual numeric)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(
    (
      select r.incremento
      from public.remate_price_rules r
      where r.remate_id = p_remate_id
        and r.horse_id = p_horse_id
        and p_monto_actual >= r.min_precio
        and (r.max_precio is null or p_monto_actual < r.max_precio)
      order by r.min_precio desc
      limit 1
    ),
    -- Sin escalera propia, manda el incremento del remate. Y ahora si:
    -- cambiarlo con editar_remate surte efecto, porque no hay nadie
    -- discutiendoselo.
    (select rm.incremento_minimo from public.remates rm where rm.id = p_remate_id)
  );
$fn$;

comment on function public._incremento_aplicable(uuid, uuid, numeric) is
  'Unica fuente de verdad del incremento que aplica a un caballo. La usan hacer_puja y remate_minimos. Desde el 30/09/2026 solo mira la escalera propia del caballo; si no tiene, manda remates.incremento_minimo.';

--  `create or replace function` conserva los permisos, pero se redeclaran
--  igual: desde la tanda de permisos del 29/09, lo que no se nombra queda
--  fuera, y esta funcion es interna (solo la llaman funciones `definer`).
--  Si esto quedara mal, P47 se pone rojo.
revoke all on function public._incremento_aplicable(uuid, uuid, numeric)
  from public, anon, authenticated;
