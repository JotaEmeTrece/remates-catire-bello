// REMATES/PAGE.TSX

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { supabase } from "@/lib/supabaseClient"
import ClientBottomNav from "@/app/components/ClientBottomNav"
import { CornerLogo } from "@/app/components/BrandLogo"

type RemateRow = {
  id: string
  nombre: string
  estado: string
  race_id: string
  created_at: string | null
  archived_at?: string | null
  opens_at?: string | null
  closes_at?: string | null
  tipo?: string | null
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
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [remates, setRemates] = useState<RemateRow[]>([])
  const [racesById, setRacesById] = useState<Record<string, RaceRow>>({})
  const [hasSession, setHasSession] = useState(false)
  const [isAdmin, setIsAdmin] = useState(false)
  const [authReady, setAuthReady] = useState(false)

  useEffect(() => {
    const load = async () => {
      setLoading(true)
      setError("")

      const { data: auth } = await supabase.auth.getUser()
      const user = auth?.user ?? null

      const hasUser = !!user
      let adminFlag = false
      if (user) {
        const { data: prof } = await supabase
          .from("profiles")
          .select("es_admin,es_super_admin")
          .eq("id", user.id)
          .maybeSingle()
        adminFlag = !!(prof?.es_admin || prof?.es_super_admin)
      }
      setHasSession(hasUser)
      setIsAdmin(adminFlag)
      setAuthReady(true)

      const { data: r, error: rErr } = await supabase
        .from("remates")
        .select("id,nombre,estado,race_id,created_at,archived_at,opens_at,closes_at,tipo")
        .is("archived_at", null)
        .neq("estado", "liquidado")
        .neq("estado", "cancelado")
        .eq("estado", "abierto")
        .order("created_at", { ascending: false })
        .limit(50)

      if (rErr) {
        setError(rErr.message)
        setLoading(false)
        return
      }

      const now = Date.now()
      const rems = (r ?? []) as RemateRow[]
      const visible = rems.filter((x) => {
        const o = x.opens_at ? new Date(x.opens_at).getTime() : null
        const c = x.closes_at ? new Date(x.closes_at).getTime() : null
        if (o && now < o) return false
        if (c && now >= c) return false
        return true
      })
      setRemates(visible)

      const raceIds = Array.from(new Set(rems.map((x) => x.race_id).filter(Boolean)))
      if (raceIds.length > 0) {
        const { data: races, error: racesErr } = await supabase
          .from("races")
          .select("id,nombre,hipodromo,numero_carrera,fecha,hora_programada,estado")
          .in("id", raceIds)

        if (racesErr) {
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
  }, [])

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando remates...</div>
  }

  return (
    <>
      <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6 pb-24">
        <div className="mx-auto w-full max-w-md">
          <div className="mb-3">
            <CornerLogo />
          </div>
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Remates</h1>
          <div className="flex items-center gap-3 text-xs text-zinc-300">
            <Link href="/reglas" className="underline underline-offset-4">
              Reglas
            </Link>
            {authReady && hasSession ? (
              <Link href={isAdmin ? "/admin" : "/dashboard"} className="underline underline-offset-4">
                Ir al panel
              </Link>
            ) : (
              <Link href="/login" className="underline underline-offset-4">
                Iniciar sesión
              </Link>
            )}
          </div>
        </div>

        {!hasSession ? (
          <div className="mt-3">
            <Link
              href="/login"
              className="inline-flex rounded-xl bg-white px-4 py-2 text-sm font-semibold text-zinc-950"
            >
              Iniciar sesión
            </Link>
          </div>
        ) : null}

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {remates.length === 0 ? (
          <div className="mt-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <p className="text-sm text-zinc-200">En este momento no hay remates activos.</p>
            <p className="mt-1 text-xs text-zinc-400">Vuelve pronto para ver nuevos remates.</p>
          </div>
        ) : (
          <div className="mt-5 space-y-3">
            {[
              { key: "vivo", label: "En vivo" },
              { key: "adelantado", label: "Adelantados" },
            ].map((section) => {
              const list =
                section.key === "adelantado"
                  ? remates.filter((r) => r.tipo === "adelantado")
                  : remates.filter((r) => r.tipo !== "adelantado")
              if (list.length === 0) return null
              return (
                <div key={section.key}>
                  <div className="mb-2 text-xs uppercase tracking-wide text-zinc-400">{section.label}</div>
                  <div className="space-y-3">
                    {list.map((r) => {
              const race = racesById[r.race_id]
              return (
                <Link
                  key={r.id}
                  href={isAdmin ? `/admin/remates/${r.id}` : `/remates/${r.id}`}
                  className="block rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 hover:border-zinc-700 transition"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-base font-semibold">{r.nombre}</div>
                      <div className="mt-1 text-xs text-zinc-400">
                        {race ? (
                          <>
                            {race.hipodromo ? `${race.hipodromo} - ` : ""}
                            {race.numero_carrera != null ? `Carrera ${race.numero_carrera} - ` : ""}
                            {race.fecha}
                            {race.hora_programada ? ` ${race.hora_programada}` : ""}
                          </>
                        ) : (
                          "-"
                        )}
                      </div>
                    </div>

                    <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(r.estado)}`}>
                      {r.estado}
                    </span>
                  </div>

                  <div className="mt-3 text-xs text-zinc-500">Toca para entrar a la tabla del remate.</div>
                </Link>
              )
                    })}
                  </div>
                </div>
              )
            })}
          </div>
        )}
        </div>
      </main>
      {authReady && hasSession && !isAdmin ? <ClientBottomNav /> : null}
    </>
  )
}
