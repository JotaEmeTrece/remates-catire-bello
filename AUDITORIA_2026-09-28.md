# Auditoría completa — 28 de septiembre de 2026

**Alcance:** todo `app/` y `lib/` (28 archivos), las 20 migraciones de `supabase/migrations/`, y el arnés `tests/pruebas_dinero.sql`. Cuatro frentes auditados en paralelo: constantes de negocio, escrituras directas y lógica duplicada, seguridad y concurrencia en SQL, y el propio arnés.

**41 hallazgos.** Este documento los ordena por lo que hay que arreglar primero.

---

## Por qué aparecieron cosas de enero

La pregunta de Jota fue: *"no es posible que sean cosas que vengan desde tan atrás cuando se supone que había quedado todo fixeado"*. Tiene razón, y la explicación es concreta:

**La auditoría de agosto miró el SQL de las funciones que mueven dinero.** No miró el frontend, no miró los `GRANT`, y no miró el arnés. Los bloques 1 y 2 arreglaron lo que esa auditoría encontró, y verificaron cada arreglo contra el arnés — que es exactamente el sitio donde tres de los huecos de hoy son invisibles por construcción.

Tres puntos ciegos concretos, que esta auditoría cierra:

1. **Los permisos de tabla nunca se auditaron enteros.** `CREATE OR REPLACE FUNCTION` no toca los permisos — eso ya lo sabíamos desde el 25/09. Lo que no sabíamos es que hay un `ALTER DEFAULT PRIVILEGES` en la baseline que **concede todo a `anon` y `authenticated` sobre cada tabla y cada función nueva**. O sea que no hace falta un `grant` para quedar expuesto: hace falta un `revoke` para no estarlo. Ver hallazgo **C1**.
2. **El frontend nunca se auditó.** Las tres copias del cálculo del pozo, los datos bancarios clavados y los botones que nunca funcionaron llevan ahí desde enero.
3. **El arnés se auditó a sí mismo.** Nadie revisó si las pruebas podían fallar. Ocho no pueden, o no podían.

---

# BLOQUE A — Antes de que esto tenga un solo usuario real con dinero

## A1 · Los datos bancarios de cobro están escritos en el código
`app/dashboard/recargar/page.tsx:178-188`

Banco, teléfono, cédula y número de cuenta de Catire Bello, en el JSX. **Un licenciatario que despliegue esto recibe las recargas de sus usuarios en la cuenta de Jota.** No hay forma de cambiarlo sin editar código y redesplegar.

Es el hallazgo más grave para licenciar y no es técnico: es que el producto, tal como está, no se puede entregar.

El patrón correcto ya existe en el proyecto: `support_settings`, con su CRUD en `/admin/super/soporte`, alimentando `contactanos`.

## A2 · Una puja puede entrar en un remate ya cerrado, sin cobrar
`supabase/migrations/20260924140000_minimos_una_sola_fuente.sql:185-188`

`hacer_puja` lee `remates` con un `select` **plano** — sin `for update` ni `for share`. `_cerrar_remate_interno` sí toma `for update`, pero en `READ COMMITTED` un select sin cláusula de bloqueo no espera a nadie.

Y los candados no se cruzan: `hacer_puja` toma espacio 2 con clave `remate:caballo`; el cierre solo toma espacio 1 por líder. **Nunca compiten.**

**El escenario, paso a paso:**
1. El cierre toma `for update` sobre el remate y empieza a cobrar a los líderes.
2. Llega una puja. Lee `estado = 'abierto'` (aún no confirmó el cierre). Pasa todas las validaciones.
3. Su `insert into bids` dispara la comprobación de la FK, que toma `FOR KEY SHARE` sobre la fila del remate → **ahí sí espera**.
4. El cierre confirma. La puja despierta, la FK solo exige que la fila exista, y **el insert se completa**.

