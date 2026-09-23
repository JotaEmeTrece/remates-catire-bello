# Backlog — Fase 1: refactors y fixes

**Proyecto:** Remates Catire Bello
**Fecha:** 27 de agosto de 2026
**Alcance:** dejar el sistema correcto y blindado. **No** incluye funcionalidad nueva de licenciamiento (eso es Fase 2).
**Documentos de referencia:** `AUDITORIA_2026-08.md` · `DISENO_SALDO_V2.md`

---

## Cómo leer este backlog

Cada tarea trae **qué**, **dónde**, y un **criterio de aceptación verificable**. El criterio no es "quedó hecho": es una consulta, una prueba o una comprobación que da un resultado concreto. Si no se puede verificar, la tarea no está terminada.

El orden **importa**. Las dependencias están marcadas. No saltarse el bloque 0: sin él, cada corrección posterior se aplica a ciegas sobre producción.

**Premisa que habilita todo esto:** la base de producción solo tiene datos de prueba y se vacía antes de empezar. No hay migración de datos reales en ninguna tarea.

---

## Bloque 0 — Base de trabajo

> Sin este bloque, todo lo demás son parches irreproducibles. Es el prerequisito real del licenciamiento.

### 0.1 · Congelar el estado actual de producción como migración inicial — ✅ **HECHO Y VERIFICADO (22/09/2026)**

> **Resultado:** `supabase/migrations/00000000000000_baseline.sql` — 135.468 bytes, 4.352 líneas.
> Generado con `npx supabase db dump --schema public --schema auth` contra producción.
>
> **Verificado aplicándolo sobre una base vacía** (PostgreSQL local). Reproduce:
> 13 tablas · 5 enums · 26 funciones · 40 políticas RLS · 3 triggers · 40 claves foráneas · 63 índices únicos.
>
> Las cuatro correcciones que existían en producción y no en el repo quedaron capturadas:
>
> | | |
> |---|---|
> | Trigger `enforce_admin_immutability` | ✅ presente |
> | `UPDATE` sobre `profiles` para `authenticated` | ✅ revocado (`false`) |
> | Política `bids_select_auth using(true)` | ✅ ausente |
> | `unique(race_id, numero)` en `horses` | ✅ presente |
>
> Y los defectos también, como debe ser: `cerrar_remate` con su bucle `user_max`, las FK en `CASCADE`, `liquidar_remate` con el `0.75`.
>
> **Nota sobre la aplicación de prueba:** dio 15 errores, todos `unrecognized privilege type "maintain"`. Es el privilegio `MAINTAIN` que introdujo PostgreSQL 17; el Postgres de prueba era 16 y el de producción es 17.6. **No es un defecto del volcado** — sobre PG 17 aplica limpio.

---

### 0.1-bis · (referencia) Cómo se hizo

**Qué:** volcar el esquema **real de producción** (no el de `sql/`) a `supabase/migrations/00000000000000_baseline.sql`.

**Por qué es delicado:** producción tiene al menos cuatro correcciones que no están en `sql/` — el trigger `enforce_admin_immutability`, el `revoke` de UPDATE sobre `profiles`, la eliminación de `bids_select_auth`, el `unique(race_id,numero)` — y `sql/` tiene al menos un script que **revierte** una de ellas. **La fuente de verdad es producción, no el repositorio.** Si se toma `sql/` como base, la instalación de un cliente nace con los agujeros ya cerrados en producción.

**Cómo:** `supabase db dump --schema public --schema auth -f baseline.sql` contra el proyecto de producción, o el volcado desde el panel. Debe incluir tablas, tipos, funciones, triggers, políticas RLS, grants, constraints e índices.

**Aceptación:** aplicar el baseline sobre una base vacía y correr `sql/diagnostico_rapido.sql`. Las filas 1, 2, 71, 80 y 81 deben dar el mismo valor que en producción hoy (`1`, `false`, `1`, `0`, `0`).

---

### 0.2 · Entorno de pruebas — **DECIDIDO: se trabaja contra producción**

**Decisión de Miguel Ángel (22/09/2026):** no se crea un segundo proyecto Supabase. Las migraciones se aplican contra producción.

**Por qué es aceptable hoy:** producción **solo tiene datos de prueba**, no hay un solo usuario real, y la base se va a vaciar de todas formas antes de salir en vivo. En la práctica, producción *es* el entorno de pruebas. Montar un segundo proyecto para proteger datos que se van a borrar sería trabajo sin retorno.

**Dos condiciones que sí hay que cumplir:**

1. **Respaldo antes de cada migración que toque dinero.** Supabase tiene backup bajo demanda. Las tareas 1.1 a 1.9 y todo el bloque 2 entran en esa categoría. Cuesta un minuto y es lo único que separa un error de una pérdida.
2. **El arnés de pruebas (0.3) no corre contra producción.** Va contra un PostgreSQL local levantado con `supabase start` (Docker) o con un Postgres suelto donde se aplique el baseline. Las pruebas de dinero necesitan crear y destruir datos constantemente; hacerlo contra la base viva es exactamente como se ensucia una base.

**Y un límite que hay que dejar por escrito:** en el modelo de base-por-cliente, **antes del primer cliente real el entorno de pruebas deja de ser opcional**. Cuando existan N bases de clientes, aplicar una migración sin haberla probado antes en un entorno idéntico significa arriesgar la operación de N negocios a la vez. Esto es una tarea de Fase 2, no una opinión.

**Aceptación:** existe un procedimiento escrito de respaldo previo, y el arnés de 0.3 corre contra una base local, no contra producción.

---

### 0.3 · Arnés de pruebas para las funciones de dinero

**Qué:** pgTAP, o un script SQL de aserciones si se prefiere algo más liviano. Debe correr contra staging con un comando.

**Por qué:** los bloques 1 y 2 modifican la liquidación y el manejo de saldo. **Sin una prueba que reproduzca el error primero, cada corrección es una apuesta.**

**Implementado:** `tests/pruebas_dinero.sql`. Script SQL de aserciones, sin dependencias. Corre completo aunque una prueba falle y al final imprime la tabla de resultados.

| # | Escenario | Estado al 23/09 |
|---|---|---|
| P1 | Liquidar con un caballo retirado que tenía puja | 🔴 rojo — tarea 1.1 |
| P2 | Liquidar con `porcentaje_casa = 30` | 🔴 rojo — tarea 1.2 |
| P3 | Gana un caballo de la casa: no se paga premio | ✅ verde |
| P4 | Liquidar con premio mayor que la caja | 🔴 rojo — tarea 1.3 |
| P5 | Usuario superado: cerrar y liquidar sin error | ✅ verde (1.8) |
| P6 | El libro de movimientos reconstruye los saldos | ✅ verde — ver **2.19** |
| P7 | Borrar un caballo con pujas → rechazado por la base | ✅ verde (3.1) |
| P8 | Borrar una carrera con remates → rechazado | ✅ verde (3.1) |
| P9 | Los retiros pendientes se restan del dinero de la casa | ✅ verde (1.4) |
| P10 | Aprobar dos veces la misma recarga no duplica saldo | ✅ verde (1.7) |
| P11 | El cron y el botón dejan el remate en el mismo estado | ✅ verde (1.9) |
| P12 | El cron puede auditar sus propios fallos | ✅ verde (1.9) |
| P13 | La regla del caballo le gana a la del remate (2ª puja) | ✅ verde (1.10) |
| P14 | La primera puja compra al precio de salida | ✅ verde (2.17) |
| P15 | Sin piso `apuesta_minima`, manual desde el automático | ✅ verde (2.17) |

