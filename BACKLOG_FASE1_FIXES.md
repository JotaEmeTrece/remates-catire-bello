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

**Casos mínimos iniciales** (los del bloque 2 se agregan en su momento):

| # | Escenario | Esperado |
|---|---|---|
| P1 | Liquidar con un caballo retirado que tenía puja | El retirado no entra al pozo |
| P2 | Liquidar con `porcentaje_casa = 30` | Premio = 70% del pozo |
| P3 | Liquidar cuando el ganador no tuvo puja | Premio 0, casa se queda el pozo |
| P4 | Liquidar con premio mayor que la caja | Falla con excepción, no acredita |
| P5 | Suma de `wallet_movements` de una wallet vs su `saldo_disponible` | Cuadran al céntimo |

**Aceptación:** las 5 corren en verde contra staging con el baseline aplicado. P1, P2 y P4 deben fallar **antes** de aplicar el bloque 1 — si pasan de entrada, la prueba está mal escrita.

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

### 1.8 · Quitar el bucle de liberación de `cerrar_remate` — **URGENTE**

**Dónde:** `cerrar_remate` desplegada (no la del repo, que es distinta).

**Qué:** eliminar por completo el bucle `for r in ... winners/user_max/agg ... v_release`. `cerrar_remate` vuelve a ser solo el cambio de estado, hasta que el bloque 2 la convierta en el momento del cobro.

**Por qué:** `total_blocked` cuenta los caballos donde al usuario ya lo superaron y ya se le devolvió el dinero. Reproducido: libera saldo que debía seguir comprometido, y después **la liquidación falla con "Inconsistencia" y el remate queda trabado en `cerrado`**. Si el usuario fue superado en todos sus caballos, falla el cierre mismo.

Bajo el modelo de bloqueo actual, lo bloqueado al cerrar **ya es** exactamente la suma de las pujas líderes: `hacer_puja` devuelve el dinero en el momento del sobrepuje. **`v_release` debería ser siempre 0.** El bucle no aporta nada y sí rompe.

**Aceptación:** remate con U1 superado en un caballo y líder en otro → cierra sin mover saldos, y liquida sin error.

---

### 1.9 · Unificar el cierre: el cron y el botón deben hacer lo mismo — **CONFIRMADO 22/09 · BLOQUEANTE DEL BLOQUE 2**

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
| 2.14 | **Reglas de puja R1–R5**: botón "Iniciar" (primera puja al precio de salida), campo manual sin tope, alinear frontend con SQL, resolver el choque con `apuesta_minima` | §6bis |
| 2.15 | **Requisito de juego (rollover), opción B**: tabla `deposit_lots`, porcentaje configurable por instalación, reversión al devolver dinero | §7ter |
| 2.16 | **Casilla de origen lícito de fondos** en el registro, con texto guardado y fecha de aceptación (`profiles.acepto_origen_licito_at`) | §7ter |
| 2.17 | **Eliminar `apuesta_minima`**: quitar el piso de `hacer_puja` y el campo de los dos formularios. La columna se deja sin uso y se borra en una migración posterior | §6bis R5 |

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

## Fuera de alcance de la Fase 1

Va a Fase 2 (licenciamiento): configuración por instalación (`app_settings`), marca configurable, zona horaria IANA, SMTP y datos bancarios por cliente, script de aprovisionamiento, panel de licencias.

Va a Fase 3 (producto): Realtime en la vista de remate, plantillas de jornada, clonar carrera, carga masiva de caballos, correo al usuario, límite de tasa, Sentry.

> **`nodemailer`** (reemplazo del cliente SMTP escrito a mano sobre socket TLS, que no tiene timeout y puede colgar la función serverless) está en Fase 3, pero es de las más baratas de adelantar si sobra tiempo en cualquier bloque.
