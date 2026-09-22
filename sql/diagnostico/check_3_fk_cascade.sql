-- UNA sola consulta. LA MAS IMPORTANTE DE LAS TRES.
--
-- ¿Que pasa si un admin borra un caballo que ya tiene pujas?
--   >>> CASCADE  = se borran las pujas y el dinero comprometido de esos
--                  usuarios queda huerfano. Hay que corregirlo ya.
--   RESTRICT / NO ACTION = la base rechaza el borrado. El dinero esta a salvo.
select
  con.conname                    as constraint_name,
  con.conrelid::regclass         as tabla_hija,
  con.confrelid::regclass        as tabla_padre,
  case con.confdeltype
    when 'a' then 'NO ACTION (rechaza)'
    when 'r' then 'RESTRICT (rechaza)'
    when 'c' then '>>> CASCADE (borra en cascada)'
    when 'n' then 'SET NULL'
    when 'd' then 'SET DEFAULT'
  end                            as on_delete
from pg_constraint con
where con.contype = 'f'
  and con.confrelid in ('public.horses'::regclass,
                        'public.races'::regclass,
                        'public.remates'::regclass)
order by tabla_padre, tabla_hija;
