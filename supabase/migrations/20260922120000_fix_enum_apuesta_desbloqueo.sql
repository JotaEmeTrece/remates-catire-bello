-- ============================================================================
--  FIX CRITICO: el sobrepuje esta roto en produccion
--
--  public.hacer_puja y public.cerrar_remate insertan un movimiento de tipo
--  'apuesta_desbloqueo', pero ese valor NO existe en el enum
--  public.wallet_movement_type, que tiene 'apuesta_liberacion'.
--
--  Efecto: la PRIMERA puja de cada caballo funciona (no hay lider previo que
--  desbloquear), pero la SEGUNDA siempre revienta con
--    invalid input value for enum wallet_movement_type: "apuesta_desbloqueo"
--  y la transaccion se revierte entera. Es decir: NADIE PUEDE SOBREPUJAR.
--
--  Se corrige agregando el valor al enum en vez de reescribir las dos
--  funciones: es un cambio de una linea, sin riesgo de transcripcion, y los
--  tipos de movimiento se rehacen completos en el bloque 2 (tarea 2.8).
-- ============================================================================

alter type public.wallet_movement_type add value if not exists 'apuesta_desbloqueo';
