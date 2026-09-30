-- ===========================================================================
--  20260929110000_permisos_tablas_y_rpc.sql
--
--  EL HALLAZGO QUE OBLIGA A ESTE ARCHIVO (29/09)
--
--  A5 -- "un admin podia acunar saldo escribiendo deposit_requests" -- no era
--  un caso aislado. Era uno de quince.
--
--  La imagen de Supabase trae, ANTES de cualquier migracion:
--
--    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--      GRANT ALL ON TABLES TO anon, authenticated;
--
--  Asi que las quince tablas de `public` nacieron con GRANT ALL para `anon` y
--  para `authenticated`. No hay un solo `GRANT` explicito en la baseline que
--  lo diga: el permiso se aplica solo, en el instante en que la tabla se crea.
--  El diagnostico del 29/09 lo confirmo tabla por tabla.
--
--  Lo unico que separa hoy a un usuario logueado de escribir en `wallets` es
--  la RLS. Y ahi hay dos agujeros distintos:
--
--  1. LAS POLITICAS `*_admin_all` SON `FOR ALL`.
--     wallets, wallet_movements, bids, race_results, profiles y
--     withdraw_requests tienen una politica `FOR ALL ... USING is_admin()
--     WITH CHECK is_admin()`. Con el GRANT ALL encima, un admin puede hacer
--     `supabase.from('wallets').update({saldo_disponible: 999999})` desde la
--     consola del navegador. Y puede insertar y borrar filas de
--     `wallet_movements`, que es justo lo que lee el cuadre: puede falsear
--     los libros y la auditoria que comprueba los libros con la misma sesion.
--
--     Eso contradice la regla que fijo Jota el 24/09: el resultado del remate
--     "va directo EN EL SISTEMA a donde tiene que mostrarse, eso no se puede
--     dejar a criterio del admin".
--
--  2. `TRUNCATE` NO PASA POR LA RLS.
--     Doc 17, 5.9 Row Security Policies, literal:
--
--       "Operations that apply to the whole table, such as TRUNCATE and
--        REFERENCES, are not subject to row security."
--
--     `anon` y `authenticated` tienen el privilegio D (TRUNCATE) sobre las
--     quince tablas. Ninguna politica lo frena porque ninguna politica PUEDE
--     frenarlo. Hoy PostgREST no expone TRUNCATE, asi que no es explotable
--     por la via normal; pero es un privilegio que no tiene por que existir
--     en una base que se alquila.
--
--  Y EN LAS FUNCIONES, LA MISMA TRAMPA CON OTRO NOMBRE
--
--  Doce funciones llevan `=X/postgres` en su ACL: el EXECUTE que PostgreSQL
--  le da a PUBLIC de fabrica. Un `revoke ... from anon` no lo quita.
--  20260925100000:109 hizo exactamente eso con `mi_wallet_resumen` y el
--  diagnostico del 29/09 la sigue dando como ejecutable por `anon`. El revoke
--  parecia hecho y no estaba hecho.
--
--  Por eso aqui TODA funcion se cierra con la forma completa --
--  `from public, anon, authenticated` -- y se reabre con un grant explicito.
--  No hay atajo: quien no aparezca nombrado, queda cerrado.
--
--  ------------------------------------------------------------------------
--  LA LINEA QUE SEPARA LO QUE SE CIERRA DE LO QUE NO
--
--    Un parametro de negocio es una ENTRADA que el licenciatario fija antes
--    de que el dinero se mueva. Un saldo es una SALIDA que el sistema calcula
--    despues. El manda sobre las reglas; no manda sobre la aritmetica.
--
--  Queda abierto, con guardia: porcentaje de la casa, precio de salida,
--  incremento, escalera, soporte. Son suyos y se cambian por RPC, con reglas
--  y con aviso a los jugadores.
--
--  Queda cerrado: wallets, wallet_movements, bids, race_results, profiles,
--  withdraw_requests, deposit_requests, admin_actions. No son decisiones,
--  son consecuencias.
--
--  Y no es quitarle poder al licenciatario: es la unica defensa que va a
--  tener el dia que un jugador lo acuse de haberle tocado el saldo.
--
--  LO QUE NO ESTA AQUI, A PROPOSITO: el `insert` sobre `remates` y el
--  insert/update/delete sobre `horses`, `races` y `remate_price_rules`. La
--  pantalla de crear y editar remates los usa directamente hoy. Cerrarlos
--  antes de tener `crear_remate_completo()` y `guardar_remate_completo()`
--  deja al licenciatario sin poder crear un remate. Van en la tanda 4.
--  El censo (P47/P48) los lleva marcados como excepcion con fecha de
--  caducidad, no como estado normal.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  BLOQUE 1 - FUNCIONES
--
--  Primero se cierran las 34 con la forma completa. Despues se reabren una a
--  una. Cualquier funcion futura que nadie nombre aqui, nace cerrada de facto
--  y sale en rojo en P47.
-- ---------------------------------------------------------------------------

