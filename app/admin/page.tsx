// ADMIN/PAGE.TSX

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

export default function AdminHomePage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")

  const [pendingDeposits, setPendingDeposits] = useState<number>(0)
  const [pendingWithdraws, setPendingWithdraws] = useState<number>(0)

  async function ensureAdmin() {
    // 1) Sesión
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/login")
      return null
    }

    // 2) Perfil (es_admin)
    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)

    if (!prof?.es_admin) {
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

      // Conteos rápidos (pendientes)
      const dep = await supabase
        .from("deposit_requests")
        .select("id", { count: "exact", head: true })
        .eq("estado", "pendiente")

      const wit = await supabase
        .from("withdraw_requests")
        .select("id", { count: "exact", head: true })
        .eq("estado", "pendiente")

      if (dep.error) throw new Error(dep.error.message)
      if (wit.error) throw new Error(wit.error.message)

      setPendingDeposits(n(dep.count))
      setPendingWithdraws(n(wit.count))
    } catch (e: any) {
      setError(e?.message || "Error cargando panel admin")
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando admin...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Panel Admin</h1>
          <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {/* Error */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {/* Cards */}
        <div className="mt-4 grid grid-cols-2 gap-2">
          <Link href="/admin/recargas" className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="text-xs text-zinc-500">Recargas pendientes</div>
            <div className="mt-1 text-2xl font-semibold text-amber-300">{pendingDeposits}</div>
            <div className="mt-2 text-xs text-zinc-300 underline underline-offset-4">Abrir</div>
          </Link>

          <Link href="/admin/retiros" className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="text-xs text-zinc-500">Retiros pendientes</div>
            <div className="mt-1 text-2xl font-semibold text-amber-300">{pendingWithdraws}</div>
            <div className="mt-2 text-xs text-zinc-300 underline underline-offset-4">Abrir</div>
          </Link>
        </div>

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>

        {/* Acciones */}
        <div className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="text-sm font-semibold">Acciones</div>

          <div className="mt-3 flex flex-col gap-2">
            <Link href="/admin/crear-remate" className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold">
              Crear remate rápido
            </Link>

            <Link href="/admin/recargas" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Gestionar recargas
            </Link>
            <Link href="/admin/retiros" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Gestionar retiros
            </Link>
            <Link href="/remates" className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm">
              Ir a remates
            </Link>
          </div>

          <div className="mt-3 text-xs text-zinc-500">
            Tip: “Crear remate rápido” te evita abrir 20 queries en el SQL Editor 😄
          </div>
        </div>
      </div>
    </main>
  )
}

