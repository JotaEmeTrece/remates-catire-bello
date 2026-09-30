# Registro de decisiones de arquitectura

Cada entrada anota una decisión que costó pensar, **por qué** se tomó, y **qué la revertiría**. Ese último campo no es estándar en un ADR y es el que más vale: una decisión sin condición de salida se convierte en dogma, y dentro de un año nadie se acuerda de si seguía teniendo sentido.

Las decisiones no se borran. Si una se cambia, se marca como reemplazada y se escribe una nueva debajo.

**Última actualización:** 27 de septiembre de 2026.

---

## ADR-001 · Un repo, una base de datos por cliente

**Contexto.** La app se va a licenciar a terceros. Las opciones eran multi-tenant (todos los clientes en una base, separados por columna) o una instalación por cliente.

**Decisión.** Código único en un solo repo; **base de datos separada por cliente**.

**Por qué.** En multi-tenant, un error en una política de RLS expone el dinero de un cliente a otro. Con bases separadas, ese error es imposible por construcción. Y el cliente es "la casa" —maneja dinero real de sus usuarios— así que el aislamiento no es una comodidad, es el requisito.

**Consecuencias.** Cada alta de cliente es un aprovisionamiento, no un `INSERT`. Hay que automatizarlo (Fase 2). Una migración se aplica N veces, una por instalación.

**Qué la revertiría.** Que el número de clientes crezca hasta que aprovisionar y migrar a mano sea el cuello de botella. Ese día se automatiza el despliegue, no se junta la base.

---

## ADR-002 · Las migraciones son la fuente de verdad, no producción

**Contexto.** Hasta septiembre de 2026 la base de producción estaba **por delante del repo**: había correcciones aplicadas a mano en Supabase que no existían en `sql/`, y al menos un script del repo que revertía una de ellas. Se encontraron **tres generaciones distintas** de la lógica de liquidación circulando a la vez.

**Decisión.** `supabase/migrations/` es la fuente de verdad. Nada se aplica a producción sin pasar por una migración versionada.

**Por qué.** Cuando la verdad vive en producción, no hay forma de saber qué está corriendo sin mirarlo, y no hay forma de reproducirlo en otra instalación — que es justo lo que exige el ADR-001.

**Consecuencias.** Se volcó el esquema real a un baseline y se adoptó producción con `migration repair`. `app/SUPABASE_CONTEXT.md`, que era la foto a mano, quedó marcado como **legacy**.

**Qué la revertiría.** Nada. Si esto se rompe, se rompe todo lo demás.

---

## ADR-003 · El compromiso se calcula, no se guarda

**Contexto.** El modelo original apartaba el dinero al pujar: `saldo_disponible −monto`, `saldo_bloqueado +monto`. Si te superaban, se te devolvía y se le apartaba al siguiente. Cada puja eran cuatro escrituras de dinero que tenían que salir bien las cuatro.

**Decisión.** El compromiso de un usuario es **la suma de las pujas que lidera ahora mismo**, calculada en el momento en que se pregunta. Durante el remate no se escribe nada en `wallets`.

**Por qué.** Un número guardado hay que mantenerlo sincronizado, y cada sincronización es una oportunidad de que aparezca o desaparezca dinero. Un número calculado no puede desincronizarse de sí mismo. El caso de subir tu propia puja —que en el modelo viejo exigía calcular un "delta" a mano— sale gratis.

**Consecuencias.** `hacer_puja` escribe una fila en `bids` y nada más. `wallets.saldo_bloqueado` vale 0 siempre; **la columna se conserva a propósito y el arnés verifica que sea 0**, en vez de borrarla a ciegas y perder la red. El coste es una consulta por puja, cubierta con dos índices.

**Qué la revertiría.** Que `compromiso_usuario()` se vuelva lenta con volumen real. Ahí se cachearía — pero con una prueba que compare el caché contra el cálculo, no reemplazándolo.

---

## ADR-004 · El dinero se cobra al cerrar, no al liquidar