Queda una puja dentro de un remate cerrado cuyo autor **no fue debitado**. Si ese caballo gana, `liquidar_remate` le paga el premio. Si no gana, su monto infla el pozo. Si luego se retira ese caballo, `retirar_caballo` le devuelve dinero que nunca se le cobró.

**Y el descuadre no lo detecta**, porque el asiento `resultado_remate` se calcula leyendo los mismos `wallet_movements`: las dos mitades del cuadre mienten igual. Este agujero es silencioso.

Variante B del mismo defecto: si el pujador **sí** lidera algo en ese remate, hay **interbloqueo** y Postgres mata una de las dos transacciones. Si mata al cierre, el remate se queda abierto pasada su hora.

**Arreglo: una línea.** `for share` en el select del remate dentro de `hacer_puja`. Choca con el `for update` del cierre, no choca entre pujas de caballos distintos, y se adquiere antes del insert — así que respeta el mismo orden y elimina el ciclo.

## A3 · Doble reembolso: retirar un caballo y después cancelar el remate
`supabase/migrations/20260924120000_liquidar_y_cancelar_v2.sql:223-231`

`cancelar_remate` suma solo `m.tipo = 'apuesta_cobro'` e **ignora las `apuesta_devolucion` ya emitidas** sobre ese remate.

Lo revelador: `liquidar_remate`, de la misma tajada, **sí** las netea, y su comentario lo dice textualmente. `cancelar_remate` se quedó con el conjunto de tipos incompleto.

**Escenario:** el usuario U lidera dos caballos, se le cobran 800 al cerrar. Se retira uno → se le devuelven 500 (neto pagado: 300). Se suspende la carrera → `cancelar_remate` le devuelve **800**. U recibe 1.300 por 800 cobrados.

**Arreglo: una línea.** `and m.tipo in ('apuesta_cobro', 'apuesta_devolucion')`. El `having sum(...) > 0` que ya existe se encarga del caso en que la devolución cubrió todo.

Hoy es latente **solo** porque `retirar_caballo` no se llama desde ninguna pantalla — el frontend voltea el booleano a mano. Se vuelve activo el día que se cablee el botón, que es justo lo que falta.

## A4 · Dos liquidaciones gastan la misma caja
`supabase/migrations/20260924150000_libro_de_la_casa.sql:331-351`

`liquidar_remate` no toma **ningún** `pg_advisory_xact_lock`. Su único candado es el `for update` sobre su propia fila de `remates`. Pero `dinero_casa_disponible()` es una agregación global: **no hay ninguna fila que represente "la caja"**, así que dos liquidaciones de remates distintos no se excluyen.

**Escenario:** caja 1.000. Se liquidan R1 (premio 800) y R2 (premio 800) a la vez, o con un doble clic. Las dos leen 1.000, las dos pasan la guarda, las dos acreditan. **1.600 acreditados contra 1.000 de caja.**

El daño se materializa cuando los dos ganadores piden el retiro: `solicitar_retiro` no mira la caja, así que las dos solicitudes se aceptan y el licenciatario queda corto 600 frente a sus jugadores.

**Arreglo:** `pg_advisory_xact_lock(3, 0)` — un espacio nuevo para "la caja" — al entrar en `liquidar_remate` y en `registrar_movimiento_casa`, que son las dos únicas que la consumen.

## A5 · Un admin puede acuñar saldo de la nada
`00000000000000_baseline.sql:2603` y `:2255`

```
GRANT SELECT, INSERT, UPDATE ON deposit_requests TO authenticated;
CREATE POLICY deposit_admin_all ... FOR ALL ... USING (is_admin()) WITH CHECK (is_admin());
```

El `WITH CHECK` solo comprueba `is_admin()`: ni `user_id`, ni `estado`, ni nada. Combinado con el grant, **cualquier admin puede, desde la consola del navegador, sin pasar por ninguna RPC y sin dejar una línea en `admin_actions`**:

