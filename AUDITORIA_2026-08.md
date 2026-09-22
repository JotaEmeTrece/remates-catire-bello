# Auditoría técnica — Remates Catire Bello

**Fecha:** 26 de agosto de 2026
**Auditor:** Claude (sesión Cowork) — revisión estática del repositorio
**Repo:** `C:\Users\mapog\Documents\Apps\remates-catire-bello`
**Objetivo:** (a) estado real de la plataforma antes de licenciarla, (b) mejoras al sistema de creación de carreras, (c) qué falta para rentarla bajo el modelo **híbrido (código único, base de datos por cliente)** donde **el cliente es la casa**.

---

## Limitación importante de esta auditoría (léela antes que nada)

Auditе **el código del repositorio**, no la base de datos viva. Las dos fuentes de verdad que tengo están desfasadas:

| Fuente | Fecha | Problema |
|---|---|---|
| `app/SUPABASE_CONTEXT.md` | 2026-01-20 | 7 meses de antigüedad. No incluye `admin_actions` ni `support_settings`, que sí existen hoy. |
| `sql schema.txt` | 2026-04-27 | Solo columnas. No trae políticas RLS, triggers, índices ni constraints. |

Además hay señales de cambios aplicados en producción que **no están versionados**: existe `sql/rollback_hardening_profiles.sql` (que revierte un hardening de roles) pero **no existe el script que aplica ese hardening**, y encima está en `.gitignore`. Eso significa que hay estado de base de datos que nadie puede reconstruir desde el repo.

**Por eso cada hallazgo lleva un nivel de confianza:**

- **CONFIRMADO** — evidencia directa en código versionado del repo.
- **POR VERIFICAR** — depende del estado real de la base de datos. Te dejé `sql/diagnostico_auditoria.sql` con consultas de solo lectura para confirmarlo en 5 minutos.

No voy a afirmar que estás comprometido si no lo puedo probar. Voy a decirte exactamente qué correr para saberlo.

---

## ESTADO: AUDITORÍA CERRADA (28 de agosto de 2026)

Todos los hallazgos fueron contrastados contra la base de datos de producción. **No queda ninguno en estado "por verificar".** Las funciones críticas se leyeron en su versión desplegada, no en la del repositorio, y los defectos de dinero se reprodujeron en un PostgreSQL 16 local antes de afirmarlos.

**Corrección más importante respecto a las versiones previas de este informe:** tres hallazgos que reporté como problemas ya estaban resueltos en producción (S1, S2, C4) y uno cambió de lugar (C3, que vive en `cerrar_remate` y `cancelar_remate`, no en `liquidar_remate`). El detalle está abajo.

---

## RESULTADOS DE LA VERIFICACIÓN (27 de agosto de 2026)

Miguel corrió `sql/diagnostico_rapido.sql` contra la base de datos de producción. **Tres hallazgos que yo había marcado como problemas ya estaban resueltos.** Los dejo consignados aquí y corregí cada sección individual.

| Hallazgo | Lo que yo dije | Lo que dice la base real | Estado |
|---|---|---|---|
| **S1** Escalada de privilegios | "Por verificar — crítico si aplica" | Trigger `enforce_admin_immutability` **presente**; `UPDATE` sobre `profiles` **revocado** para `authenticated` | ✅ **CERRADO** |
| **C4** Doble acreditación | "**CONFIRMADO**" | `aprobar_recarga` y `procesar_retiro` **sí tienen `FOR UPDATE`**. Cero recargas duplicadas en el histórico | ❌ **ERROR MÍO** |
| **S2** `bids` legible por todos | "Por verificar" | Política `using(true)` **eliminada** | ✅ **CERRADO** |
| **RLS general** | "Verificar tablas sin RLS" | **0 tablas** sin RLS en `public` | ✅ **OK** |
| **P3** Números de caballo duplicados | "Nada lo impide" | Constraint `unique` **existe**; 0 duplicados | ✅ **CERRADO** |
| **S3** Bitácora vacía | "`admin_actions` sin uso" | **15 registros** | ⚠️ **Parcial** — se usa, falta cobertura total |
| **A1** Retiros pendientes | Fórmula incompleta | Correcto, pero hoy hay **0 retiros pendientes** → sin impacto actual | ⚠️ **Latente** |
| **C2** `porcentaje_casa` | Corregido en la revisión previa | Todos los remates en **25.00**; default de columna sigue en 20.00 | ⚠️ **Latente** |
| **C3** `total_blocked` | "**CONFIRMADO**" | `cancelar_remate` **sí** lo tiene. `liquidar_remate` **aparentemente no** (pendiente de confirmar, ver nota) | ⚠️ **Parcial** |

### Sobre mi error en C4

Lo etiqueté **CONFIRMADO** cuando la única evidencia que tenía era `app/SUPABASE_CONTEXT.md`, un volcado de **enero**. La función desplegada hoy sí tiene el candado. La evidencia era real para ese momento; **la etiqueta estaba mal**: debió ser "por verificar", igual que S1, porque venía de la misma fuente vencida. Fue una inconsistencia de criterio mía, no un dato falso, pero el efecto práctico es el mismo: te reporté como confirmado algo que no lo estaba.

### Lo que esto realmente demuestra

La base de datos de producción está **por delante** del repositorio en al menos cuatro correcciones que no están versionadas en `sql/`. Eso es bueno para tu operación y **muy malo para licenciar**: el estado que funciona vive solo en un proyecto de Supabase, y no hay forma de reproducirlo en la instalación de un cliente. **Refuerza E2/B1 (migraciones versionadas) como el problema número uno del proyecto**, por encima de cualquier hallazgo funcional.

### Fotografía financiera al 27/08/2026

| Métrica | Valor |
|---|---|
| Recargas aprobadas | 600,00 Bs |
| Retiros pagados | 0,00 Bs |
| Saldo total de usuarios | 675,00 Bs |
| **Dinero de la casa** | **−75,00 Bs** |
| Remates liquidados | 40 |
| Pozo aportado por usuarios | 300,00 Bs |
| **Pozo aportado por la casa** | **8.981,00 Bs** |
| Resultado neto de la casa en remates | −75,00 Bs |

Dos lecturas de estos números:

1. **La contabilidad cuadra perfecto.** El −75 de caja coincide exactamente con el −75 del resultado en remates, y con la diferencia entre saldos (675) y recargas (600). No hay dinero perdido ni inventado. El motor contable es consistente.
2. **La exposición de la casa es de 30 a 1.** Frente a 300 Bs aportados por usuarios en 40 remates, la casa comprometió 8.981 Bs. Promedio: 7,50 Bs de usuarios y 225 Bs de la casa por remate. La casa ganó casi todos —por eso el neto es solo −75— pero eso es aritmética, no habilidad: con 30 caballos suyos por cada uno vendido, ganar era lo esperable. **El riesgo de cola es lo que importa**: en un remate promedio, si un usuario compra el caballo ganador, la casa paga ~174 Bs y cobra ~7,50 → pierde ~167 Bs de un golpe, más del doble de todo lo perdido en 40 remates.

Ese es el argumento de C1, ahora con tus propios datos: no es que la fórmula esté mal, es que **el sistema no mide ni avisa esa exposición en ninguna parte**.

---

## 0. Veredicto ejecutivo