**Contexto.** Terminar un remate son dos momentos separados por un hueco indefinido: se acaban las pujas, y más tarde se sabe quién ganó la carrera. En el modelo viejo el dinero seguía en `saldo_bloqueado` entre los dos: ya no era gastable, pero seguía contando como patrimonio del usuario y todavía no había entrado al pozo.

**Decisión.** **Cerrar** cobra a cada líder de puja. **Liquidar** solo paga el premio.

**Por qué.** Deja el dinero en un solo sitio en cada momento, sin limbo. Y hace que el estado `cerrado` signifique algo concreto: la plata ya salió.

**Consecuencias.** `cerrar_remate()` delega en `_cerrar_remate_interno(uuid)` porque el cron corre sin `auth.uid()` y **tiene que pasar por el mismo camino que el botón**. Antes no lo hacía: el cron cerraba con un `UPDATE` plano y no cobraba a nadie, lo que escondió un defecto grave durante meses.

**Qué la revertiría.** Nada previsto.

---

## ADR-005 · Candado consultivo por usuario, siempre en el mismo orden

**Contexto.** Sin candado, dos operaciones simultáneas del mismo usuario leen el mismo saldo y las dos pasan. **Verificado con dos conexiones reales**, no es teoría: un usuario con 500 que puja 300 a dos caballos a la vez termina con 600 comprometidos; y una puja de 800 simultánea con un retiro de 1000 pasan las dos.

**Decisión.** `pg_advisory_xact_lock(1, hashtext(user_id))` en las cinco funciones que mueven dinero. **Espacio de usuario (1) siempre antes que espacio de caballo (2)**, y los bucles ordenados por `user_id`.

**Por qué.** El invariante `saldo_disponible >= compromiso_usuario()` solo se sostiene si nadie puede leer y escribir en paralelo sobre el mismo usuario.

**Consecuencias.** El orden fijo no es estética: es lo que evita el interbloqueo. Cualquier función nueva que toque dinero **tiene que respetarlo**, y eso hay que recordarlo al escribirla — el compilador no ayuda aquí.

**Qué la revertiría.** Nada. Si hay contención medible, se afina el alcance del candado, no se quita.

---

## ADR-006 · La guarda va dentro de la función, no solo en la tabla

**Contexto.** `house_ledger` tenía RLS activa con una política `using (is_admin())`. Aun así, cualquier usuario logueado podía leer el patrimonio de la casa llamando a `casa_resumen()` desde la consola del navegador.

**Decisión.** Toda función `security definer` expuesta a `authenticated` comprueba **dentro** quién la llama.

**Por qué.** Una función `definer` lee la tabla **por encima** de la RLS. La política de la tabla no protege el dato que una función devuelve sumado.

**Consecuencias.** Se auditaron las 31 funciones con grant a `authenticated` o `anon` y se encontraron cuatro agujeros más, dos graves: `auto_cerrar_remates()` y `log_admin_action()` estaban abiertas a **`anon`**. Y una lección de fondo: **`CREATE OR REPLACE FUNCTION` no toca los permisos**, así que los grants de la baseline sobrevivieron intactos a todas las migraciones que reescribieron los cuerpos. Revisar el cuerpo no basta — hay que mirar el ACL aparte. La prueba P33 lo comprueba con `has_function_privilege()`.

**Qué la revertiría.** Nada.

---

## ADR-007 · El libro de la casa tiene un asiento que el admin no puede escribir

**Contexto.** La casa aporta al pozo los caballos que nadie puja, pero esa contribución nunca entraba como efectivo: `dinero_casa_disponible()` daba negativo siempre y la guarda de solvencia bloqueaba casi toda liquidación.

**Decisión.** `house_ledger` con cuatro tipos de asiento. Tres los escribe el admin (capital, utilidad, ajuste). El cuarto —`resultado_remate`— **lo escribe el sistema al liquidar y `registrar_movimiento_casa()` lo rechaza a propósito.**

**Por qué.** Esta fue una corrección de Jota, y tenía razón. La propuesta inicial era no registrar la comisión para no contarla dos veces. Estaba mal planteada: el libro no es *otra fuente del mismo número*, es una **fuente independiente que tiene que cuadrar**. Si el admin pudiera escribir ese asiento, las dos fuentes dejarían de ser independientes y el cuadre no significaría nada.