- insertar un depósito ya aprobado para cualquier usuario y llamar `aprobar_recarga` → acredita el saldo que quiera;
- marcar `estado = 'aprobado'` sin acreditar nada → **sube `dinero_casa_disponible()`**, que es el número del que depende la guarda de solvencia. Un admin que quiera pagar un premio que la casa no cubre solo tiene que aprobar a mano una recarga inventada.

**Es exactamente el agujero de `remates.estado` que cerramos el 28/09, en otra tabla.** Y desactiva por completo el propósito declarado del libro de la casa.

**Arreglo:** `revoke insert, update on deposit_requests from authenticated`, y sustituir `deposit_admin_all` por una política de solo `SELECT`.

## A6 · Toda tabla y toda función nueva nacen abiertas
`00000000000000_baseline.sql:2709-2712` y `:2719-2722`

```
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
-- y lo mismo ON TABLES
```

**No hace falta un `grant` para que algo quede expuesto: hace falta un `revoke` para que no lo esté.**

Esto explica el hallazgo de hoy `dinero_casa_disponible()` (A7) y explica por qué `house_ledger` y `remate_avisos` tuvieron que revocar explícitamente. Para un producto que se licencia es la mina estructural del esquema: la próxima tabla que añada cualquiera nace escribible por cualquier usuario con sesión.

**Arreglo:** `ALTER DEFAULT PRIVILEGES ... REVOKE ALL ON TABLES FROM anon, authenticated` y lo mismo `ON FUNCTIONS`. Y la regla operativa: **toda migración que cree una función o una tabla termina con su `revoke` y su `grant` explícitos.**

## A7 · `dinero_casa_disponible()` la puede llamar cualquier usuario logueado
`supabase/migrations/20260923150000_compromiso_y_caja.sql:99-101`

```sql
revoke all on function public.compromiso_usuario(uuid)  from public, anon;
revoke all on function public.dinero_casa_disponible()  from public, anon;   -- falta authenticated
```

El revoke **omite `authenticated`**, y por A6 la función ya lo tenía desde su creación. Devuelve la caja de la casa: recargas, retiros, saldo agregado de todos los usuarios y capital propio del licenciatario.

Es el mismo defecto que `casa_resumen` (tarea 2.22), **en la misma migración que lo arregló, en la función de al lado.**

**Arreglo:** un `revoke ... from authenticated`. No necesita guarda interna: solo la llaman funciones `definer` que corren como postgres.

---

# BLOQUE B — El número que ve el admin no es el que se paga

## B1 · El pozo ignora los caballos retirados, en tres sitios

| dónde | filtra retirados |
|---|---|
| `liquidar_remate` (la que paga) | ✅ |
| Pantalla del jugador | ✅ |
| `admin/remates/[id]` — resumen en vivo | ❌ |
| `admin/remates` — lista | ❌ (ni siquiera trae la columna) |
| `admin_contabilidad_resumen` (SQL) | ❌ |

**Consecuencia:** con un caballo retirado, el admin aprueba la liquidación viendo un pozo y un premio más grandes que los que se pagan. Con el escenario de la prueba P1 (pozo real 300, premio 225), la pantalla diría pozo 400 / premio 300.

Y el texto de confirmación tampoco lo corrige: descarta el mensaje que devuelve la RPC y arma el resumen con sus propios totales.

**Esto es la segunda mitad de la tarea 1.1, que nunca se hizo.** El criterio de aceptación decía "los dos cálculos del pozo dan el mismo número".

## B2 · La etiqueta "Casa 25%" clavada en el resumen de liquidación
`app/admin/remates/[id]/page.tsx:898`

El **valor** ya sale de `porcentaje_casa`. La **etiqueta** no. En un remate al 30% el admin lee literalmente `Casa 25%: 60,00 Bs`. Es el único texto que queda como constancia de la liquidación.

Igual en `app/admin/remates/page.tsx:425`: *"el pozo (bruto / 25% / neto)"*.

## B3 · Los totales del admin usan el borrador sin guardar
`app/admin/remates/[id]/page.tsx:947`

