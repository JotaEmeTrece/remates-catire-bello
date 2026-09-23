# Diseño: modelo de saldo comprometido (v2)

**Fecha:** 27 de agosto de 2026
**Estado:** propuesta para revisión — no implementada
**Reemplaza:** el modelo actual de `saldo_bloqueado` con bloqueo y liberación en cada puja
**Origen:** propuesta de Miguel Ángel (Jota), desarrollada y detallada aquí

---

## 1. Qué cambia, en una frase

Hoy el compromiso de un usuario es un **número guardado** (`wallets.saldo_bloqueado`) que se escribe y reescribe en cada puja. Pasa a ser un **número calculado** a partir de las pujas que ese usuario lidera en este momento.

El dinero deja de moverse durante el remate. Se mueve una sola vez, al cerrar.

## 2. Por qué

| Problema actual | Cómo lo resuelve |
|---|---|
| Cada puja son 2 a 4 `UPDATE` sobre `wallets` — la tabla más caliente del sistema — en pleno remate en vivo | Cero escrituras sobre `wallets` durante el remate |
| `wallet_movements` se llena de pares `apuesta_bloqueo`/`apuesta_desbloqueo` que se anulan entre sí y hacen el libro ilegible | Un solo movimiento por usuario y por remate, al cierre |
| El defecto C3: `saldo_bloqueado` puede descuadrarse contra las pujas reales, y nada lo detecta | **Desaparece la clase entera de defecto.** Si no hay número guardado, no hay número que se pueda descuadrar |
| Retirar un caballo a mitad de remate exige devolver dinero ya bloqueado (hoy no implementado) | **Se vuelve gratis**: nada fue debitado, y la puja del caballo retirado simplemente deja de contar |
| Cancelar un remate abierto exige devolver todos los saldos, con el mismo defecto C3 | **Se vuelve trivial**: no hay nada que devolver |
| Al usuario le desaparece el saldo de la pantalla apenas puja | El saldo se mantiene visible; lo que se muestra es cuánto tiene comprometido |

## 3. El concepto: compromiso

> **Compromiso de un usuario** = la suma de las pujas que **lidera en este momento**, en remates **abiertos**, sobre caballos **no retirados**.

Es exactamente el dinero que se le debitaría si todos esos remates cerraran ahora mismo.

Propiedades que lo hacen correcto:

- Si te superan en una puja, esa puja deja de ser líder → tu compromiso baja **solo**, sin que nadie escriba nada.
- Si subes tu propia puja de 100 a 150, sigues siendo el único líder de ese caballo → tu compromiso sube 50, no 250. **El "delta" sale gratis**, no hay que calcularlo.
- Si retiran un caballo, deja de contar → tu compromiso baja **solo**.
- Si el remate se cancela, deja de estar abierto → tu compromiso baja **solo**.

Todo lo que hoy son ramas de código con dinero de por medio, pasa a ser una consecuencia de la definición.

```sql
create or replace function public.compromiso_usuario(p_user_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(sum(lider.monto), 0)
  from (
    select distinct on (b.remate_id, b.horse_id)
           b.user_id,
           b.monto
    from public.bids b
    join public.remates r on r.id = b.remate_id
    join public.horses  h on h.id = b.horse_id
    where r.estado = 'abierto'
      and coalesce(h.retirado, false) = false
    order by b.remate_id, b.horse_id, b.monto desc, b.created_at asc
  ) lider
  where lider.user_id = p_user_id;
$function$;
```

## 4. El invariante

Una sola regla, y todo lo demás se deduce de ella:

> **`saldo_disponible` ≥ `compromiso_usuario()`, siempre, para todo usuario.**

Las tres operaciones que pueden romperlo, y su guarda:

| Operación | Guarda |
|---|---|
| Pujar (sube el compromiso) | `saldo_disponible ≥ compromiso_sin_este_caballo + monto_nuevo` |
| Retirar (baja el saldo) | ver §7, decisión pendiente |
| Ajuste manual de admin a la baja | `saldo_nuevo ≥ compromiso_usuario()` |

Si esas tres se respetan, **el saldo de un usuario solo puede subir entre que puja y que cierra el remate**. Por eso el débito diferido no puede fallar por fondos: cuando llega, el dinero está garantizado.

## 5. Ciclo de vida del dinero

