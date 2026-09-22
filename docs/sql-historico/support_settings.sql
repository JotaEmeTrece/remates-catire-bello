begin;

create table if not exists public.support_settings (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  value text not null,
  type text not null check (type in ('email','whatsapp','phone','social')),
  href text null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.set_support_settings_updated_at()
returns trigger
language plpgsql
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists trg_support_settings_updated_at on public.support_settings;
create trigger trg_support_settings_updated_at
before update on public.support_settings
for each row
execute function public.set_support_settings_updated_at();

alter table public.support_settings enable row level security;

do $$
declare r record;
begin
  for r in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename  = 'support_settings'
  loop
    execute format('drop policy if exists %I on public.support_settings;', r.policyname);
  end loop;
end $$;

create policy support_settings_public_read
on public.support_settings
as permissive
for select
to anon, authenticated
using (is_active = true);

create policy support_settings_superadmin_write
on public.support_settings
as permissive
for all
to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

revoke all on table public.support_settings from anon, authenticated;
grant select on table public.support_settings to anon, authenticated;

insert into public.support_settings (label, value, type, href, sort_order)
values
  ('Correo', 'rematecbsoporte@gmail.com', 'email', 'mailto:rematecbsoporte@gmail.com', 10),
  ('WhatsApp', '+58 0412 1497695', 'whatsapp', 'https://wa.me/5804121497695', 20),
  ('WhatsApp', '+57 3145159179', 'whatsapp', 'https://wa.me/573145159179', 30)
on conflict do nothing;

commit;
