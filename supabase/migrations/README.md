# Migraciones

**Esta carpeta es la unica fuente de verdad del esquema.**

1. Todo cambio de base de datos entra aqui como archivo nuevo, numerado. Nunca
   se edita una migracion ya aplicada.
2. Nada se aplica a mano desde el editor SQL de Supabase sin que exista antes
   el archivo aqui. Ese fue exactamente el problema que llevo a tener tres
   versiones distintas de `liquidar_remate` circulando.
3. El orden lo da el nombre: `YYYYMMDDHHMMSS_descripcion.sql`.

## Estado

- [ ] `00000000000000_baseline.sql` — **PENDIENTE** (tarea 0.1). Volcado del
      esquema REAL de produccion, no de `docs/sql-historico/`.

## Por que el baseline sale de produccion y no del repo

Produccion tiene al menos cuatro correcciones que nunca se versionaron: el
trigger `enforce_admin_immutability`, el `revoke` de UPDATE sobre `profiles`,
la eliminacion de la politica `bids_select_auth`, y el `unique(race_id,numero)`
en `horses`. Los scripts historicos no las tienen, y `rollback_hardening_profiles.sql`
directamente **revierte** la primera.
