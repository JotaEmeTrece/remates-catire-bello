# Tarea 0.1 — Baseline del esquema de producción

**Esto lo tienes que correr tú.** La shell que uso no tiene salida a internet
ni el CLI de Supabase, así que no puedo alcanzar tu proyecto desde aquí.

**Regla que no se puede romper:** el baseline sale del **volcado de producción**,
nunca de `docs/sql-historico/`. Producción tiene al menos cuatro correcciones que
esos scripts no tienen, y uno de ellos revierte una de ellas.

---

## ⚠️ El CLI necesita Docker

`npx supabase db dump` falla con `docker: command not found` porque corre
`pg_dump` dentro de un contenedor. **Docker Desktop es prerequisito documentado
del CLI**, no es un error de configuración.

Hay dos caminos.

---

## Opción A — Instalar Docker Desktop (recomendada)

**Por qué a pesar de ser la más pesada:** la tarea 0.3 del backlog necesita un
PostgreSQL local para el arnés de pruebas, y acordamos que esas pruebas **no**
corren contra producción. `supabase start` levanta ese Postgres local, y también
necesita Docker. **Una sola instalación resuelve 0.1 y 0.3.** Instalar el cliente
de Postgres suelto resuelve solo 0.1 y en dos semanas hay que instalar Docker igual.

1. Descargar Docker Desktop para Windows e instalarlo.
2. Abrirlo y esperar a que el motor arranque (el ícono deja de girar).
3. Verificar: `docker --version`
4. Repetir el volcado:

```powershell
npx supabase db dump -f supabase/migrations/00000000000000_baseline.sql --schema public --schema auth
```

---

## Opción B — `pg_dump` nativo, sin Docker

Desbloquea hoy, pero **no resuelve la 0.3**.

### B.1 · Averiguar la versión de PostgreSQL del proyecto

`pg_dump` tiene que ser de una versión **igual o mayor** que la del servidor.
En el editor SQL de Supabase:

```sql
select version();
```

### B.2 · Instalar el cliente de PostgreSQL

Instalador oficial de PostgreSQL para Windows, de esa versión o superior.
En la selección de componentes basta con **Command Line Tools** — no hace falta
el servidor. Verificar con `pg_dump --version`.

### B.3 · Sacar la cadena de conexión del panel

Panel de Supabase → botón **Connect**. Usar la de **Session pooler** (puerto 5432)
salvo que tengas IPv6 o el add-on de IPv4, en cuyo caso sirve la conexión directa.
Trae tu contraseña de base de datos; cópiala del panel, no la escribas de memoria.

### B.4 · El volcado

```powershell
pg_dump "postgresql://postgres.<REF>:<PASSWORD>@aws-0-<REGION>.pooler.supabase.com:5432/postgres" `
  --schema-only `
  --schema=public `
  --schema=auth `
  --no-owner `
  -f supabase/migrations/00000000000000_baseline.sql
```

> **Importante: NO uses `--no-privileges` ni `--no-acl`.** Los GRANT y REVOKE son
> parte de lo que estamos capturando. El `revoke update on profiles from
> authenticated` es una de las cuatro correcciones que existen en producción y no
> en el repo; con `--no-privileges` la perderíamos y la instalación de un cliente
> nacería con el agujero de escalada de privilegios abierto.
>
> `--no-owner` sí conviene: evita los `ALTER ... OWNER TO supabase_admin`, que dan
> error de permisos al restaurar en otro proyecto.

Si el esquema `auth` da errores de permisos, sácalo (`--schema=public` solo) y
avísame: el trigger `handle_new_user` vive sobre `auth.users` y habría que
recuperarlo aparte.

## Cómo verifico que quedó bien

Pásame el archivo (o los primeros 200 renglones) y yo confirmo que trae:

- [ ] Las 12 tablas de `public`
- [ ] Los 5 tipos enum (`deposit_status`, `withdraw_status`, `remate_status`,
      `race_status`, `wallet_movement_type`)
- [ ] El trigger **`enforce_admin_immutability`** sobre `profiles` ← el que no está en el repo
- [ ] El `revoke` de UPDATE sobre `profiles` para `authenticated`
- [ ] **Ausencia** de la política `bids_select_auth` con `using(true)`
- [ ] El constraint `unique(race_id, numero)` en `horses`
- [ ] Las 8 claves foráneas (todas en `CASCADE` — así deben quedar en el baseline;
      se corrigen en la tarea 3.1, no aquí)
- [ ] `liquidar_remate` con la CTE `winners` y `total_win` (la versión buena,
      distinta a la de `docs/sql-historico/liquidar_remate_ganador.sql`)
- [ ] `cerrar_remate` con el bucle `user_max` (el defectuoso — también va tal cual;
      se corrige en la 1.8)

**El baseline retrata lo que hay, defectos incluidos.** Las correcciones son
migraciones posteriores. Si "aprovechamos" para arreglar algo dentro del baseline,
perdemos la trazabilidad de qué cambió y cuándo, que es justamente el problema
que venimos a resolver.

---

## Antes de la primera migración que toque dinero

Respaldo bajo demanda desde el panel de Supabase. Aplica a las tareas 1.1 a 1.9
y a todo el bloque 2. Es la condición que acordamos para trabajar contra
producción sin un entorno aparte.
