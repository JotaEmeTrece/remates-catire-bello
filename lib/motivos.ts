"use client"

// ===========================================================================
//  lib/motivos.ts  -  LOS MOTIVOS DE RECHAZO, UNA SOLA VEZ
//
//  POR QUE (01/10/2026)
//
//  Las dos pantallas de admin -- recargas y retiros -- necesitan la misma
//  lista. Escribirla dos veces es como se separan (ADR-015), y escribirla en
//  el frontend es peor todavia: la lista vive en `motivos_rechazo`, que es una
//  tabla de la INSTALACION, para que cada licenciatario tenga los suyos.
//
//  Esta pantalla no decide nada: pide la lista y la pinta. La base valida el
//  codigo igual en `_motivo_etiqueta()`, asi que un desplegable desactualizado
//  no puede colar un motivo que no existe -- lo peor que pasa es que el admin
//  vea una opcion de menos hasta recargar.
// ===========================================================================

import { useEffect, useState } from "react"
import { supabase } from "@/lib/supabaseClient"

export type Motivo = {
  codigo: string
  etiqueta: string
  ambito: "recarga" | "retiro" | "ambos"
  orden: number
}

export function useMotivos(ambito: "recarga" | "retiro") {
  const [motivos, setMotivos] = useState<Motivo[]>([])
  const [error, setError] = useState<string>("")

  useEffect(() => {
    let cancelado = false
    ;(async () => {
      const { data, error: err } = await supabase
        .from("motivos_rechazo")
        .select("codigo,etiqueta,ambito,orden")
        .eq("activo", true)
        .in("ambito", [ambito, "ambos"])
        .order("orden", { ascending: true })

      if (cancelado) return
      if (err) {
        // No se bloquea la pantalla: el admin sigue pudiendo aprobar y pagar.
        // Lo que no va a poder es rechazar, y el mensaje dice por que.
        console.warn("[motivos] no se pudo leer la lista:", err.message)
        setError("No se pudo cargar la lista de motivos. Recarga la página para rechazar.")
        setMotivos([])
        return
      }
      setMotivos((data ?? []) as Motivo[])
    })()
    return () => {
      cancelado = true
    }
  }, [ambito])

  return { motivos, error }
}
