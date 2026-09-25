# Cómo se aplican las migraciones

**Las migraciones no se corren una por una.** No abres el archivo y lo pegas en
el editor SQL. El CLI las aplica en orden y **lleva la cuenta** de cuáles ya
corrieron, en una tabla del propio proyecto: `supabase_migrations.schema_migrations`.

| Comando | Dónde | Qué hace |
|---|---|---|
| `npx supabase db reset` | **local** | Borra la base local y aplica **todas** las migraciones desde cero, en orden |
| `npx supabase db push` | **producción** | Compara la carpeta contra la tabla de control y aplica **solo las que faltan** |

---

> ## 🛑 ANTES DE TU PRIMER `db push` CONTRA PRODUCCIÓN
>
> Producción ya tiene el esquema, pero su tabla de seguimiento está vacía. Si
> corres `db push` sin más, el CLI intenta crear el esquema completo otra vez y
> revienta. **Pasó el 23/09/2026**, exactamente así:
>
> ```
> Applying migration 00000000000000_baseline.sql...
> ERROR: type "deposit_status" already exists (SQLSTATE 42710)
> ```
>
> No es grave — cada migración corre dentro de una transacción, así que esa se
> deshace entera y no queda nada a medias. Pero se evita con dos líneas:
>
> ```powershell
> npx supabase migration repair --status applied 00000000000000
> npx supabase migration repair --status applied 00000000000001
> ```
>
> **Esto se hace UNA sola vez en la vida del proyecto.** Después, `db push`
> aplica solo lo que de verdad falta. El detalle está más abajo, en "La trampa".
>
> Para comprobar en qué estado está producción antes y después:
> pega `docs/supabase/verificar_produccion.sql` completo en el SQL Editor de
> Supabase. Todo en `false` = solo el baseline. Todo en `true` = las seis
> migraciones aplicadas.

---

## Correr el arnés de pruebas

Desde la raíz del repo, en PowerShell, con Docker levantado:

```powershell
npx supabase db reset
$db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres
```

La segunda línea averigua cómo se llama el contenedor de la base que levantó Supabase — el nombre lleva un hash y cambia por proyecto, por eso no se puede escribir a mano. La tercera le mete el archivo de pruebas por la entrada estándar.

Si `$db` sale vacío, el contenedor no está arriba: `npx supabase start` primero.

> **`supabase start` y `supabase db start` no son lo mismo.**
>
> - `npx supabase start` levanta **todo el stack local** (Postgres, API, Studio,
>   Auth, Storage) y por eso imprime el banner con la API URL, los puertos y las
>   llaves `anon` / `service_role`.
> - `npx supabase db start` levanta **solo el contenedor de Postgres**. No
>   imprime banner porque no hay API ni llaves que anunciar. Si la base ya
>   estaba arriba responde `Postgres database is already running.` y no hace
>   nada más.
>
> Para correr el arnés basta con la base, así que `db start` sirve. Si quieres
> el banner o abrir Studio, es `start`.

**No se usa `psql` suelto** (no está instalado en Windows) ni `npx supabase db query` (no devuelve la tabla de resultados del arnés). El `psql` que corre es el que vive dentro del contenedor.

**Marcador esperado al 23/09/2026: 12 en verde, 3 en rojo, de 15.** Los tres rojos son defectos reproducidos a propósito — tareas 1.1, 1.2 y 1.3, absorbidas por el bloque 2. Si te da otro número, algo cambió: compáralo contra la tabla de la sección 0.3 de `BACKLOG_FASE1_FIXES.md`.

---

## ⚠️ La trampa: producción ya tiene el baseline, pero no lo sabe

El baseline **salió de producción**. Producción ya está en ese estado. Pero la
tabla `supabase_migrations.schema_migrations` está vacía, porque nunca se usaron
migraciones en este proyecto.

**Si corres `db push` tal cual, el CLI va a intentar aplicar el baseline sobre
producción**, que ya tiene todos esos objetos. Resultado: errores de "ya existe",
o peor, según el orden en que reviente.

**La solución** es marcar las dos primeras como ya aplicadas, sin ejecutarlas:

```powershell
npx supabase migration repair --status applied 00000000000000
npx supabase migration repair --status applied 00000000000001
```

`migration repair` **solo escribe en la tabla de control. No ejecuta ni revierte
SQL.** Es exactamente para este caso: adoptar una base que ya existía.

**Comprobado el 23/09/2026:** las seis migraciones del bloque 1 son
idempotentes. Se aplicaron dos veces seguidas sobre una base con solo el
baseline y la segunda pasada corrió limpia, dejando el arnés en 12/15. Así que
si el `repair` se hace de más o de menos, volver a aplicar no rompe nada.

Después de eso, `db push` aplica únicamente lo que de verdad falta.

---

## El orden completo, la primera vez