**Marcador: 12 verdes / 3 rojas de 15.** Los tres rojos son 1.1, 1.2 y 1.3, absorbidos por el bloque 2.

**Cómo correrlo** (con Docker levantado):

```powershell
npx supabase db reset
$db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres
```

**Regla de oro del arnés:** una prueba que pasa de entrada, antes de aplicar la corrección, **no está probando nada**. Pasó con P11: la primera versión era verde contra el código roto porque el escenario tenía un solo pujador y el bucle defectuoso nunca se disparaba. Hubo que reescribirla con un usuario superado.

---

### 0.4 · Limpieza del repositorio

**Qué:**
- Borrar `estructura.txt` del control de versiones (**11,3 MB** versionados).
- `git rm --cached` de todos los `Desktop.ini` (están en `.gitignore` pero fueron agregados antes de la regla).
- Commitear o descartar los ~20 archivos modificados sin commitear desde hace cuatro meses.
- Mover `sql/*.sql` a `supabase/migrations/` o a `docs/sql-historico/`. **No pueden quedar scripts sueltos que alguien pueda correr por error** — sobre todo `rollback_hardening_profiles.sql`, que reabre el agujero de privilegios, y `reset_app_cero.sql`.

**Aceptación:** `git status` limpio. `du -sh .git` razonable. `sql/` no contiene nada ejecutable a mano.

---

## Bloque 1 — Fixes de cálculo

### 1.0 · El sobrepuje está roto en producción — 🔴 **CRÍTICO · ENCONTRADO Y CORREGIDO 22/09/2026**

**Descubierto al correr el arnés de pruebas contra el baseline.**

`hacer_puja` y `cerrar_remate` insertan un movimiento de tipo `'apuesta_desbloqueo'`, pero ese valor **no existe** en el enum `public.wallet_movement_type`, que tiene `'apuesta_liberacion'`:

```
recarga · apuesta_bloqueo · apuesta_liberacion · premio · ajuste_manual · retiro
```

**Qué provoca:** la **primera** puja de cada caballo funciona, porque no hay líder previo a quien devolverle nada. La **segunda** —el sobrepuje— entra en la rama que libera al líder anterior, choca con el enum, y **la transacción entera se revierte**:

```
ERROR: invalid input value for enum wallet_movement_type: "apuesta_desbloqueo"
```

> **Nadie ha podido sobrepujar nunca. Cada caballo admite exactamente una puja y ahí se congela.** La mecánica central del remate no funciona.

**Esto explica los datos de prueba:** 300 Bs de participación de usuarios repartidos en 40 remates. No era falta de uso — era que el segundo que intentaba pujar recibía un error y se iba.

**Y explica por qué el defecto de `cerrar_remate` (1.8) nunca se manifestó:** su bucle solo libera cuando alguien fue superado, y superar era imposible.

**La corrección** (`supabase/migrations/20260922120000_fix_enum_apuesta_desbloqueo.sql`):

```sql
alter type public.wallet_movement_type add value if not exists 'apuesta_desbloqueo';
```

Se agrega el valor al enum en vez de reescribir las dos funciones: es una línea, sin riesgo de transcripción, y los tipos de movimiento se rehacen completos en el bloque 2 (tarea 2.8).

**Verificado:** aplicada sobre el baseline, el sobrepuje funciona y al líder anterior se le devuelve su monto completo.

---

## Bloque 1 (resto) — Fixes de cálculo

> Depende de: bloque 0 completo. Cambios acotados, sin tocar el modelo de saldo.

### 1.1 · El caballo retirado sale del pozo

**Dónde:** `liquidar_remate`, y el CTE `pozo` de `admin_contabilidad_resumen`.

**Qué:** agregar `and coalesce(h.retirado, false) = false` al `where` del cálculo del pozo, en **ambas** funciones.

**Aceptación:** prueba P1 en verde. Los dos cálculos del pozo dan el mismo número para un mismo remate.

---

### 1.2 · La comisión sale de `porcentaje_casa`

**Dónde:** `liquidar_remate` · `app/admin/remates/[id]/page.tsx` (literal `"Casa 25%"`, ~línea 897) · default de la columna.

**Qué:**
```sql
v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa, 25) / 100.0), 2);
```
Más: `alter table public.remates alter column porcentaje_casa set default 25;` y en la UI mostrar el porcentaje real del remate en vez del literal.

**Por qué también el default:** hoy la columna trae 20, la UI escribe 25 y la liquidación usa 25. Coinciden solo porque el formulario siempre manda el valor. Cualquier `insert` que no venga del formulario rompe la coincidencia.

**Aceptación:** prueba P2 en verde. `diagnostico_rapido.sql` fila 21 (`liquidar_remate lee porcentaje_casa`) pasa de `0` a `1`, y fila 20 (`0.75 hardcodeado`) de `1` a `0`.

---

### 1.3 · Guarda de solvencia en la liquidación

**Dónde:** `liquidar_remate`, antes de acreditar el premio.

**Qué:** crear `dinero_casa_disponible()` (definida en `DISENO_SALDO_V2.md` §6.3) y:

```sql
if v_premio > public.dinero_casa_disponible() then
  raise exception 'La casa no tiene fondos para pagar este premio (premio: %, disponible: %). Revisa la caja antes de liquidar.',
    v_premio, public.dinero_casa_disponible();
end if;
```

**Regla:** el sistema nunca acredita un saldo que no puede pagar. Si la caja no alcanza, la liquidación se detiene y el operador decide. No acredita y sigue.

**Aceptación:** prueba P4 en verde — con la caja insuficiente, la liquidación falla y **ni la wallet ni `remates.estado` cambian** (la transacción revierte entera).

---

### 1.4 · Contabilidad: restar los retiros pendientes

**Dónde:** `admin_contabilidad_resumen`, una línea.

```sql
v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios - v_retiros_pendientes;
```

`v_retiros_pendientes` ya se calcula; solo no se resta. El usuario ya tiene el monto descontado de su wallet aunque el pago todavía no salió, así que hoy figura como dinero de la casa.

**Aceptación:** crear un retiro pendiente en staging y comprobar que `dinero_casa` baja por ese monto.

---

### 1.5 · Eliminar `resumen_casa`

**Qué:** `drop function if exists public.resumen_casa();`

**Por qué:** función muerta —la app usa `admin_contabilidad_resumen`— con el signo de los retiros invertido y doble conteo de premios. Es la única función de dinero sin `security definer` ni `search_path` fijo. No dejarla ahí para que alguien la llame por error.

**Aceptación:** `diagnostico_rapido.sql` fila 90 pasa a `0`. La app compila y el panel de contabilidad funciona.

---

### 1.6 · Una sola RPC para liquidar

**Dónde:** `app/admin/remates/[id]/page.tsx` líneas 874-881, que llama `set_ganador_carrera` y después `liquidar_remate`.

**Qué:** una RPC `liquidar_con_ganador(p_remate_id uuid, p_horse_num integer)` que haga ambas cosas en **una** transacción.

**Por qué:** hoy, si la segunda llamada falla, el ganador ya quedó grabado y el remate queda a medio liquidar.

**Aceptación:** forzar el fallo de la parte de liquidación (por ejemplo con la guarda de 1.3) y comprobar que **`race_results` no quedó escrito**.