`remateDraft.porcentaje_casa` es el valor **del input**, no lo guardado. Si el admin teclea 30 y no guarda, la pantalla muestra premio al 30% mientras `liquidar_remate` paga con lo guardado. Y como `editar_remate` **prohíbe** cambiar el porcentaje si hay pujas, en cualquier remate con pujas la divergencia está garantizada.

Además: `??` solo cubre null. Si el admin **borra el campo**, vale `""`, `n("") = 0`, y la pantalla dice `Casa (0%)` y `Neto = pozo completo`.

## B4 · `1.500` se guarda como `1.50`
`app/remates/[id]/page.tsx:88-95` y `app/admin/remates/[id]/page.tsx:217-220`

`Number("1.500")` = **1.5**. Teclear `1.500` en `precio_salida` escribe **1,50** en la base — el aporte al pozo y el precio de la primera puja quedan 1000 veces abajo. `canSave` solo comprueba `> 0`.

Lo peor: el formato de lectura usa `toLocaleString("es-VE")`, que muestra el punto como separador de miles. **La app le enseña al admin exactamente el formato que luego malinterpreta.**

## B5 · La caja de la guarda y la caja del panel ya no coinciden
`dinero_casa_disponible()` suma el capital propio del `house_ledger`. `admin_contabilidad_resumen().dinero_casa` **no**.

Visible en el propio arnés: en P30, tras un aporte de 5.000, la función da 5.500 y el panel sigue diciendo 500. La tarea 2.18 rompió el invariante que la tajada A declaró ("se usa la del panel") y no actualizó el panel.

---

# BLOQUE C — Botones que no funcionan y rutas inalcanzables

## C1 · `horses.delete`: el privilegio no existe
`app/admin/remates/[id]/page.tsx:681`. `authenticated` tiene `SELECT, INSERT, UPDATE` sobre `horses` y nada más. **Cada guardado que elimine un caballo falla con 42501** — y falla *después* de que `races.update` y `editar_remate` ya se confirmaron en sus propias peticiones.

El botón "quitar caballo" **nunca ha funcionado**. Detalle irónico: la migración `20260923100000` se escribió precisamente para proteger ese botón poniendo `bids.horse_id` en RESTRICT.

## C2 · `support_settings`: la pantalla del super admin no puede guardar
`app/admin/super/soporte/page.tsx:127,141,144`. Mismo caso: política de escritura correcta, privilegio de tabla ausente. La política es **muerta**.

## C3 · La ruta de devolución diseñada está apagada en el frontend
`cancelar_remate` acepta `abierto` **o** `cerrado`, y la migración dice que la rama `cerrado` **es** la salida de la tarea 2.13 — *"un remate que se cerraba y no se podía liquidar dejaba el dinero cobrado sin forma de devolverlo salvo metiendo mano en la base"*.

Las dos pantallas lo limitan a `abierto`. **La ruta que se diseñó no se puede alcanzar desde la aplicación.**

## C4 · Los avisos se escriben y nadie los lee
`grep -rn "remate_avisos" app/` → **cero resultados.**

El aviso es la mitigación que justifica dejar cambiar el incremento con el remate en marcha. Sin lectura, el jugador no se entera de nada y la decisión del 27/09 queda sin respaldo.

Además, `remate_avisos` acepta los tipos `'escalera'`, `'precio_salida'` y `'caballo_retirado'` en su CHECK, y **nada escribe esos tres**.

## C5 · `saveAll` son 6+ peticiones sin transacción
`app/admin/remates/[id]/page.tsx:651-755`. `races.update` → `editar_remate` → `horses.delete` → N × `horses.update/insert` → `rules.delete` → `rules.insert`. Nada las envuelve.

Con C1 activo, **siempre** queda a medias cuando se borra un caballo: el remate con los horarios nuevos, la carrera con su estado nuevo, y los caballos a medio escribir. El admin lee "Error guardando cambios" sin saber qué quedó aplicado.