| Momento | Modelo actual | Modelo v2 |
|---|---|---|
| Usuario puja | `disponible −monto`, `bloqueado +monto`, 1 movimiento | **nada** |
| Lo superan | `disponible +monto`, `bloqueado −monto`, 1 movimiento | **nada** |
| Sube su propia puja | `disponible −delta`, `bloqueado +delta`, 1 movimiento | **nada** |
| Retiran el caballo | *(no implementado)* | **nada** — deja de contar solo |
| **Cierra el remate** | nada | **`disponible −monto` por cada puja líder**, 1 movimiento `apuesta_cobro` |
| Se liquida | libera perdedores, cobra ganadores, paga premio | **solo paga el premio** |
| Se cancela (abierto) | devuelve todos los saldos | **nada** |
| Se cancela (ya cerrado) | — | devuelve lo cobrado, 1 movimiento `apuesta_devolucion` |

## 6. Cambios función por función

### 6.1 `hacer_puja` — la guarda de exposición

Se le quitan las secciones 7 a 10 y 12 del código actual (cálculo de delta, lock de wallet, desbloqueo del anterior, bloqueo del nuevo, movimiento). Entra en su lugar:

```sql
-- Candado por USUARIO. Imprescindible: sin esto, dos pujas simultaneas del
-- mismo usuario sobre caballos distintos pasan las dos la validacion.
-- Espacio de nombres 1 para usuarios, 2 para remate+caballo, y SIEMPRE en
-- este orden, para que no haya interbloqueos.
perform pg_advisory_xact_lock(1, hashtext(v_user_id::text));
perform pg_advisory_xact_lock(2, hashtext(p_remate_id::text || ':' || p_horse_id::text));

-- Compromiso actual del usuario, descontando lo que ya lidera en ESTE caballo
-- (porque subir tu propia puja la reemplaza, no la suma).
v_compromiso := public.compromiso_usuario(v_user_id);

if v_top_user_id = v_user_id then
  v_compromiso := v_compromiso - coalesce(v_top_monto, 0);
end if;

select saldo_disponible into v_saldo
from public.wallets
where user_id = v_user_id;

if v_saldo is null then
  raise exception 'No se encontro wallet para el usuario';
end if;

if v_saldo < (v_compromiso + p_monto) then
  raise exception 'Saldo insuficiente. Disponible: %, ya comprometido: %, requerido para esta puja: %',
    v_saldo, v_compromiso, p_monto;
end if;
```

**El candado por usuario es el punto crítico de todo el diseño.** El candado actual es por `remate + caballo`, que sirve para que dos usuarios no pujen a la vez al mismo caballo. Pero aquí la validación cruza **todos** los remates de **un** usuario, así que hace falta un candado sobre el usuario. Sin él, alguien con 500 Bs abre dos pestañas, puja 400 a dos caballos distintos al mismo tiempo, las dos validaciones leen el mismo compromiso viejo y las dos pasan. Se compromete 800 teniendo 500.

Se conserva sin cambios: validación de admin, ventana `opens_at`/`closes_at`, caballo retirado, reglas de incremento, mínimo manual, e inserción en `bids`.

### 6.2 `cerrar_remate` — aquí se mueve el dinero

Deja de ser un simple cambio de estado. Pasa a ser el momento del cobro:

```sql
for r in
  select lider.user_id, sum(lider.monto) as total
  from (
    select distinct on (b.horse_id) b.user_id, b.monto
    from public.bids b
    join public.horses h on h.id = b.horse_id
    where b.remate_id = p_remate_id
      and coalesce(h.retirado, false) = false
    order by b.horse_id, b.monto desc, b.created_at asc
  ) lider
  group by lider.user_id
loop
  select * into v_wallet from public.wallets
  where user_id = r.user_id for update;

  -- No deberia pasar nunca si el invariante se respeto. Si pasa, es un bug
  -- en otra parte y hay que enterarse, no seguir de largo.
  if v_wallet.saldo_disponible < r.total then
    raise exception 'Invariante roto: usuario % tiene % y debe %',
      r.user_id, v_wallet.saldo_disponible, r.total;
  end if;

  update public.wallets
     set saldo_disponible = saldo_disponible - r.total
   where id = v_wallet.id;

  insert into public.wallet_movements (wallet_id, tipo, monto, descripcion, ref_externa)
  values (v_wallet.id, 'apuesta_cobro', -r.total,
          'Cobro de pujas ganadas al cierre del remate ' || v_remate.nombre,
          p_remate_id::text);
end loop;

update public.remates set estado = 'cerrado', closed_at = now() where id = p_remate_id;
```

**Consecuencia importante:** `auto_cerrar_remates()` (el cron de cada minuto) pasa a mover dinero. Hoy solo cambia un estado. Eso eleva mucho lo que está en juego si el cron falla o se ejecuta dos veces — el cierre tiene que ser idempotente por construcción (el `where estado = 'abierto'` lo garantiza, siempre que el `UPDATE` de estado y los débitos vayan en la **misma transacción**).