---

### 1.7 · Segunda red en recargas y retiros

**Dónde:** `aprobar_recarga` y `procesar_retiro`.

**Qué:** agregar `and estado = 'pendiente'` al `UPDATE` final de cada una.

**Nota:** el `FOR UPDATE` **ya está** en producción (verificado 27/08). Esto es solo la guarda de respaldo, para que aunque el candado falle el estado no pueda pisarse.

**Aceptación:** revisión de código. Opcional: prueba de doble llamada concurrente que confirme una sola acreditación.

---

### 1.8 · Quitar el bucle de liberación de `cerrar_remate` — ✅ **HECHO Y VERIFICADO (23/09/2026)**

**Dónde:** `cerrar_remate` desplegada (no la del repo, que es distinta).

**Qué:** eliminar por completo el bucle `for r in ... winners/user_max/agg ... v_release`. `cerrar_remate` vuelve a ser solo el cambio de estado, hasta que el bloque 2 la convierta en el momento del cobro.

**Por qué:** `total_blocked` cuenta los caballos donde al usuario ya lo superaron y ya se le devolvió el dinero. Reproducido: libera saldo que debía seguir comprometido, y después **la liquidación falla con "Inconsistencia" y el remate queda trabado en `cerrado`**. Si el usuario fue superado en todos sus caballos, falla el cierre mismo.

Bajo el modelo de bloqueo actual, lo bloqueado al cerrar **ya es** exactamente la suma de las pujas líderes: `hacer_puja` devuelve el dinero en el momento del sobrepuje. **`v_release` debería ser siempre 0.** El bucle no aporta nada y sí rompe.

**Aceptación:** remate con U1 superado en un caballo y líder en otro → cierra sin mover saldos, y liquida sin error.

**Resuelto en** `supabase/migrations/20260923120000_cierre_unificado.sql`. `cerrar_remate` pasó de 108 a 31 líneas: valida rol y delega en `_cerrar_remate_interno`. Verificado contra PostgreSQL real: la prueba **P5** pasa de `Inconsistencia: bloqueado (200) < a cobrar (400)` a verde, con el bloqueado de juan intacto en 400.

---

### 1.9 · Unificar el cierre: el cron y el botón deben hacer lo mismo — ✅ **HECHO Y VERIFICADO (23/09/2026)**

**Verificado:** `auto_cerrar_remates()` hace un `UPDATE` plano y **no** llama a `cerrar_remate`. `llama_a_cerrar_remate = false`, `toca_saldos = false`.

**Qué:**

```sql
create or replace function public.auto_cerrar_remates()
returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare v_count integer := 0; r record;
begin
  for r in
    select id from public.remates
    where estado = 'abierto' and closes_at is not null and closes_at <= now()
    order by closes_at
  loop
    begin
      perform public.cerrar_remate(r.id);   -- la MISMA ruta que el boton del admin
      v_count := v_count + 1;
    exception when others then
      -- un remate que falla no puede tumbar el resto del lote
      insert into public.admin_actions (admin_id, action, target_table, target_id, success, error)
      values (null, 'auto_cerrar_remates', 'remates', r.id::text, false, sqlerrm);
    end;
  end loop;
  return v_count;
end;
$function$;
```

**Por qué es bloqueante:** hoy da igual, porque bajo el modelo actual cerrar no debe mover dinero (ver 1.8). **Pero a partir de la tarea 2.3, cerrar ES el momento del cobro.** Si el cron sigue haciendo un `UPDATE` plano, todo remate que cierre por horario —que es la mayoría— quedará cerrado **sin cobrarle a nadie**, y la liquidación después pagará el premio contra un pozo que nunca se cobró. Es la forma más rápida de vaciar la caja que existe en este sistema.

**Nota de diseño:** `cerrar_remate` valida `es_admin` sobre `auth.uid()`, y el cron corre **sin usuario**. Hay que extraer la lógica a una función interna sin la guarda de rol (`_cerrar_remate_interno(uuid)`), y que tanto `cerrar_remate` (que valida rol) como `auto_cerrar_remates` la llamen. Si no, el cron va a fallar con 'No autenticado' en cada ejecución.

**Aceptación:** un remate cerrado por cron y otro por botón quedan en estado idéntico, con los mismos movimientos de wallet. Un remate que falle al cerrar queda registrado en `admin_actions` y no impide que los demás del lote cierren.

**Resuelto en la misma migración.** Verificado: la prueba **P11** (dos remates idénticos, uno cerrado por botón y otro por cron) pasa de `boton: cerrado con 1 mov | cron: cerrado con 0 mov` a `0 mov` en ambos.

**Corrección extra encontrada al probar el manejador de errores.** El bloque `exception` del cron llama a `log_admin_action` con `admin_id = null`, porque el cron corre sin usuario. Pero `admin_actions.admin_id` era `NOT NULL` **y** `log_admin_action` se traga sus propias excepciones. Comprobado en la base: `log_admin_action(null, ...)` devuelve sin error e inserta **0 filas**. Es decir, el manejador de errores del cron no habría dejado rastro de nada.

La migración hace tres cosas por esto:

1. `admin_id` pasa a ser nullable, con `comment` que fija el significado: **NULL = lo hizo el sistema**.
2. `log_admin_action` conserva el `exception when others` (correcto: un fallo de auditoría no puede tumbar la operación principal) pero ahora emite `raise warning` en vez de desaparecer en silencio.
3. Nueva prueba **P12** como guarda de regresión.

---

### 1.10 · La regla individual del caballo no le ganaba a la general — ✅ **HECHO Y VERIFICADO (23/09/2026)**

**Dónde:** `hacer_puja`, la selección de la regla de incremento.

**Qué pasaba.** La consulta ordenaba así:

```
order by (r.horse_id = p_horse_id) desc, r.min_precio desc
```

La intención es la correcta y es la regla de negocio: **primero la regla del caballo, después la general del remate.** Pero para la regla general `horse_id` es `NULL`, y `NULL = <uuid>` no devuelve `false` — devuelve `NULL`. PostgreSQL, en un `ORDER BY ... DESC`, ordena los `NULL` **primero** (`DESC` implica `NULLS FIRST`). La regla general se colaba al frente de la individual, siempre.

**Reproducido** en PostgreSQL 16, caballo con precio de salida 100:

| aumento general | aumento individual | debía cobrar | cobraba |
|---|---|---|---|
| 20 | 100 | 200 | **120** ❌ |
| 100 | 20 | 120 | **200** ❌ |

Se probaron los dos sentidos a propósito: con un solo caso no se distingue "tomó la general" de "tomó la más chica". Tomaba la general fuera mayor o menor, lo que descarta que fuera una comparación de montos.

**Consecuencia real, no teórica.** El frontend **sí** elegía bien (`pickIncrement` prueba primero `rulesByHorse[horseId]`). O sea que **la pantalla calculaba con la regla individual y la base cobraba con la general**. Donde se veía en la cara del usuario era en el letrero "Puja manual mínima: X Bs": ese X salía del frontend y la base validaba contra otro número. Ver tarea **2.20**.

**Corregido en** `supabase/migrations/20260923130000_regla_individual_gana.sql`:

```
order by (r.horse_id is not null) desc, r.min_precio desc
```

El `WHERE` de arriba ya garantiza que toda fila con `horse_id` no nulo es la de este caballo, así que la expresión separa las dos clases sin producir `NULL` nunca. `desc nulls last` también lo arreglaría, pero deja la lógica de tres valores viva esperando al próximo que lea rápido.