## C6 · La escalera se reescribe en caliente, sin candado y sin aviso
`app/admin/remates/[id]/page.tsx:749,753`. Borra todas las reglas del remate y las reinserta, en dos peticiones separadas.

`editar_remate` blindó `incremento_minimo` — que es el **respaldo**. La escalera es la que de verdad manda: `_incremento_aplicable()` la consulta primero. **Se blindó el parámetro secundario y se dejó abierto el principal.**

Y si el insert falla, el remate queda **sin escalera** y todos los caballos pasan al incremento plano, en silencio.

## C7 · `retirado` y `precio_salida` se escriben a mano, existiendo `retirar_caballo()`
`app/admin/remates/[id]/page.tsx:689-698`. `retirar_caballo` exige motivo, rechaza si algún remate de la carrera está liquidado, **devuelve el dinero cobrado** en los remates cerrados, y audita. El frontend **nunca la llama**: voltea el booleano.

Hoy está contenido por accidente —`editar_remate` corre antes y rechaza remates no abiertos— no por diseño. Se reabre en cuanto alguien reordene el guardado, o en cuanto haya **dos remates sobre la misma carrera**, que nada impide: `remates.race_id` no tiene unique y los caballos pertenecen a la carrera, no al remate.

## C8 · `numero` de caballo editable con pujas
`set_ganador_carrera(p_remate_id, p_horse_num)` resuelve el ganador **por número**. Renumerar caballos cambia a quién se le paga el premio.

---

# BLOQUE D — Integridad del resultado de la carrera

## D1 · `race_results` sin unicidad, y `set_ganador_carrera` sin candado
`00000000000000_baseline.sql:1664-1671`. Es un *update-then-insert* sin candado, sobre una tabla **sin restricción única en `race_id`**.

Dos llamadas simultáneas (dos admins, un doble clic, el reintento de un fetch) → las dos hacen `update` que afecta 0 filas, las dos insertan. **Dos filas de `race_results` para la misma carrera, con ganadores posiblemente distintos.**

Después, `liquidar_remate` hace `select ... into` **sin `limit` y sin `strict`**: PL/pgSQL toma la primera fila que devuelva el plan, sin error y sin aviso. **El ganador pagado es indeterminado.**

**Arreglo:** `unique (race_id)` + `insert ... on conflict do update`, y `limit 1` en la lectura como segunda red.

## D2 · Se puede reescribir el ganador de una carrera ya pagada
`set_ganador_carrera` exige que **el remate que se le pasa** esté cerrado, pero escribe en `race_results`, indexada por **carrera**. Con dos remates sobre la misma carrera —uno liquidado, otro cerrado— se reescribe el resultado que justificó el pago ya hecho.

Las FK se pusieron en RESTRICT precisamente para que no se borrara *"la prueba de quién ganó y por qué se pagó lo que se pagó"*. Dejarla **modificable con un update** es la misma pérdida por otra puerta.

## D3 · Nada impide un saldo negativo en la base
`wallets` no tiene `CHECK (saldo_disponible >= 0)`. El invariante vive **exclusivamente** en el cuerpo de tres funciones PL/pgSQL. Cualquier ruta que no pase por ellas puede dejar el saldo en negativo: `service_role`, un `psql` de mantenimiento, una migración futura, o el propio A2.

---

# BLOQUE E — El arnés

Ocho pruebas no podían fallar. Las más graves:

