-- UNA sola consulta. Devuelve el codigo fuente completo de la funcion
-- desplegada. Copiamelo tal cual, aunque sea largo.
select pg_get_functiondef('public.liquidar_remate(uuid)'::regprocedure) as codigo_desplegado;
