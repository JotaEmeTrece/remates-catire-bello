# Pendientes — al 1 de octubre de 2026

Lo que queda abierto, de lo que importa hacia lo que puede esperar. Sale de lo
que Jota reportó probando la app los días 30/09 y 01/10, más lo que apareció
auditando. Lo cerrado no está aquí: está en `ADR.md` y en las auditorías.

---

## Cerrado el 01/10, para que no se vuelva a abrir por error

- Mínimos de dinero por instalación (`ajustes_instalacion`, migración `20261001100000`): incremento ≥ 50 Bs y precio de salida ≥ 100 Bs, configurables, defendidos por tres triggers. P54.
- Escalera general fuera de las dos pantallas. La regla general es `precio_salida + incremento_minimo`. **Verificado por Jota: el incremento ya surte efecto al cambiarlo.**
- `lib/escalera.ts`: una sola implementación de la escalera y de su validación para crear y editar.
- Fechas y horas: vacías al entrar, con selects. `app/components/SelectorFechaHora.tsx`, probado en `tests/fechas.mjs`.
- Hora de cierre opcional de verdad en las dos pantallas (era un `||` de más en cada una).
- El botón de guardar dice qué falta, en las dos pantallas.
- Doble clic en crear remate ya no crea N remates.
- Realtime por broadcast desde la base, con sus seis triggers y P53.
- Permisos: censos P47 y P48, extensiones declaradas (ADR-020).

---

## 1 · Dinero y reglas que faltan

### 1.1 · `crear_remate_completo` transaccional — SIGUE ABIERTO
Crear un remate son **cuatro escrituras separadas** (`races`, `remates`,
`horses`, `remate_price_rules`), sin transacción ni RPC. **La guarda del botón
no es esto**: esa solo tapa el doble clic.

Hay un camino que falla hoy y lo demuestra: `horses` tiene
`UNIQUE (race_id, numero)` y el formulario **no valida que los números no se
repitan**. Dos caballos con el número 3 → la carrera y el remate se crean, el
insert de caballos rebota con 23505, y queda un remate `abierto` visible al
público con cero caballos. Dos arreglos: validar los repetidos en el formulario
(minutos) y el RPC transaccional del bloque 4.1 del backlog.

Aceptación: forzar el fallo en el paso de reglas y comprobar que **no queda
ninguna carrera ni remate**.

### 1.3 · Estado del remate: dos fuentes para un hecho
El formulario escribe `estado: "abierto"` siempre, aunque `opens_at` sea futuro.
La pantalla dice "programado" y la base dice "abierto". Hoy no se cuela nadie
porque `hacer_puja` compara `opens_at` por separado, pero el estado guardado es
falso. ADR-015.

### 1.4 · Motivo de rechazo — NO EXISTE LA COLUMNA
`deposit_requests` y `withdraw_requests` no tienen dónde guardarlo. Jota escribió
un motivo al rechazar y se fue a la basura. El cliente ve "rechazado" sin saber
por qué.

Falta: columna, que la RPC de rechazo la exija, y mostrarla al cliente.

### 1.5 · Pantalla de rechazados
Los datos están (las filas con `estado = 'rechazado'`); lo que no hay es una
pantalla que las liste. Recargas, retiros y depósitos.

---

## 2 · Notificaciones — lo más pedido

### 2.1 · Al admin, independiente de la pantalla
Hoy las solicitudes aparecen solas en las pantallas de recargas y retiros
(realtime), pero solo si el admin está en esa pantalla. Hace falta un aviso que
le llegue esté donde esté.

### 2.2 · Al cliente
- Recarga aprobada o rechazada (con el motivo de 1.4).
- Retiro procesado o rechazado.
- Remate nuevo abierto.

### 2.3 · Fuera de la app: correo, WhatsApp y Telegram
Intención de Jota, a medio hacer: *"mi intención era poner esa notificación a que
llegara también directo a whatsapp y telegram y al parecer ahí la dejé"*.

### 2.4 · `NOTIFY_EMAIL_TO` como lista, desde los ajustes de instalación
Hoy es un valor único en el entorno.

---

## 3 · Formularios y recargas

### 3.1 · Campos de recarga según el método de pago
Jota: si eligen cuenta bancaria hace falta algo más que el teléfono.
**Regla que él fijó: titular y últimos 4 dígitos, nunca el número completo.**

### 3.2 · Modal de confirmación al crear un remate
Siempre, con los tres números de dinero a la vista antes de escribir nada.

### 3.3 · Aviso del incremento ANTES de pujar, no al pujar
Jota: *"ahí el usuario decide si puja con el incremento o lo deja ahí"*. Hoy el
aviso sale después de intentar la puja.

### 3.4 · Reglas propias: aceptarlas explícitamente
Parcialmente hecho — ahora activar la casilla genera una escalera válida y se
ve la simulación. Falta el paso de **aceptar** y que quede a la vista en la
ficha del caballo que tiene reglas propias, no solo la casilla marcada.

---

## 4 · Navegación e interfaz

- **Navbar arriba.** Jota: *"la navegabilidad de la pág no me gusta... deberíamos considerar un menú arriba, un navbar típico"*. Decisión suya pendiente sobre la forma.
- **Nombre de usuario visible en todas las secciones**, no solo en `/dashboard`, **y debajo el saldo disponible**, como en las casas de apuestas (decisión de Jota, 01/10).
- **Remates nuevos no le aparecen al cliente** sin recargar: falta realtime en la lista. Y un indicador de "hay remates activos", que él prefiere ver después del rediseño.
- **Ver incremento y pozo por caballo** desde la pantalla de admin.
- **`/contactanos`**: la info está pero los enlaces no son activos (WhatsApp, correo).
- **Revisar el texto de `/reglas`.**
- **`©2026` clavado** en el pie.
- **El logo "parece muy IA"** — criterio de Jota.
- **`remate_minimos.soy_lider` devuelve NULL** en vez de `false` para un visitante sin sesión. Un `coalesce(..., false)`.

---

## 5 · Fase 2 y licenciamiento

- **A1 · Ajustes de instalación completos.** Ya existe la tabla con dos claves. Faltan: datos bancarios, % de la casa por defecto, precio de salida, incremento, SMTP, marca.
- **Roles granulares y bitácora** (bloque 3 del backlog): el cliente va a tener empleados.
- **Marca configurable**: `BrandLogo.tsx`, textos y assets están fijos a "Catire Bello".
- **Panel de licencias**, separado y de Jercol.
- **Estados Unidos en la lista de países**, y buscar una API pública de resultados de carreras de EEUU.

---

## 6 · Deuda de herramientas (de la conversación del 01/10)

- **`AGENT.md` en el repo.** Las reglas de trabajo no existen como archivo: vivían en el contenedor de una sesión anterior y se perdieron. Un archivo de reglas que no está en el repo no existe.
- **`herramientas/quien_usa.py`.** Misma historia. Enumeraría dónde aparece un identificador en `supabase/migrations/`, `tests/`, `app/` y `lib/` antes de cerrar o cambiar algo. Lo que falló tres veces el 01/10 fue exactamente eso, y con un grep mal escrito.
- **Lo que de verdad funcionó** fueron los controles que **corren**: el arnés, los censos, el chequeo de tipos y `tests/fechas.mjs`. Las reglas escritas no atraparon nada. Preferir siempre un control ejecutable a una regla escrita.