| prueba | sale verde sin probar nada cuando… |
|---|---|
| **P4** | `liquidar_remate` no existe (`42883`) → cualquier excepción enciende el "falló". Y si se cae `dinero_casa_disponible()`, P4 declara que la guarda de solvencia funciona **cuando la guarda no existe** |
| **P24** | `solicitar_retiro` cambia de firma. **Es la prueba cuya cabecera dice "mientras esta prueba siga roja, la app NO puede tener usuarios reales pujando"** — y se puede poner verde borrando la función |
| **P6** | cuatro `exception when others then null` seguidos. Si cerrar, liquidar y retirar fallaran los tres, solo quedarían las recargas y el invariante se cumple trivialmente |
| **P19** | compara dos fórmulas en la única configuración en que no pueden diferir (`_p.limpiar` borra `house_ledger`). **Y tapa la divergencia real B5** |
| **P21** | comprueba que existe un candado, no que sea el correcto. No compara el `objid` contra el hash del usuario |
| **P28** | bucle vacío = verde. Si `remate_minimos` devolviera cero filas, declara "coinciden en los 3 caballos" sin comparar nada |
| **P29, P3** | mismo patrón: `42883` las aprueba / comparan 0 contra 0 |

**El andamiaje también miente en un punto:** `_p.usuario` crea el `deposit_requests` que respalda el saldo pero **no** el `wallet_movements` de recarga. Produce un estado que la aplicación real no puede producir, y hace que el invariante de P6 sea **falso por construcción** para cualquier usuario creado con saldo. P6 se salva solo porque crea a sus usuarios en 0 y los recarga por la puerta buena.

**Y el andamiaje usa la puerta trasera que queremos cerrar:** P1 y P18 hacen `update horses set retirado = true` a mano en vez de llamar a `retirar_caballo`. P18 dice probar "el caballo retirado sale solo" y lo que prueba es `compromiso_usuario` contra un update a mano.

**Cobertura ausente, lo que más duele:** la composición `retirar_caballo` → `cancelar_remate` (A3) no tiene prueba; el ganador retirado tiene guarda en el código y ninguna prueba; `procesar_retiro`, `rechazar_recarga` y `archivar_remate` no tienen una sola línea; y las bandas de la escalera de precios se prueban en un único punto (`min=0, max=null`), o sea que la selección por banda, el desempate y el caso "ninguna regla aplica" nunca se ejercitan.

---

# Lo que hay que decidir antes de arreglar

Cinco decisiones que no puedo tomar yo:

1. **A1 — los datos bancarios.** ¿A `support_settings`, que ya existe con su CRUD, o a una tabla `app_settings` de ajustes de instalación con clave/valor tipado? La segunda es más trabajo y más limpia si van a venir más ajustes por licenciatario (y van a venir: SMTP, zona horaria, branding).

2. **A2 — cómo cerrar la carrera puja/cierre.** `for share` en `hacer_puja` es **una línea** y cierra los dos escenarios; el `advisory(2, remate)` explícito en las cuatro funciones de cierre hace el orden visible en el código pero toca más. Recomiendo `for share` ahora y el refactor explícito en el bloque 4.

3. **C6/C7 — con pujas en curso, ¿la escalera y el `precio_salida` se bloquean o se permiten con aviso?** Ya decidiste que la escalera **sí** se puede editar en marcha, con aviso. Falta `precio_salida`: yo lo bloquearía —cambia el aporte al pozo de un caballo que ya tiene dueño— pero es tu negocio.

4. **B5 — la caja.** ¿`admin_contabilidad_resumen` pasa a sumar el capital propio, o `dinero_casa_disponible()` deja de sumarlo? Defiendo lo primero: la guarda de solvencia **tiene** que ver el capital propio, si no volvemos al problema que abrió la tarea 2.18. Pero cambia el número que ves en pantalla.

5. **El `porcentaje_casa` por defecto de esta instalación: ¿20 o 25?** Hoy hay dos respuestas en el repo — el esquema dice `DEFAULT 20.00`, el formulario precarga `25`, y los respaldos `coalesce(..., 25)` dicen 25. Un remate creado sin pasar por el formulario paga el **80%** mientras la interfaz dice 75%.

---

# Orden de trabajo propuesto