**Verificado:** diff línea a línea de `hacer_puja` antes y después — **cambia exactamente una línea**. Prueba **P13** roja antes, verde después. Ninguna otra prueba se movió (9/13 → 10/13).

**Alcance:** esta migración corrige SOLO la precedencia. No toca el precio de la primera puja, ni `apuesta_minima`, ni el `+10` de la puja manual — eso es 2.17, y va aparte por decisión expresa.

---

## Bloque 2 — Modelo de saldo v2

> Depende de: bloques 0 y 1 completos. **Especificación completa en `DISENO_SALDO_V2.md`** — ese documento es la fuente, aquí solo va el orden y la aceptación.

**Orden obligatorio:**

| # | Tarea | Referencia |
|---|---|---|
| 2.1 | `compromiso_usuario()` + `dinero_casa_disponible()` + los 3 índices | §3, §6.3, §8 |
| 2.2 | `hacer_puja`: guarda de exposición **con candado por usuario** | §6.1 |
| 2.3 | `cerrar_remate`: debita a los líderes | §6.2 |
| 2.4 | `liquidar_remate`: solo paga el premio | §6.3 |
| 2.5 | `cancelar_remate`: dos casos, ambos simples | §6.4 |
| 2.6 | `solicitar_retiro`: `saldo − compromiso`, **con el mismo candado por usuario** | §7 |
| 2.7 | `retirar_caballo()`: RPC nueva | §6.5 |
| 2.8 | Tipos nuevos en `wallet_movement_type`: `apuesta_cobro`, `apuesta_devolucion` | §5 |
| 2.9 | `mi_wallet_resumen()` devuelve total / comprometido / disponible para retirar | §7 |
| 2.10 | Frontend: dashboard, pantalla de retiro y vista de remate muestran los tres números | §7 |
| 2.11 | Los ajustes manuales de admin validan contra el compromiso | §6.7 |
| 2.12 | `update wallets set saldo_bloqueado = 0` — **la columna NO se borra todavía** | §9 |
| 2.13 | **Ruta de salida para un remate `cerrado` que no se puede liquidar** — ver abajo | nueva |
| 2.14 | **Reglas de puja R1–R5** — lo que quede después de 1.10, 2.17 y 2.20: campo manual sin tope y mínimo por acumulación. Decidido 23/09: **no hace falta un botón "Iniciar" aparte**, lo hace el mismo "Ponerle" | §6bis |
| 2.15 | **Requisito de juego (rollover), opción B**: tabla `deposit_lots`, porcentaje configurable por instalación, reversión al devolver dinero | §7ter |
| 2.16 | **Casilla de origen lícito de fondos** en el registro, con texto guardado y fecha de aceptación (`profiles.acepto_origen_licito_at`) | §7ter |
| 2.20 | **El frontend deja de calcular dinero.** RPC que devuelva, por caballo, el mínimo automático y el mínimo manual; la pantalla los muestra y no los recalcula. Hoy `useMemo` de `app/remates/[id]/page.tsx` reimplementa la escalera de precios en TypeScript, y 1.10 demostró que los dos cálculos se separan sin que nadie se entere | nueva |
| 2.18 | **Libro de la casa** (`house_ledger`) + descomposición caja / comprometido / patrimonio + alarma de cobertura | §7quater |
| 2.17 | ✅ **HECHO 23/09/2026** — ver abajo. (a) primera puja al `precio_salida` exacto, (b) fuera el piso `apuesta_minima`, (c) fuera el `+10` del mínimo manual | §6bis R5 |

### 2.13 · El remate trabado en `cerrado` — **deficiencia confirmada**

**El agujero:** hoy un remate que se cierra y **nunca se liquida** no tiene salida. La carrera se suspende, el admin no alcanza a cargar el ganador, o la liquidación falla — y el dinero de los ganadores de puja queda comprometido **indefinidamente**. `cancelar_remate` solo acepta `estado = 'abierto'`, así que tampoco se puede deshacer. La única forma de destrabarlo es meter mano en la base de datos.

Con adelantados que viven de martes a sábado, un remate trabado puede quedarse así un fin de semana entero con la plata de la gente adentro.

**Qué hacer — dos rutas distintas, no una:**

**a) `cancelar_remate` acepta también `cerrado`.** Es la salida definitiva: devuelve a cada usuario exactamente lo que se le cobró al cerrar (los movimientos `apuesta_cobro` con `ref_externa = este remate`), con movimiento `apuesta_devolucion`, y deja el remate en `cancelado`. Requiere motivo y queda en `admin_actions`.

**b) `reabrir_remate(p_remate_id, p_motivo)` — `cerrado` → `abierto`.** Para el caso "lo cerré por error" o "la carrera se corre más tarde". Revierte los cobros igual que (a), pero deja el remate abierto y las pujas intactas, listo para seguir. Solo desde `cerrado`, nunca desde `liquidado`. Requiere motivo y queda en `admin_actions`.

**c) Alarma.** Un remate en `cerrado` por más de N horas sin liquidar (sugerido: 24) genera un aviso. Es la diferencia entre enterarse el lunes y enterarse cuando el usuario reclama.

**Por qué va en el bloque 2 y no en el 1:** la lógica de devolución depende directamente del modelo de saldo. Implementarla ahora contra el modelo actual —liberando `saldo_bloqueado`— y reescribirla en el bloque 2 —revirtiendo los débitos— es escribir lo mismo dos veces. Y no hay riesgo en la ventana intermedia, porque no hay usuarios reales antes de que el bloque 2 esté listo. **Si el lanzamiento se adelanta a la Fase 2, esta tarea sube al bloque 1 de inmediato.**

**Aceptación:**
- Remate cerrado → cancelar → cada usuario recupera exactamente lo cobrado, y la suma de movimientos del remate da 0.
- Remate cerrado → reabrir → saldos restituidos, pujas intactas, estado `abierto`, y se puede volver a pujar.
- Remate `liquidado` → ambas operaciones fallan.
- Remate cerrado hace 25 horas sin liquidar → salta la alarma.

> ### ⚠️ El punto que no se puede omitir
>
> **`hacer_puja` y `solicitar_retiro` deben tomar `pg_advisory_xact_lock(1, hashtext(user_id::text))` antes de leer el compromiso.**
>
> El candado actual es por `remate + caballo` y no sirve aquí, porque esta validación cruza todos los remates de un mismo usuario. Verificado contra PostgreSQL 16: sin ese candado, un usuario con 500 Bs que puja 400 a dos caballos simultáneamente **compromete 800**. Con el candado, la segunda se rechaza.
>
> Orden de candados siempre el mismo —primero usuario, después remate+caballo— para no provocar interbloqueos.

**Aceptación del bloque:** las 13 pruebas de `DISENO_SALDO_V2.md` §11 en verde, **incluida la número 2** (dos pujas simultáneas del mismo usuario desde dos conexiones).

---

### 2.19 · El libro de movimientos no reconstruye el saldo — **encontrado 23/09**

**Dónde:** `wallet_movements`, y todas las funciones que escriben en ella.

**Qué pasa.** La tabla mezcla en una sola columna `monto` dos cosas que no son lo mismo:

