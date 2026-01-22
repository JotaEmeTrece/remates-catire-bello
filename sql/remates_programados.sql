-- Remates programados (adelantados/en vivo) + autocierre

begin;

-- 1) Campos de programación
alter table public.remates
  add column if not exists opens_at timestamptz,
  add column if not exists closes_at timestamptz,
  add column if not exists tipo text;

-- 2) Defaults y backfill
update public.remates
set tipo = 'vivo'
where tipo is null;

update public.remates
set opens_at = coalesce(opens_at, created_at, now())
where opens_at is null;

update public.remates
set closes_at = closed_at
where closes_at is null and closed_at is not null;

alter table public.remates
  alter column tipo set default 'vivo',
  alter column opens_at set default now();

-- 3) Check de tipo
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'remates_tipo_check') then
    alter table public.remates
      add constraint remates_tipo_check check (tipo in ('vivo','adelantado'));
  end if;
end $$;

-- 4) Autocierre (solo cerrar, nunca liquidar)
create or replace function public.auto_cerrar_remates()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count integer;
begin
  update public.remates
  set estado = 'cerrado',
      closed_at = coalesce(closed_at, now())
  where estado = 'abierto'
    and closes_at is not null
    and closes_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

-- 5) Cron (cada minuto) para autocierre
create extension if not exists pg_cron;

do $$
declare
  v_jobid integer;
begin
  select jobid into v_jobid from cron.job where jobname = 'auto_cerrar_remates';
  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
  perform cron.schedule('auto_cerrar_remates', '* * * * *', $$select public.auto_cerrar_remates();$$);
end $$;

commit;