**Consecuencias.** `casa_resumen()` expone `descuadre`, que debe ser 0 siempre. El panel avisa en ámbar si no lo es. Verificado: la prueba P31 detecta un asiento falso.

**Qué la revertiría.** Nada.

---

## ADR-008 · Una sola fuente para los mínimos de puja

**Contexto.** El frontend reimplementaba en TypeScript la escalera de precios que la base ya calculaba dentro de `hacer_puja`. El 23/09 se demostró que las dos implementaciones se habían separado sin que nadie se enterara: **la pantalla mostraba un número y la base cobraba otro.**

**Decisión.** `_incremento_aplicable()` es el único sitio donde se elige la regla. `remate_minimos()` devuelve por caballo todo lo que la pantalla necesita. **El frontend muestra, no calcula.**

**Por qué.** Dos implementaciones de la misma regla siempre acaban separándose. La única pregunta es cuándo te enteras.

**Consecuencias.** El defecto que lo destapó (1.10) era de una línea: `NULL = uuid` devuelve NULL y `ORDER BY DESC` pone los NULL **primero**, así que la regla por caballo **nunca** ganaba sobre la general.

**Qué la revertiría.** Nada. Cualquier cálculo de dinero nuevo nace en la base.

---

## ADR-009 · Una prueba que pasa antes del arreglo no prueba nada

**Contexto.** Varias pruebas escritas de buena fe resultaron no estar midiendo lo que decían. Una comparaba 0 contra 0. Otra dejó de ejercitar su escenario cuando cambió el modelo y siguió en verde sin probar nada.

**Decisión.** Toda prueba nueva se verifica **en rojo contra el código roto** antes de darla por buena. Si no se puede poner roja, no es una prueba.

**Por qué.** Una prueba verde da una confianza que puede ser falsa, y una prueba falsa es peor que ninguna: impide buscar el fallo donde sí está.

**Consecuencias.** El arnés es SQL puro (`tests/pruebas_dinero.sql`), sin dependencias, y corre completo en segundos. Distingue pruebas que detectan **divergencia** de las que detectan que algo está **mal**.

**Corolario añadido el 28/09, después de violar este mismo ADR dentro del arnés.** Cuando el éxito de una prueba consiste en "saltó una excepción", hay que comprobar **cuál**. P39 pasaba en verde sin la migración aplicada: llamaba a una función inexistente, saltaba `undefined_function`, y su `exception when others` lo contaba como el rechazo que buscaba. Las dos mitades aprobaban porque no había nada que probar. La prueba debe **(a)** comprobar primero que existe lo que va a ejercitar, **(b)** exigir el SQLSTATE correcto —`P0001` para un rechazo nuestro, no `42883`— y **(c)** verificar además que no se escribió nada.

**Qué la revertiría.** Nada.

---

## ADR-010 · El CLI de Supabase se fija en scripts, no como dependencia

**Contexto.** `npx supabase` sin versión descarga lo que sea `latest` ese día. La documentación afirmaba que estaba instalado como dependencia del proyecto; **era falso**, nunca lo estuvo.

**Decisión.** Scripts en `package.json` con la versión escrita: `db:start`, `db:stop`, `db:reset`, `db:push:produccion`, todos con `npx -y supabase@2.118.0`.

**Por qué.** Meterlo como `devDependency` lo fijaría, pero Vercel instala las devDependencies en cada build y el paquete baja un binario de ~40 MB que el build no usa jamás. La idea de moverlo a scripts fue de Jota y es mejor que la alternativa que yo proponía (escribir la versión a mano cada vez, que nadie sostiene).

**Consecuencias.** El `-y` es obligatorio: sin él, el prompt de npx cuelga el script. El nombre largo de `db:push:produccion` es deliberado — toca producción y no debe escribirse por accidente.

**Qué la revertiría.** Que el CLI pase a hacer falta en el build. No se ve cómo.

---

## ADR-011 · El autocierre es opcional y viene apagado

**Contexto.** Hay dos tipos de remate. El **en vivo** dura horas el día de la carrera. El **adelantado** se monta días antes y puede seguir abierto hasta el sábado.

