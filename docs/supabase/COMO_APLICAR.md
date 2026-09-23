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
> El CLI está instalado como **dependencia del proyecto** (`npm install supabase --save-dev`),
> no global. Vive en `node_modules/.bin`, y `npx` es lo que lo encuentra ahí.
> Por eso `supabase start` da "no reconocido" y `npx supabase start` funciona.
>
> Es el comportamiento correcto: así la versión del CLI queda fijada en
> `package.json` y no depende de lo que cada máquina tenga instalado.

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
