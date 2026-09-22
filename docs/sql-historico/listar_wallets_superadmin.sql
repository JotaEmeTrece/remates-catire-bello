-- Lista wallets + perfiles (solo superadmin)
create or replace function public.listar_wallets_superadmin(p_query text default null, p_limit int default 50)
returns table (
  user_id uuid,
  username text,
  email text,
  saldo_disponible numeric,
  saldo_bloqueado numeric,
  created_at timestamptz
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_is_super boolean;
begin
  if v_uid is null then
    raise exception 'No autenticado';
  end if;

  select coalesce(es_super_admin,false) into v_is_super
  from public.profiles
  where id = v_uid;

  if coalesce(v_is_super,false) = false then
    raise exception 'No autorizado';
  end if;

  return query
  select
    w.user_id,
    p.username,
    p.email,
    w.saldo_disponible,
    w.saldo_bloqueado,
    w.created_at
  from public.wallets w
  join public.profiles p on p.id = w.user_id
  where p_query is null
     or p.username ilike '%' || p_query || '%'
     or p.email ilike '%' || p_query || '%'
  order by w.created_at desc
  limit greatest(p_limit, 1);
end;
$function$;

revoke all on function public.listar_wallets_superadmin(text,int) from public;
grant execute on function public.listar_wallets_superadmin(text,int) to authenticated;