**Decisión.** El cierre automático por horario es una casilla que el admin marca si quiere, **apagada por defecto**. La apertura automática sí queda siempre activa.

**Por qué.** Cerrar solo es correcto para un remate en vivo. En un adelantado, `closes_at` es una hora estimada, y cerrar automáticamente ahí **cobra** a gente que el admin quería seguir dejando pujar.

**Consecuencias.** Con el autocierre apagado, `closes_at` queda como informativa, pero `hacer_puja` sigue rechazando pujas pasada esa hora. **Pendiente de implementar**: hoy `auto_cerrar_remates()` cierra todo lo vencido sin mirar ninguna casilla.

**Qué la revertiría.** Que en la práctica todos los remates sean en vivo. Entonces el valor por defecto cambia, no la opción.

---

## ADR-012 · La app no custodia dinero

**Contexto.** El cliente es la casa: cobra las recargas, paga los retiros y se queda su comisión. El dinero se mueve entre personas, por fuera.

**Decisión.** La plataforma es un **registro contable**, no un medio de pago. No tiene cuenta bancaria, no recibe pagos y no transfiere nada. Refleja lo que la casa confirma haber recibido y pagado.

**Por qué.** Es lo que de verdad hace. Documentarlo de otra forma sería describir mal el producto.

**Consecuencias.** Está escrito así en `docs/MODELO_DE_SALDO.md` y en `docs/licencia/COMO_FUNCIONA_EL_DINERO.md`. Los dos documentos dicen además que **los requisitos legales de operar así cambian según el país y son consulta con un abogado de esa jurisdicción** — ni del desarrollador ni del proveedor de la licencia.

**Riesgo estructural anotado, sin resolver:** nada impide hoy que una casa pague un premio con dinero que en realidad es del saldo de sus usuarios. El sistema lo **detecta** y avisa en rojo, pero no lo puede impedir: no controla la cuenta bancaria. La mitigación es la recomendación de tener dos cuentas separadas, y es una recomendación, no una garantía.

**Qué la revertiría.** Integrar una pasarela de pago de verdad (Fase 2). Eso cambiaría el modelo entero y exigiría rehacer esta decisión desde cero, con asesoría legal.

---

## ADR-013 · El borrado de un usuario lo frena una clave foránea, no un trigger

**Contexto.** La cadena `auth.users → profiles → wallets → wallet_movements`, más `profiles → bids / deposit_requests / withdraw_requests`, estaba entera en CASCADE. Borrar un usuario desde el panel de Auth de Supabase se llevaba su saldo, su historial de dinero y sus pujas — y borrar pujas de un remate abierto cambia en silencio quién va ganando, o sea el pozo y el compromiso de los demás.

**Decisión.** RESTRICT en los eslabones que **son** un dato (`wallet_movements`, `bids`, `deposit_requests`, `withdraw_requests`, `race_results→races`). CASCADE en los que **no** lo son (`profiles→auth.users`, `wallets→profiles`, `remate_price_rules→*`).

**Por qué así y no de otra forma.** Se consideró un log de auditoría que registrara el borrado para que el admin ajustara después. **No funciona, y no por falta de esfuerzo:** el cuadre de `casa_resumen()` se calcula desde `deposit_requests`, `withdraw_requests` y `wallets`, que son justo las tablas borradas — no queda un descuadre que ajustar, desaparece un sumando. Y las pujas de un remate abierto no son un asiento contable: para deshacerlas habría que reinsertarlas, o sea que el log tendría que ser una copia completa de las filas. Peor todavía: si borrar usuarios puede causar descuadres legítimos, la alarma ámbar deja de significar "hay un bug" y pasa a significar "revisa el log" — que es como se muere una alarma.

**Consecuencias.** El comportamiento sale del orden en que Postgres resuelve las cascadas, **sin un solo trigger ni lógica que mantener**: un usuario con cualquier rastro de dinero o pujas no se puede borrar; uno que se registró y nunca hizo nada sí. Esto último no es un detalle: `handle_new_user` crea un wallet al registrarse, así que un RESTRICT a secas sobre `wallets` habría bloqueado hasta las cuentas de prueba.