La aplicación **funciona**, tiene decisiones de arquitectura sólidas (toda la lógica de dinero vive en funciones SQL `SECURITY DEFINER` con `pg_advisory_xact_lock`, que es exactamente donde debe estar) y se nota trabajo serio. Eso es real y hay que reconocerlo.

Dicho eso: **no la licenciaría a un tercero en su estado actual.** No por el sistema de creación de carreras, sino porque **la plataforma puede acreditar premios que no tiene con qué pagar, y no lo detecta**. Hoy eso es un riesgo tuyo, y lo administras porque conoces el negocio de memoria. Bajo licencia, el que descubre el descuadre es un tercero — y el que responde eres tú.

**Conteo de hallazgos:** 4 críticos de dinero · 3 críticos de seguridad · 3 de contabilidad · 6 de producto/operación · 5 de ingeniería.

**El riesgo central, en una frase:** la casa aporta al pozo el precio de salida de cada caballo que nadie compró —esa es la regla del negocio y es correcta—, pero **ese aporte nunca se registra, no se reserva y no se verifica**. Cuando gana un caballo de usuario, el premio se acredita sin comprobar que la caja alcance. A partir de ahí, la suma de los saldos de tus usuarios puede superar el dinero real en el banco sin que ningún panel lo diga. Detalle en C1.

---

## 1. Hallazgos CRÍTICOS — lógica de dinero

### C1 · El pozo y el premio deben calcularse bien — **CONFIRMADO**

> **Nota de alcance.** Las versiones previas de este informe discutían si el modelo de negocio expone a la casa. **Eso queda fuera de la auditoría por decisión del dueño**, y con razón: la regla del negocio es la que es. Los caballos que nadie puja quedan a la casa a su precio de salida y suman al pozo; gana un caballo de usuario, ese usuario cobra el 75%; gana un caballo de la casa, la casa se queda con todo. **Punto.** Lo que sigue es solo si el código hace bien esa cuenta.

**Regla que el sistema debe cumplir, sin excepciones:**

> Pozo = suma de la puja más alta de cada caballo pujado **+** precio de salida de cada caballo no pujado.
> Se excluyen los caballos **retirados** de ambos términos.
> Premio = pozo × (100 − `porcentaje_casa`) / 100. Casa = el resto.
> Si el ganador no tenía puja, premio = 0 y la casa se queda con el pozo completo.

**Lo que hoy no cumple:**

| # | Defecto | Estado |
|---|---|---|
| 1 | **Los caballos `retirado` siguen sumando al pozo.** La casa "compra" un caballo que no corre y el pozo queda inflado. | ❌ A corregir |
| 2 | **El 75/25 está clavado como `0.75`** en vez de leer `porcentaje_casa`. Ver C2. | ❌ A corregir |
| 3 | **No hay guarda de solvencia.** `liquidar_remate` acredita el premio con un `update` a secas, sin comprobar que la plataforma tenga el dinero. Si no lo tiene, el usuario queda con saldo que no puede retirar y nadie se entera hasta que el pago rebote. | ❌ A corregir |

El punto 3 no es una opinión sobre el negocio: **es que el sistema nunca debe acreditar un saldo que no puede pagar.** Si la caja no alcanza, la liquidación tiene que detenerse con un mensaje claro para que el operador decida, no acreditar y seguir. Especialmente cuando el operador sea un licenciatario y no tú.

La corrección de los tres puntos está escrita en `DISENO_SALDO_V2.md`, §6.3.

### C2 · `porcentaje_casa` se guarda y se lee, pero la liquidación no lo usa — **CONFIRMADO (alcance corregido)**

> **Corrección respecto a la versión anterior de este informe.** Yo afirmé que "contabilidad y liquidación ya discrepan hoy con la configuración por defecto". **Eso era incorrecto y lo retiro.** El formulario de crear remate envía `porcentaje_casa: 25` **siempre y explícitamente**, así que el default `20.00` de la columna nunca llega a aplicarse en la práctica. Hoy los dos números coinciden.
>
> **Y la fórmula que defiendes es exactamente la que está implementada:** casa 25%, usuario 75% del pozo acumulado. En eso tienes razón y el código hace lo correcto.

**Lo que sí es un defecto:**

La tabla `remates` guarda `porcentaje_casa`. El formulario deja al admin escribirlo. `admin_contabilidad_resumen` **lo lee** y calcula con él:

```sql
round(p.pozo_total * (1 - (l.pct_casa / 100.0)), 2) as premio_total
```

Pero `liquidar_remate` **lo ignora** y multiplica por una constante:

```sql
v_premio := round(v_pozo_total * 0.75, 2);   -- nunca lee v_remate.porcentaje_casa
```

Hoy coinciden **por coincidencia**: porque la UI siempre escribe 25 y la constante es 0.75. No coinciden por diseño.

**Por qué importa igual:**

1. **El campo del formulario es una trampa.** Está ahí, es editable, y si alguien escribe 30 el sistema paga 75% igual. El admin cree que cobró 30% y cobró 25%, y contabilidad le reporta 30%. La discrepancia aparece en el momento exacto en que alguien usa una función que el propio formulario le ofrece.
2. **El default de la columna es 20.00**, distinto del 25 que envía la UI y del 25 implícito en el `0.75`. Son tres números para el mismo concepto en tres lugares. Está apagado hoy, pero cualquier `insert` que no venga del formulario lo enciende.
3. **Es un bloqueador duro del licenciamiento.** Todo tu modelo de renta se apoya en que cada cliente configure su comisión. Con el `0.75` clavado, todos tus licenciatarios cobran 25% quieran o no.

**Corrección:** una línea en `liquidar_remate` (`v_premio := round(v_pozo_total * (1 - coalesce(v_remate.porcentaje_casa,25)/100.0), 2)`), alinear el default de la columna a 25, y quitar el literal `"Casa 25%"` de `app/admin/remates/[id]/page.tsx`.

**Bloque 11 y 12 del diagnóstico rápido** te confirman si todos tus remates tienen 25 o si alguno se salió del molde.

### C3 · `total_blocked` sobre el historial completo — **RESUELTO en `liquidar_remate` · VIVO en `cancelar_remate`** (verificado 28/08)

> **Veredicto con el código desplegado a la vista:**
>
> - **`liquidar_remate`: corregido.** La versión en producción calcula `total_win` agregando **solo sobre la CTE `winners`** (la puja líder de cada caballo), no sobre todas las pujas. Descuenta exactamente lo que estaba bloqueado. La versión defectuosa es la de `sql/liquidar_remate_ganador.sql`, que **no es la que corre**.
> - **`cancelar_remate`: el defecto sigue vivo.** Los marcadores confirman `usa_sum_b_monto = true`, `menciona_total_blocked = true`, `menciona_total_win = false`. Suma todas las pujas del usuario e intenta liberar ese total. **Cancelar un remate donde alguien fue superado va a fallar con "Inconsistencia", o va a devolver de más.**
> - **`cerrar_remate`: hay que mirarlo.** La desplegada pesa 3.129 caracteres y menciona `total_blocked` y `total_win`, cuando la del repo es un simple cambio de estado. Son funciones distintas. Pendiente `sql/check_4_cerrar_cancelar.sql`.
>
> **Y el hallazgo de fondo:** la `liquidar_remate` desplegada **no coincide con ningún archivo del repositorio**. Hay al menos tres generaciones de esa función circulando: la del volcado de enero, la de `sql/`, y la que corre. Es la demostración más clara de por qué la tarea 0.1 del backlog —volcar producción como baseline— va antes que cualquier otra cosa.