### 6.3 `liquidar_remate` — solo paga el premio

Todo el bucle de liberación desaparece: al liquidar, el dinero ya está cobrado.

```sql
-- Pozo = pujas lideres + precio de salida de los caballos que quedaron a la
-- casa. Se excluyen los retirados en ambos terminos.
select
  coalesce(sum(coalesce(t.max_monto, h.precio_salida)), 0)
into v_pozo_total
from public.horses h
left join (
  select horse_id, max(monto) as max_monto
  from public.bids where remate_id = p_remate_id
  group by horse_id
) t on t.horse_id = h.id
where h.race_id = v_remate.race_id
  and coalesce(h.retirado, false) = false;     -- <-- corrige el defecto del retirado

-- Comision configurable, en vez del 0.75 clavado
v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa, 25) / 100.0), 2);

-- Guarda de solvencia: la casa no puede acreditar lo que no tiene
if v_premio > public.dinero_casa_disponible() then
  raise exception 'La casa no tiene fondos para pagar este premio (premio: %, disponible: %). Revisa la caja antes de liquidar.',
    v_premio, public.dinero_casa_disponible();
end if;
```

Con `dinero_casa_disponible()` definida como la identidad que ya usa el panel de contabilidad:

```sql
create or replace function public.dinero_casa_disponible()
returns numeric language sql stable security definer set search_path to 'public'
as $function$
  select
      (select coalesce(sum(monto),0) from public.deposit_requests  where estado='aprobado')
    - (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pagado')
    - (select coalesce(sum(monto),0) from public.withdraw_requests where estado='pendiente')
    - (select coalesce(sum(saldo_disponible),0) from public.wallets);
$function$;
```

### 6.4 `cancelar_remate` — dos casos, ambos simples

```sql
if v_remate.estado = 'abierto' then
  -- No se cobro nada todavia. No hay nada que devolver.
  null;
elsif v_remate.estado = 'cerrado' then
  -- Devolver exactamente lo que se cobro al cerrar: los movimientos
  -- 'apuesta_cobro' con ref_externa = este remate.
  ...
end if;
```

Desaparece el `sum(b.monto)` que hoy provoca el error *"Inconsistencia"*.

### 6.5 `retirar_caballo` — RPC nueva

```sql
create or replace function public.retirar_caballo(p_horse_id uuid, p_motivo text)
returns text
```

- Valida admin, motivo obligatorio, y que el remate **no** esté liquidado.
- `update horses set retirado = true`.
- Si el remate está **abierto**: no toca dinero. La puja de ese caballo deja de contar para el compromiso de su líder de forma automática, y el caballo sale del pozo.
- Si el remate está **cerrado** (ya se cobró): devuelve al líder de ese caballo el monto cobrado, con movimiento `apuesta_devolucion`.
- Escribe en `admin_actions`.

> Esta función es el mejor argumento a favor de todo el rediseño. En el modelo actual habría que localizar el bloqueo del líder y revertirlo con cuidado. En el modelo v2, el caso frecuente —retirar durante un remate abierto— **no toca el dinero en absoluto**.

### 6.6 `solicitar_retiro`

Ver §7 (decisión pendiente).

### 6.7 Ajustes manuales de admin

Cualquier RPC que baje el `saldo_disponible` de un usuario debe validar `saldo_nuevo >= compromiso_usuario(user_id)`. Es la tercera pata del invariante y es la que se olvida.

---

## 7. Regla de retiro — **DECIDIDA**

> **Decisión de Miguel Ángel (27/08/2026): retirable = `saldo_disponible` − `compromiso_usuario()`.**
> Se muestran los dos números al usuario: cuánto tiene disponible para retirar y cuánto tiene comprometido en pujas.

```sql
-- dentro de solicitar_retiro, despues de validar monto > 0 y metodo
v_compromiso := public.compromiso_usuario(v_user_id);
v_retirable  := v_wallet.saldo_disponible - v_compromiso;

if p_monto > v_retirable then
  raise exception 'Solo puedes retirar % Bs. Tienes % Bs comprometidos en pujas activas.',
    greatest(v_retirable, 0), v_compromiso;
end if;
```

**Nota de concurrencia:** `solicitar_retiro` tiene que tomar el **mismo candado por usuario** que `hacer_puja` (`pg_advisory_xact_lock(1, hashtext(user_id::text))`) antes de leer el compromiso. Si no, un usuario puede pujar y pedir el retiro simultáneamente, y las dos operaciones leen el mismo estado viejo. Es el mismo defecto de §6.1 por la otra puerta.

