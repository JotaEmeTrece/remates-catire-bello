-- ============================================================================
--  Tarea 3.1 — Las claves foraneas que protegen dinero pasan a RESTRICT
--
--  PROBLEMA: las 8 FK del nucleo estaban en ON DELETE CASCADE. La pantalla
--  app/admin/remates/[id] tiene un boton que borra caballos, sin ninguna
--  guarda. Borrar un caballo con pujas ELIMINA esas pujas, y el saldo
--  bloqueado de esos usuarios queda huerfano para siempre: no queda ninguna
--  puja que lo libere, la liquidacion no lo encuentra, la cancelacion tampoco.
--  Borrar una carrera era peor: arrastraba remates, caballos, pujas y
--  resultados de una sola vez.
--
--  CRITERIO: si borrar la fila padre puede destruir un rastro de dinero, la
--  base lo rechaza. Si no, se deja en CASCADE.
--
--  Lo que NO se toca y por que:
--    remate_price_rules -> horses/remates : CASCADE. No contiene dinero, y al
--        borrar una carrera vacia se quieren ir con ella.
--    race_results -> races               : CASCADE. Idem.
--    wallets -> profiles                 : CASCADE. Cambiarlo romperia el
--        borrado de usuarios. Es una decision aparte (ver nota al final).
-- ============================================================================

-- --- bids: el rastro del dinero. Nada que tenga pujas se puede borrar. ------
alter table public.bids drop constraint if exists bids_horse_id_fkey;
alter table public.bids add  constraint bids_horse_id_fkey
  foreign key (horse_id) references public.horses(id) on delete restrict;

alter table public.bids drop constraint if exists bids_remate_id_fkey;
alter table public.bids add  constraint bids_remate_id_fkey
  foreign key (remate_id) references public.remates(id) on delete restrict;

-- --- la cadena carrera -> caballos / remates --------------------------------
-- Sin esto, borrar la carrera esquiva la proteccion de arriba: se llevaria los
-- caballos y los remates por delante, y con ellos las pujas.
alter table public.horses drop constraint if exists horses_race_id_fkey;
alter table public.horses add  constraint horses_race_id_fkey
  foreign key (race_id) references public.races(id) on delete restrict;

alter table public.remates drop constraint if exists remates_race_id_fkey;
alter table public.remates add  constraint remates_race_id_fkey
  foreign key (race_id) references public.races(id) on delete restrict;

-- --- el ganador de la carrera ----------------------------------------------
-- Borrar el caballo ganador de un remate liquidado borraria la prueba de
-- quien gano y por que se pago lo que se pago.
alter table public.race_results drop constraint if exists race_results_ganador_horse_id_fkey;
alter table public.race_results add  constraint race_results_ganador_horse_id_fkey
  foreign key (ganador_horse_id) references public.horses(id) on delete restrict;

-- ============================================================================
--  NOTA PENDIENTE (no se resuelve aqui)
--
--  profiles -> auth.users y wallets -> profiles siguen en CASCADE. Borrar un
--  usuario de auth arrastra su perfil, su wallet y todos sus movimientos.
--  Para un sistema que mueve dinero de terceros eso es discutible: el rastro
--  contable deberia sobrevivir al borrado de la cuenta. Cambiarlo rompe el
--  borrado de usuarios tal como funciona hoy, asi que es una decision de
--  producto, no un fix. Queda anotada.
-- ============================================================================
