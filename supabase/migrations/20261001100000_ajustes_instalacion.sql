-- ===========================================================================
--  AJUSTES DE INSTALACION  +  MINIMOS DE DINERO
--  01/10/2026
--
--  EL PROBLEMA
--
--  Jota pidio dos reglas: ningun incremento por debajo de 50 Bs, ningun precio
--  de salida por debajo de 100 Bs. Al buscarlas no existian: lo unico escrito
--  era `incremento > 0` dentro de editar_remate, y `horses.precio_salida` no
--  tenia NINGUNA validacion, ni en la base ni en el formulario. Se podia crear
--  un caballo en 1 Bs con incrementos de 0,01.
--
--  LA DECISION, Y POR QUE NO VAN FIJAS
--
--  50 y 100 son los numeros de Jota, en bolivares. Un licenciatario en otro
--  pais, con otra moneda, los necesita distintos; imponerselos es el mismo
--  error que habriamos cometido con el porcentaje de la casa (ADR-017). Asi
--  que no se escriben en el codigo: se siembran en una tabla de ajustes de la
--  INSTALACION, y la base los lee cada vez que valida.
--
--  Esta tabla es el primer pedazo de A1 (Fase 2: datos bancarios, porcentaje
--  por defecto, SMTP, marca). Nace con dos claves para no adivinar las demas.
--
--  COMO SE DEFIENDE
--
--  No con un CHECK: un CHECK no puede leer otra tabla. Con un trigger por
--  tabla, que lee el ajuste. Tres tablas lo necesitan porque el formulario de
--  admin escribe directo en las tres (y seguira haciendolo hasta que exista
--  crear_remate_completo en la tanda 4):
--
--      remates.incremento_minimo          <- el incremento general
--      remate_price_rules.incremento      <- cada tramo de escalera propia
--      horses.precio_salida               <- el precio de arranque
--
--  CUIDADO CON LOS DATOS VIEJOS
--
--  En produccion puede haber caballos por debajo de 100 creados antes de esta
--  regla. Si el trigger los revisara en cada UPDATE, corregirle el NOMBRE a
--  uno de esos caballos fallaria. Por eso en UPDATE solo se valida cuando la
--  columna en cuestion CAMBIA (`is distinct from`). Lo viejo se queda quieto;
--  lo que se toque, se toca bien.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  PASO 1 - La tabla. Clave/valor con tipo, porque A1 va a traer textos
--  (SMTP, nombre del banco) y no solo numeros.
--
--  Nace CERRADA y se abre a mano mas abajo: ADR-016. Lo que la imagen de
--  Supabase regala por ALTER DEFAULT PRIVILEGES se quita explicitamente.
-- ---------------------------------------------------------------------------
create table if not exists public.ajustes_instalacion (
  clave       text primary key,
  valor       text not null,
  tipo        text not null default 'numero'
              check (tipo in ('numero', 'texto', 'booleano')),
  descripcion text not null,
  updated_at  timestamptz not null default now()
);

comment on table public.ajustes_instalacion is
  'Ajustes de ESTA instalacion, no del codigo. Cada licenciatario pone los suyos. Las claves las crean las migraciones; el super admin solo cambia valores.';

create or replace function public.tr_ajustes_updated_at()
returns trigger language plpgsql
set search_path to ''
as $fn$
begin
  new.updated_at := now();
  return new;
end $fn$;

drop trigger if exists trg_ajustes_updated_at on public.ajustes_instalacion;
create trigger trg_ajustes_updated_at
  before update on public.ajustes_instalacion
  for each row execute function public.tr_ajustes_updated_at();


-- ---------------------------------------------------------------------------
--  PASO 2 - Las dos claves. `on conflict do nothing`: si la migracion se
--  vuelve a correr sobre una base donde el licenciatario ya cambio el valor,
--  no se le pisa.
-- ---------------------------------------------------------------------------
insert into public.ajustes_instalacion (clave, valor, tipo, descripcion) values
  ('minimo_incremento',
   '50',
   'numero',
   'Monto minimo en que puede subir una puja. Aplica al incremento general del remate y a cada tramo de escalera propia.'),
  ('minimo_precio_salida',
   '100',
   'numero',
   'Precio de salida minimo de un caballo.')
on conflict (clave) do nothing;


-- ---------------------------------------------------------------------------
--  PASO 3 - El lector. Una sola puerta para leer un ajuste numerico.
--
--  Si la clave no esta, REVIENTA. No devuelve cero ni un valor por defecto: un
--  minimo que desaparece en silencio es un minimo de cero, y eso es justo el
--  agujero que esta migracion viene a tapar.
-- ---------------------------------------------------------------------------
create or replace function public.ajuste_numero(p_clave text)
returns numeric
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare v_valor text;
begin
  select a.valor into v_valor
  from public.ajustes_instalacion a
  where a.clave = p_clave;

  if v_valor is null then
    raise exception 'Falta el ajuste de instalacion "%". La base no puede validar sin el.', p_clave;
  end if;

  return v_valor::numeric;