El costo es que el admin ve un error crudo de Postgres en el panel de Supabase. Un `desactivar_usuario()` con mensaje decente queda para el ADR de roles.

**Qué la revertiría.** Que aparezca una obligación legal de borrado real de datos personales en alguna jurisdicción donde opere un licenciatario. Eso exigiría separar el dato personal del dato contable —anonimizar en vez de borrar— y sería una decisión nueva, con asesoría legal.

---

## ADR-014 · Los avisos al jugador los escribe el sistema, no el admin

**Contexto.** Se decidio (27/09) que el admin pueda cambiar el incremento de un remate en marcha —un remate estancado puede necesitar subir mas rapido— y el porcentaje de la casa antes de la primera puja. Los dos cambian lo que el jugador esperaba cuando entro.

**Decision.** Tabla `remate_avisos`, escrita **desde dentro de las RPC de edicion**. El admin no redacta el aviso ni puede omitirlo: si el cambio ocurre, el aviso existe. Lectura publica (`anon` incluido), escritura solo por RPC.

**Por que.** Es el mismo razonamiento del asiento `resultado_remate` del ADR-007: **un aviso que depende de que alguien se acuerde de escribirlo no es un aviso, es una intencion.** Si el admin pudiera elegir si anunciar o no, el jugador no tendria forma de distinguir "no cambio nada" de "cambio y no me lo dijeron".

**Consecuencias.** El texto del aviso lo compone la funcion a partir del valor anterior y el nuevo, asi que dice siempre la verdad y siempre en el mismo formato. `detalles` guarda los dos valores en jsonb para poder auditar sin parsear texto.

**Qué la revertiría.** Nada previsto. Si aparecen mas campos editables en marcha, se suman al mismo mecanismo.

---

## ADR-015 · Una regla se implementa una vez, y vive donde vive el dato

**Regla de Jota, 28/09/2026, literal:** *"Erradica todo lo que se haga en la DB y en el frontend y que son la misma cosa. Ya vemos que eso trae confusión y desastre. Lo que es DB que sea solo allá y lo que debe ser FE solo ahí."*

**Contexto.** La auditoría del 28/09 encontró la misma regla implementada en varios sitios, tres veces:

- **El pozo y la comisión de la casa:** en `liquidar_remate`, en `admin_contabilidad_resumen`, y en TypeScript en tres pantallas. Cinco implementaciones. Las del admin no filtraban caballos retirados y una tenía el 25% clavado, así que el admin aprobaba pagos viendo cifras que no eran las que se iban a pagar.
- **Los mínimos de puja:** en `hacer_puja` y en el frontend. Divergieron el 23/09 y la pantalla mostraba un número mientras la base cobraba otro. Se resolvió con `remate_minimos()`.
- **Quién va ganando un caballo:** en cuatro funciones SQL y en tres pantallas. Hoy coinciden. Es cuestión de tiempo.

**Decisión.** Toda regla de negocio —lo que se cobra, lo que se paga, quién gana, qué cuenta y qué no— se implementa **una sola vez, en la base**, y se expone por RPC. **El frontend muestra, no calcula.**

El criterio para decidir dónde va algo: *si el número tiene consecuencias en el dinero, va en la base.* Si es presentación —formato, colores, orden de una lista, qué se ve primero— va en el frontend y solo ahí.

**Por qué.** No es preferencia de arquitectura: es que **dos implementaciones de la misma regla siempre acaban separándose, y la única pregunta es cuándo te enteras.** En este proyecto nos enteramos tres veces, y las tres por casualidad: mirando un número que no cuadraba. El caso del pozo llevaba desde enero.

Y tiene una consecuencia que importa para licenciar: un licenciatario que configure el 20% y una pantalla que calcule el 25% no producen un error — producen un pago incorrecto con una interfaz que lo confirma.