**Lo que debe mostrar el frontend** (`app/dashboard`, `app/dashboard/retirar`, y la vista de remate):

| Etiqueta | Valor |
|---|---|
| Saldo total | `saldo_disponible` |
| Comprometido en pujas | `compromiso_usuario()` |
| Disponible para retirar | `saldo_disponible − compromiso_usuario()` |

`mi_wallet_resumen()` debe devolver los tres. Hoy devuelve `saldo_disponible` y `saldo_bloqueado`; el segundo pasa a ser siempre 0 y se reemplaza por el compromiso calculado.

---

## 7bis. Verificación del diseño contra PostgreSQL real

No entrego este diseño sobre el papel. Levanté un PostgreSQL 16 con el esquema replicado y corrí los casos críticos.

**`compromiso_usuario()` — comportamiento verificado:**

| Escenario | Esperado | Obtenido |
|---|---|---|
| U1 puja 100 al caballo A → lo superan → puja 200 al caballo B | 200 (no 300) | **200** ✅ |
| U1 sube su propia puja de 200 a 260 en el mismo caballo | 260 (no 460) | **260** ✅ |
| Se retira el caballo donde U1 lidera | 0, sin mover dinero | **0** ✅ |
| U2, superado en un caballo y líder en otro | solo la líder | **150** ✅ |

**El candado por usuario — la prueba que justifica todo el §6.1:**

Usuario con 500 Bs, dos pujas **simultáneas** de 400 Bs a caballos distintos, desde dos conexiones:

| Versión | Resultado | Compromiso final |
|---|---|---|
| **Sin** candado por usuario | Las **dos** aceptadas | **800 Bs contra un saldo de 500** ❌ |
| **Con** candado por usuario | Una aceptada, una rechazada | **400 Bs** ✅ |

Sin ese candado el modelo v2 es **peor** que el actual, porque el modelo actual tiene el `for update` sobre la wallet que serializa por accidente. Quien implemente esto no puede omitirlo: es la diferencia entre un sistema correcto y uno que regala dinero al que abra dos pestañas.

---

## 6bis. Reglas de puja — **DECIDIDAS 22/09/2026**

Estas reglas son la referencia para reescribir `hacer_puja` y la vista de remate. Reemplazan lo que hace el código hoy.

### R0 · Precios y escalas por caballo — **YA EXISTE, verificado 22/09**

Jota pidió un menú para configurar precio de salida y escala de incrementos por caballo, porque un favorito no vale lo mismo que un caballo de relleno y no suben igual. **Eso ya está construido:**

- `horses.precio_salida` es **por caballo**.
- `remate_price_rules.horse_id` es nullable: `null` = regla por defecto del remate, con valor = regla específica de ese caballo.
- **Las dos pantallas lo soportan.** `app/admin/crear-remate` y `app/admin/remates/[id]` tienen el interruptor `horseRulesEnabled` por caballo, y la de edición ya relee y reconstruye las reglas separando defaults de específicas.
- `hacer_puja` prioriza correctamente: `order by (r.horse_id = p_horse_id) desc, r.min_precio desc`.

**Lo que SÍ falta, y es lo que hay que arreglar:**

Los diez tramos por defecto están **escritos a mano en el componente React** (`app/admin/crear-remate/page.tsx`, líneas 221-230):

```js
{ min_precio: "0",     max_precio: "100",  incremento: "20"  },
{ min_precio: "100",   max_precio: "300",  incremento: "30"  },
...
{ min_precio: "30000", max_precio: "",     incremento: "1000" },
```

Esos números se fijaron hace meses y **con la inflación venezolana ya no proceden**. Hoy cambiarlos exige tocar código y desplegar. Deben vivir en la base, configurables por instalación (`app_settings`), para que cada licenciatario ponga su escala y la actualice cuando quiera sin depender de nadie.

Mismo criterio que el interruptor de apertura y cierre: **se entrega el pico y la pala, el operador decide cómo usarlos.**

### R1 · La primera puja toma el caballo al precio de salida

Como en la pizarra: el primero que levanta la mano se lleva el caballo **en el precio en que salió**.

- Caballo **sin ninguna puja** → el botón dice **"Iniciar"** (no "Ponerle") y puja **exactamente `precio_salida`**.
- Caballo **con al menos una puja** → el botón dice **"Ponerle"** y puja `monto_actual + incremento`.

**Cambio respecto de hoy:** hoy la primera puja posible es `precio_salida + incremento`. Un caballo que sale en 30 con incremento 20 no se puede tomar en 30, hay que pagar 50. Eso se elimina.

