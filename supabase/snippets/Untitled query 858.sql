select p.username, u.email, p.es_admin, p.es_super_admin, u.created_at
from public.profiles p
join auth.users u on u.id = p.id
where p.es_admin or p.es_super_admin
order by u.created_at;