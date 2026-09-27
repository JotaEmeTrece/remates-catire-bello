# Cómo funciona el dinero — versión Jota

**Actualizado:** 27 de septiembre de 2026 · **Aplica a:** el modelo v2, desplegado en producción desde el 24/09/2026.

Este documento está escrito en dos idiomas a la vez. **En cristiano** es lo que le explicas a una persona. **Por dentro** es lo que hace el sistema. Si alguna vez los dos se contradicen, el que manda es el código y este documento está desactualizado — avísalo.

La versión sin la parte técnica, la que se le entrega al licenciatario, está en `docs/licencia/COMO_FUNCIONA_EL_DINERO.md`. Las dos dicen lo mismo.

---

## 1. La idea entera, en una frase

> **Durante el remate no se mueve un solo peso. El dinero se mueve una sola vez, al cerrar.**

Si te acuerdas de esa frase, el resto se deduce.

---

## 2. Los tres números del usuario

**En cristiano.** Cada usuario ve tres cifras, no una:

| Número | Qué es |
|---|---|
| **Saldo total** | Todo lo que tiene en la casa |
| **Comprometido** | Lo que se le va a cobrar si los remates cerraran ahora mismo |
| **Retirable** | Lo que puede sacar hoy: total menos comprometido |

El saldo total **no baja** cuando pujas. Lo que baja es el retirable. Mucha gente espera que baje el total — y ahí es donde se confunden.

**Por dentro.** Los devuelve `mi_wallet_resumen()`, que da cuatro columnas:

```
saldo_disponible          -- la columna real de la tabla wallets
saldo_bloqueado           -- vale 0 SIEMPRE, ver §6
comprometido              -- compromiso_usuario(auth.uid())
disponible_para_retirar   -- greatest(saldo_disponible - comprometido, 0)
```

El `greatest(..., 0)` es defensivo: si por lo que sea el compromiso superara al saldo, el retirable se queda en 0 y no en negativo.

---

## 3. Qué pasa en cada momento

**En cristiano.**

| Momento | Qué le pasa al dinero |
|---|---|
| Pujas por primera vez | **Nada.** Queda comprometido, no cobrado |
| Te superan | **Nada.** Tu compromiso baja solo, porque ya no vas ganando |
| Subes tu propia puja | **Nada.** Tu compromiso pasa a ser la puja nueva |
| Retiran el caballo | **Nada.** Sale del remate y tu compromiso baja |
| **Se cierra el remate** | **Aquí sí.** A cada uno que iba ganando un caballo se le cobra |
| Se liquida | Se le paga el premio al ganador |

**Por dentro.** `hacer_puja()` escribe **una fila en `bids`** y nada más. No toca `wallets` ni `wallet_movements`. El compromiso no es un número guardado: se calcula con `compromiso_usuario(user_id)`, que suma las pujas que el usuario **lidera ahora mismo**, en remates abiertos, sobre caballos no retirados.

Por eso "te superan" no dispara ninguna devolución: no hay nada que devolver. La suma simplemente deja de incluirte.

---

## 4. El caso que confunde a todo el mundo: subir tu propia puja

**En cristiano.** Vas ganando un caballo en 200 y lo subes a 250. Quedas comprometido por **250**, no por 450. Tu puja nueva **reemplaza** a la vieja, no se suma.

**Por dentro.** Es una resta de dos líneas dentro de `hacer_puja()`:

```sql
v_compromiso := compromiso_usuario(v_user_id);   -- incluye tus 200
if v_top_user_id = v_user_id then
  v_compromiso := v_compromiso - v_top_monto;    -- se los quita
end if;
if v_saldo < (v_compromiso + p_monto) then ... rechaza
```

En el modelo viejo esto había que calcularlo a mano ("bloquéale solo el delta") y era una fuente de errores. Aquí sale gratis porque el compromiso se recalcula entero cada vez.

---

## 5. Un usuario puede estar comprometido en varios sitios a la vez

**En cristiano.** Si vas ganando tres caballos en dos remates distintos, tu comprometido es la suma de los tres. Y si uno de esos remates es adelantado, ese dinero puede quedar comprometido tres o cuatro días.

Por eso el retiro te deja sacar **lo retirable**, no cero: bloquearte todo el saldo por una puja de 100 sería inaceptable en un adelantado.

**Por dentro.** `solicitar_retiro()` valida contra `saldo_disponible - compromiso_usuario()`, con el mismo candado por usuario que `hacer_puja`. Sin ese candado, una puja y un retiro simultáneos pasan los dos — está demostrado con dos conexiones reales, no es teoría.

---

## 6. Por qué no se mueve dinero durante el remate

**En cristiano.** Antes sí se movía: al pujar se te apartaba la plata, y si te superaban se te devolvía y se le apartaba al otro. Funcionaba, pero cada puja era un baile de cuatro movimientos de dinero. Si algo fallaba a la mitad —se cae la conexión, se traba una consulta— aparecía plata o desaparecía.

Ahora no hay nada que pueda fallar a la mitad, porque no hay nada.

**Por dentro.** Comparación de la misma secuencia (Juan puja 100, Pedro 150, Juan 200):

| | v1 (hasta el 24/09) | **v2 (hoy)** |
|---|---|---|
| Escrituras en `wallets` | 12 | **0** |
| Filas en `wallet_movements` | 6 | **0** |
| Filas en `bids` | 3 | 3 |

