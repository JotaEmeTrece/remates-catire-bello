// REMATES/PAGE.TSX

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type RemateRow = {
  id: string
  nombre: string
  estado: string
  race_id: string
  created_at: string | null
}

type RaceRow = {
  id: string
  nombre: string
  hipodromo: string | null
  numero_carrera: number | null
  fecha: string
  hora_programada: string | null
  estado: string
}

function badgeClass(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e.includes("abierto")) return "bg-emerald-500/15 text-emerald-200 ring-1 ring-emerald-500/25"
  if (e.includes("cerr")) return "bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/25"
  if (e.includes("liq") || e.includes("liquid")) return "bg-sky-500/15 text-sky-200 ring-1 ring-sky-500/25"
  return "bg-zinc-500/15 text-zinc-200 ring-1 ring-zinc-500/25"
}

export default function RematesPage() {
  /**
   * =========================
   * State
   * =========================
   */
  const router = useRouter()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [remates, setRemates] = useState<RemateRow[]>([])
  const [racesById, setRacesById] = useState<Record<string, RaceRow>>({})

  /**
   * =========================
   * Carga inicial
   * =========================
   */
  useEffect(() => {
    const load = async () => {
      setLoading(true)
      setError("")

      // 1) sesión
      const { data: auth, error: authErr } = await supabase.auth.getUser()
      if (authErr) {
        setError(authErr.message)
        setLoading(false)
        return
      }
      if (!auth?.user) {
        router.replace("/login")
        return
      }

      // 2) remates
      const { data: r, error: rErr } = await supabase
        .from("remates")
        .select("id,nombre,estado,race_id,created_at")
        .order("created_at", { ascending: false })
        .limit(50)

      if (rErr) {
        setError(rErr.message)
        setLoading(false)
        return
      }

      const rems = (r ?? []) as RemateRow[]
      setRemates(rems)

      // 3) races de esos remates (para mostrar info)
      const raceIds = Array.from(new Set(rems.map((x) => x.race_id).filter(Boolean)))
      if (raceIds.length > 0) {
        const { data: races, error: racesErr } = await supabase
          .from("races")
          .select("id,nombre,hipodromo,numero_carrera,fecha,hora_programada,estado")
          .in("id", raceIds)

        if (racesErr) {
          // No bloquea la pantalla, solo deja menos info
          console.error("Error cargando races:", racesErr.message)
        } else {
          const map: Record<string, RaceRow> = {}
          for (const rc of (races ?? []) as RaceRow[]) map[rc.id] = rc
          setRacesById(map)
        }
      }

      setLoading(false)
    }

    void load()
  }, [router])

  /**
   * =========================
   * UI
   * =========================
   */
  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando remates...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Remates</h1>
          <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
            Ir al panel
          </Link>
        </div>

        {/* Error */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {/* Empty state */}
        {remates.length === 0 ? (
          <div className="mt-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <p className="text-sm text-zinc-200">Aún no hay remates creados.</p>
            <p className="mt-1 text-xs text-zinc-400">
              Crea un remate en Supabase (tabla <span className="text-zinc-200">remates</span>) para que aparezca aquí.
            </p>
          </div>
        ) : (
          <div className="mt-5 space-y-3">
            {remates.map((r) => {
              const race = racesById[r.race_id]
              return (
                <Link
                  key={r.id}
                  href={`/remates/${r.id}`}
                  className="block rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 hover:border-zinc-700 transition"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-base font-semibold">{r.nombre}</div>
                      <div className="mt-1 text-xs text-zinc-400">
                        {race ? (
                          <>
                            {race.hipodromo ? `${race.hipodromo} · ` : ""}
                            {race.numero_carrera != null ? `Carrera ${race.numero_carrera} · ` : ""}
                            {race.fecha}
                            {race.hora_programada ? ` ${race.hora_programada}` : ""}
                          </>
                        ) : (
                          "—"
                        )}
                      </div>
                    </div>

                    <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(r.estado)}`}>
                      {r.estado}
                    </span>
                  </div>

                  <div className="mt-3 text-xs text-zinc-500">
                    Toca para entrar a la tabla del remate →
                  </div>
                </Link>
              )
            })}
          </div>
        )}
      </div>
    </main>
  )
}