-- internas: solo las llaman otras funciones `definer`, que corren como postgres
revoke all on function public._cerrar_remate_interno(uuid)                    from public, anon, authenticated;
revoke all on function public._incremento_aplicable(uuid, uuid, numeric)      from public, anon, authenticated;
revoke all on function public.compromiso_usuario(uuid)                        from public, anon, authenticated;
revoke all on function public.dinero_casa_disponible()                        from public, anon, authenticated;
revoke all on function public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)
                                                                              from public, anon, authenticated;
-- el cron: lo llama el scheduler con la clave de servicio
revoke all on function public.auto_cerrar_remates()                           from public, anon, authenticated;

-- funciones de trigger: COMPROBADO el 29/09 en un Postgres real que un trigger
-- sigue disparando aunque el rol que hace el insert no tenga EXECUTE sobre su
-- funcion. PostgreSQL comprueba ese permiso al CREAR el trigger, no al
-- dispararlo. Cerrarlas no rompe nada y quita tres nombres de la superficie.
revoke all on function public.handle_new_user()                               from public, anon, authenticated;
revoke all on function public.tr_check_admin_immutability()                    from public, anon, authenticated;
revoke all on function public.set_support_settings_updated_at()                from public, anon, authenticated;

-- sin uso en la aplicacion (comprobado en app/ y lib/ el 29/09).
-- get_usernames solo aparece en app/SUPABASE_CONTEXT.md, que es legacy.
-- promover_usuario y set_admin no las llama ninguna pantalla: hoy los roles
-- se asignan a mano en la base. Si algun dia hay pantalla de promocion,
-- se reabren con una linea y se anaden al censo.
revoke all on function public.get_usernames(uuid[])                           from public, anon, authenticated;
revoke all on function public.promover_usuario(uuid, boolean, boolean)        from public, anon, authenticated;
revoke all on function public.set_admin(uuid, boolean)                        from public, anon, authenticated;

-- el resto: se cierran y se reabren abajo
revoke all on function public.admin_contabilidad_resumen()                     from public, anon, authenticated;
revoke all on function public.aprobar_recarga(uuid)                            from public, anon, authenticated;
revoke all on function public.archivar_remate(uuid, text)                      from public, anon, authenticated;
revoke all on function public.cancelar_remate(uuid, text)                      from public, anon, authenticated;
revoke all on function public.casa_resumen()                                   from public, anon, authenticated;
revoke all on function public.cerrar_remate(uuid)                              from public, anon, authenticated;
revoke all on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz)
                                                                               from public, anon, authenticated;
revoke all on function public.hacer_puja(uuid, uuid, numeric, boolean)         from public, anon, authenticated;
revoke all on function public.is_admin()                                       from public, anon, authenticated;
revoke all on function public.is_super_admin()                                 from public, anon, authenticated;
revoke all on function public.liquidar_remate(uuid)                            from public, anon, authenticated;
revoke all on function public.listar_pujas_publicas(uuid)                      from public, anon, authenticated;
revoke all on function public.listar_wallets_superadmin(text, integer)         from public, anon, authenticated;
revoke all on function public.mi_wallet_resumen()                              from public, anon, authenticated;
revoke all on function public.procesar_retiro(uuid, public.withdraw_status)    from public, anon, authenticated;
revoke all on function public.rechazar_recarga(uuid, text)                     from public, anon, authenticated;
revoke all on function public.registrar_movimiento_casa(text, numeric, text)   from public, anon, authenticated;
revoke all on function public.remate_minimos(uuid)                             from public, anon, authenticated;
revoke all on function public.retirar_caballo(uuid, text)                      from public, anon, authenticated;
revoke all on function public.set_ganador_carrera(uuid, integer)               from public, anon, authenticated;
revoke all on function public.solicitar_recarga(numeric, text, text, text, date)
                                                                               from public, anon, authenticated;
revoke all on function public.solicitar_retiro(numeric, text, text, text)      from public, anon, authenticated;


