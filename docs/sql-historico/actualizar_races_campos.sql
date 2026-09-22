begin;

-- Nuevos campos de carrera
alter table public.races
  add column if not exists dia text;

alter table public.races
  add column if not exists numero_carrera_text text;

alter table public.races
  add column if not exists distancia_m numeric;

-- Retiro de caballos
alter table public.horses
  add column if not exists retirado boolean default false;

update public.horses
set retirado = false
where retirado is null;

-- Backfill del texto de carrera
update public.races
set numero_carrera_text = numero_carrera::text
where numero_carrera_text is null
  and numero_carrera is not null;

-- Nueva apuesta minima por defecto
alter table public.remates
  alter column apuesta_minima set default 40;

commit;