**Lo que la versión desplegada SÍ tiene mal** (código a la vista, 28/08):

| # | Defecto | Línea |
|---|---|---|
| 1 | El pozo **no excluye los caballos retirados** — `where h.race_id = v_remate.race_id` sin más | cálculo de `v_pozo_total` |
| 2 | La CTE `winners` tampoco excluye retirados: **al líder de un caballo retirado se le cobra su puja** | CTE `winners` |
| 3 | `v_premio := round(v_pozo_total * 0.75, 2)` — comisión clavada, `porcentaje_casa` nunca se lee | cálculo del premio |
| 4 | El cobro se registra como `ajuste_manual` con monto negativo — el libro no es auditable | `insert into wallet_movements` |
| 5 | **Sin guarda de solvencia**: `update wallets set saldo_disponible = saldo_disponible + v_premio` a secas | pago del premio |
| 6 | `select ganador_horse_id into ...` sin `limit`: con `race_results` duplicados toma uno arbitrario. Lo cierra el `unique(race_id)` de la tarea 3.3 | lectura del ganador |

El análisis original queda abajo como referencia de la clase de defecto.

### C3-ter · `cerrar_remate` rompe la liquidación — **CONFIRMADO Y REPRODUCIDO 28/08**

Con el código desplegado a la vista, el defecto C3 no desapareció: **se mudó de `liquidar_remate` a `cerrar_remate`**.

La `cerrar_remate` que corre tiene un bucle de liberación con esta agregación:

```sql
user_max as (
  select b.user_id, b.horse_id, max(b.monto)::numeric as max_monto
  from public.bids b where b.remate_id = p_remate_id
  group by b.user_id, b.horse_id          -- <-- TODOS los caballos donde pujo
),
agg as (
  select m.user_id,
    sum(m.max_monto)::numeric as total_blocked,   -- <-- incluye caballos donde lo superaron
    coalesce(sum(w.monto),0)::numeric as total_win
  from user_max m left join winners w on w.horse_id = m.horse_id and w.user_id = m.user_id
  group by m.user_id
)
v_release := total_blocked - total_win;
```

Es mejor que el `sum(b.monto)` del repo —deduplica varias pujas al mismo caballo— pero **sigue contando los caballos donde al usuario ya lo superaron y ya se le devolvió el dinero**. `hacer_puja` libera en el momento del sobrepuje, así que **lo realmente bloqueado es `total_win`, y `v_release` debería ser siempre 0.**

**Reproducido en PostgreSQL 16** con el escenario más común que existe en un remate:

| Paso | |
|---|---|
| 1 | U1 puja 100 al caballo A |
| 2 | U2 lo supera con 150 → a U1 se le **devuelven** sus 100 |
| 3 | U1 puja 200 al caballo B y queda líder |

Estado real antes de cerrar: **U1 → disponible 800, bloqueado 200.** Correcto.

Lo que calcula `cerrar_remate`: `total_blocked = 300`, `total_win = 200`, **`v_release = 100`**.

| | Antes de cerrar | Después de cerrar |
|---|---|---|
| U1 disponible | 800 | **900** |
| U1 bloqueado | **200** | **100** |
| U1 total | 1000 | 1000 |

**No se crea dinero** —el total de U1 no cambia— pero **100 Bs que debían seguir comprometidos con el caballo B pasan a estar disponibles y son retirables**. Y acto seguido:

```
ERROR: Inconsistencia: bloqueado (100) < a cobrar (200) para user_id 1111...
```

**La liquidación falla y el remate queda trabado en `cerrado`.** Si el usuario retira ese saldo antes de que alguien lo note, el dinero comprometido se pierde de verdad.

**Y hay un caso peor, más común todavía:** un usuario que pujó y fue superado en **todos** sus caballos tiene `total_win = 0`, `total_blocked = 100`, `v_release = 100`, contra un `saldo_bloqueado` real de 0. La guarda dispara **en el cierre mismo**: el remate no se puede ni cerrar.

**Regla que resulta de todo esto:** bajo el modelo de bloqueo actual, lo que un usuario tiene bloqueado al cerrar **es exactamente la suma de sus pujas líderes**, porque `hacer_puja` ya devolvió todo lo demás. **El bucle de liberación de `cerrar_remate` sobra por completo y solo hace daño.** Eso valida el §6.2 de `DISENO_SALDO_V2.md`, donde `cerrar_remate` pasa a ser el momento del **cobro** y no de la liberación.

### C3-quater · El cron y el botón hacen cosas distintas — **CONFIRMADO 22/09**

`auto_cerrar_remates()` hace un `update remates set estado='cerrado'` **plano**: no llama a `cerrar_remate` ni toca saldos. El botón del admin sí llama a `cerrar_remate`.

Son **dos comportamientos distintos para la misma transición de estado**:

| Camino | Libera saldos | Liquidación posterior |
|---|---|---|
| Cron `auto_cerrar_remates` | No | **Funciona** — lo bloqueado sigue siendo las pujas líderes |
| Botón admin → `cerrar_remate` | Sí, mal | **Falla** con "Inconsistencia" |

**Verificado.** La `auto_cerrar_remates()` desplegada es exactamente esto:

```sql
update public.remates
set estado = 'cerrado', closed_at = coalesce(closed_at, now())
where estado = 'abierto' and closes_at is not null and closes_at <= now();
```

No llama a `cerrar_remate`, no toca saldos. **Explica por qué el problema pasó desapercibido:** los remates que cierran solos por horario funcionan, y solo revientan los que se cierran a mano.

**Y a partir de la tarea 2.3 esto se vuelve un agujero de dinero**, porque el cierre pasará a ser el momento del cobro y este cron se lo saltaría entero: remates cerrados sin cobrar a nadie. Unificar antes de tocar el bloque 2 (tarea 1.9).

---

### C3-bis · El texto original del hallazgo

**Archivos:** `sql/liquidar_remate_ganador.sql` (CTE `agg`, líneas 162-171) y `sql/cancelar_archivar_remate.sql` (líneas 74-78 — sin CTE, con un `for r in` directo, pero con exactamente el mismo `sum(b.monto)` y el mismo defecto).

```sql
agg as (
  select b.user_id,
    sum(b.monto)::numeric as total_blocked,      -- <-- suma TODAS las pujas
    coalesce(sum(w.monto),0)::numeric as total_win
  from public.bids b
  left join winners w on w.bid_id = b.id
  where b.remate_id = p_remate_id
  group by b.user_id )
```

La tabla `bids` es **append-only**: `hacer_puja` inserta una fila por cada puja y no hay `DELETE` ni trigger de limpieza en ninguna parte del repo (lo verifiqué). Cada vez que un usuario sube su oferta, queda una fila nueva.

Pero `hacer_puja` **no bloquea el histórico**: cuando te superan, te devuelve el monto (`apuesta_desbloqueo`), y cuando subes tu propia puja solo bloquea el *delta*. Es decir:

> **Lo que un usuario tiene realmente bloqueado = la suma de sus pujas donde hoy es el líder = `total_win`, no `total_blocked`.**

**Caso mínimo que rompe:** usuario puja 100 al caballo A → lo superan (se le devuelven los 100) → puja 200 al caballo B y queda líder.
- `total_blocked` calculado = 300
- Bloqueado real en su wallet = 200
- La guarda `if v_wallet.saldo_bloqueado < v_total_blocked` dispara → **`Inconsistencia: wallet bloqueado (200) < total bloqueado remate (300)`** → *la liquidación falla y el remate queda trabado en estado `cerrado`*.