| tipo | signo | ¿cambia el saldo total? | ¿de qué columna sale? |
|---|---|---|---|
| `recarga` | + | **sí** | entra a `disponible` |
| `premio` | + | **sí** | entra a `disponible` |
| `retiro` | − | **sí** | sale de `disponible` |
| `apuesta_bloqueo` | + | **no** | mueve `disponible` → `bloqueado` |
| `apuesta_desbloqueo` | + | **no** | mueve `bloqueado` → `disponible` |
| `ajuste_manual` (cobro al ganador) | − | **sí** | sale de `bloqueado` |
| `ajuste_manual` (devolución por cancelación) | + | **no** | mueve `bloqueado` → `disponible` |
| `ajuste_manual` (devolución de retiro rechazado) | + | **sí** | entra a `disponible` |
| `apuesta_liberacion` | — | nunca se usa | — |

Las dos últimas filas positivas son indistinguibles: mismo tipo, mismo signo, efectos distintos. **Con la tabla así, el saldo de una wallet no se puede reconstruir desde su libro sin leer el código que lo escribió.** Para un sistema donde el licenciatario custodia el dinero real de terceros, eso es exactamente lo que no puede pasar: un auditor —o el propio cliente desconfiado— no tiene forma de verificar un saldo contra los asientos.

**Cómo salió.** La prueba P6 original sumaba `monto` de todos los tipos asumiendo que eran deltas con signo. **Error mío**: estaba roja por una razón equivocada, no por un defecto del sistema. Al reescribirla tuve que listar a mano qué tipos cuentan para cada invariante, y esa lista escrita a mano *es* el hallazgo.

**Qué hacer (en el bloque 2, junto al modelo v2).**

1. Con el modelo v2 no hay bloqueo durante el remate, así que `apuesta_bloqueo` y `apuesta_desbloqueo` **desaparecen**: todo movimiento pasa a ser un delta con signo sobre el saldo real. El problema se disuelve solo para lo nuevo.
2. Partir `ajuste_manual` en tipos con significado propio: `cobro_puja`, `devolucion_cancelacion`, `devolucion_retiro`. Un `ajuste_manual` genuino (el admin corrige algo a mano) debe quedar reservado para eso y solo para eso, y exigir motivo.
3. Retirar `apuesta_liberacion` del enum, que nunca se usó.
4. Regla, escrita en un `comment` sobre la tabla: **`monto` es siempre el delta con signo del saldo total del usuario.** Un asiento que no cambia el saldo total no es un asiento.
5. Migración de datos: los movimientos históricos son de pruebas, así que se pueden reclasificar o limpiar sin drama. Para el primer cliente, el libro nace limpio.

**Aceptación:** para toda wallet, `saldo_disponible + saldo_bloqueado = suma(monto)` sobre **todos** los movimientos, sin listas de tipos a mano. Prueba P6 reescrita sin el `where tipo in (...)`.

---

### 2.17 · Reglas de la primera puja y del mínimo manual — ✅ **HECHO 23/09/2026**

**Corregido en** `supabase/migrations/20260923140000_reglas_primera_puja.sql`. Tres cambios en el mismo bloque de `hacer_puja`:

**(a) La primera puja compra al `precio_salida` exacto.** Antes cobraba `precio_salida + incremento`. El argumento que cerró la discusión no fue de gusto sino de coherencia: el caballo que nadie puja se queda con la casa por su `precio_salida` y entra al pozo por ese monto, así que el sistema **ya trataba `precio_salida` como precio de compra real** — pero solo para la casa. Un caballo de 100 le costaba 100 a la casa y 110 al usuario.

**(b) Fuera el piso `apuesta_minima`.** Se aplicaba después de elegir la regla, encima del resultado, para cualquier caballo: era el único parámetro que **no se podía sobreescribir por caballo**, justo lo contrario de la regla de negocio. Reproducido: salida 100 + incremento 10 + `apuesta_minima` 500 → el primer clic cobraba 500.

**(c) Fuera el `+10` del mínimo manual.** La manual acepta desde el mínimo automático.

**Consecuencia registrada:** sobre un caballo virgen de salida 100 con incremento 50, una manual de 120 ahora se acepta, porque el mínimo automático de un caballo virgen es 100. La primera oferta no es un escalón de la escalera: es la compra al precio de salida, y de ahí para arriba vale cualquier monto.

**La columna `apuesta_minima` NO se borró.** Es `NOT NULL` y hasta este deploy el frontend la escribía al crear un remate. Queda huérfana y sin efecto. Se borra en **2.21**, después de que el deploy esté arriba.

**Frontend, cambiado en el mismo paso** (tiene que salir con la migración):

| archivo | qué cambió |
|---|---|
| `app/remates/[id]/page.tsx` | `nextMin` de caballo virgen = `salida`; `manualMin` = `nextMin` (sin `+10`); fuera `minApuesta` y la columna del `select` |
| `app/admin/crear-remate/page.tsx` | el campo pasa a llamarse **"Salida por defecto"** y **ya no se guarda en la base**: solo precarga el `precio_salida` de cada caballo, que era su uso real |
| `app/admin/remates/[id]/page.tsx` | fuera el campo, su validación y la columna del `select`; el caballo nuevo arranca con el precio vacío |

**Orden de despliegue: primero la migración, después el deploy.** Al revés no. Si sale el frontend primero, la pantalla muestra `salida` y la base todavía cobra `salida + incremento`. Con la migración primero, el botón "Ponerle" ya cobra bien (manda `es_manual = false` y la base calcula sola) y lo único desfasado por unos minutos es el letrero del mínimo manual, que queda más alto de lo debido — un fallo conservador: rechaza pujas legales, pero no cobra de más.

**Verificado:** P14 y P15 rojas antes, verdes después. **P13 se rompió con este cambio y hubo que reescribirla**: su escenario pujaba una sola vez sobre un caballo virgen, y desde (a) la primera puja no consulta ninguna regla de incremento. Ahora puja dos veces y mide la segunda. Se comprobó que la versión nueva sigue detectando la regresión de 1.10 volviendo a poner el `ORDER BY` roto a mano.

**Marcador: 12 verdes / 3 rojas de 15.**

---

### 2.21 · Borrar la columna `apuesta_minima` — **pendiente, después del deploy de 2.17**

`alter table public.remates drop column apuesta_minima;`

No antes: es `NOT NULL` y cualquier versión del frontend anterior a 2.17 la escribe al crear un remate. Con el deploy arriba y comprobado que se pueden crear carreras, la columna se cae sin ruido.

---

## Bloque 3 — Blindaje de escritura

> Depende de: bloques 0-2. **Es el bloque que convierte la app en algo que puede operar alguien que no seas tú.**

### 3.1 · Corregir las FK en CASCADE — **CONFIRMADO 28/08. MÁXIMA PRIORIDAD DE TODA LA FASE 1**

**Verificado en producción.** Las ocho claves foráneas del núcleo están en `ON DELETE CASCADE`:

| Hija | Padre | Efecto de borrar el padre |
|---|---|---|
| `horses` | `races` | se borran los caballos |
| `remates` | `races` | se borran los remates |
| `race_results` | `races` | se borra el resultado |
| **`bids`** | **`horses`** | **se borran las pujas** |
| **`bids`** | **`remates`** | **se borran las pujas** |
| `remate_price_rules` | `horses` / `remates` | se borran las reglas |
| `race_results` | `horses` | se borra el resultado |