**Concurrencia:** dos usuarios pueden apretar "Iniciar" a la vez. El candado por `remate+caballo` los serializa; el segundo encontrará que ya hay una puja y su llamada debe **fallar con un mensaje claro** ("alguien inició este caballo, el precio ahora es X"), no convertirse silenciosamente en un "Ponerle". La vista se refresca y el botón cambia solo.

### R2 · El campo manual lleva el monto total, sin tope

Sirve para ofrecer **más** de lo que propone el botón automático. Reglas:

- Es el **precio total acumulado** al que queda el caballo, no cuánto le sube.
- **No tiene tope superior.**
- Debe ser **mayor o igual al mínimo automático** que corresponda en ese momento (`precio_salida` si no hay pujas, `actual + incremento` si las hay).

**Pendiente de confirmar:** hoy el mínimo manual es `automático + 10`, con el 10 escrito a mano en el código (`manualMinByHorse[h.id] = nextMin + 10` en la vista, y `v_minimo_permitido + 10` en el SQL). Jota no mencionó ese +10 al definir la regla. Si no es intencional, el mínimo manual debe ser simplemente el mínimo automático.

### R3 · Sobrepujarse a uno mismo queda permitido

No hay regla del negocio que lo prohíba; simplemente nadie lo hace porque no tiene sentido. **Se mantiene el comportamiento actual**, y con él la lógica de delta de `hacer_puja`, que existe precisamente para ese caso: si ya eres el líder con 100 y subes a 150, se te bloquean 50 más, no 150 más. Terminas con el precio completo bloqueado, nunca con una fracción.

### R4 · El líder siempre tiene bloqueado el precio completo

Regla del negocio, ya implementada correctamente en el servidor: *"cada usuario que se va posicionando primero es responsable por el total en lo que vaya el caballo, no solo por el delta"*.

**Defecto a corregir:** el frontend calcula distinto que el SQL.

```js
// app/remates/[id]/page.tsx — INCORRECTO
const myPrev = computed.myMaxByHorse[horseId] ?? 0   // tu puja mas alta historica
const requerido = Math.max(0, monto - myPrev)
```

`myMaxByHorse` es la puja más alta que ese usuario hizo en ese caballo **alguna vez**, sea o no el líder actual. El SQL solo resta si es el líder **ahora**. Resultado: al usuario se le dice que necesita menos de lo que el servidor le va a exigir, aprieta el botón, y el servidor lo rechaza con "Saldo insuficiente".

**Corrección:** el frontend debe restar solo si el usuario es el líder actual de ese caballo, igual que el SQL. Mejor aún: exponer el mínimo y el requerido desde una función SQL y que la vista no calcule nada de esto por su cuenta.

### R5 · Dos conflictos que hay que resolver antes de implementar R1

**a) `apuesta_minima` choca con "tomar el caballo al precio de salida".**

Hoy `hacer_puja` hace:

```sql
if v_minimo_permitido < v_remate.apuesta_minima then
  v_minimo_permitido := v_remate.apuesta_minima;
end if;
```

Si un caballo sale en 30 y la `apuesta_minima` del remate es 40, el botón "Iniciar" **no podría** tomarlo en 30: el piso lo subiría a 40. La regla R1 se rompe.

Opciones:
1. **Validar al crear/editar que `precio_salida >= apuesta_minima`** para todos los caballos. La regla queda coherente y `apuesta_minima` pasa a ser un piso que en la práctica nunca se activa (porque toda puja posterior es mayor). Es decir: el campo se vuelve redundante y se podría eliminar.
2. **Que `apuesta_minima` no aplique a la primera puja**, solo a las siguientes. Conserva el campo pero lo vuelve difícil de explicar.

> ### ✅ DECIDIDO (22/09/2026): eliminar `apuesta_minima`
>
> Jota no encuentra motivo para conservarla, y no lo hay: con la validación `precio_salida >= apuesta_minima` el piso nunca se activaría, porque toda puja posterior a la primera es mayor por construcción. El campo no hace nada.
>
> **Plan:** quitar el piso de `hacer_puja`, quitar el campo del formulario de crear y editar, y dejar la columna en la tabla durante unas semanas (sin uso) antes de borrarla en una migración posterior. El control de "cuánto vale mínimo participar en este remate" ya lo da el `precio_salida` de cada caballo, que es donde debe estar.

**b) `pozoTotal` en la vista pública usa el 25% fijo.**

`const casaTotal = pozoTotal * 0.25` en `app/remates/[id]/page.tsx`. Mismo defecto que en la liquidación (C2): debe leer `porcentaje_casa` del remate.

