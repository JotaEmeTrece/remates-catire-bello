# Guia de Uso - Remate Catire Bello

Esta guia esta pensada para admins y usuarios generales. Explica el flujo diario, el manejo de remates y los procesos de recarga/retiro con palabras simples.

## Inicio rapido

### Clientes
1) Entra a /remates para ver remates activos.
2) Si deseas jugar, inicia sesion en /login.
3) Recarga saldo en /dashboard/recargar (debes llenar monto, metodo y referencia).
4) Entra al remate activo y usa el boton "Ponerle" (puja automatica) o escribe un monto y luego "Ponerle" (puja manual).
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
   - Entra a /admin y toca "Crear remate".
   - Completa los datos de carrera (descripcion, hipodromo, numero, fecha y hora).
   - Completa los datos del remate (nombre, apuesta minima, incremento y % casa).
   - Agrega caballos con numero, nombre, jinete y precio de salida.
   - Si un caballo necesita reglas propias, activalas y agrega rangos.
   - Si no tiene reglas propias, se aplican las reglas default.
   - Presiona "Crear remate".
2) Remate abierto
   - Los usuarios ven la tabla y pueden pujar.
   - El pozo se actualiza con cada puja.
3) Cerrar remate (admin)
   - Entra a /admin/remates y toca "Cerrar remate".
   - Se dejan de aceptar pujas.
   - Se liberan saldos de usuarios que no ganaron ningun caballo.
4) Liquidar remate (admin)
   - Entra a /admin/remates, selecciona "Liquidar".
   - Se abre un selector para elegir el caballo ganador (numero + nombre).
   - Confirma la seleccion.
   - El ganador recibe el pozo menos 25% de la casa.
   - Si el caballo ganador era de la casa, la casa se queda con todo.

## Roles y permisos

- Anonimo: solo puede ver remates activos.
- Cliente: puede ver remates, recargar saldo, retirar saldo y pujar.
- Admin: gestiona remates, recargas, retiros y contabilidad.
- Superadmin: lo mismo que admin, con control total del sistema.

## Recargas

- El cliente registra su pago (monto, metodo, referencia, fecha).
- El admin revisa y aprueba o rechaza.
- Al aprobar, se acredita saldo en wallet.

## Retiros

- El cliente solicita retiro.
- El admin revisa y marca como pagado.

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

## Reglas de precios (explicado simple)

Las reglas de precios determinan de cuanto en cuanto sube el precio de un caballo cuando alguien toca "Ponerle".

Se usan rangos de precio:
- Cada rango tiene un minimo, un maximo (opcional) y un incremento.
- Si el precio actual del caballo cae dentro de ese rango, ese es el incremento que aplica.

Ejemplo simple:
- Rango 0 a 100: incremento 20
- Rango 100 a 300: incremento 30
- Rango 300 a 600: incremento 40

Si un caballo esta en 80, la siguiente puja automatica sube 20.
Si esta en 120, la siguiente sube 30.
Si esta en 350, la siguiente sube 40.

Reglas default vs reglas propias:
- Reglas default: aplican a todos los caballos que no tengan reglas propias.
- Reglas propias: solo para un caballo especifico.

Puja manual:
- El usuario puede escribir un monto mayor.
- Ese monto debe ser mayor a la puja automatica minima (auto + 10).

## Stack utilizado

- Frontend: Next.js (React) + TypeScript + Tailwind CSS
- Backend: Supabase (Postgres + Auth + RLS + RPC)
- Infra: Vercel (frontend) y Supabase (base de datos)

## Capturas sugeridas (para el PDF)

Si vas a pasar esta guía a Word/PDF, estas capturas ayudan muchísimo a un admin no técnico. Puedes pegarlas debajo de cada punto.

1) **Inicio / Remates**
   - Pantalla `/remates` con y sin remates activos.
   - Botón “Iniciar sesión” visible para usuarios no logueados.

2) **Login y Registro**
   - Pantalla `/login` mostrando dónde poner correo/contraseña.
   - Pantalla `/register` mostrando username, teléfono y correo.

3) **Panel del cliente**
   - `/dashboard` con saldo disponible/bloqueado.
   - Acordeones (Recargas recientes, Retiros recientes, Historial) cerrados y abiertos.

4) **Recargar**
   - `/dashboard/recargar` mostrando el formulario y el listado de solicitudes.

5) **Retirar**
   - `/dashboard/retirar` mostrando el formulario y el listado de solicitudes.

6) **Panel Admin**
   - `/admin` (inicio del admin) con accesos: crear remate, recargas, retiros, remates, contabilidad.

7) **Crear remate**
   - `/admin/crear-remate` en cada bloque: Carrera, Remate, Reglas default, Caballos.
   - Ejemplo de “Agregar rango” y “Agregar caballo”.

8) **Gestionar remates**
   - `/admin/remates` mostrando botones “Cerrar remate” y el acceso a liquidación.

9) **Liquidación**
   - Modal/selector para elegir el caballo ganador (número + nombre) y confirmación.

10) **Contabilidad**
   - `/admin/contabilidad` mostrando totales y desglose por método.

## Glosario (términos usados en la app)

- **Remate**: evento donde se puja por caballos de una carrera.
- **Carrera**: la carrera real (hipódromo, número de carrera, fecha y hora).
- **Caballo**: participante de la carrera. En el remate, cada caballo “tiene un precio” que va subiendo por pujas.
- **Precio de salida**: precio inicial del caballo al abrir el remate (si nadie puja, ese caballo queda “para la casa”).
- **Puja / Rematar**: acción de subir el precio de un caballo.
- **Ponerle**: puja automática. Sube el precio según el incremento del rango actual.
- **Puja manual**: el usuario escribe un monto y luego presiona “Ponerle” para ofertar por encima del mínimo.
- **Reglas de precios**: rangos que definen el incremento automático según el precio actual del caballo.
- **Reglas default**: reglas que aplican a todos los caballos que no tengan reglas propias.
- **Reglas propias**: reglas específicas para un caballo (se priorizan sobre las default).
- **Pozo (acumulado)**: suma total de lo que vale la tabla completa de caballos en ese momento (incluye precios de salida si algún caballo queda para la casa).
- **% casa (25%)**: porcentaje fijo del pozo que se queda la casa cuando el ganador del remate es un usuario.
- **Cerrar remate**: se detienen las pujas. Se liberan saldos bloqueados de usuarios que no quedaron ganando ningún caballo.
- **Liquidar remate**: se indica el caballo ganador y se hace el reparto final del pozo.
- **Disponible**: saldo que el usuario puede usar para pujar/operar.
- **Bloqueado**: saldo “retenido” por pujas mientras el remate está activo o hasta que se ejecuten las reglas al cerrar/liquidar.
- **Recarga**: solicitud para añadir saldo (se aprueba manualmente).
- **Retiro**: solicitud para sacar saldo (se procesa manualmente).

---

Remate Catire Bello ©2026 Todos los derechos reservados. Desarrollado por Jercol Technologies. Powered by GPT Codex.
