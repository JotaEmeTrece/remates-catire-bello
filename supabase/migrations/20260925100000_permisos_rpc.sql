-- ===========================================================================
--  20260925100000_permisos_rpc.sql
--
--  Auditoria de permisos sobre las funciones `security definer`, disparada
--  por la tarea 2.22 (casa_resumen se le escapaba a cualquier usuario).
--
--  Se revisaron las 31 funciones de `public` con grant a authenticated o anon.
--  De las que NO comprueban quien llama, la mayoria esta bien asi porque son
--  del usuario y derivan la identidad de auth.uid(). Estas cuatro no:
--
--   1. auto_cerrar_remates()  -- GRAVE
--   2. log_admin_action(...)  -- GRAVE
--   3. compromiso_usuario(uuid)
--   4. resumen_casa()         -- funcion muerta, se borra
--
--  El resto de este archivo es higiene: quitar el grant a `anon` de funciones
--  que ya rechazan al anonimo por su cuenta. No arregla ningun hueco, reduce
--  superficie.
--
--  NOTA IMPORTANTE SOBRE `CREATE OR REPLACE`: no toca los permisos. Por eso
--  estos grants de la baseline sobrevivieron intactos a todas las migraciones
--  del bloque 1 y 2, que reescribieron los cuerpos de casi todas estas
--  funciones. Revisar el cuerpo no basta: hay que mirar el ACL.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. auto_cerrar_remates()
--
--  Es la funcion del cron. Estaba con GRANT ALL a `anon` y a `authenticated`,
--  `security definer`, y sin comprobar nada. Cualquier visitante —sin siquiera
--  estar logueado— podia llamar supabase.rpc('auto_cerrar_remates') y forzar
--  el cierre de todos los remates con closes_at vencido.
--
--  Alcance real, sin exagerar: solo cierra remates que YA pasaron su hora, o
--  sea que no permite cerrar nada antes de tiempo. Pero desde la tajada C esa
--  funcion COBRA a los lideres de puja, y con la decision 7 (autocierre
--  opcional, apagado por defecto) la hora de cierre de un adelantado pasa a
--  ser informativa: ahi si, un tercero podria cerrar y cobrar un remate que
--  el admin queria mantener abierto.
--
--  pg_cron corre el job como `postgres`, que es superusuario y no necesita
--  grant. Nadie mas tiene por que poder llamarla.
-- ---------------------------------------------------------------------------
revoke all on function public.auto_cerrar_remates() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  2. log_admin_action(...)
--
--  Estaba con GRANT ALL a `anon` y a `authenticated`. Escribe en
--  admin_actions, que es la bitacora de auditoria. Cualquiera podia insertar
--  registros falsos: atribuirle acciones a un admin, o llenar la tabla de
--  ruido hasta que la bitacora dejara de servir para nada.
--
--  Una bitacora en la que puede escribir cualquiera no es una bitacora.
--
--  Solo la llaman funciones `definer` de la propia base, que corren como
--  postgres. Se revoca a todo el mundo.
-- ---------------------------------------------------------------------------
revoke all on function public.log_admin_action(uuid, text, text, text, jsonb, boolean, text)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  3. compromiso_usuario(uuid)
--
--  Recibe un user_id por parametro y estaba concedida a `authenticated` sin
--  comprobar que fuera el propio. Un usuario logueado podia consultar cuanto
--  tiene comprometido cualquier otro, si conocia su id.
--
--  No se le pone guarda adentro a proposito: _cerrar_remate_interno la llama
--  con el id de CADA lider mientras corre como el admin o como el cron, asi
--  que una guarda `p_user_id = auth.uid()` romperia el cierre.
--
--  Se revoca y punto. El frontend no la llama nunca —usa mi_wallet_resumen(),
--  que ya devuelve el compromiso del usuario actual— y los llamadores de SQL
--  son funciones `definer` de postgres, que no necesitan el grant.
-- ---------------------------------------------------------------------------
revoke all on function public.compromiso_usuario(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  4. resumen_casa() — funcion muerta
--
--  Hallazgo A2 de la auditoria de agosto: tenia el signo invertido y contaba
--  los premios dos veces. La app nunca la llamo; usa admin_contabilidad_resumen.
--  Llevaba desde agosto marcada para borrar y seguia ahi, concedida a `anon`,
--  devolviendo numeros de la casa que ademas estaban mal.
-- ---------------------------------------------------------------------------
drop function if exists public.resumen_casa();


-- ---------------------------------------------------------------------------
--  HIGIENE: quitar el grant a `anon` donde no hace falta.
--
--  Estas cuatro SI comprueban: la primera linea de cada una es
--  `if auth.uid() is null then raise exception 'No autenticado'`. Verificado
--  una por una. O sea que el grant a `anon` no era un hueco — era superficie
--  de ataque sin motivo. Se quita igual.
--
--  remate_minimos() se queda con `anon` a proposito: es informacion publica
--  del remate y la pantalla la necesita para mostrar precios a quien todavia
--  no se ha registrado.
-- ---------------------------------------------------------------------------
revoke all on function public.hacer_puja(uuid, uuid, numeric, boolean) from anon;
revoke all on function public.solicitar_retiro(numeric, text, text, text) from anon;
revoke all on function public.solicitar_recarga(numeric, text, text, text, date) from anon;
revoke all on function public.mi_wallet_resumen() from anon;