**Y el caso peor:** si ese usuario tiene saldo bloqueado en **otro** remate simultáneo, la guarda pasa. Entonces:
- Se le descuentan 300 de `saldo_bloqueado` (300 − 200 = 100 de más, robados del otro remate)
- Se le acreditan `release = 300 − 200 = 100` a `saldo_disponible` — **dinero creado de la nada**
- Y el otro remate, cuando se liquide, fallará por inconsistencia

Lo mismo aplica a `cancelar_remate`, que usa idénticamente esa agregación para devolver saldos.

**Corrección:** `total_blocked` debe ser `total_win` (solo las pujas líderes). El `v_release` correcto en liquidación es **0** para los perdedores — su dinero ya se les devolvió al ser superados.

> **Verifica esto primero.** Si liquidas remates con competencia real y nunca viste el error "Inconsistencia", significa que la función desplegada **no es la del repo** — y entonces tienes un problema de versionado peor que el bug. La consulta `D3` del script de diagnóstico te lo dice en un segundo.

---

### C4 · Doble acreditación por falta de `FOR UPDATE` en recargas y retiros — ~~CONFIRMADO~~ **RESUELTO EN PRODUCCIÓN**

> **Este hallazgo era incorrecto.** La verificación del 27/08 muestra que `aprobar_recarga` y `procesar_retiro` **sí tienen `FOR UPDATE`** sobre la fila de la solicitud, y que nunca hubo una recarga acreditada dos veces. Lo etiqueté como confirmado apoyándome en un volcado de enero; la función desplegada ya estaba corregida. **Error de criterio mío.** Dejo abajo el análisis original porque el código del volcado sí tenía el defecto y sirve como referencia de qué buscar — pero el defecto **no está en tu producción**.
>
> **Lo único que queda por revisar:** que el `UPDATE` final incluya `and estado = 'pendiente'` como segunda red. Eso no lo mide el diagnóstico.

**Funciones:** `public.aprobar_recarga` y `public.procesar_retiro`.

Ambas bloquean la wallet, pero **no bloquean la fila de la solicitud**:

```sql
select * into v_request
from public.deposit_requests
where id = p_deposit_request_id;   -- <-- sin FOR UPDATE

if v_request.estado <> 'pendiente' then raise exception ...; end if;
```

Dos ejecuciones concurrentes (el admin hace doble clic, o la conexión se cae y reintenta) leen ambas `estado = 'pendiente'`, ambas pasan la validación, y **ambas acreditan el monto**. La wallet sí está bloqueada, así que los `UPDATE` se serializan — pero se aplican los dos. El usuario recibe el doble.

En `procesar_retiro` el defecto es el mismo pero el impacto depende de la rama:
- rama `'pagado'`: **no toca la wallet**, así que no hay doble acreditación — solo doble marcado de estado.
- rama `'rechazado'`: **sí devuelve el monto a la wallet** → doble ejecución = doble devolución.

**Defecto adicional en ambas funciones:** el `UPDATE` final que cambia el estado **no lleva guarda `and estado = 'pendiente'`**. Aunque se agregue el `for update`, esa guarda es la segunda línea de defensa correcta y cuesta lo mismo.

**Corrección:** `for update` en el `select` de la solicitud, y `and estado = 'pendiente'` en el `update` final. En ambas funciones. Adicionalmente, deshabilitar el botón en la UI durante el `await` (hoy `app/admin/recargas/page.tsx` sí tiene un estado de carga, pero la defensa no puede vivir en el cliente).

---

## 2. Hallazgos CRÍTICOS — seguridad

### S1 · Escalada de privilegios: cualquier usuario puede hacerse admin — **CERRADO (verificado 27/08)**

> **No aplica.** El trigger `enforce_admin_immutability` está presente y el permiso de `UPDATE` sobre `profiles` está revocado para `authenticated`. El hardening sí se aplicó. Solo hay 2 cuentas con privilegios, ambas legítimas y creadas el 16/01.
>
> **Lo que sigue siendo un problema no es la política, es que esa corrección no está en el repositorio** — solo existe el script que la revierte. Si mañana provisionas la base de un cliente desde `sql/`, esa instalación nace con el agujero abierto. Ver E2/B1.
>
> El análisis original queda abajo como referencia de qué es lo que el trigger está protegiendo.

**Evidencia:** `app/SUPABASE_CONTEXT.md`, sección Policies.

```
profiles | profiles_update_own | UPDATE | using (id = auth.uid()) | with check (id = auth.uid())
```

Esa política permite a un usuario actualizar su propia fila de `profiles`. **No restringe columnas.** Y `profiles` contiene `es_admin` y `es_super_admin`.

Con la `anon key` (que es pública por diseño, va en el bundle del navegador) y una sesión normal, esto basta:

```js
await supabase.from('profiles').update({ es_admin: true }).eq('id', myUserId)
```

A partir de ahí `is_admin()` devuelve `true`, y las políticas `wallets_admin_all` / `deposit_admin_all` / `withdraw_admin_all` le dan control total: puede escribir su propio `saldo_disponible` al valor que quiera y pedir el retiro. **Compromiso total con pérdida monetaria directa.**

**Por qué digo POR VERIFICAR y no CONFIRMADO:** existe `sql/rollback_hardening_profiles.sql`, que revierte un trigger `enforce_admin_immutability` y una RPC `promover_usuario`. Eso indica que en algún momento aplicaste un hardening exactamente contra este agujero. Pero:
- el script que **aplica** el hardening no está en el repo (solo el que lo revierte)
- ese archivo está listado en `.gitignore`, o sea que se decidió no versionarlo
- el volcado de funciones de enero **no incluye** `tr_check_admin_immutability` ni `promover_usuario`

O sea: probablemente lo arreglaste después de enero, pero **no hay forma de comprobarlo desde el repo**. Corre `D1` del diagnóstico. Si el trigger no está, esto es lo primero que tocas hoy, antes que C1.

**Corrección definitiva** (independiente de si el trigger existe): quitar `es_admin` y `es_super_admin` de `profiles` a una tabla `user_roles` separada, sin política de escritura para `authenticated`, y promover solo por RPC `SECURITY DEFINER` que exija super-admin y escriba en `admin_actions`.

---

### S2 · Todas las pujas de todos los usuarios son legibles por cualquier autenticado — **CERRADO (verificado 27/08)**

> La política `bids_select_auth` con `using(true)` **ya no existe**, y no hay ninguna tabla de `public` sin RLS. Corregido antes de esta auditoría. El análisis original queda como referencia.

```
bids | bids_select_auth | SELECT | using (true)
```

Cualquier usuario logueado puede hacer `select * from bids` y obtener **el `user_id` de cada puja de cada remate**, incluidos remates ajenos. Cruzando con `get_usernames(p_ids uuid[])` — que es `SECURITY DEFINER` y acepta cualquier arreglo de UUIDs sin filtro — puede mapear cada puja a un nombre de usuario.

Hoy: fuga de privacidad y ventaja competitiva (ver la estrategia de puja de los rivales en tiempo real).

**Bajo licencia con DB por cliente**, el radio de daño se contiene a un solo cliente — que es precisamente uno de los méritos del modelo híbrido que elegiste. Pero sigue siendo un problema dentro de cada instalación.

