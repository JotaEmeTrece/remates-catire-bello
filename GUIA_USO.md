# Guia de Uso - Remate Catire Bello

Esta guia esta pensada para admins y usuarios generales. Explica el flujo diario, el manejo de remates y los procesos de recarga/retiro con palabras simples.

## Inicio rapido

### Clientes
1) Entra a /remates para ver remates activos.
2) Inicia sesion en /login.
3) Recarga saldo en /dashboard/recargar.
4) Pujar desde el remate activo.
5) Revisa tu saldo y movimientos en /dashboard.

### Admins
1) Entra a /admin con tu cuenta admin.
2) Crea remates en "Crear remate".
3) Gestiona recargas y retiros pendientes.
4) Cierra remates cuando ya no se aceptan pujas.
5) Liquida remates cuando ya conoces el caballo ganador.
6) Revisa contabilidad para el resumen financiero.

## Flujo de un remate

1) Crear remate (admin)
   - Datos de carrera y remate.
   - Agregar caballos y reglas de precios.
2) Remate abierto
   - Los usuarios ven la tabla y pueden pujar.
   - El pozo se actualiza con cada puja.
3) Cerrar remate (admin)
   - Se dejan de aceptar pujas.
   - Se liberan saldos de usuarios que no ganaron ningun caballo.
4) Liquidar remate (admin)
   - Se selecciona el caballo ganador.
   - El ganador recibe el pozo menos 25% de la casa.
   - Si el caballo ganador era de la casa, la casa se queda con todo.

## Roles y permisos

- Anonimo: solo puede ver remates activos.
- Cliente: puede ver remates, recargar saldo, retirar saldo y pujar.
- Admin: gestiona remates, recargas, retiros y contabilidad.
- Superadmin: lo mismo que admin, con control total del sistema.

## Recargas

- El cliente registra su pago (monto, referencia, fecha).
- El admin aprueba o rechaza.
- Al aprobar, se acredita saldo en wallet.

## Retiros

- El cliente solicita retiro.
- El admin aprueba y marca como pagado.

## Contabilidad (admin)

Incluye:
- Total recargado
- Total retirado
- Ganancias de la casa por remates
- Saldos agregados de usuarios

Se usa para revision diaria o por periodos.

## Checklist diario (admin)

1) Revisar recargas pendientes.
2) Revisar retiros pendientes.
3) Confirmar remates activos.
4) Cerrar remates antes de la carrera.
5) Liquidar remates cuando ya hay ganador.
6) Revisar contabilidad al cierre del dia.

## Problemas comunes

- No llega correo de recuperacion: revisar spam o reintentar.
- No puedo pujar: revisar saldo disponible.
- No veo remates: puede no haber remates activos.