**Qué significa concretamente:** la pantalla `app/admin/remates/[id]` tiene un botón que borra caballos, sin ninguna guarda. Borrar un caballo que tiene pujas **elimina esas pujas**, y el `saldo_bloqueado` de esos usuarios **queda huérfano para siempre**: no queda ninguna puja que lo pueda liberar, la liquidación no lo va a encontrar, y la cancelación tampoco. Dinero congelado de forma irreversible, sin ningún rastro de por qué.

Borrar una **carrera** es peor: arrastra remates, caballos, pujas y resultados de una sola vez.

**Es la cosa más destructiva del sistema hoy.** Lo único que la contiene es que no hay usuarios reales todavía.

**Qué hacer:**

```sql
-- El dinero manda: si hay pujas, la base rechaza el borrado.
alter table public.bids drop constraint bids_horse_id_fkey;
alter table public.bids add  constraint bids_horse_id_fkey
  foreign key (horse_id) references public.horses(id) on delete restrict;

alter table public.bids drop constraint bids_remate_id_fkey;
alter table public.bids add  constraint bids_remate_id_fkey
  foreign key (remate_id) references public.remates(id) on delete restrict;

alter table public.remates drop constraint remates_race_id_fkey;
alter table public.remates add  constraint remates_race_id_fkey
  foreign key (race_id) references public.races(id) on delete restrict;

alter table public.horses drop constraint horses_race_id_fkey;
alter table public.horses add  constraint horses_race_id_fkey
  foreign key (race_id) references public.races(id) on delete restrict;

alter table public.race_results drop constraint race_results_ganador_horse_id_fkey;
alter table public.race_results add  constraint race_results_ganador_horse_id_fkey
  foreign key (ganador_horse_id) references public.horses(id) on delete restrict;
```

`remate_price_rules` y `race_results → races` **pueden quedar en `CASCADE`**: no contienen dinero y su borrado en cadena es el comportamiento deseado cuando efectivamente se elimina una carrera vacía.

**Aceptación:** insertar una puja, intentar borrar ese caballo, y comprobar que la base lo rechaza con error de FK. Intentar borrar la carrera y comprobar que también la rechaza.

---

### 3.2 · RPC `editar_remate` y cierre de la escritura directa

**Qué:**
1. Una RPC transaccional que reciba los cambios de carrera, remate y caballos, y valide:
   - remate `programado` → se puede editar todo
   - remate `abierto` **sin pujas** → se puede editar todo
   - remate `abierto` **con pujas** → solo campos que no afectan dinero (nombre, comentarios, jinete, entrenador) y marcar `retirado`
   - remate `cerrado`, `liquidado` o `cancelado` → nada
   - **`estado` nunca es editable por esta vía.** Solo por las RPC de transición.
2. `revoke update, delete, insert on public.races, public.remates, public.horses from authenticated` y dejar solo `select`.
3. Reescribir `app/admin/remates/[id]/page.tsx` y `app/admin/crear-remate/page.tsx` para usar las RPC.

**Por qué:** hoy un admin puede, con un remate abierto y con pujas, cambiar el `precio_salida` de un caballo ya pujado, cambiar la comisión, mover los horarios, borrar caballos, y **escribir `estado` directamente saltándose `cerrar_remate` y `liquidar_remate` con todas sus validaciones**. Marcar un remate como `liquidado` sin que la liquidación corra deja el dinero de todos comprometido para siempre.

**Aceptación:** desde el navegador, con sesión de admin, un `supabase.from("remates").update({estado:'liquidado'})` debe ser **rechazado por RLS**.

---

### 3.3 · Constraints en la base

```sql
alter table public.horses  add constraint horses_precio_positivo   check (precio_salida > 0);
alter table public.remates add constraint remates_ventana_valida   check (closes_at is null or opens_at is null or closes_at > opens_at);
alter table public.remates add constraint remates_pct_valido       check (porcentaje_casa between 0 and 100);
alter table public.remates add constraint remates_apuesta_positiva check (apuesta_minima > 0 and incremento_minimo > 0);
alter table public.race_results add constraint race_results_una_por_carrera unique (race_id);
```

**Por qué:** hoy toda la validación vive en `canSave` del navegador. La base acepta `precio_salida = 0` o `closes_at < opens_at` sin chistar.

**Aceptación:** cada `insert` inválido es rechazado por la base.

---

### 3.4 · Bitácora completa en `admin_actions`

**Qué:** que **toda** RPC que mueva dinero o edite un remate escriba en `admin_actions`: quién, qué, cuándo, con qué parámetros, y si tuvo éxito o falló.

**Estado actual:** la tabla tiene 15 registros, así que ya se usa en alguna parte. Falta cobertura completa.

**Aceptación:** ejecutar una de cada operación y comprobar que las 8 quedan registradas, incluidos los intentos fallidos.

---

### 3.5 · Roles granulares — **NO POSTERGABLE**

Decisión de Miguel Ángel (28/08/2026): el servicio se cobra desde el primer día y no puede entregarse condicionado a que el cliente opere con una sola cuenta de admin.

#### Punto de partida: ya existe más de lo que parecía

El baseline reveló dos funciones que no estaban en ningún script del repo y que **ya implementan el patrón correcto**:

- **`set_admin(p_user_id, p_is_admin)`** — exige `es_super_admin`, valida parámetros, comprueba que el usuario exista, y **escribe en `admin_actions`**. Es exactamente el patrón "los roles se otorgan solo por RPC" que iba a proponer desde cero.
- **`log_admin_action(...)`** — `SECURITY DEFINER`, con un detalle bien pensado: atrapa cualquier excepción y la descarta, para que **un fallo de auditoría no tumbe la operación principal**. Decisión correcta y deliberada.

Entonces esta tarea **no es construir desde cero**, es extender lo que ya funciona:

1. Pasar de binario (`es_admin` / `es_super_admin`) a los cuatro roles.
2. Generalizar `set_admin` a `asignar_rol(p_user_id, p_rol, p_expira_at)`, conservando su estructura.
3. **Cubrir con `log_admin_action` todas las RPC de dinero**, que es donde falta — hoy solo hay 15 registros en `admin_actions`.

#### Los dos ejes: no es una escalera

Hoy `es_admin` y `es_super_admin` son una escalera: el super hace todo lo del admin y algo más. Al licenciar, esa escalera deja de servir, porque **hay dos jerarquías que no se pueden mezclar**:

| Eje | Quién | Dónde vive |
|---|---|---|
| **Operación** | El personal del cliente: quien arma remates, quien maneja el dinero, y el dueño del negocio | Dentro de cada instalación, en `user_roles` |
| **Proveedor** | Jercol / Miguel Ángel, dueño del software | **Fuera de la app.** En el panel de Supabase y en el panel de licencias |

**El super_admin de hoy se convierte en el `owner` de cada cliente — y ese owner es el cliente, no tú.**

#### Por qué tú NO debes tener una cuenta permanente dentro de la app del cliente

En el modelo híbrido que elegiste, cada cliente tiene su propia base de datos. Tú ya tienes acceso total por el panel de Supabase: es tu infraestructura. Crearte además un rol de superusuario **dentro** de la app sería lo peor de los dos mundos.

Lo dijiste tú mismo: *"por mí no va a pasar dinero de nadie"*. Ese es el argumento más fuerte de tu posición, y **un rol tuyo con capacidad de escribir sobre las wallets del cliente lo destruye**. Si el sistema te permite mover saldos, ningún disclaimer arregla eso: la capacidad técnica existe y queda registrada en el esquema. Lo que te conviene, y no es solo prudencia legal sino buen diseño, es que **el software no te dé ninguna forma de tocar el dinero de tus clientes.**

