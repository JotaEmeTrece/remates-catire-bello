# Trabajar con Supabase en este proyecto

| Documento | Para qué |
|---|---|
| `COMO_APLICAR.md` | **Empieza aquí.** Cómo se aplican las migraciones, local y producción, y la trampa del `migration repair` |
| `COMO_HACER_EL_BASELINE.md` | Cómo se generó el volcado inicial y qué verificar si hay que rehacerlo |

## Reglas de `supabase/migrations/`

**Esa carpeta es la única fuente de verdad del esquema, y solo admite archivos
`<timestamp>_nombre.sql`.** Cualquier otra cosa —un README, una nota— el CLI la
salta con un aviso en cada corrida. Por eso la documentación vive aquí.

1. Todo cambio de base de datos entra como archivo nuevo, numerado. Nunca se
   edita una migración ya aplicada.
2. Nada se aplica a mano desde el editor SQL de Supabase sin que exista antes el
   archivo. Ese fue exactamente el problema que llevó a tener tres versiones
   distintas de `liquidar_remate` circulando.
3. El orden lo da el nombre del archivo.

## Comandos del día a día

```powershell
npx supabase status   # ¿está corriendo la pila local?
npx supabase start    # levantarla
npx supabase stop     # apagarla y liberar RAM
npx supabase db reset # borrar la base local y reaplicar TODAS las migraciones
```

Siempre con `npx`: el CLI está instalado como dependencia del proyecto, no global.
