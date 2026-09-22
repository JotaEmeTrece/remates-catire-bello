# Auditoria Tecnica - Evidencia de Seguridad y Dinero

## 1) Manejo de dinero en pujas

### 1.1 Punto de entrada de puja (frontend -> RPC)
Archivo: `app/remates/[id]/page.tsx`

```ts
const { error: rpcErr } = await supabase.rpc("hacer_puja", {
  p_remate_id: remate.id,
  p_horse_id: horseId,
  p_monto: monto,
  p_es_manual: esManual,
})
```

### 1.2 Validacion de saldo en cliente (pre-check UX)
Archivo: `app/remates/[id]/page.tsx`

```ts
const disponible = wallet ? n(wallet.saldo_disponible) : 0
const myPrev = computed.myMaxByHorse[horseId] ?? 0
const requerido = Math.max(0, monto - myPrev)
if (requerido > disponible) {
  setPlacing(null)
  setError(`Saldo insuficiente. Disponible: ${formatMoney(disponible)} Bs. Requerido: ${formatMoney(requerido)} Bs`)
  return
}
```

Nota: este chequeo es de UX; la validacion real de seguridad se hace en la funcion SQL `public.hacer_puja`.

### 1.3 Funcion SQL completa que ejecuta la puja
Archivo: `sql/actualizar_hacer_puja_horarios.sql`

```sql
-- Ajusta public.hacer_puja para respetar ventana opens_at/closes_at
-- Ã¢Å“â€¦ No permite pujar antes de opens_at
-- Ã¢Å“â€¦ No permite pujar despuÃƒÂ©s de closes_at

create or replace function public.hacer_puja(p_remate_id uuid, p_horse_id uuid, p_monto numeric, p_es_manual boolean DEFAULT false)
returns bids
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();

  v_remate public.remates%rowtype;
  v_horse  public.horses%rowtype;

  v_wallet public.wallets%rowtype;

  -- top actual (antes de esta puja)
  v_top_user_id uuid;
  v_top_monto   numeric;
  v_top_bid_id  uuid;

  v_ultimo_monto numeric;
  v_incremento numeric;
  v_minimo_permitido numeric;

  v_rule public.remate_price_rules%rowtype;
  v_bid  public.bids%rowtype;

  v_delta numeric;

  v_prev_wallet public.wallets%rowtype;
begin
  if v_user_id is null then
    raise exception 'No autenticado';
  end if;

 Serializa pujas por remate+caballo para evitar carreras
  perform pg_advisory_xact_lock(
    ('x' || substr(md5(p_remate_id::text || ':' || p_horse_id::text), 1, 16))::bit(64)::bigint
  );

  -- 1) Remate
  select *
    into v_remate
  from public.remates
  where id = p_remate_id;

  if not found then raise exception 'Remate no existe'; end if;
  if v_remate.estado <> 'abierto' then raise exception 'El remate no estÃƒÂ¡ abierto'; end if;

  if v_remate.opens_at is not null and now() < v_remate.opens_at then
    raise exception 'El remate aÃƒÂºn no estÃƒÂ¡ abierto';
  end if;
  if v_remate.closes_at is not null and now() >= v_remate.closes_at then
    raise exception 'El remate ya cerrÃƒÂ³';
  end if;

  -- 2) Caballo
  select *
    into v_horse
  from public.horses
  where id = p_horse_id
    and race_id = v_remate.race_id;

  if not found then
    raise exception 'Caballo no pertenece a la carrera de este remate';
  end if;
  if coalesce(v_horse.retirado, false) then
    raise exception 'Caballo retirado';
  end if;

  -- 3) Top actual (si existe)
  select b.user_id, b.monto, b.id
    into v_top_user_id, v_top_monto, v_top_bid_id
  from public.bids b
  where b.remate_id = p_remate_id
    and b.horse_id  = p_horse_id
  order by b.monto desc, b.created_at asc
  limit 1;

  if found then
    v_ultimo_monto := v_top_monto;
  else
    v_top_user_id := null;
    v_top_monto   := null;
    v_top_bid_id  := null;
    v_ultimo_monto := v_horse.precio_salida;
  end if;

  -- 4) Regla de incremento (prioriza por caballo; fallback a default horse_id null)
  select *
    into v_rule
  from public.remate_price_rules r
  where r.remate_id = p_remate_id
    and (r.horse_id is null or r.horse_id = p_horse_id)
    and v_ultimo_monto >= r.min_precio
    and (r.max_precio is null or v_ultimo_monto < r.max_precio)
  order by (r.horse_id = p_horse_id) desc, r.min_precio desc
  limit 1;

  if found then
    v_incremento := v_rule.incremento;
  else
    v_incremento := v_remate.incremento_minimo;
  end if;

  if v_incremento is null or v_incremento <= 0 then
    raise exception 'Incremento no vÃƒÂ¡lido para el remate';
  end if;

  -- 5) MÃƒÂ­nimo permitido (auto)
  v_minimo_permitido := v_ultimo_monto + v_incremento;

  if v_minimo_permitido < v_remate.apuesta_minima then
    v_minimo_permitido := v_remate.apuesta_minima;
  end if;

  -- 6) Auto vs manual
  if coalesce(p_es_manual, false) = false then
    -- auto: "Ponerle"
    p_monto := v_minimo_permitido;
  else
    -- manual: debe ser al menos auto + 10
    if p_monto is null or p_monto < (v_minimo_permitido + 10) then
      raise exception 'Oferta manual mÃƒÂ­nima: % (auto: %)', (v_minimo_permitido + 10), v_minimo_permitido;
    end if;
  end if;

  -- 7) Calcula cuÃƒÂ¡nto bloquear realmente
  -- Si el usuario ya era el top -> solo delta (p_monto - top_monto)
  -- Si NO era el top -> bloquea p_monto completo
  if v_top_user_id = v_user_id then
    v_delta := p_monto - coalesce(v_top_monto, 0);
    if v_delta <= 0 then
      raise exception 'La puja debe superar el monto actual';
    end if;
  else
    v_delta := p_monto;
  end if;

  -- 8) Lock wallet del que estÃƒÂ¡ pujando
  select *
    into v_wallet
  from public.wallets
  where user_id = v_user_id
  for update;

  if not found then
    raise exception 'No se encontrÃƒÂ³ wallet para el usuario';
  end if;

  if v_wallet.saldo_disponible < v_delta then
    raise exception 'Saldo insuficiente (disponible: %, requerido: %)',
      v_wallet.saldo_disponible, v_delta;
  end if;

  -- 9) Si el top anterior era otro usuario, desbloquea su monto
  if v_top_user_id is not null and v_top_user_id <> v_user_id then
    select *
      into v_prev_wallet
    from public.wallets
    where user_id = v_top_user_id
    for update;

    if found then
      if v_prev_wallet.saldo_bloqueado < coalesce(v_top_monto,0) then
        raise exception 'Inconsistencia: bloqueado anterior insuficiente (bloqueado: %, a liberar: %)',
          v_prev_wallet.saldo_bloqueado, v_top_monto;
      end if;

      update public.wallets
         set saldo_disponible = saldo_disponible + v_top_monto,
             saldo_bloqueado  = saldo_bloqueado  - v_top_monto
       where id = v_prev_wallet.id;

      insert into public.wallet_movements (
        wallet_id, tipo, monto, descripcion, ref_externa
      ) values (
        v_prev_wallet.id,
        'apuesta_desbloqueo',
        v_top_monto,
        'Desbloqueo por ser superado en remate ' || v_remate.nombre || ' caballo ' || v_horse.numero,
        coalesce(v_top_bid_id::text,'')
      );
    end if;
  end if;

  -- 10) Bloquear delta al pujador
  update public.wallets
     set saldo_disponible = saldo_disponible - v_delta,
         saldo_bloqueado  = saldo_bloqueado  + v_delta
   where id = v_wallet.id;

  -- 11) Insertar puja
  insert into public.bids (remate_id, horse_id, user_id, monto)
  values (p_remate_id, p_horse_id, v_user_id, p_monto)
  returning * into v_bid;

  -- 12) Movimiento de bloqueo (solo delta)
  insert into public.wallet_movements (
    wallet_id, tipo, monto, descripcion, ref_externa
  ) values (
    v_wallet.id,
    'apuesta_bloqueo',
    v_delta,
    'Bloqueo por puja en remate ' || v_remate.nombre || ' caballo ' || v_horse.numero,
    v_bid.id::text
  );

  return v_bid;
end;
$function$;
```