**Consecuencias.**
- Las pantallas que hoy calculan el pozo pasan a consumir una RPC `remate_totales(p_remate_id)` que devuelva pozo, porcentaje, casa y neto **desde la misma consulta que `liquidar_remate`**. Cuatro copias → una.
- `remate_minimos()` es el precedente y el patrón: devuelve por caballo todo lo que la pantalla necesita dibujar.
- Ningún valor de negocio se escribe a mano en el frontend. Los que hoy lo están —el porcentaje por defecto, el precio de salida por defecto, el incremento— pasan a los ajustes de instalación.
- Cuando una regla cambie, cambia en un sitio. Si hay que tocar dos archivos para cambiar una regla, la regla está mal puesta.

**Qué la revertiría.** Un cálculo de presentación pura que necesite ser interactivo sin ida y vuelta al servidor — por ejemplo la simulación de la escalera al elegir el ritmo, que no mueve dinero y tiene que responder al teclear. Esos casos existen y son legítimos; la prueba para distinguirlos es si el número que sale puede diferir del que se cobra. Si puede, va en la base.

---

## ADR-016 · Los permisos son un inventario declarado, no una consecuencia

**Contexto.** El 29/09, al probar A6, se descubrió que `ALTER DEFAULT PRIVILEGES` no es una rareza de este proyecto: la imagen de Supabase trae, antes de cualquier migración, `GRANT ALL ON TABLES TO anon, authenticated` para todo lo que cree `postgres` en `public`. Su propio `config.toml` lo llama *"matching the cloud default"*. Las quince tablas del esquema nacieron abiertas sin que ninguna migración lo escribiera, y por tanto sin que apareciera en ningún diff.

Cerrarlo desde la base resultó imposible para las funciones. PostgreSQL concede `EXECUTE` a `PUBLIC` de fábrica, y su documentación dice literalmente que un revoke con `IN SCHEMA` **no hace nada**: *"per-schema default privileges can only add privileges to the global setting, not remove privileges granted by it."* La entrada global sí funciona, pero aplica a todos los esquemas: comprobado en un Postgres real, tras ponerla un `create extension citext` deja sus 23 funciones sin `EXECUTE` para `authenticated`, lo que rompe hasta un `where columna = 'x'`. En una base que opera un licenciatario, eso es una mina.

**Decisión.** La base **no** falla cerrada en funciones. El arnés falla ruidoso.

- `P47` enumera todas las funciones de `public` y las compara contra una lista blanca declarada. Una función que nadie declaró se pone roja.
- `P48` hace lo mismo con las tablas, verbo por verbo, para `anon` y para `authenticated`.
- Toda RPC nueva necesita dos cosas: su `grant execute` y su línea en el censo. Con solo una de las dos, el arnés está rojo.

**Por qué.** El defecto real no era que algo naciera abierto: era que **nadie se enteraba**. Un censo que enumera el estado completo y falla ante lo no declarado convierte un silencio en un rojo, y no deja minas en casa de nadie.

**Y una segunda razón, del mismo día.** `TRUNCATE` no pasa por la RLS — doc 17, 5.9: *"Operations that apply to the whole table, such as TRUNCATE and REFERENCES, are not subject to row security."* `anon` y `authenticated` tenían ese privilegio sobre las quince tablas. Ninguna política lo frenaba porque **ninguna política puede frenarlo**. Un modelo de seguridad que solo mira las políticas es ciego a esa clase entera de permisos. El censo mira el privilegio.

**Consecuencias.**
- Los revokes se escriben siempre en la forma completa: `from public, anon, authenticated`. Doce funciones llevaban `=X/postgres` y sobrevivieron a revokes que solo nombraban a `anon` — `mi_wallet_resumen` entre ellas, revocada el 25/09 y todavía ejecutable por `anon` el 29/09.
- Los permisos no se prueban ejercitándolos: el arnés corre como `postgres` y se salta cualquier ACL. Se consultan con `has_table_privilege` y `has_function_privilege`.
- Como el arnés no puede ver una rotura de permisos en la aplicación, **toda tanda que quite permisos se clica a mano contra la base local** antes de subir. De ahí sale `.env.development.local`.

**Qué la revertiría.** Que Supabase permita fijar `auto_expose_new_tables = false` también en el proyecto alojado, no solo en el CLI local. Entonces la base sí podría fallar cerrada sin el coste de la entrada global, y el censo pasaría de ser la defensa a ser la comprobación de que la defensa sigue puesta.

