-- UNA sola consulta.
--
-- La FUNCION auto_cerrar_remates existe en produccion (ya lo confirmamos).
-- Lo que NO sabemos es si el JOB de pg_cron que la ejecuta cada minuto
-- sigue programado y activo. Son dos cosas distintas:
--   - la funcion existe  -> alguien la puede llamar
--   - el job esta activo -> se llama sola cada minuto
--
-- COMO LEERLO:
--   0 filas          -> el cron NUNCA se programo o se borro. Los remates
--                       NO cierran solos. Todo cierre pasa por el boton.
--   active = false   -> programado pero apagado. Tampoco cierran solos.
--   active = true    -> si cierran solos, y ultima_ejecucion lo confirma.
--
-- Si da error "no existe la relacion cron.job", pg_cron no esta instalado
-- en este proyecto y la respuesta es: NO cierran solos.

select
  j.jobid,
  j.jobname,
  j.schedule,
  j.active,
  (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid) as ultima_ejecucion,
  (select d.status from cron.job_run_details d where d.jobid = j.jobid
    order by d.start_time desc limit 1)                                          as ultimo_estado,
  (select count(*) from cron.job_run_details d
    where d.jobid = j.jobid and d.status <> 'succeeded')                         as ejecuciones_fallidas
from cron.job j
where j.jobname = 'auto_cerrar_remates';