#### Roles dentro de la instalación

```sql
create type public.app_role as enum ('operador','finanzas','owner','soporte');

create table public.user_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  rol        public.app_role not null,
  granted_by uuid,
  granted_at timestamptz not null default now(),
  expira_at  timestamptz            -- solo se usa en 'soporte'
);
alter table public.user_roles enable row level security;
-- sin politica de escritura para authenticated: se otorga solo por RPC
revoke insert, update, delete on public.user_roles from authenticated;
```

| Puede | operador | finanzas | owner | soporte |
|---|:--:|:--:|:--:|:--:|
| Crear / editar / abrir / cerrar remates | ✅ | — | ✅ | 👁 |
| Marcar caballo retirado, fijar ganador | ✅ | — | ✅ | 👁 |
| Liquidar remate (mueve dinero) | — | ✅ | ✅ | 👁 |
| Aprobar recargas · procesar retiros | — | ✅ | ✅ | 👁 |
| Ver wallets y contabilidad | — | ✅ | ✅ | 👁 |
| Ajuste manual de saldo | — | — | ✅ | ❌ |
| Otorgar y revocar roles | — | — | ✅ | ❌ |
| Pujar | ❌ | ❌ | ❌ | ❌ |

👁 = **solo lectura, sin excepción.**

#### El rol `soporte`: tu única puerta, y con llave del cliente

- Solo el `owner` de la instalación puede otorgarlo. **Tú no puedes autoasignártelo.**
- Es **estrictamente de lectura**. No aparece en el `using` de ninguna política de escritura, ni en el `grant execute` de ninguna RPC que mueva dinero.
- Tiene `expira_at` obligatorio, máximo 72 horas, y un job lo revoca al vencer.
- **Todo** lo que hace queda en `admin_actions`, incluidas las lecturas de wallets.
- El cliente lo otorga cuando te pide ayuda y lo revoca cuando quiera.

Así, cuando tu cliente pregunte *"¿tú puedes ver mi plata?"*, la respuesta es concreta y verificable en el esquema: solo si él te da acceso, solo de lectura, solo por 72 horas, y con registro de cada cosa que miraste.

#### Reglas de la migración

- `es_admin` y `es_super_admin` se **retiran de `profiles`** una vez migrados. Dos fuentes de verdad para el mismo permiso es exactamente por donde se cuelan los agujeros.
- `is_admin()` se conserva como `exists (select 1 from public.user_roles where user_id = auth.uid() and rol <> 'soporte')`, para no reescribir todas las políticas RLS de golpe. Se agregan `tiene_rol(text)` y `es_owner()`.
- Los roles se otorgan solo por RPC `asignar_rol(p_user_id, p_rol, p_expira_at)` que exige `owner` y escribe en `admin_actions`.
- El trigger de inmutabilidad que ya protege `profiles` se replica sobre `user_roles`.
- Cada RPC de dinero cambia su guarda de `es_admin` a `tiene_rol('finanzas') or es_owner()`.

**Aceptación:**
- Una cuenta `operador` recibe error al llamar `aprobar_recarga` y `liquidar_remate`, y puede crear y cerrar un remate.
- Una cuenta `finanzas` recibe error al llamar `crear_remate_completo`.
- Una cuenta `soporte` puede leer wallets y **recibe error en toda operación de escritura**.
- Una cuenta `soporte` con `expira_at` vencido no puede leer nada.
- Ninguna cuenta con rol puede ejecutar `hacer_puja`.

---

## Bloque 4 — Creación de carreras

> Depende de: bloque 3 (comparte la RPC y el cierre de escritura directa).

### 4.1 · RPC `crear_remate_completo(p_payload jsonb)`

**Qué:** una sola transacción que reciba carrera + caballos + reglas y las cree, con toda la validación del lado del servidor.

**Por qué:** hoy son cuatro `insert` sueltos desde el navegador. Lo dice el propio código en `app/admin/crear-remate/page.tsx` línea 440: *"Sin RPC transaccional, esto NO es atómico"*. Si falla el cuarto paso, queda un remate abierto y visible al público con caballos y sin reglas de incremento.

**Aceptación:** forzar el fallo en el paso de reglas y comprobar que **no queda ninguna carrera ni remate creado**.

### 4.2 · Estado `programado`, apertura automática y **autocierre opcional**

**Decisión de Miguel Ángel (22/09/2026):** el autocierre pasa a ser **opcional y a criterio del admin**, apagado por defecto.

**Por qué cambió:** los remates **adelantados** se montan el martes por la noche o el miércoles temprano y pueden seguir abiertos hasta el viernes, o hasta el sábado mismo en el caso de La Rinconada. Un `closes_at` que cierra solo es correcto para un remate **en vivo** y **peligroso** para un adelantado: cierra las pujas a mitad de semana, cuando el operador esperaba tenerlas abiertas tres días más.

**Qué:**

```sql
alter table public.remates
  add column if not exists autocierre boolean not null default false;
```

1. **`closes_at` con `autocierre = false`** pasa a ser informativo: *"hora estimada de cierre"*. Se muestra al usuario, no dispara nada. La validación de `hacer_puja` sobre `closes_at` **se mantiene** — un remate no acepta pujas pasada su hora, aunque siga en `abierto`.
2. **El cron solo cierra** remates con `autocierre = true`:
   ```sql
   where estado = 'abierto' and autocierre = true
     and closes_at is not null and closes_at <= now()
   ```
3. **En el formulario de crear/editar:** una casilla *"Cerrar automáticamente a la hora programada"*, **desmarcada por defecto**. Sugerida para `tipo = 'vivo'`, desaconsejada para `tipo = 'adelantado'` (con una nota visible al lado).
4. **Apertura automática** (lo que ya estaba): el remate nace `programado` y el cron lo pasa a `abierto` cuando llega `opens_at`. Esto **no** es opcional — abrir a la hora prevista es siempre lo deseado.

**Aceptación:**
- Remate con `autocierre = false` y `closes_at` vencido → **sigue en `abierto`**, el cron no lo toca, y `hacer_puja` rechaza pujas nuevas.
- Remate con `autocierre = true` y `closes_at` vencido → cierra por cron, por la misma ruta que el botón (ver 1.9).
- Remate con `opens_at` a 2 minutos → pasa de `programado` a `abierto` solo.

### 4.4 · Precio de salida general en el formulario, con "aplicar a todos"

**Decidido 23/09/2026.** El precio general **vive en el formulario, no en la base.** Es la diferencia que hundió a `apuesta_minima`: aquel era un piso que se leía **al momento de pujar** y pisaba el precio del caballo en cada clic; este es un valor que se copia dentro del `precio_salida` de cada caballo **al momento de crear** y después nadie lo vuelve a leer. Una cosa sobreescribe al caballo para siempre, la otra lo rellena una vez y se aparta.

**Por qué no lleva columna.** Una columna llamada "precio por defecto" conviviendo con las columnas que guardan la verdad es una invitación a que alguien, dentro de seis meses, la lea en el momento equivocado — que es literalmente el bug de 2.17. Y para el import (4.5) tampoco hace falta: el importador recibe el precio como parámetro y escribe el `precio_salida` real de cada caballo.

**El hueco que hay hoy.** El campo "Salida por defecto" de `app/admin/crear-remate/page.tsx` solo se aplica **en el instante en que se agrega un caballo**. Si el admin agrega los doce caballos y después escribe el precio general, no pasa nada: los doce ya nacieron con el campo vacío. Y ese es justamente el orden en que se llena el formulario en la vida real.