> ### Siempre `npx supabase`, nunca `supabase` a secas
>
> **Corregido el 25/09/2026.** Este bloque decía que el CLI estaba instalado
> como dependencia del proyecto. **Es falso:** `supabase` no está en
> `package.json` ni en `pnpm-lock.yaml`. Nunca lo estuvo.
>
> Lo que pasa de verdad: `npx` no lo encuentra en `node_modules`, así que lo
> **descarga del registro**. Por eso a veces aparece
> `Need to install the following packages: supabase@2.x.x`. Cuando no aparece
> es porque quedó en la caché de npx, no porque esté en el proyecto.
>
> **Esto importa:** sin versión fijada, cada máquina —y cada licenciatario—
> corre el CLI que sea `latest` ese día. Un cambio de versión mayor puede
> cambiar cómo se aplican las migraciones.
>
> **Se decidió NO meterlo como devDependency**, aunque eso arreglaría el pin:
> el paquete `supabase` descarga un binario de ~40 MB al instalarse, y Vercel
> instala las devDependencies en cada build. Sería pagar ese peso en cada
> deploy por una herramienta que solo se usa desde el escritorio y que el
> build no toca jamás.
>
> **La regla entonces es fijar la versión en el comando**, no en el
> `package.json`. La versión con la que se aplicó todo el bloque 1 y 2 es la
> **2.118.0**. Si necesitas reproducir exactamente:
>
> ```powershell
> npx supabase@2.118.0 db reset
> ```
>
> **Resuelto el 25/09/2026 con scripts en `package.json`.** La versión queda
> fijada donde se usa, sin meter el CLI como dependencia:
>
> ```json
> "db:start": "npx -y supabase@2.118.0 start",
> "db:stop": "npx -y supabase@2.118.0 stop",
> "db:reset": "npx -y supabase@2.118.0 db reset",
> "db:push:produccion": "npx -y supabase@2.118.0 db push"
> ```
>
> **Úsalos siempre**, en vez de escribir `npx supabase ...` a mano:
>
> | comando | qué hace |
> |---|---|
> | `pnpm db:start` | Levanta el stack local completo, con banner de llaves y puertos |
> | `pnpm db:stop` | Lo apaga |
> | `pnpm db:reset` | Borra la base local y reaplica todas las migraciones |
> | `pnpm db:push:produccion` | **Toca producción.** Aplica las migraciones que falten |
>
> Tres detalles que no son capricho:
>
> - **El `-y`** salta el prompt `Ok to proceed?` de npx. Sin él, el script se
>   queda colgado esperando una respuesta que nadie le va a dar.
> - **El nombre largo de `db:push:produccion`** es a propósito. Pinear la
>   versión de `db push` es lo más importante de todo, pero convertir el
>   comando que toca producción en algo de ocho letras baja la fricción justo
>   donde la fricción es sana. No se escribe por accidente ni se confunde con
>   `db:reset`.
> - **Pinear la versión no te protege de una migración rota.** Si el SQL está
>   mal, falla con la 2.118.0 igual que con cualquier otra. Lo que evita es que
>   *el CLI* cambie de comportamiento entre versiones: que el `db push` de
>   dentro de seis meses no haga algo distinto al de hoy con los mismos
>   archivos.
>
> El arnés no tiene script porque la línea que busca el contenedor de Docker es
> PowerShell (`$db = docker ps --filter ...`) y los scripts de npm corren por
> `cmd`. Se queda como está, más arriba en este documento.

```powershell
# 1. Regenerar el baseline SOLO con public (ver COMO_HACER_EL_BASELINE.md)
npx supabase db dump -f supabase/migrations/00000000000000_baseline.sql --schema public

# 2. Crear supabase/config.toml (una sola vez, si no existe)
npx supabase init

# 3. Levantar la pila local. LA PRIMERA VEZ TARDA VARIOS MINUTOS:
#    descarga las imagenes Docker de Postgres, GoTrue, PostgREST, Studio...
#    Al terminar imprime las URLs y las claves locales.
npx supabase start

# 4. Probar TODO en local: borra y reaplica las tres migraciones
npx supabase db reset

# 5. Correr el arnés contra la base local (ver "Correr el arnés" arriba)
$db = docker ps --filter "name=supabase_db" --format "{{.Names}}"
Get-Content tests/pruebas_dinero.sql | docker exec -i $db psql -U postgres -d postgres

# ---- hasta aqui TODO es local y no toca nada de produccion ----

# 6. RESPALDO de produccion desde el panel de Supabase  <-- no saltarse

# 7. Adoptar produccion: marcar las dos primeras como ya aplicadas
npx supabase migration repair --status applied 00000000000000
npx supabase migration repair --status applied 00000000000001

# 8. Aplicar lo que de verdad falta (hoy: solo el fix del enum)
npx supabase db push
```

De aquí en adelante el ciclo es siempre el mismo: escribir la migración,
`db reset` + arnés en local, respaldo, `db push`.

---

## Por qué esto importa para el licenciamiento

Este es el mecanismo con el que vas a mantener N bases de clientes. Cada
instalación nueva arranca con `db push` sobre un proyecto vacío y queda idéntica
a las demás. Y cuando corrijas algo, la misma migración viaja a todos.

Sin esto, cada cliente sería una base distinta que nadie puede reproducir — que
es exactamente el estado del que venimos saliendo.