---

## ADR-017 · El licenciatario manda sobre las reglas, no sobre la aritmética

**Contexto.** Al cerrar la escritura directa de las tablas de dinero, Jota planteó la objeción correcta: *"tampoco puedo imponerle el porcentaje de utilidad a nadie"*. La pregunta de fondo es qué le queda en las manos a quien alquila la aplicación.

**Decisión.** La línea que separa lo que se cierra de lo que no:

> **Un parámetro de negocio es una ENTRADA que el licenciatario fija antes de que el dinero se mueva. Un saldo es una SALIDA que el sistema calcula después. Él manda sobre las reglas; no manda sobre la aritmética.**

**Queda abierto, con guardia** — suyo, por RPC, con reglas y con aviso a los jugadores: porcentaje de la casa, precio de salida, incremento, escalera por caballo, textos de soporte, datos bancarios.

**Queda cerrado** — nadie lo escribe a mano, tampoco el dueño: `wallets`, `wallet_movements`, `bids`, `race_results`, `profiles`, `withdraw_requests`, `deposit_requests`, `admin_actions`.

**Por qué.** Cerrar el saldo no le quita poder al licenciatario: **le da la única defensa que va a tener el día que un jugador lo acuse de haberle tocado la cuenta.** Mientras un admin pueda escribir `wallet_movements` —que es justo lo que lee el cuadre— puede falsear los libros y la auditoría que comprueba los libros con la misma sesión, y por tanto no puede demostrar que no lo hizo. Es un argumento de venta, no una restricción.

**Consecuencias.**
- Las políticas `*_admin_all` sobre tablas de dinero pasan de `FOR ALL` a `FOR SELECT`. El admin sigue viendo todo; deja de poder escribirlo.
- El porcentaje se fija remate a remate y se congela con la primera puja. Falta el valor por defecto de la instalación (A1), para que el número de arranque sea suyo y no el 25 que trae el código.
- Al crear un remate se muestra siempre una confirmación con los tres números que mandan sobre el dinero —porcentaje, precio de salida, incremento— antes de guardar.

**Qué la revertiría.** Un caso legítimo de corrección manual sobre un saldo. Existe: un error operativo que hay que deshacer. La respuesta no es reabrir la tabla, sino darle su propia RPC con motivo obligatorio y asiento en el libro, como `registrar_movimiento_casa`. Si algún día hace falta, se añade así.

---

## ADR-018 · Antes de cerrar una puerta, buscar quién la usa

**Contexto.** El 30/09, la migración que puso `remate_price_rules.horse_id` en `NOT NULL` dejó dos pruebas en rojo —P13 y P28— porque montaban sus escenarios insertando reglas generales. La migración era correcta; lo que faltó fue un `grep remate_price_rules tests/` de dos segundos antes de escribirla.

Fue la tercera vez el mismo día. Las otras dos: `alter default privileges ... in schema public revoke ... from public`, escrito sin leer la página del comando que lo declara inútil; y el `revoke select` sobre `deposit_requests` para `anon`, afirmado a partir de leer la baseline en vez de consultar la base real, donde el permiso sí estaba.

**Decisión.** Antes de quitar un permiso, añadir una restricción o borrar una capacidad, se enumeran sus usos. No se deduce: se busca.

- **En el repositorio:** `grep` del nombre del objeto en `app/`, `lib/`, `tests/` y `supabase/migrations/`, antes de escribir la migración.
- **En la base:** el estado real se consulta, no se infiere del código que debería haberlo producido. Para eso existen `tests/diagnostico_acl.sql` y `supabase/snippets/diagnostico_remate.sql`.
- **En la documentación:** si la migración usa un comando poco frecuente, se lee su página antes de escribirlo.

**Por qué.** Las tres equivocaciones del 30/09 tienen la misma forma: **afirmar el estado de algo en vez de consultarlo.** Cuestan minutos cuando las caza el arnés y cuestan dinero cuando no. La de `ALTER DEFAULT PRIVILEGES` habría dejado el agujero A6 abierto creyéndolo cerrado, y solo la destapó una prueba escrita antes del arreglo.