---

## 7ter. Requisito de juego antes de retirar (rollover) — **A DECIDIR**

Regla que quiere Jota: **una recarga no se puede retirar tal cual.** El usuario tiene que jugar al menos un porcentaje de ella (propuesto: 50%) antes de poder sacar ese dinero. Lo que gane por encima no queda sujeto a la regla.

El problema que resuelve: alguien recarga 500, apuesta 40, pierde, y quiere retirar 460 enseguida. Eso convierte la plataforma en un canal de transferencia gratis y le cuesta comisiones al operador sin que haya juego real.

### Piezas

```sql
-- porcentaje configurable POR INSTALACION (cada licenciatario elige el suyo)
-- vive en app_settings; 50 por defecto

create table public.deposit_lots (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null,
  deposit_id     uuid not null references public.deposit_requests(id),
  monto_original numeric not null,
  requisito      numeric not null,   -- monto_original * pct / 100
  cumplido       numeric not null default 0,
  cerrado        boolean not null default false,
  created_at     timestamptz not null default now()
);
```

- **Al aprobar una recarga:** se crea un lote con `requisito = monto × pct/100`.
- **Al cerrar un remate** (que es cuando se cobra de verdad): el monto cobrado suma a `cumplido` de los lotes abiertos del usuario, del más viejo al más nuevo. Un lote llega a `cumplido >= requisito` → `cerrado = true`.
- **Al devolver dinero** (cancelar remate, reabrir, caballo retirado después del cierre): se **revierte** el `cumplido` correspondiente. Sin esto, alguien puja, pide que le cancelen el remate, y se queda con el requisito cumplido sin haber arriesgado nada.

### Qué cuenta como "jugado"

**Solo el dinero efectivamente cobrado al cerrar el remate.** No cuentan las pujas donde al usuario lo superaron, porque ésas nunca le costaron nada — si contaran, bastaría con pujar bajo y dejarse superar toda la tarde para limpiar el requisito sin arriesgar un céntimo.

### Las dos variantes — hay que elegir una

Ejemplo de Jota: recarga **500**, juega **50**, gana **1000**. Saldo final **1450**. Requisito = 250, cumplido = 50.

**Opción A — contador simple.** Se bloquea lo que falta del requisito.

```
bloqueado = requisito − cumplido = 200
retirable = 1450 − 200 = 1250
```

**Opción B — el lote queda retenido.** Se bloquea lo que queda sin jugar de esa recarga, y el lote se libera entero cuando se alcanza el porcentaje.

```
bloqueado = monto_original − cumplido = 450
retirable = 1450 − 450 = 1000
```

**La opción B da exactamente los 1.000 que Jota describió.** La A es más permisiva: deja sacar 1.250 de una recarga cuyo requisito todavía no se cumplió.

> ### ✅ DECIDIDO: opción B (22/09/2026)
>
> Razones dadas por Jota:
> - Esto no es un banco donde alguien guarda 2.000 Bs hoy y los saca mañana.
> - Obliga a que haya juego real, que es lo que el negocio necesita.
> - El sistema **no arranca con pasarelas de pago ni retiros automatizados**: el usuario solicita el retiro en la página, un admin lo aprueba y transfiere a pago móvil o cuenta. Cada retiro cuesta trabajo humano, así que no puede ser un canal de ida y vuelta gratis.
> - Como proveedor del software, entregarle al licenciatario las mejores condiciones posibles es parte del trabajo, aunque el negocio de Jercol sean las licencias y no la operación.
>
> **Requisito legal asociado:** en el registro, el usuario debe dar fe de que el dinero que deposita es de origen lícito. Casilla obligatoria, con el texto guardado y la fecha de aceptación (`profiles.acepto_origen_licito_at`). Va junto a los términos y al disclaimer de que el saldo no es un depósito bancario.

### La fórmula final de retiro

Con esto, el retirable del §7 se completa:

```
retirable = saldo_disponible
          − compromiso_usuario()          -- pujas que lidera ahora
          − retencion_por_lotes(user_id)  -- requisito de juego pendiente
```

Los tres números se muestran al usuario por separado. Que vea *"tienes 1.450, 450 retenidos por requisito de juego, 0 comprometidos en pujas, puedes retirar 1.000"* evita la mitad de los mensajes a soporte.

### Casos borde a cerrar (pendientes de decisión)