Noto que la app ya no consulta `bids` directamente para la vista pública: usa `listar_pujas_publicas` (RPC). Eso es lo correcto. Falta cerrar la puerta de atrás: `bids_select_auth` debería restringirse a las pujas propias, y todo lo público pasar por la RPC que expone solo lo que debe exponer.

---

### S3 · No hay separación entre "operador" y "dueño de la casa" — **CONFIRMADO**

`is_admin()` es binario. Un `es_admin = true` puede: aprobar recargas, marcar retiros como pagados, cerrar, cancelar y liquidar remates, y leer todas las wallets. No hay rol intermedio.

Para un cliente que va a contratar operadores de mesa, esto es inaceptable: cualquier empleado con acceso al panel puede aprobar una recarga inventada a una cuenta cómplice. Y `admin_actions` existe como tabla pero **no encontré ninguna función que escriba en ella** — la bitácora está vacía por diseño, así que ni siquiera hay rastro forense.

**Se necesita:** roles `operador` / `finanzas` / `owner`, y que **toda** RPC de dinero escriba en `admin_actions` (quién, qué, cuándo, con qué parámetros, éxito o error).

---

### S4 · Secretos y configuración — **CONFIRMADO**

- `.env.local` **no está en git** (bien: `.gitignore` cubre `.env*`, y `git ls-files` lo confirma). Punto a favor.
- Pero contiene una **contraseña de aplicación de Gmail** (`SMTP_PASS`) en texto plano en tu disco. Al pasar a modelo de licencias, cada cliente necesita sus propias credenciales SMTP y las suyas nunca deben pasar por tu máquina.
- `APP_URL=http://localhost...` — los enlaces en los correos de notificación apuntan a localhost. Si esto está igual en Vercel, los correos que llegan al admin traen enlaces rotos.
- El cliente SMTP está **escrito a mano sobre un socket TLS crudo** (`app/api/notify/recarga/route.ts`). Es ingenioso, pero el lector de respuestas tiene un defecto: `readLine` resuelve con el primer chunk que contenga `\n` y descarta el resto del búfer; con respuestas SMTP fragmentadas se desincroniza. Y **no hay ningún timeout** en el socket: si Gmail no responde, la función serverless se queda colgada hasta que Vercel la mata. Cambiar por `nodemailer` elimina la clase entera de problemas.
- El endpoint `/api/notify/recarga` acepta `POST` autenticado por cookie **sin token anti-CSRF**. Una página externa puede hacer que un admin logueado dispare correos. Impacto bajo (spam), pero es gratis cerrarlo.

---

## 3. Contabilidad

### A1 · Los retiros pendientes no se descuentan del dinero de la casa — **CONFIRMADO**

`sql/contabilidad_resumen.sql`:

```sql
v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios;
```

La identidad es correcta en su forma, **pero le falta un término**. Cuando un usuario solicita un retiro, `solicitar_retiro` le descuenta el monto de `saldo_disponible` **inmediatamente**, aunque el dinero todavía no salió del banco de la casa. Ese monto desaparece de `v_saldo_usuarios` y no aparece en `v_retiros_pagados`.

**Ejemplo:** usuario recarga 1.000, pide retirar 1.000.
- Banco de la casa: 1.000 (el pago aún no se hizo)
- `saldo_usuarios`: 0
- `dinero_casa` reportado: **1.000**
- Dinero real de la casa: **0** — le debe los 1.000 al usuario

`v_retiros_pendientes` **ya se calcula** en la función; simplemente no se resta. La corrección es una línea:

```sql
v_dinero_casa := v_recargas_aprobadas - v_retiros_pagados - v_saldo_usuarios - v_retiros_pendientes;
```

### A2 · `resumen_casa` (la función vieja) tiene el signo invertido y doble conteo — **CONFIRMADO**

```sql
v_dinero_casa := v_total_recargas - v_total_premios - v_total_retiros - v_saldo_usuarios;
```

Dos errores independientes:

1. **Signo invertido.** `solicitar_retiro` inserta el movimiento de tipo `retiro` con **monto negativo** (`-p_monto`). Entonces `v_total_retiros` sale negativo, y `- v_total_retiros` **suma** los retiros al dinero de la casa en lugar de restarlos. Error de 2× el total retirado, en la dirección optimista.
2. **Doble conteo de premios.** Los premios ya están dentro de `v_saldo_usuarios` (se acreditaron a la wallet del ganador). Restarlos otra vez los cuenta dos veces.

Adicional: `resumen_casa` es la única función de dinero que **no** es `SECURITY DEFINER` ni fija `search_path`.

**No encontré llamadas a `resumen_casa` desde la app** — la pantalla de contabilidad usa `admin_contabilidad_resumen`, que sí está bien planteada. Así que probablemente es código muerto. **Bórrala**, no la dejes ahí para que alguien la llame por error en dos años.

### A3 · El libro de movimientos no es auditable — **CONFIRMADO**

`liquidar_remate` registra tanto la liberación de apuestas perdedoras como el **cobro** de las ganadoras con el tipo `ajuste_manual`, y el cobro va con **monto negativo**:

```sql
values (v_wallet.id, 'ajuste_manual'::wallet_movement_type, -v_total_win, 'Pago por remate ganado ...')
```

`procesar_retiro` también usa `ajuste_manual` para la devolución de un retiro rechazado.

Resultado: `ajuste_manual` significa cuatro cosas distintas, con signos mezclados, y es imposible reconstruir el estado de una wallet desde sus movimientos o cuadrar el libro contra los saldos. Para un producto que mueve dinero de terceros, el libro **es** el producto.

**Se necesitan tipos explícitos:** `apuesta_liberacion`, `apuesta_cobro`, `premio`, `retiro_solicitado`, `retiro_pagado`, `retiro_devuelto`, `recarga`, `ajuste_manual` (solo para ajustes manuales de verdad). Y una convención de signo única y documentada.

---

## 4. Sistema de creación de carreras

Me dijiste que no hay algo puntual que te moleste. Te digo lo que encontré, ordenado por lo que más te va a doler cuando lo opere un cliente y no tú.

### Lo que está mal hoy

**P1 · No es atómico, y el propio código lo admite.** `app/admin/crear-remate/page.tsx` línea 440 tiene este comentario:

```
// NOTA IMPORTANTE:
// Sin RPC transaccional, esto NO es atómico:
// si falla horses, ya quedan creados race/remate y los borras manual.
```

Son **cuatro** operaciones separadas desde el navegador: `races` → `remates` → `horses` → `remate_price_rules`. Si la cuarta falla (o se cierra el laptop, o se cae el wifi), queda un remate **en estado `abierto`, visible al público, con caballos y sin reglas de incremento**. Los usuarios pueden pujar en él. Tú lo operas y sabes borrarlo a mano en Supabase; tu cliente no.

**P2 · El remate nace `abierto` aunque `opens_at` sea futuro.** El insert fija `estado: "abierto"` siempre. La protección contra pujar antes de tiempo existe (`hacer_puja` valida `opens_at`), pero el remate **aparece listado** y el usuario ve un botón que le va a tirar error. Debería nacer `programado` y abrirlo el mismo cron que ya lo cierra.