end $fn$;

comment on function public.ajuste_numero(text) is
  'Lee un ajuste numerico de la instalacion. Revienta si la clave no existe: un minimo ausente seria un minimo de cero.';


-- ---------------------------------------------------------------------------
--  PASO 4 - Los tres guardianes.
--
--  Mismo molde los tres: en INSERT se valida siempre; en UPDATE solo si la
--  columna cambia. El mensaje nombra el minimo vigente para que el admin sepa
--  contra que choco, en vez de "valor invalido".
-- ---------------------------------------------------------------------------

create or replace function public.tr_minimo_incremento_remate()
returns trigger language plpgsql
security definer
set search_path to ''
as $fn$
declare v_min numeric;
begin
  if tg_op = 'UPDATE'
     and new.incremento_minimo is not distinct from old.incremento_minimo then
    return new;
  end if;

  v_min := public.ajuste_numero('minimo_incremento');

  if new.incremento_minimo is null or new.incremento_minimo < v_min then
    raise exception 'El incremento no puede ser menor a % Bs (pusiste %).',
      v_min, coalesce(new.incremento_minimo::text, 'nada');
  end if;

  return new;
end $fn$;

drop trigger if exists trg_minimo_incremento_remate on public.remates;
create trigger trg_minimo_incremento_remate
  before insert or update on public.remates
  for each row execute function public.tr_minimo_incremento_remate();


create or replace function public.tr_minimo_incremento_regla()
returns trigger language plpgsql
security definer
set search_path to ''
as $fn$
declare v_min numeric;
begin
  if tg_op = 'UPDATE'
     and new.incremento is not distinct from old.incremento then
    return new;
  end if;

  v_min := public.ajuste_numero('minimo_incremento');

  if new.incremento is null or new.incremento < v_min then
    raise exception 'El incremento de la escalera no puede ser menor a % Bs (pusiste %).',
      v_min, coalesce(new.incremento::text, 'nada');
  end if;

  return new;
end $fn$;

drop trigger if exists trg_minimo_incremento_regla on public.remate_price_rules;
create trigger trg_minimo_incremento_regla
  before insert or update on public.remate_price_rules
  for each row execute function public.tr_minimo_incremento_regla();


create or replace function public.tr_minimo_precio_salida()
returns trigger language plpgsql
security definer
set search_path to ''
as $fn$
declare v_min numeric;
begin
  if tg_op = 'UPDATE'
     and new.precio_salida is not distinct from old.precio_salida then
    return new;
  end if;

  v_min := public.ajuste_numero('minimo_precio_salida');

  if new.precio_salida is null or new.precio_salida < v_min then
    raise exception 'El precio de salida no puede ser menor a % Bs (caballo %, pusiste %).',
      v_min, coalesce(new.numero::text, '?'), coalesce(new.precio_salida::text, 'nada');
  end if;

  return new;
end $fn$;

drop trigger if exists trg_minimo_precio_salida on public.horses;
create trigger trg_minimo_precio_salida
  before insert or update on public.horses
  for each row execute function public.tr_minimo_precio_salida();


-- ---------------------------------------------------------------------------
--  PASO 5 - PERMISOS. ADR-016: lo nuevo se declara, no se hereda.
--
--  La tabla: el formulario de admin necesita LEER los minimos para avisar
--  antes de guardar, y el super admin necesita CAMBIARLOS. Nada mas.
--
--    - sin insert y sin delete para nadie: las claves las crean las
--      migraciones. Si la app pudiera borrar `minimo_incremento`, ajuste_numero
--      reventaria y no se podria ni crear un remate.
--    - sin nada para anon: un visitante sin sesion no necesita los minimos.
--    - sin TRUNCATE, que ninguna politica RLS puede frenar (doc 17, 5.9).
--
--  Las funciones de trigger no necesitan EXECUTE: PostgreSQL comprueba ese
--  privilegio al CREATE TRIGGER, no al disparar (comprobado el 29/09).
-- ---------------------------------------------------------------------------
revoke all on table public.ajustes_instalacion from public, anon, authenticated;
grant select, update on table public.ajustes_instalacion to authenticated;

revoke all on function public.ajuste_numero(text)                from public, anon, authenticated;
revoke all on function public.tr_ajustes_updated_at()            from public, anon, authenticated;
revoke all on function public.tr_minimo_incremento_remate()      from public, anon, authenticated;
revoke all on function public.tr_minimo_incremento_regla()       from public, anon, authenticated;
revoke all on function public.tr_minimo_precio_salida()           from public, anon, authenticated;

alter table public.ajustes_instalacion enable row level security;

drop policy if exists ajustes_lee_admin on public.ajustes_instalacion;
create policy ajustes_lee_admin on public.ajustes_instalacion
  for select to authenticated
  using (public.is_admin());

drop policy if exists ajustes_cambia_superadmin on public.ajustes_instalacion;
create policy ajustes_cambia_superadmin on public.ajustes_instalacion
  for update to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());