**Qué hacer:**

1. Botón **"aplicar a todos"** al lado del campo, que escribe ese precio en todos los caballos ya cargados de la lista.
2. Que siga precargando cada caballo nuevo, como ahora.
3. Lo mismo en la pantalla de edición (`app/admin/remates/[id]/page.tsx`), que hoy no tiene campo equivalente: ahí el caballo nuevo arranca con el precio vacío.

**Aceptación:** cargar 12 caballos, escribir el precio general, pulsar "aplicar a todos" → los 12 quedan con ese precio. Cambiar dos a mano → esos dos conservan el suyo y el botón no se vuelve a pulsar solo. Nada de esto toca la base: `remates` no gana ninguna columna.

---

### 4.5 · Importar la programación de una carrera — **dos capas, en este orden**

**Decidido 23/09/2026.** La captura de datos es donde el admin quema tiempo y mete errores, así que atacarla es correcto. Pero la arquitectura va al revés de lo que parece:

**Capa 1 — el formato y el import manual (esto es lo que se construye).** Se define un formato de importación (CSV o pegado de texto) con la carrera y sus caballos: número, nombre, jinete, precio de salida. El admin lo sube y el sistema arma la carrera completa. Funciona pase lo que pase con cualquier página de terceros, y **es lo que se le vende al licenciatario**.

**Capa 2 — el scraper (opcional, encima, y después).** Un scraper del INH u otra fuente que produzca *ese mismo archivo*. Si se cae o la página cambia, el import manual sigue funcionando y nadie se queda sin operar.

**Por qué en ese orden, y no al revés.** Un scraper ata el producto a que la página de un tercero no cambie. Al licenciarlo, cada cliente pasa a depender de que Jercol mantenga ese scraper vivo: es una **obligación de soporte que no se está cobrando**. Con el import manual de base, el scraper es una comodidad, no un punto único de fallo.

**Pendiente antes de prometer nada:** mirar la página del INH con ojos propios — estructura, estabilidad y términos de uso. **No hay ninguna verificación hecha sobre esto al 23/09/2026.**

---

### 4.3 · Alarma sobre el cron

**Qué:** un heartbeat que avise si `auto_cerrar_remates` deja de ejecutarse.

**Por qué:** si el cron se cae, el síntoma es que **los remates siguen aceptando pujas después de que la carrera corrió**. Y a partir de 2.3 el cierre además mueve dinero, así que un cron caído deja de ser un problema cosmético.

**Aceptación:** desactivar el job en staging y comprobar que llega la alerta.

---

## Resumen de dependencias

```
Bloque 0  (base)
   └─> Bloque 1  (cálculo)
          └─> Bloque 2  (saldo v2)
                 └─> Bloque 3  (blindaje)
                        └─> Bloque 4  (creación de carreras)
```

Ningún bloque arranca sin el anterior cerrado y sus pruebas en verde.

## Estado al cierre del bloque 1 — 23/09/2026

**Bloque 1 cerrado.** Arnés: **12 verdes / 3 rojas de 15**. Build de Next.js limpio (TypeScript OK, 25/25 páginas).

Las 3 rojas son defectos reproducidos a propósito, no regresiones: **1.1** (caballo retirado en el pozo), **1.2** (`porcentaje_casa` ignorado) y **1.3** (sin guarda de solvencia). Las tres quedan absorbidas por el bloque 2, porque tocan `liquidar_remate`, que el modelo v2 reescribe entera.

Migraciones del bloque 1, en orden:

| archivo | qué trae |
|---|---|
| `20260922120000_fix_enum_apuesta_desbloqueo.sql` | el valor de enum que faltaba — sin él el sobrepuje nunca funcionó |
| `20260923100000_fk_restrict_dinero.sql` | cinco FK de CASCADE a RESTRICT |
| `20260923110000_contabilidad_y_guardas.sql` | retiros pendientes en la contabilidad, guardas en los UPDATE, fuera `resumen_casa` |
| `20260923120000_cierre_unificado.sql` | una sola ruta de cierre, sin liberación de saldos; `admin_id` nullable |
| `20260923130000_regla_individual_gana.sql` | la regla del caballo le gana a la general |
| `20260923140000_reglas_primera_puja.sql` | primera puja al precio de salida, fuera `apuesta_minima` y el `+10` |

**PENDIENTE ANTES DEL BLOQUE 2: nada de esto está en producción todavía.** Todo se ha probado contra la base local con `npx supabase db reset`. Falta `npx supabase db push` y el deploy del frontend, **en ese orden** (ver 2.17).

---

## Riesgo estructural anotado para la Fase 2 — custodia del dinero

Planteado por Miguel Ángel (23/09/2026). **No es un defecto de código, es un riesgo del modelo de licencia**, y tiene dos caras.

### a) El dinero vive en la cuenta del licenciatario

Por más que el sistema muestre caja, comprometido y patrimonio, **toda esa plata está en la cuenta bancaria del licenciatario y él puede hacer con ella lo que quiera.** A Jercol no la afecta directamente —el dinero nunca pasa por ahí— pero **sí afecta a la marca**: si un licenciatario hace una locura, el software lleva su nombre.

Pendiente de investigar: **pasarelas de pago en Venezuela**, para automatizar recargas y retiros y reducir la manipulación manual. Hoy todo es transferencia manual aprobada a mano.

### b) Y este SÍ es un hueco del sistema: no hay prueba de pago

Un retiro pasa de `pendiente` a `pagado` porque **un admin aprieta un botón**. No se pide referencia de la transferencia, ni comprobante, ni nada. Dos formas concretas de que la contabilidad se despegue de la realidad:

| Qué pasa | Consecuencia |
|---|---|
| Se aprueba el retiro pero **nunca se marca como pagado** | El usuario ya tiene el saldo descontado, el dinero nunca salió, y `retiros_pendientes` crece para siempre sin que nadie mire |
| Se marca como **pagado sin haber transferido** | La contabilidad dice que se pagó. El usuario dice que no recibió. No hay forma de dirimir |

**Lo que hace falta, y es barato:**

1. **Referencia de pago obligatoria** al marcar `pagado`: número de operación, banco, fecha. Sin eso, la RPC rechaza.
2. **Alarma de antigüedad**: un retiro en `pendiente` por más de N horas genera aviso. Hoy puede quedarse ahí indefinidamente sin que nadie se entere.
3. **Comprobante adjunto** (opcional, evaluar): captura de la transferencia en Storage, ligada a la solicitud.

Los puntos 1 y 2 protegen al licenciatario honesto de su propio desorden, que es el caso frecuente — mucho más que el fraude.

---

## Fuera de alcance de la Fase 1

Va a Fase 2 (licenciamiento): configuración por instalación (`app_settings`), marca configurable, zona horaria IANA, SMTP y datos bancarios por cliente, script de aprovisionamiento, panel de licencias.

Va a Fase 3 (producto): Realtime en la vista de remate, plantillas de jornada, clonar carrera, carga masiva de caballos, correo al usuario, límite de tasa, Sentry.

> **`nodemailer`** (reemplazo del cliente SMTP escrito a mano sobre socket TLS, que no tiene timeout y puede colgar la función serverless) está en Fase 3, pero es de las más baratas de adelantar si sobra tiempo en cualquier bloque.