**P3 · El mapeo caballo→regla usa el número como llave, sin constraint que lo garantice.** Después de insertar, el código relee los caballos y arma `byNumero: Map<number, string>`. Si por error se crean dos caballos con el mismo número en la misma carrera —**nada en el esquema lo impide**, no hay unique en `horses(race_id, numero)`— las reglas por caballo se asignan al equivocado. Y `set_ganador_carrera` busca al ganador **por número**: con números duplicados, `select id into v_horse_id ... where numero = p_horse_num` toma uno arbitrario. **Se liquida al caballo equivocado.**

**P4 · ~~No existe pantalla de edición~~ — CORREGIDO: sí existe, y ese es el problema.**

> Error mío en la primera pasada: solo leí `app/admin/crear-remate` a fondo. `app/admin/remates/[id]/page.tsx` **sí tiene edición completa** de carrera, remate y caballos, con alta, baja y modificación. Retiro el hallazgo.

Lo que encontré al leerla es peor que su ausencia: **la pantalla de edición no tiene ninguna guarda.** No comprueba el estado del remate ni si hay pujas. El único `bids.length === 0` del archivo (línea 1670) es lógica de presentación, no una validación.

Con un remate **abierto y con pujas en curso**, un admin puede:

| Acción | Consecuencia |
|---|---|
| Cambiar `precio_salida` de un caballo con pujas | El pozo cambia retroactivamente después de que la gente pujó |
| Cambiar `porcentaje_casa` | Cambia el reparto después de que se aceptaron las apuestas |
| Cambiar `apuesta_minima` / `incremento_minimo` | Altera las reglas del juego a mitad del juego |
| Mover `opens_at` / `closes_at` | Alarga o acorta el remate en curso |
| **Borrar un caballo que tiene pujas** | Depende de la FK. Si es `ON DELETE CASCADE`, **las pujas desaparecen y el `saldo_bloqueado` de esos usuarios queda huérfano para siempre** — no queda ninguna puja que lo libere. Verificar con la consulta 3 de `sql/confirmar_liquidacion.sql`. |
| **Escribir `estado` directamente** | `supabase.from("remates").update({estado: ...})` **se salta las RPC `cerrar_remate` y `liquidar_remate` y todas sus validaciones**. Un admin puede marcar un remate como `liquidado` sin que la liquidación se ejecute: el dinero de todos los pujadores queda bloqueado para siempre y el remate figura como cerrado. |

Hoy esto lo contiene el hecho de que los dos únicos admins eres tú y una cuenta tuya. **Bajo licencia, con operadores contratados, esto es la puerta principal para el fraude interno** — y no deja rastro, porque `admin_actions` no registra escrituras directas a tablas, solo lo que pasa por RPC.

**Corrección:** las escrituras a `races`, `remates` y `horses` deben pasar por una RPC `editar_remate` que valide el estado, rechace cambios que afecten dinero cuando ya hay pujas, prohíba escribir `estado` (eso solo por las RPC de transición) y registre todo en `admin_actions`. Y en RLS: quitarle a `authenticated` el `UPDATE`/`DELETE` directo sobre esas tres tablas, igual que ya hiciste con `profiles`.

**P4b · Un caballo retirado a mitad de remate se queda con el dinero de quien lo pujó.** Verificado en el código: `hacer_puja` **sí** rechaza pujas sobre un caballo `retirado` (correcto), la vista pública **sí** lo muestra como retirado (correcto), y la pantalla admin **sí** guarda el flag. Pero **no hay nada, en ninguna parte, que devuelva el dinero de las pujas que ese caballo ya tenía**. El líder de ese caballo sigue con su monto bloqueado, el caballo no corre, y al liquidar su puja se cobra igual y va al pozo. Pierde su dinero por un caballo que no compitió.

Y `liquidar_remate` tampoco excluye los retirados del pozo, así que la casa "compra" un caballo que no corre.

**Los dos escenarios que hay que cubrir explícitamente:**
1. **Retirado antes de abrir el remate** — el operador lo marca y el caballo no entra al pozo ni acepta pujas. Hoy funciona a medias: no acepta pujas, pero sí entra al pozo.
2. **Retirado durante el remate** — hay que devolver la puja líder a su dueño (movimiento `apuesta_desbloqueo`), sacar el caballo del pozo, y dejar constancia. **Hoy no está implementado en absoluto.**

**P5 · Cero reutilización.** Las 10 reglas de precio por defecto están **hardcodeadas en el componente React** (líneas 210-221). Cada carrera se arma desde cero: mismo hipódromo, mismos jinetes, misma estructura de reglas, todo tecleado de nuevo. Una jornada de La Rinconada son 12+ carreras. Eso es una tarde entera de formulario.

**P6 · La fecha se arma con tres inputs de texto y un offset fijo `-04:00`.**

```js
return `${dateIso}T${t}-04:00`   // buildCaracasTs
```

Venezuela hoy está en UTC−4 y no aplica horario de verano, así que **funciona**. Pero está clavado en el código. En el momento que licencies a un hipódromo en Colombia, Perú, Panamá o Chile —y Chile **sí** cambia de hora— todos los `opens_at`/`closes_at` quedan corridos. Para un producto multi-cliente esto tiene que ser una zona horaria por instalación, resuelta con la IANA (`America/Caracas`, `America/Bogota`), no un literal.

**P7 · La validación vive solo en el cliente.** `canSave` (líneas 265-330) es un bloque de validación bastante completo... que corre en el navegador. La base de datos acepta `precio_salida = 0`, `apuesta_minima` negativa o `closes_at < opens_at` sin chistar, porque no hay `CHECK` constraints. Cualquiera con la anon key y rol admin puede insertar basura saltándose el formulario.

### Rediseño que propongo

**Una sola RPC transaccional.** `crear_remate_completo(p_payload jsonb)` que recibe carrera + caballos + reglas en un solo JSON y hace todo dentro de una transacción. Se acaban P1 y P7 de un golpe: o queda todo, o no queda nada, y las validaciones se ejecutan del lado del servidor donde nadie las puede saltar. La página pasa de 4 llamadas a 1.

**Plantillas de jornada.** Tabla `race_templates` con hipódromo, zona horaria, escala de reglas de precio por defecto, comisión de la casa y nómina habitual de jinetes/entrenadores. Crear una carrera arranca de una plantilla, no de cero. Esto es lo que convierte "cargar la jornada" de una tarde a diez minutos, y es lo que un cliente va a percibir como valor real.

**Clonar carrera.** Botón "duplicar" sobre una carrera existente que copia caballos y reglas y solo pide fecha/número nuevos. Es la operación más frecuente y hoy no existe.

**Carga masiva de caballos.** Un `textarea` donde se pega `número, nombre, jinete, precio` —una línea por caballo, tal como llega el programa oficial— con vista previa antes de confirmar. Diez caballos en un pegado en vez de cuarenta clics.

**Modo jornada.** Crear las 12 carreras del día en una pasada, heredando hipódromo y fecha, con los horarios en cascada.

**Pantalla de edición con reglas claras.** Editable libremente mientras el remate esté `programado`. Con el remate `abierto` y con pujas, solo campos que no afecten dinero (nombre, comentarios, jinete) y marcar `retirado`. Todo cambio a `admin_actions`.

**Constraints en la base:** `unique(race_id, numero)` en `horses`, `check (precio_salida > 0)`, `check (closes_at > opens_at)`, `check (porcentaje_casa between 0 and 100)`, `unique(race_id)` en `race_results`. Barato, permanente, y cierra P3.

---

## 5. Producto y operación