**Tanda 1 — SQL quirúrgico, una migración.** A2 (`for share`), A3 (un filtro), A4 (`advisory(3,0)`), A5 (`revoke` + política de solo select), A6 (`ALTER DEFAULT PRIVILEGES` + revokes), A7 (`revoke`), D1 (`unique` + `on conflict`), D3 (`check >= 0`). Son ocho arreglos y ninguno pasa de diez líneas. Con sus pruebas, cada una verificada en rojo antes.

**Tanda 2 — el número que se ve.** B1, B2, B3, B4, B5. Y el arreglo de fondo: una RPC `remate_totales(p_remate_id)` que devuelva pozo, porcentaje, casa y neto desde la misma consulta que `liquidar_remate`, consumida por las tres pantallas. **Cuatro copias → una.** Mientras cada pantalla lo calcule por su cuenta, esto vuelve.

**Tanda 3 — el arnés.** El retrofit de SQLSTATE (que ya estaba anotado como tarea 0.4, y ahora tiene ocho casos concretos), el arreglo del andamiaje, y las pruebas que faltan de lo que se arregle en las tandas 1 y 2.

**Tanda 4 — la pantalla de edición.** C1 a C8, con `guardar_remate_completo()` transaccional. Es la que más trabajo cuesta y la que arregla la clase entera.

**Fase 2 — A1**, con el resto de los ajustes por instalación.

---

# ADENDA — 29 de septiembre de 2026

Lo que apareció al **escribir las pruebas** de los arreglos de esta auditoría, no al escribirlos. Tres de los cuatro hallazgos de abajo salieron de una prueba que se negó a ponerse verde.

## A6 estaba mal resuelto, y lo dijo la prueba

El arreglo original hacía:

```sql
alter default privileges for role postgres in schema public
  revoke all on functions from public;
```

**No hace nada.** La documentación de PostgreSQL usa ese comando exacto como ejemplo de lo que no funciona: *"you cannot accomplish that effect with a command limited to a single schema... per-schema default privileges can only add privileges to the global setting, not remove privileges granted by it."*

La entrada global sí funciona, pero aplica a todos los esquemas. Comprobado en un Postgres real: con ella puesta, `create extension citext` deja sus 23 funciones sin `EXECUTE` para `authenticated`, lo que rompe un simple `where columna = 'x'`. Para una base que opera un licenciatario es una mina con retardo.

**Resolución (decisión de Jota, 29/09):** la base no falla cerrada en funciones; el arnés falla ruidoso. Ver ADR-016 y las pruebas P47 y P48.

## A5 era uno de quince

`deposit_requests` no tenía nada especial. El diagnóstico del 29/09 contra la base real mostró que **las quince tablas de `public` nacieron con `GRANT ALL` para `anon` y `authenticated`**, por el `ALTER DEFAULT PRIVILEGES` que trae la imagen de Supabase antes de la primera migración. Ninguna migración lo escribió; se aplicó solo.

Con las políticas `*_admin_all` siendo `FOR ALL`, la consecuencia concreta:

> Un admin podía hacer `supabase.from('wallets').update({saldo_disponible: 999999})` desde la consola del navegador. Y escribir o borrar filas de `wallet_movements`, que es exactamente lo que lee el cuadre: **falsear los libros y la auditoría que comprueba los libros, con la misma sesión.**

Contradecía de frente la regla del 24/09: *"ese 25% va directo EN EL SISTEMA a donde tiene que mostrarse, eso no se puede dejar a criterio del admin"*.

## D4 (nuevo) · `TRUNCATE` no pasa por la RLS

Doc 17, 5.9, literal: *"Operations that apply to the whole table, such as `TRUNCATE` and `REFERENCES`, are not subject to row security."*

`anon` y `authenticated` tenían el privilegio `D` (TRUNCATE) sobre las quince tablas, `wallets` y `wallet_movements` incluidas. Ninguna política lo frenaba **porque ninguna política puede frenarlo**. Hoy no es explotable por la vía normal —PostgREST no expone TRUNCATE— pero es la demostración de que un modelo de seguridad que solo mira políticas es ciego a una clase entera de permisos.