## 2) Cliente Supabase (frontend)

Archivo: `lib/supabaseClient.ts`

```ts
// lib/supabaseClient.ts
import { createBrowserClient } from "@supabase/ssr"

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

export const supabase = createBrowserClient(supabaseUrl, supabaseAnonKey)
```

## 3) RLS (profiles y bids)

Fuente de evidencia en este repo:
- `app/SUPABASE_CONTEXT.md` (sección Policies)

### 3.1 Estado RLS habilitado

```sql
-- Estado observado en el contexto exportado:
-- public.bids     -> rls_enabled = true
-- public.profiles -> rls_enabled = true
```

### 3.2 SQL de políticas para `bids`

```sql
alter table public.bids enable row level security;

create policy bids_admin_all
on public.bids
as permissive
for all
to authenticated
using (is_admin())
with check (is_admin());

create policy bids_select_auth
on public.bids
as permissive
for select
to authenticated
using (true);
```

### 3.3 SQL de políticas para `profiles`

```sql
alter table public.profiles enable row level security;

create policy profiles_admin_all
on public.profiles
as permissive
for all
to authenticated
using (is_admin())
with check (is_admin());

create policy profiles_select_own
on public.profiles
as permissive
for select
to authenticated
using (id = auth.uid());

create policy profiles_update_own
on public.profiles
as permissive
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());
```

## 4) Nota para auditoria

La puja se procesa en base de datos (RPC `public.hacer_puja`) y no en Server Action/API de Next.js.  
Esto centraliza atomicidad, validacion de saldo y control de concurrencia en una sola transaccion SQL.
