# Scripts SQL historicos — NO EJECUTAR

Quedan aqui como referencia de lo que se hizo, no como algo aplicable.

**Advertencias concretas:**

- `rollback_hardening_profiles.sql` — **reabre el agujero de escalada de
  privilegios.** Ejecutarlo permite que cualquier usuario se haga admin y
  modifique wallets. No correrlo nunca.
- `reset_app_cero.sql` y `reset_remates_demo.sql` — **borran datos.**
- `liquidar_remate_ganador.sql` — contiene una version de `liquidar_remate`
  DISTINTA y mas defectuosa que la desplegada. Aplicarlo seria un retroceso.
- `cancelar_archivar_remate.sql` — la `cancelar_remate` que trae tiene el
  defecto C3 (`sum(b.monto)` sobre todas las pujas).

A partir de ahora todo cambio de esquema va en `supabase/migrations/`.