--  Las que necesita un usuario con sesion. Todas son `security definer` y
--  llevan su propia guarda de admin dentro donde toca.
grant execute on function public.admin_contabilidad_resumen()                  to authenticated;
grant execute on function public.aprobar_recarga(uuid)                         to authenticated;
grant execute on function public.archivar_remate(uuid, text)                   to authenticated;
grant execute on function public.cancelar_remate(uuid, text)                   to authenticated;
grant execute on function public.casa_resumen()                                to authenticated;
grant execute on function public.cerrar_remate(uuid)                           to authenticated;
grant execute on function public.editar_remate(uuid, numeric, numeric, text, timestamptz, timestamptz)
                                                                               to authenticated;
grant execute on function public.hacer_puja(uuid, uuid, numeric, boolean)      to authenticated;
grant execute on function public.liquidar_remate(uuid)                         to authenticated;
grant execute on function public.listar_wallets_superadmin(text, integer)      to authenticated;
grant execute on function public.mi_wallet_resumen()                           to authenticated;
grant execute on function public.procesar_retiro(uuid, public.withdraw_status) to authenticated;
grant execute on function public.rechazar_recarga(uuid, text)                  to authenticated;
grant execute on function public.registrar_movimiento_casa(text, numeric, text) to authenticated;
grant execute on function public.retirar_caballo(uuid, text)                   to authenticated;
grant execute on function public.set_ganador_carrera(uuid, integer)            to authenticated;
grant execute on function public.solicitar_recarga(numeric, text, text, text, date)
                                                                               to authenticated;
grant execute on function public.solicitar_retiro(numeric, text, text, text)   to authenticated;

--  is_admin / is_super_admin: NO son RPC de pantalla, pero `authenticated`
--  necesita poder ejecutarlas porque las politicas RLS las invocan y una
--  politica corre con los permisos de quien hace la consulta. Sin este grant,
--  cualquier select sobre una tabla con politica de admin revienta con
--  "permission denied for function is_admin".
--  A `anon` no le hace falta: ninguna politica `to anon` las usa (comprobadas
--  las 41 politicas el 29/09).
grant execute on function public.is_admin()                                    to authenticated;
grant execute on function public.is_super_admin()                              to authenticated;

--  Informacion publica del remate: la pantalla del remate se ve sin sesion.
grant execute on function public.remate_minimos(uuid)                          to authenticated, anon;
grant execute on function public.listar_pujas_publicas(uuid)                   to authenticated, anon;


-- ---------------------------------------------------------------------------
--  BLOQUE 2 - TABLAS QUE NADIE ESCRIBE A MANO
--
--  Comprobado el 29/09 recorriendo `app/` y `lib/`: el frontend NO escribe
--  ninguna de estas ocho. Solo las lee. Todo lo que las modifica pasa por una
--  funcion `definer`, que corre como postgres y no necesita estos permisos.
--
--  `revoke all` en vez de `revoke insert, update, delete` a proposito: hay que
--  quitar tambien TRUNCATE, REFERENCES, TRIGGER y MAINTAIN. TRUNCATE es el que
--  importa, porque es el que la RLS no puede frenar.
-- ---------------------------------------------------------------------------
revoke all on table public.wallets           from public, anon, authenticated;
revoke all on table public.wallet_movements  from public, anon, authenticated;
revoke all on table public.bids              from public, anon, authenticated;
revoke all on table public.race_results      from public, anon, authenticated;
revoke all on table public.profiles          from public, anon, authenticated;
revoke all on table public.withdraw_requests from public, anon, authenticated;
revoke all on table public.deposit_requests  from public, anon, authenticated;
revoke all on table public.admin_actions     from public, anon, authenticated;
revoke all on table public.house_ledger      from public, anon, authenticated;

--  Leer si: cada quien lo suyo, y el admin lo que le deje su politica.
grant select on table public.wallets           to authenticated;
grant select on table public.wallet_movements  to authenticated;
grant select on table public.bids              to authenticated;
grant select on table public.race_results      to authenticated;
grant select on table public.profiles          to authenticated;
grant select on table public.withdraw_requests to authenticated;
grant select on table public.deposit_requests  to authenticated;
grant select on table public.admin_actions     to authenticated;
grant select on table public.house_ledger      to authenticated;


-- ---------------------------------------------------------------------------
--  BLOQUE 3 - TABLAS QUE LA PANTALLA DE ADMIN ESCRIBE HOY
--
--  horses, races, remate_price_rules y support_settings las escribe el
--  frontend directamente (comprobado: 11 puntos de escritura en `app/`).
--  Hasta la tanda 4 se quedan escribibles por `authenticated`, con la RLS
--  exigiendo admin. Lo que SI se les quita a todos es TRUNCATE, REFERENCES,
--  TRIGGER y MAINTAIN, que no los usa ni los va a usar nadie.
--
--  `anon` pierde la escritura entera y conserva solo la lectura, que es lo
--  que necesita la pantalla publica.
-- ---------------------------------------------------------------------------
revoke all on table public.horses             from public, anon, authenticated;
revoke all on table public.races              from public, anon, authenticated;
revoke all on table public.remate_price_rules from public, anon, authenticated;
revoke all on table public.support_settings   from public, anon, authenticated;

