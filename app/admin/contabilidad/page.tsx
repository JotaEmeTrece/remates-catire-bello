// ADMIN/CONTABILIDAD/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

function n(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: unknown) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

type Resumen = {
  recargas_aprobadas: number
  recargas_pendientes: number
  retiros_pagados: number
  retiros_pendientes: number
  remates_liquidados: number
  remates_pozo_total: number
  remates_premio_total: number
  remates_casa_total: number
  saldo_usuarios: number
  dinero_casa: number
}

export default function AdminContabilidadPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")

  const [resumen, setResumen] = useState<Resumen | null>(null)

  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      const { data, error: rpcErr } = await supabase.rpc("admin_contabilidad_resumen")
      if (rpcErr) throw new Error(rpcErr.message)

      const raw = (data ?? {}) as Record<string, unknown>
      setResumen({
        recargas_aprobadas: n(raw.recargas_aprobadas),
        recargas_pendientes: n(raw.recargas_pendientes),
        retiros_pagados: n(raw.retiros_pagados),
        retiros_pendientes: n(raw.retiros_pendientes),
        remates_liquidados: n(raw.remates_liquidados),
        remates_pozo_total: n(raw.remates_pozo_total),
        remates_premio_total: n(raw.remates_premio_total),
        remates_casa_total: n(raw.remates_casa_total),
        saldo_usuarios: n(raw.saldo_usuarios),
        dinero_casa: n(raw.dinero_casa),
      })
    } catch (e: any) {
      setError(e?.message || "Error cargando contabilidad")
      setResumen(null)
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const cards = useMemo(() => {
    if (!resumen) return []
    return [
      {
        title: "Casa (remates)",
        value: `${formatMoney(resumen.remates_casa_total)} Bs`,
        hint: `Remates liquidados: ${resumen.remates_liquidados}`,
      },
      {
        title: "Recargas aprobadas",
        value: `${formatMoney(resumen.recargas_aprobadas)} Bs`,
        hint: `Pendientes: ${formatMoney(resumen.recargas_pendientes)} Bs`,
      },
      {
        title: "Retiros pagados",
        value: `${formatMoney(resumen.retiros_pagados)} Bs`,
        hint: `Pendientes: ${formatMoney(resumen.retiros_pendientes)} Bs`,
      },
      {
        title: "Saldo usuarios",
        value: `${formatMoney(resumen.saldo_usuarios)} Bs`,
        hint: "Disponible + bloqueado",
      },
      {
        title: "Dinero neto casa",
        value: `${formatMoney(resumen.dinero_casa)} Bs`,
        hint: "Recargas - retiros - saldo usuarios",
      },
      {
        title: "Pozo total (remates)",
        value: `${formatMoney(resumen.remates_pozo_total)} Bs`,
        hint: `Premios pagados: ${formatMoney(resumen.remates_premio_total)} Bs`,
      },
    ]
  }, [resumen])

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando contabilidad...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Contabilidad</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        <div className="mt-4 grid grid-cols-2 gap-2">
          {cards.map((c) => (
            <div key={c.title} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
              <div className="text-xs text-zinc-500">{c.title}</div>
              <div className="mt-1 text-lg font-semibold text-amber-300">{c.value}</div>
              <div className="mt-2 text-[11px] text-zinc-400">{c.hint}</div>
            </div>
          ))}
        </div>

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>
      </div>
    </main>
  )
}