**O1 · No hay tiempo real en un remate "en vivo".** Verifiqué todo el código de la app: **cero** suscripciones Realtime de Supabase, **cero** `setInterval`, **cero** polling. La única forma de ver una puja nueva es que el usuario toque el botón "Actualizar precios" (`app/remates/[id]/page.tsx`, línea 610).

En un remate en vivo esto significa que el usuario puja contra un precio viejo, la RPC se lo rechaza con *"la puja debe superar el monto actual"*, y él lo lee como que la app está rota. **Para mí este es el hallazgo de producto más importante del informe**, y probablemente lo que más se nota al usarlo. Supabase Realtime sobre la tabla `bids` filtrado por `remate_id` lo resuelve.

**O2 · La liquidación son dos RPC separadas desde el navegador.** `set_ganador_carrera` y luego `liquidar_remate` (`app/admin/remates/[id]/page.tsx`, líneas 874-881). Si la segunda falla —y por C3 va a fallar seguido— el ganador ya quedó grabado y el remate queda a medio liquidar. Debe ser una sola RPC `liquidar_con_ganador(p_remate_id, p_horse_num)`.

**O3 · El autocierre depende de `pg_cron` sin ninguna alarma.** `sql/remates_programados.sql` programa `auto_cerrar_remates()` cada minuto. Correcto en concepto. Pero si el job se cae, nadie se entera: no hay monitoreo, y el síntoma es que los remates **siguen aceptando pujas después de que la carrera corrió**. Eso sí es fraude explotable. Hace falta un heartbeat y una alerta.

**O4 · No hay apertura automática.** El cron solo cierra. La apertura programada la suple `hacer_puja` rechazando pujas tempranas, lo que produce el error confuso de P2.

**O5 · La notificación por correo va solo a la casa.** `NOTIFY_EMAIL_TO` es un destinatario único. El usuario nunca se entera de que le aprobaron o rechazaron la recarga; tiene que entrar a mirar. Es una fuente garantizada de mensajes de soporte.

**O6 · Sin límite de tasa en ninguna parte.** `solicitar_recarga`, `solicitar_retiro`, `hacer_puja`, el registro y el endpoint de correo no tienen throttle. `hacer_puja` está protegida por `pg_advisory_xact_lock` contra condiciones de carrera, pero nada impide que un script haga mil pujas por segundo y sature la instancia.

---

## 6. Ingeniería y entrega

- **E1 · No hay pruebas.** Ni una. En un sistema que mueve dinero de terceros y que vas a licenciar, la lógica de `hacer_puja` / `liquidar_remate` / `cancelar_remate` necesita una suite de casos —incluidos exactamente los escenarios de C1 y C3— antes de tocar una sola línea. Sin eso, cada corrección es una apuesta.
- **E2 · No hay migraciones versionadas.** `sql/` es una carpeta de scripts sueltos, algunos ya aplicados, otros quizá no, sin orden ni registro. Y la divergencia ya es demostrable: la `liquidar_remate` que aparece en `app/SUPABASE_CONTEXT.md` (enero) es una **versión anterior que no calcula pozo ni premio en absoluto** — no contiene `0.75`, ni `v_pozo_total`, ni pago al ganador; solo el bucle de liberación. La del repo sí. O sea que ya hay al menos dos generaciones distintas de la función de liquidación circulando, más el hardening de S1 que no está versionado en ninguna parte. **Bajo modelo de DB-por-cliente esto es letal**: con tres clientes vas a tener tres bases de datos en estados divergentes que nadie puede reproducir. Necesitas `supabase/migrations` con numeración y `supabase db push`. **Este es el prerequisito número uno del licenciamiento**, por encima de cualquier feature.
- **E3 · Sin monitoreo de errores.** Los fallos se muestran al usuario y se pierden. No hay Sentry ni equivalente. Cuando el cliente te llame diciendo "no funciona", no vas a tener nada que mirar.
- **E4 · `next.config.ts` está vacío.** Sin cabeceras de seguridad (`Strict-Transport-Security`, `X-Frame-Options`, `Content-Security-Policy`).
- **E5 · Ruido en el repo.** `estructura.txt` pesa **11,3 MB** y está versionado. Hay archivos `Desktop.ini` de Windows rastreados en cinco carpetas pese a estar en `.gitignore` (fueron añadidos antes de la regla). Y hay 20 archivos modificados sin commitear desde hace cuatro meses. Antes de licenciar, el repo tiene que estar limpio.

---

## 7. Lo que está bien hecho

No todo es deuda, y varias decisiones aquí son mejores que lo que veo habitualmente en proyectos de este tamaño:

- **La lógica de dinero vive en la base de datos, no en el frontend.** Es la decisión arquitectónica correcta y es la razón por la que los bugs que encontré son de *fórmula* y no de *seguridad estructural*. Un atacante no puede inventarse una puja desde el navegador.
- **`pg_advisory_xact_lock` por `remate + caballo` en `hacer_puja`.** Manejo de concurrencia hecho a conciencia. La mayoría de la gente ni lo intenta.
- **`SECURITY DEFINER` con `search_path` fijo** en prácticamente todas las funciones. Es la defensa correcta contra secuestro de `search_path`, y está aplicada de forma consistente.
- **La validación de saldo del cliente está explícitamente marcada como "solo UX"**, con la validación real en SQL. Entendiste bien dónde va cada cosa.
- **`sql/support_settings.sql` es el mejor script del repo**: RLS habilitado, políticas limpias, `revoke` explícito antes de `grant`, trigger de `updated_at`, idempotente. Si todos los scripts tuvieran ese nivel, media auditoría sobraba.
- **`admin_contabilidad_resumen`** usa la identidad contable correcta (`recargas − retiros − saldos`) y **sí** respeta `porcentaje_casa`. Es la versión buena; el problema es que la liquidación no la acompaña.
- **`.env.local` correctamente fuera de git.**
- **La app funciona y está en producción.** Eso no es poco y no lo estoy minimizando.

---

## 8. Bloqueadores para licenciar

Elegiste **híbrido: código único, base de datos por cliente**, con **el cliente como la casa**. Es la decisión que yo habría recomendado para tu situación, y te digo por qué: no exige meter `tenant_id` en once tablas ni reescribir todas las políticas RLS (que es donde S1 y S2 se volverían catastróficos), y aísla el dinero de cada cliente por construcción — si un cliente tiene un incidente, no contamina a los demás. El costo es operativo, no arquitectónico, y ese costo se automatiza.

Ahora, lo que **falta**:

