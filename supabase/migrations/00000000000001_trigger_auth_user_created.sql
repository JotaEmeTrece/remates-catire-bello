-- ============================================================================
--  Lo unico que nos pertenece del esquema auth
--
--  El baseline NO debe incluir el esquema `auth`: Supabase lo crea y lo posee
--  (rol supabase_auth_admin), tanto en la nube como en local. Intentar
--  recrearlo desde una migracion da:
--      ERROR: permission denied for schema auth (SQLSTATE 42501)
--
--  De los 378 objetos `auth` que traia el volcado original, UNO solo es
--  nuestro: este trigger. La funcion que ejecuta vive en `public` y ya entra
--  con el baseline.
-- ============================================================================

create or replace trigger "on_auth_user_created"
  after insert on "auth"."users"
  for each row execute function "public"."handle_new_user"();