1. **Recarga sobre saldo existente.** Con el modelo de lotes se resuelve solo: cada recarga es su propio lote con su propio requisito, y conviven. Jota marcó esto como "otra cosa" que había que pulir — con lotes, no requiere regla aparte.
2. **¿Caduca el requisito?** Algunas casas lo vencen a los N días y liberan el saldo. Hoy: no caduca.
3. **¿Qué pasa si el usuario pide retirar y tiene lotes parcialmente cumplidos?** Con B, sale lo que no esté retenido. No se rompe ningún lote.
4. **¿El premio ganado puede usarse para cumplir requisito?** Con este diseño sí: si juega las ganancias, ese monto cobrado suma a `cumplido`. Es lo razonable, pero conviene confirmarlo.
5. **Primera recarga vs. recurrentes.** ¿Mismo porcentaje siempre, o más blando a partir de la segunda? Hoy: mismo porcentaje.

---

## 7quater. Contabilidad de la casa — **DECIDIDO 23/09/2026, va en el bloque 2**

### El problema

Hoy `dinero_casa` es **un solo número calculado por resta**:

```
dinero_casa = recargas_aprobadas - retiros_pagados - saldo_usuarios - retiros_pendientes
```

La cuenta es correcta: los depósitos entran como activo y salen como pasivo, así que **no se cuentan como ganancia**. Lo que queda es patrimonio, y ese patrimonio es exactamente el 25% acumulado más los pozos ganados por caballos de la casa.

**Pero la casa no tiene libro.** Verificado en el baseline:

- Cero tablas de la casa.
- `liquidar_remate` hace dos `insert` en `wallet_movements`, y **los dos van a wallets de usuarios**.
- **El 25% de la casa no se registra en ninguna parte.**

Consecuencia: si `dinero_casa` da 3.400 Bs, no hay forma de saber si son comisiones legítimas, un ajuste manual, o un defecto. Es un número sin contraparte.

### La decisión: dos caminos al mismo número

> **Patrimonio** se calcula **por resta** (caja menos comprometido).
> **Ganancia acumulada** se calcula **por suma** (el libro de la casa).
> **Los dos deben dar idéntico.** Si difieren, hay un error, y el libro dice en qué remate empezó.

Hoy solo existe el primer camino.

### Tabla nueva: `house_ledger`

```sql
create type public.house_entry as enum (
  'comision_remate',              -- (+) el porcentaje de la casa al liquidar
  'pozo_ganado',                  -- (+) gano un caballo que quedo a la casa
  'aporte_caballos_no_vendidos',  -- (-) lo que la casa banca en ese remate
  'ajuste_manual'                 -- (+/-) con motivo obligatorio
);

create table public.house_ledger (
  id         uuid primary key default gen_random_uuid(),
  tipo       public.house_entry not null,
  monto      numeric not null,
  remate_id  uuid references public.remates(id) on delete restrict,
  motivo     text,
  creado_por uuid,
  created_at timestamptz not null default now()
);
```

`liquidar_remate` emite sus asientos en el mismo momento en que calcula esos montos. Por eso esta tarea va en el bloque 2 y no antes: hacerla aparte obligaría a tocar la función dos veces.

### Cómo se presenta al operador — **esto NO es cosmético**

Observación de Jota: llamar "lo que se les debe" a la suma de saldos y retiros pendientes **hace que un operador poco atento crea que le falta plata**. El pasivo con usuarios es normal: nace con cada depósito y está cubierto por la caja.

La presentación tiene que dejar ver la cobertura, no la deuda:

```
DINERO EN LA CUENTA
  Recargas aprobadas                    + 12.400
  Retiros ya pagados                    -  3.200
  ----------------------------------------------
  CAJA                                    9.200

DE ESA CAJA, ESTA COMPROMETIDO
  Saldo de los usuarios                    5.800    pueden usarlo o retirarlo
  Retiros por pagar                        1.400    aprobados, falta transferir
  ----------------------------------------------
  COMPROMETIDO                             7.200

PATRIMONIO DE LA CASA                      2.000    esto si es suyo
Ganancia acumulada (libro)                 2.000    debe coincidir
```

Reglas de presentación:

1. **La caja va primero.** El operador ve que hay dinero antes de ver qué parte está comprometida.
2. **"Comprometido", no "deuda" ni "lo que se les debe".** Cada línea con su explicación al lado.
3. **Patrimonio y ganancia acumulada se muestran juntos.** Coinciden o hay un problema.

### La alarma que hoy no existe

**Si `comprometido > caja`, eso sí significa que falta plata.** Es la única condición que de verdad es una emergencia, y hoy no hay ninguna señal para ella.

```sql
-- cobertura = caja / comprometido
--   >= 1  normal
--    < 1  ALARMA: la casa no puede cubrir lo que debe
```