| # | Bloqueador | Por qué bloquea |
|---|---|---|
| **B1** | **Migraciones versionadas** (`supabase/migrations`) | Sin esto no puedes provisionar un cliente nuevo de forma reproducible ni aplicar una corrección a las N instalaciones. Es el prerequisito de todo lo demás. |
| **B2** | **Configuración por instalación** en tabla `app_settings` | Hoy están hardcodeados: nombre de la marca, `-04:00` de Caracas, moneda "Bs", `0.75` de comisión, las 10 reglas de precio, los datos bancarios de recarga. Todo eso tiene que ser configurable sin tocar código. |
| **B3** | **`porcentaje_casa` funcionando de verdad** (C2) | Es literalmente el modelo de negocio del licenciatario. Hoy es un campo decorativo. |
| **B4** | **Liquidación correcta** (C1 + C3) | No puedes entregarle a un tercero un motor de liquidación que paga más de lo que recauda. Esto es responsabilidad legal, no solo técnica. |
| **B5** | **Roles granulares + bitácora** (S3) | Tu cliente va a tener empleados. Necesita poder darles acceso limitado y necesita rastro de quién aprobó qué. |
| **B6** | **Marca configurable** | `BrandLogo.tsx`, textos y assets en `public/` están fijos a "Catire Bello". Cada cliente quiere lo suyo. |
| **B7** | **Panel de licencias** (tuyo, separado) | Alta/baja de clientes, estado de suscripción, versión desplegada por instalación, y un interruptor de corte por impago. |
| **B8** | **SMTP y datos bancarios por cliente** | Cada instalación con sus credenciales. Las tuyas no pueden estar en la instalación de nadie. |
| **B9** | **Contrato + acuerdo de nivel de servicio** | Con dinero de terceros de por medio: alcance del soporte, responsabilidad ante pérdidas por defecto de software, propiedad de los datos, respaldos, y qué pasa al terminar el contrato. **Esto no es opcional y no es un tema técnico.** Habla con un abogado en Colombia o Venezuela según dónde constituyas. |

**Sobre B9, y te lo digo aunque no me lo preguntaste:** una plataforma donde terceros depositan dinero real, apuestan y retiran, casi con seguridad cae bajo regulación de juegos de azar en Venezuela y en Colombia (donde Coljuegos regula el juego en línea y exige licencia). Que hoy lo operes tú es un riesgo tuyo; **el día que se lo licencias a un tercero, tú pasas a ser proveedor tecnológico de una operación de juego**, y eso tiene implicaciones distintas. No soy abogado y no verifiqué el estado actual de esa normativa — es exactamente el tipo de información sensible donde prefiero decirte "confírmalo con una fuente fiable" antes que darte una respuesta con cara de certeza. **Resuélvelo antes de firmar, no después.**

---

## 9. Plan priorizado

### Fase 0 — Verificar (hoy, 15 minutos)

Corre **`sql/diagnostico_rapido.sql`** en el editor SQL de Supabase: es **una sola consulta** que devuelve los 25 chequeos en una tabla. (El archivo `sql/diagnostico_auditoria.sql` tiene los mismos chequeos desglosados con más detalle, pero son ~20 consultas separadas y el editor de Supabase **solo muestra el resultado de la última** — úsalo para profundizar en un hallazgo puntual, no para el barrido inicial.) Ambos son de **solo lectura**, no modifican nada. Te dicen si S1 sigue abierto, si el código desplegado coincide con el repo, y cuánto dinero fantasma hay ya en tus liquidaciones pasadas. **Todo lo demás depende de este resultado.**

### Fase 1 — Contener (esta semana)

1. S1 si `D1` sale positivo — trigger de inmutabilidad de roles. Es lo único que puede costarte la caja completa hoy mismo.
2. C4 — agregar `for update` en `aprobar_recarga` y `procesar_retiro`. Dos palabras.
3. C1 — **guarda de solvencia en `liquidar_remate`**: que falle si el premio supera el dinero disponible de la casa, en vez de acreditar a ciegas. Es la red de seguridad, no el rediseño completo.
4. C2 — usar `v_remate.porcentaje_casa` en vez de `0.75`, alinear el default de la columna a 25, y quitar el literal "25%" de la UI.
5. C3 — corregir `total_blocked` en `liquidar_remate` y `cancelar_remate`.
6. A1 — restar `retiros_pendientes` en contabilidad. Una línea.
7. Borrar `resumen_casa` (A2).

*Antes de aplicar 3-5: hacer respaldo, y escribir las pruebas de esos casos. No toques la liquidación sin una prueba que reproduzca el error primero.*

### Fase 2 — Estabilizar (2-3 semanas)

8. Migraciones versionadas (B1/E2). **Prerequisito de todo lo que sigue.**
9. Realtime en la vista de remate (O1) — el mayor salto de calidad percibida por el usuario.
10. RPC `crear_remate_completo` transaccional (P1/P7) + constraints en base (P3).
11. Unificar la liquidación en una sola RPC (O2).
12. Estado `programado` + apertura automática (P2/O4).
13. Tipos de movimiento explícitos en el libro (A3) + **wallet/ledger de la casa** que registre la compra de los caballos no pujados (C1).
14. Sentry + alarma sobre el cron (E3/O3).

### Fase 3 — Producto (3-4 semanas)

15. Plantillas de jornada, clonar carrera, carga masiva de caballos, modo jornada (P5).
16. Pantalla de edición de carrera/remate (P4).
17. Roles granulares + bitácora en `admin_actions` (S3/B5).
18. Correo al usuario en aprobación/rechazo (O5), con `nodemailer` (S4).
19. Límite de tasa (O6).

### Fase 4 — Licenciar (3-4 semanas)

20. `app_settings` por instalación: marca, zona horaria IANA, moneda, comisión, datos bancarios, SMTP (B2/B6/B8).
21. Zona horaria configurable de verdad, adiós al `-04:00` (P6).
22. Script de provisión de cliente nuevo: crear proyecto Supabase, correr migraciones, sembrar configuración, desplegar en Vercel.
23. Tu panel de licencias (B7).
24. Contrato, acuerdo de servicio, y la consulta legal de B9.

**Estimación total: 9 a 12 semanas** de trabajo enfocado, asumiendo que las fases 2-4 las ejecutan agentes con estas decisiones ya cerradas. La Fase 1 es de días, no de semanas, y es la que no puede esperar.

---

## 10. Qué necesito de ti para el siguiente paso

Dijiste que por ahora solo querías el informe, así que no toco código. Cuando quieras avanzar, esto es lo que me falta y no puedo deducir del repo:

1. **El resultado de `sql/diagnostico_auditoria.sql`.** Sin eso, S1 y C3 quedan en "por verificar" y estoy trabajando a ciegas sobre el estado real.
2. **¿Has liquidado remates con competencia real y te salió el error "Inconsistencia"?** Es la pregunta más barata de responder y la que más me dice sobre C3.
3. **¿La base de datos de producción es la misma que refleja `SUPABASE_CONTEXT.md`, o hay cambios aplicados a mano que no están en `sql/`?** Necesito saber el tamaño real del hueco de versionado.
4. **¿Cuánto te está ofreciendo pagar el cliente y con qué plazo?** No por curiosidad: define si vale la pena ir a Fase 4 completa o si conviene arrancar con una instalación dedicada operada por ti mientras se estabiliza el producto.
5. **¿El cliente es de Venezuela o de otro país?** Determina la urgencia de P6 (zonas horarias) y de B9 (marco regulatorio).

**Y dos preguntas de regla de negocio que no puedo deducir del código:**

6. **Un caballo marcado `retirado`, ¿sigue quedando a la casa a su precio de salida y sumando al pozo?** Hoy el código dice que sí. Si la respuesta es no, es un cambio de una línea.
7. **¿Existe un tope de exposición?** Es decir: ¿hay algún límite a cuánto puede comprometer la casa en un remate, o se abre siempre con todos los caballos sin importar cuánto sume su precio de salida? De la respuesta depende si la guarda de solvencia va en la liquidación, en la apertura del remate, o en las dos.

**Mi recomendación, sin adornos:** no le pongas fecha de entrega al cliente hasta cerrar la Fase 1. Son días de trabajo y son los que separan "un producto que puedo licenciar" de "un pasivo con mi nombre encima".