**Consecuencias.**
- El orden de despliegue se decide mirando quién escribe qué. Cuando la migración cierra algo que el frontend todavía usa, **el frontend va primero** — al revés de lo habitual. Pasó con la escalera: `crear-remate` mandaba `horse_id: null` hasta que se desplegó el cambio.
- Una prueba que se pone roja por una migración nueva no se parchea para que pase. Se mira qué medía: si medía el defecto que se acaba de eliminar, se reescribe para medir lo que queda en pie. P13 probaba la precedencia de la regla general sobre la del caballo, que era exactamente el agujero; reescrita, mide la precedencia de la escalera del caballo sobre el incremento del remate.

**Qué la revertiría.** Nada previsible. Es una regla de método, no de arquitectura; su coste es de segundos y su fallo se paga en producción.

---

## ADR-019 · Una carrera se prueba con dos sesiones, o no se prueba

**Contexto.** Tres de los nueve arreglos de la auditoría del 28/09 son condiciones de carrera: el `for share` de `hacer_puja` (A2), el candado de caja de `liquidar_remate` (A4) y el `unique` de `race_results` (D1). Los tres se desplegaron a producción el 29/09 con el arnés en verde. Pero el arnés corre con **una sola conexión**, y una carrera no se reproduce con una conexión: P45 comprobaba que un `insert` a mano rebota contra el `unique`, no que dos admins simultáneos no puedan insertar.

Es una distinción que se pierde con facilidad porque el resultado se parece: la prueba de la valla y la prueba de la carrera salen las dos verdes. La diferencia aparece el día que la valla no estaba y nadie se enteró.

**Decisión.** `tests/concurrencia.sql`. La sesión principal toma un candado dentro de una transacción abierta y no la cierra; una segunda conexión, abierta con `dblink` desde el mismo psql, lanza la operación real de forma asíncrona. `dblink_is_busy` dice si se quedó esperando. Las funciones son las de producción; lo único simulado es el momento.

La contraprueba es lo que le da valor: sin el `unique`, la segunda sesión **no espera**, entra, y quedan dos filas para la misma carrera. Verificado antes de escribir el archivo.

**Lo que costó hacerlo funcionar, y que vale para el paquete del licenciatario.**

- En Supabase el rol `postgres` **no es superusuario** (`rolsuper = f`).
- La documentación de dblink: *"Only superusers may use `dblink_connect` to create non-password-authenticated and non-GSSAPI-authenticated connections."*
- El `pg_hba` del contenedor confía en las conexiones locales, así que por socket o por `127.0.0.1` la contraseña **no se usa** aunque se mande, y dblink lo rechaza con `2F003`. No es que la clave sea incorrecta: es que no se llegó a pedir.
- `dblink_connect_u`, la variante para no-superusuarios, tiene el ACL `{supabase_admin=X/supabase_admin}`: `postgres` no puede ejecutarla ni concederse el permiso.
- **Lo que funciona:** conectar al nombre de red del contenedor (`host=db`). Esa conexión sale por una dirección que no es loopback, ahí el `pg_hba` exige `scram`, la contraseña se usa, y la comprobación de seguridad pasa.

**Consecuencias.**
- El archivo depende del andamiaje `_p` del arnés en vez de duplicarlo. Una segunda implementación del mismo escenario es exactamente el defecto que persigue el ADR-015.
- Después de un `dblink_send_query` hay que **drenar** con `dblink_get_result` hasta que devuelva cero filas. Sin drenar, la conexión queda con el comando a medias y la siguiente operación falla con *"another command is already in progress"* — y el síntoma aparece en una prueba distinta de la que lo causó, que es la peor forma de fallar. Cada escenario abre además su propia conexión, como segunda red.
- Todo arreglo futuro que dependa de un candado lleva su prueba aquí, no en el arnés.

**Qué la revertiría.** Que `pg_hba` cambie y la conexión por nombre de red deje de exigir contraseña. Entonces haría falta que un superusuario conceda `dblink_connect_u`, o pasar a dos procesos `psql` coordinados desde fuera de la base.
