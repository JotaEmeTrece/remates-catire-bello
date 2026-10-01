"use client"

import { useEffect, useRef } from "react"
import { supabase } from "./supabaseClient"

/**
 * SUSCRIPCION A LAS SENALES DE LA BASE
 *
 * El evento que llega es una SENAL, no el dato: dice "algo cambio en el
 * remate X" y nada mas. Quien lo recibe vuelve a preguntarle a la base.
 *
 * Eso no es un rodeo, es el ADR-015. Si el evento trajera la puja, esta
 * pantalla tendria que recalcular el minimo siguiente, quien lidera y el
 * precio actual a partir de ella — o sea, reimplementar en TypeScript lo que
 * hace `_incremento_aplicable` en la base. Ese defecto ya ocurrio el 23/09:
 * la pantalla mostraba un numero y la base cobraba otro.
 *
 * Aqui no puede pasar, porque la pantalla nunca calcula: pregunta.
 *
 * Ver la migracion 20260930120000_realtime_senales.sql.
 */

/** Lo que puede cambiar dentro de un remate. */
export const EVENTOS_REMATE = ["puja", "remate", "aviso", "caballo"] as const

/** Lo que puede cambiar en la caja: solo lo ven los admins. */
export const EVENTOS_CAJA = ["recarga", "retiro"] as const

export function topicoRemate(remateId: string) {
  return `remate:${remateId}`
}

export const TOPICO_CAJA = "admin:caja"

/**
 * Escucha un canal y llama a `alRecibir` cuando llega cualquiera de `eventos`.
 *
 * - `topico` en null desactiva la suscripcion (util mientras no se sabe el id).
 * - Las senales se agrupan: una rafaga de pujas provoca UNA recarga, no diez.
 * - Si la suscripcion falla, se queda escrito en la consola con el motivo. Una
 *   suscripcion que no conecta y no lo dice es un diagnostico ciego, y de esos
 *   ya llevamos suficientes.
 */
export function useSenal(
  topico: string | null,
  eventos: readonly string[],
  alRecibir: () => void,
  esperaMs = 250,
) {
  // La referencia evita volver a suscribirse cada vez que el componente
  // vuelve a renderizar y crea una funcion nueva.
  const cb = useRef(alRecibir)
  cb.current = alRecibir

  const listaEventos = eventos.join(",")

  useEffect(() => {
    // La guarda va ANTES, y la constante lleva el tipo escrito.
    //
    // TypeScript no arrastra el estrechamiento de una variable al interior de
    // una funcion anidada, ni siquiera si es `const`. Escribir
    // `const t = topico; if (!t) return;` y usar `t` dentro de `arrancar`
    // falla con "Type 'null' is not assignable to type 'string'".
    // Comprobado con tsc --strict el 30/09, despues de equivocarme dos veces
    // razonandolo de cabeza.
    //
    // Declarandola DESPUES de la guarda y con `: string`, el tipo queda fijado
    // en la declaracion y no depende del analisis de flujo.
    if (!topico) return
    const canalTopico: string = topico

    let cancelado = false
    let temporizador: ReturnType<typeof setTimeout> | null = null
    let canal: ReturnType<typeof supabase.channel> | null = null

    function agrupar() {
      if (cancelado) return
      if (temporizador) clearTimeout(temporizador)
      temporizador = setTimeout(() => {
        if (!cancelado) cb.current()
      }, esperaMs)
    }

    async function arrancar() {
      // Pone el token de la sesion (o la clave anonima) en el socket. Sin
      // esto un canal privado no autoriza y no llega nada.
      try {
        await supabase.realtime.setAuth()
      } catch (e) {
        console.warn("[realtime] setAuth fallo:", e)
      }
      if (cancelado) return

      const c = supabase.channel(canalTopico, { config: { private: true } })
      for (const ev of listaEventos.split(",")) {
        c.on("broadcast", { event: ev }, (msg) => {
          console.log(`[realtime] ${canalTopico} <- ${ev}`, msg)
          agrupar()
        })
      }
      c.subscribe((estado, err) => {
        // SE REGISTRA TODO ESTADO, NO SOLO LOS FALLOS.
        //
        // La primera version solo avisaba en CHANNEL_ERROR y TIMED_OUT, y eso
        // dejaba una consola limpia significando dos cosas opuestas: "se
        // suscribio bien" o "este hook nunca corrio". Sin poder distinguirlas,
        // el log no servia para diagnosticar nada -- que es el defecto que
        // llevamos toda la semana corrigiendo en otros sitios.
        if (estado === "CHANNEL_ERROR" || estado === "TIMED_OUT") {
          console.warn(`[realtime] ${canalTopico}: ${estado}`, err)
        } else {
          console.log(`[realtime] ${canalTopico}: ${estado}`)
        }
      })
      canal = c
    }

    void arrancar()

    return () => {
      cancelado = true
      if (temporizador) clearTimeout(temporizador)
      if (canal) void supabase.removeChannel(canal)
    }
  }, [topico, listaEventos, esperaMs])
}