Debe ir en rojo en el panel y disparar un aviso. Es el indicador que le dice al operador —o al licenciatario— que algo se rompió, antes de que un usuario intente retirar y el pago rebote.

---

## 8. Índices necesarios

El compromiso se calcula en **cada puja**, así que la consulta tiene que volar:

```sql
create index if not exists idx_bids_lider
  on public.bids (remate_id, horse_id, monto desc, created_at asc);

create index if not exists idx_bids_user
  on public.bids (user_id);

create index if not exists idx_remates_abiertos
  on public.remates (estado) where estado = 'abierto';
```

Con esos tres, `compromiso_usuario()` recorre solo las pujas de los remates abiertos, que son pocos por definición.

## 9. Qué se elimina

- El bloque completo de bloqueo/desbloqueo de `hacer_puja` (secciones 7 a 12 del código actual).
- Los tipos de movimiento `apuesta_bloqueo` y `apuesta_desbloqueo`: dejan de generarse. Los históricos se conservan.
- `wallets.saldo_bloqueado`: queda en 0 permanentemente. **No borrar la columna en la misma migración** — dejarla, verificar durante unas semanas que se mantiene en 0, y eliminarla en una migración posterior.
- El defecto C3, completo, en `liquidar_remate` y en `cancelar_remate`.

## 10. Migración

Trivial en este caso: **la base de producción solo tiene datos de prueba y se va a vaciar antes de salir en vivo.** No hay remates abiertos reales que convertir.

Orden sugerido:

1. Vaciar datos de prueba (`sql/reset_app_cero.sql`).
2. Crear `compromiso_usuario()` y `dinero_casa_disponible()`.
3. Crear los índices.
4. Reemplazar `hacer_puja`, `cerrar_remate`, `liquidar_remate`, `cancelar_remate`, `solicitar_retiro`.
5. Crear `retirar_caballo()`.
6. `update wallets set saldo_bloqueado = 0`.
7. Ajustar el frontend: la vista de remate y el dashboard muestran *comprometido* en vez de *bloqueado*.

**Todo esto como migraciones numeradas en `supabase/migrations`, no como scripts sueltos en `sql/`.** Es la ocasión natural para arrancar el versionado que hace falta para licenciar.

## 11. Pruebas obligatorias antes de desplegar

Ninguna de estas es opcional. Son los casos donde el dinero se rompe.

| # | Escenario | Resultado esperado |
|---|---|---|
| 1 | Usuario con 500 puja 300 al caballo A y 300 al B | La segunda puja se rechaza |
| 2 | Lo mismo, **en paralelo** desde dos conexiones | Una pasa, la otra se rechaza (prueba del candado por usuario) |
| 3 | Usuario puja 100, lo superan, puja 200 en otro caballo | Compromiso = 200, no 300 |
| 4 | Usuario sube su propia puja de 100 a 150 | Compromiso = 150, no 250 |
| 5 | Se retira un caballo con puja líder, remate abierto | Compromiso baja solo; no se mueve dinero; el caballo sale del pozo |
| 6 | Se retira un caballo con puja líder, remate ya cerrado | Se devuelve el monto cobrado a su líder |
| 7 | Cierre de remate con 3 usuarios y 10 caballos | Cada uno debitado exactamente por sus pujas líderes |
| 8 | Cierre de dos remates del mismo usuario, en paralelo | Ambos débitos correctos, sin descuadre |
| 9 | Liquidación donde el premio supera la caja de la casa | **Falla con mensaje claro**, no acredita |
| 10 | Cancelar remate abierto con pujas | No se mueve dinero |
| 11 | Cancelar remate cerrado con pujas | Se devuelve exactamente lo cobrado |
| 12 | Retiro con compromiso activo | Según la opción elegida en §7 |
| 13 | Suma de movimientos de una wallet vs su `saldo_disponible` | Cuadran al céntimo |

## 12. Lo que este diseño NO resuelve

Para que quede explícito y no se dé por cubierto:

- **Nada sobre el modelo de negocio.** La regla —caballos no pujados quedan a la casa y suman al pozo, 75% al usuario ganador, 25% a la casa— se toma como dada y no se discute. Este diseño solo garantiza que la cuenta se haga bien y que el sistema no acredite un saldo que no puede pagar.
- **Los permisos de la pantalla de edición del remate.** Un admin puede seguir cambiando `precio_salida` o `estado` a mano con un remate abierto. Va aparte.
- **La comisión configurable por instalación.** Este diseño la lee de `remates.porcentaje_casa`, pero el default de la columna y el de la UI siguen sin estar alineados.
