-- ===========================================================================
--  20260927100000_fk_borrado_usuario.sql
--
--  Tarea 3.1, segunda mitad. La primera fue la 20260923100000, que puso en
--  RESTRICT las cinco claves del lado de la carrera:
--    bids->horses, bids->remates, horses->races, remates->races,
--    race_results->horses
--
--  Esas cinco cerraron el camino por el que se llegaba a casi todas las
--  demas: si no puedes borrar un caballo con pujas, tampoco puedes borrar la
--  carrera. Quedaba una cadena abierta, y era la peor:
--
--      auth.users --> profiles --> wallets --> wallet_movements
--                        |
--                        +-------> bids, deposit_requests, withdraw_requests
--
--  Todo en CASCADE. Borrar un usuario desde el panel de Auth de Supabase se
--  llevaba por delante su saldo, su historial de movimientos, sus recargas,
--  sus retiros Y SUS PUJAS -- lo que cambia en silencio quien va ganando cada
--  caballo de un remate abierto, y por tanto el pozo y el compromiso de los
--  demas.
--
--  LA SOLUCION, QUE NO NECESITA NI UN TRIGGER
--
--  No se bloquea el borrado siempre: se bloquea solo cuando hay rastro de
--  dinero. Y eso sale gratis del orden en que Postgres resuelve las cascadas.
--
--  Se dejan en CASCADE los eslabones que no son un dato por si mismos
--  (profiles, wallets: un wallet en cero no es informacion) y se ponen en
--  RESTRICT los que SI lo son. Al borrar un usuario, Postgres baja por la
--  cascada y choca contra el primer RESTRICT que encuentre: error, y toda la
--  transaccion se deshace.
--
--    - Usuario con CUALQUIER rastro de dinero o pujas  -> no se puede borrar
--    - Usuario que se registro y nunca hizo nada       -> se borra limpio
--
--  Esa segunda parte importa: `handle_new_user` le crea un wallet a todo el
--  mundo al registrarse. Con un RESTRICT a secas sobre wallets, ni una cuenta
--  de prueba recien creada se podria borrar jamas.
--
--  NOTA OPERATIVA: el error que vera el admin en el panel de Supabase es un
--  mensaje crudo de Postgres, no uno amable. Un `desactivar_usuario()` con su
--  boton queda pendiente para la tarea 3.5, cuando toquen los roles.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. wallet_movements -> wallets
--
--  Es el libro de movimientos del usuario. Es el freno principal de toda la
--  cadena: aqui es donde choca el borrado de cualquiera que haya movido un
--  bolivar.
-- ---------------------------------------------------------------------------
alter table public.wallet_movements drop constraint if exists wallet_movements_wallet_id_fkey;
alter table public.wallet_movements add  constraint wallet_movements_wallet_id_fkey
  foreign key (wallet_id) references public.wallets(id) on delete restrict;


-- ---------------------------------------------------------------------------
--  2. bids -> profiles
--
--  Borrar las pujas de alguien no es solo perder su historial: cambia quien
--  lidera cada caballo, y con eso el pozo del remate y el compromiso de los
--  demas usuarios. Esto no es un descuadre que se ajuste despues; es un
--  remate distinto.
-- ---------------------------------------------------------------------------
alter table public.bids drop constraint if exists bids_user_id_fkey;
alter table public.bids add  constraint bids_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete restrict;


-- ---------------------------------------------------------------------------
--  3 y 4. deposit_requests / withdraw_requests -> profiles
--
--  Las dos entran en el cuadre de casa_resumen():
--      perdida_usuarios = recargas - retiros pagados - retiros pendientes - saldos
--  Borrar sus filas no produce un descuadre que un admin pueda ajustar:
--  desaparece uno de los sumandos y el cuadre deja de ser comprobable.
-- ---------------------------------------------------------------------------
alter table public.deposit_requests drop constraint if exists deposit_requests_user_id_fkey;
alter table public.deposit_requests add  constraint deposit_requests_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete restrict;

alter table public.withdraw_requests drop constraint if exists withdraw_requests_user_id_fkey;
alter table public.withdraw_requests add  constraint withdraw_requests_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete restrict;


-- ---------------------------------------------------------------------------
--  5. race_results -> races
--
--  Por consistencia. En la practica es casi inalcanzable, porque
--  horses->races ya esta en RESTRICT desde la 20260923100000 y una carrera
--  con resultado tiene caballos. Pero un resultado de carrera es un hecho
--  historico, no configuracion.
-- ---------------------------------------------------------------------------
alter table public.race_results drop constraint if exists race_results_race_id_fkey;
alter table public.race_results add  constraint race_results_race_id_fkey
  foreign key (race_id) references public.races(id) on delete restrict;


-- ===========================================================================
--  LO QUE SE QUEDA EN CASCADE, A PROPOSITO
--
--  No es que se nos hayan olvidado. Cada una tiene su razon:
--
--  profiles -> auth.users        Un perfil sin nada detras no es un dato. Y
--                                es el eslabon que permite borrar una cuenta
--                                de prueba que nunca se uso.
--
--  wallets -> profiles           Un wallet en cero, sin un solo movimiento,
--                                tampoco es un dato. El freno de verdad esta
--                                un nivel mas abajo, en wallet_movements.
--
--  remate_price_rules -> horses  Son CONFIGURACION del remate, no historia.
--  remate_price_rules -> remates No tienen ningun sentido sin el remate al
--                                que pertenecen, y no cargan dinero. Si se
--                                borra un remate (cosa que ya bloquean otras
--                                claves si tiene pujas), sus reglas deben
--                                irse con el.
-- ===========================================================================