La columna `wallets.saldo_bloqueado` **sigue existiendo y vale 0 siempre**. No se borró a propósito: el arnés verifica que sea 0 en vez de asumirlo. Borrarla a ciegas habría sido perder la red de seguridad.

---

## 7. El final tiene dos pasos, no uno

**En cristiano.** Terminar un remate son dos cosas separadas, y entre una y otra puede pasar tiempo:

1. **Cerrar** — se acaban las pujas. A cada líder se le cobra. Pase lo que pase en la carrera, esa plata ya no vuelve.
2. **Liquidar** — ya se sabe qué caballo ganó. Se le paga al dueño de ese caballo.

Entre los dos pasos hay un hueco que puede durar horas. Es normal: la carrera todavía no ha corrido.

**Por dentro.** `cerrar_remate()` delega en `_cerrar_remate_interno(uuid)`, que existe porque el cron corre sin `auth.uid()` y necesita el mismo camino que el botón. Escribe un `apuesta_cobro` por usuario. `liquidar_remate()` exige `estado = 'cerrado'`, paga el `premio`, y escribe el asiento `resultado_remate` en el libro de la casa.

Los tipos de movimiento vigentes: `recarga`, `apuesta_cobro`, `apuesta_devolucion`, `premio`, `retiro`, `ajuste_manual`. Los dos del modelo viejo (`apuesta_bloqueo`, `apuesta_liberacion`) siguen en el enum por los registros históricos pero ya nadie los escribe.

---

## 8. El dinero de la casa

**En cristiano.** La casa tiene su propio libro, aparte del saldo de los usuarios. Registra cuatro cosas: capital que metiste, utilidades que sacaste, ajustes, y **lo ganado en cada remate — esto último lo escribe el sistema solo, no se puede meter a mano**.

Eso da dos formas independientes de calcular lo mismo, y tienen que dar igual. Si no cuadran, hay un bug o alguien metió mano.

**Por dentro.** `house_ledger` y `casa_resumen()`. El cuadre es:

```
resultado_operativo  = suma de los asientos 'resultado_remate'
perdida_usuarios     = recargas - retiros pagados - retiros pendientes - saldos
descuadre            = resultado_operativo - perdida_usuarios     -- debe ser 0
```

`registrar_movimiento_casa()` **rechaza** el tipo `resultado_remate` a propósito. Si un admin pudiera escribirlo, las dos fuentes dejarían de ser independientes y el cuadre no significaría nada.

---

## 9. Las tres protecciones, y qué pasa si faltan

**En cristiano.** Hay tres cosas que impiden que el dinero se descuadre, y cada una existe porque sin ella se rompe algo concreto:

| Protección | Sin ella pasa esto |
|---|---|
| Candado por usuario | Dos pujas simultáneas de 300 con 500 de saldo: pasan las dos, quedan 600 comprometidos |
| Guarda de exposición | Alguien compromete más de lo que tiene |
| Guarda de solvencia | La casa paga un premio con plata que es de otro usuario |

**Por dentro.** `pg_advisory_xact_lock(1, hashtext(user_id))` en las cinco funciones que mueven dinero: `hacer_puja`, `_cerrar_remate_interno`, `solicitar_retiro`, `cancelar_remate`, `retirar_caballo`. **Siempre espacio de usuario (1) antes que espacio de caballo (2)**, y los bucles ordenados por `user_id`. Ese orden no es estético: es lo que evita el interbloqueo.

El invariante que todo esto sostiene, y que el arnés comprueba: **`saldo_disponible >= compromiso_usuario()`, para todo usuario, siempre.**

---

## 10. Lo que la app NO hace

**En cristiano.** La app **no custodia dinero**. No tiene cuenta bancaria, no recibe pagos, no transfiere nada. Lo que hace es **llevar la cuenta**: refleja lo que la casa dice haber recibido y lo que dice haber pagado.

El dinero de verdad se mueve por fuera, entre personas. Cuando un usuario recarga, alguien de la casa confirma que recibió el pago y la app anota el saldo. Cuando retira, la casa le paga por fuera y marca el retiro como pagado.

Esto importa decirlo bien, y con cuidado: **la app es un registro contable, no un medio de pago.** Los requisitos legales de operar así varían por país y no son algo que yo pueda resolverte — eso es conversación con un abogado del sitio donde vaya a operar cada licenciatario, no con el desarrollador.

---

## 11. Glosario

| Palabra | Qué significa aquí |
|---|---|
| **Comprometido** | Lo que se te cobraría si todo cerrara ahora. No está cobrado |
| **Retirable** | Saldo total menos comprometido |
| **Líder** | Quien va ganando un caballo ahora mismo |
| **Pozo** | La suma de todos los caballos del remate, incluidos los que quedaron a la casa |
| **Cerrar** | Se acaban las pujas y se cobra |
| **Liquidar** | Se conoce el ganador y se paga el premio |
| **Adelantado** | Remate que se monta días antes de la carrera |
| **Descuadre** | Diferencia entre el libro de la casa y los saldos. Debe ser 0 |

---

## Dónde comprobar cada cosa

Nada de este documento es teoría: todo está verificado en `tests/pruebas_dinero.sql`, que corre en verde de punta a punta. Si dudas de una afirmación, la prueba correspondiente la demuestra o la desmiente. Esa es la forma de mantener este documento honesto — cuando cambie el comportamiento, la prueba se pone roja antes de que el documento se vuelva mentira.