grant select, insert, update, delete on table public.horses             to authenticated;
grant select, insert, update, delete on table public.races              to authenticated;
grant select, insert, update, delete on table public.remate_price_rules to authenticated;
grant select, insert, update, delete on table public.support_settings   to authenticated;

grant select on table public.horses             to anon;
grant select on table public.races              to anon;
grant select on table public.remate_price_rules to anon;
grant select on table public.support_settings   to anon;


-- ---------------------------------------------------------------------------
--  BLOQUE 4 - remates y remate_avisos
--
--  `remates` ya perdio update y delete en la 3.2 (tarea 3.2, P36). Aqui pierde
--  lo que quedaba suelto -- TRUNCATE incluido -- y `anon` pierde el insert,
--  que no tenia ningun sentido.
--
--  El `insert` de `authenticated` se conserva A PROPOSITO: lo usa la pantalla
--  de crear remate. Se cierra en la tanda 4, cuando exista
--  `crear_remate_completo()`. Esta excepcion esta declarada en P48 con esa
--  razon; el dia que la RPC exista, se quita de los dos sitios a la vez.
-- ---------------------------------------------------------------------------
revoke all on table public.remates       from public, anon, authenticated;
grant select on table public.remates     to anon, authenticated;
grant insert on table public.remates     to authenticated;

revoke all on table public.remate_avisos from public, anon, authenticated;
grant select on table public.remate_avisos to anon, authenticated;


-- ---------------------------------------------------------------------------
--  BLOQUE 5 - LAS POLITICAS `FOR ALL` DEL ADMIN, A SOLO LECTURA
--
--  El revoke de arriba ya basta hoy. Esto es el segundo cerrojo: si manana
--  alguien repone un grant -- o Supabase cambia su default, o una migracion
--  hace `grant all on all tables` sin pensarlo -- la politica sigue sin
--  permitir la escritura.
--
--  Dos candados independientes sobre el dinero, que es la unica parte donde
--  vale la pena pagar el precio de la redundancia. Mismo criterio que se uso
--  con `deposit_admin_all` en la tanda 1.
--
--  OJO: no se BORRAN, se ESTRECHAN a select. Son el unico camino por el que
--  un admin ve las filas de los demas: `wallets_select_own` y
--  `wallet_movements_select_own` solo le ensenan las suyas, y las pantallas
--  de admin leen `bids`, `withdraw_requests` y `profiles` directamente.
--  Borrarlas dejaria el panel ciego.
--
--  Las funciones `definer` no se ven afectadas: son propiedad de postgres, que
--  es el dueno de las tablas, y el dueno se salta la RLS salvo que la tabla
--  tenga FORCE ROW LEVEL SECURITY, que no es el caso en ninguna.
-- ---------------------------------------------------------------------------
drop policy if exists wallets_admin_all on public.wallets;
create policy wallets_admin_select on public.wallets
  for select to authenticated using (public.is_admin());

drop policy if exists wallet_movements_admin_all on public.wallet_movements;
create policy wallet_movements_admin_select on public.wallet_movements
  for select to authenticated using (public.is_admin());

drop policy if exists bids_admin_all on public.bids;
create policy bids_admin_select on public.bids
  for select to authenticated using (public.is_admin());

drop policy if exists results_admin_all on public.race_results;
create policy results_admin_select on public.race_results
  for select to authenticated using (public.is_admin());

drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_select on public.profiles
  for select to authenticated using (public.is_admin());

drop policy if exists withdraw_admin_all on public.withdraw_requests;
create policy withdraw_admin_select on public.withdraw_requests
  for select to authenticated using (public.is_admin());

--  Y las politicas de escritura que quedaron sin privilegio detras. No hacen
--  dano -- sin el GRANT no se pueden ejercer -- pero una politica que dice
--  que algo se puede hacer, cuando no se puede, es una mentira en el esquema
--  y el dia que alguien reponga el grant se convierte en un agujero.
--  El usuario cambia su perfil, pide recarga y pide retiro por RPC, no
--  escribiendo la tabla.
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists deposit_insert_own_pendiente on public.deposit_requests;
drop policy if exists withdraw_insert_own_pendiente on public.withdraw_requests;