Resuelto: los revokes de la tanda usan `revoke all` y vuelven a conceder solo lo necesario, en vez de nombrar verbo por verbo.

## Doce revokes que parecían hechos y no lo estaban

Doce funciones llevaban `=X/postgres` en su ACL: el `EXECUTE` que PostgreSQL da a `PUBLIC` de fábrica. Un `revoke ... from anon` no lo quita.

El caso que lo demuestra: `20260925100000_permisos_rpc.sql:109` hizo `revoke all on function public.mi_wallet_resumen() from anon` — y el diagnóstico del 29/09 seguía dándola como ejecutable por `anon`, cuatro días después. El revoke estaba escrito, revisado y era inútil.

**Regla que sale de aquí:** todo revoke sobre una función se escribe `from public, anon, authenticated`. No hay atajo.

## C1 · Corrección a esta misma auditoría

El apartado C1 afirma que *"el privilegio `horses.delete` no existe"*. **Es falso.** El diagnóstico contra la base real muestra `anon=arwdDxtm` sobre `horses`: el privilegio existía. Lo que fallaba en el botón de quitar caballo era otra cosa, y se afirmó sin comprobarlo.

Queda como recordatorio de la regla que más veces se ha roto en este proyecto: **verificar contra la base, no contra la lectura del código.**

## Lo que quedó probado, y cómo

- 49 pruebas en verde, las diez nuevas (P40–P49) verificadas **en rojo primero**.
- P47 y P48 son censos: enumeran todas las funciones y todas las tablas y se ponen rojos ante cualquier objeto no declarado.
- Recorrido manual completo por la aplicación contra la base local, con `.env.development.local`, sin un solo `permission denied`. El arnés no puede sustituir a ese recorrido: corre como `postgres` y se salta todos los permisos.

## Pendientes abiertos el 29/09

| | qué |
|---|---|
| **Escalera general** | `crear-remate` sigue escribiendo reglas con `horse_id: null`, que ganan sobre `remates.incremento_minimo`. Cambiar el incremento en `editar_remate` no surte efecto en los caballos sin reglas propias. Contradice la decisión del 24/09. |
| **`hacer_puja` sin guarda de admin** | La regla "los admins no pueden pujar" vive solo en el frontend (`app/remates/[id]/page.tsx:188`). Un admin puede pujar por RPC, en su propio remate, viendo todas las pujas. ADR-015. |
| **`remate_minimos.soy_lider`** | Devuelve NULL en vez de `false` cuando quien consulta no tiene sesión. Falta un `coalesce(..., false)`. |
| **Mensaje de saldo insuficiente** | La aritmética es correcta; la redacción no dice el número que importa (lo que queda libre) y "otras pujas" es ambiguo. Además el texto lo escribe la base: según ADR-015 debería devolver números y que el frontend arme la frase. |
| **Realtime** | Recargas en el panel, pujas y últimas pujas exigen recargar la página. Tarea 2.25. |
| **Notificaciones** | Nadie avisa cuando un usuario pide una recarga. Intención de Jota: correo, WhatsApp y Telegram. Y `NOTIFY_EMAIL_TO` admite un solo destinatario. |
| **Formulario de recarga** | Pide teléfono aunque el método sea transferencia. Propuesta: campos por método, y nunca la cuenta completa — titular más los últimos cuatro dígitos bastan para cuadrar. |
| **Marca y ajustes de instalación** | `layout.tsx` traía el título de `create-next-app`, corregido el 29/09. El footer sigue con la marca fija. Modelo acordado: cada licenciatario como su propio sitio dentro de la plataforma. |
| **Interfaz** | Navbar superior, nombre de usuario visible en todas las secciones, escalera con los tres ritmos en la pantalla de edición, ver incremento y pozo por caballo desde ahí. |
| **Concurrencia** | A2, A4 y la carrera de `set_ganador_carrera` no se reproducen con una sola conexión. Falta `tests/concurrencia.sql`. |
