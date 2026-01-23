// app/admin/super/usuarios/page.tsx
"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type WalletRow = {
  user_id: string
  username: string | null
  email: string | null
  saldo_disponible: string | number
  saldo_bloqueado: string | number
  created_at: string | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null | undefined) {
  if (!v) return "-"
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString("es-VE")
}

export default function SuperUsuariosPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [query, setQuery] = useState("")
  const [items, setItems] = useState<WalletRow[]>([])

  async function ensureSuperAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (pErr) throw new Error(pErr.message)
    if (!prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  async function loadData() {
    setLoading(true)
    setError("")
    try {
      const uid = await ensureSuperAdmin()
      if (!uid) return

      const { data, error: rpcErr } = await supabase.rpc("listar_wallets_superadmin", {
        p_query: query.trim() || null,
        p_limit: 100,
      })

      if (rpcErr) throw new Error(rpcErr.message)
      setItems((data ?? []) as WalletRow[])
    } catch (e: any) {
      setError(e?.message || "Error cargando datos.")
      setItems([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void loadData()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-4xl">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold">Usuarios y wallets</h1>
            <p className="mt-1 text-sm text-zinc-300">Vista exclusiva para superadmin.</p>
          </div>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <div className="mt-4 flex flex-col md:flex-row gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="w-full rounded-xl bg-zinc-900/60 border border-zinc-800 px-3 py-2 text-sm"
            placeholder="Buscar por usuario o correo..."
          />
          <button
            onClick={() => void loadData()}
            className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-zinc-950"
          >
            Buscar
          </button>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {loading ? (
          <div className="mt-4 text-sm text-zinc-400">Cargando...</div>
        ) : items.length === 0 ? (
          <div className="mt-4 text-sm text-zinc-400">Sin resultados.</div>
        ) : (
          <div className="mt-4 space-y-2">
            {items.map((it) => (
              <div key={it.user_id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-2">
                  <div>
                    <div className="text-sm font-semibold">{it.username ?? "—"}</div>
                    <div className="text-xs text-zinc-400">{it.email ?? "—"}</div>
                    <div className="mt-1 text-xs text-zinc-500">ID: {it.user_id}</div>
                  </div>
                  <div className="text-sm">
                    <div>
                      Disponible: <span className="font-semibold">{formatMoney(it.saldo_disponible)} Bs</span>
                    </div>
                    <div className="text-zinc-300">
                      Bloqueado: <span className="font-semibold">{formatMoney(it.saldo_bloqueado)} Bs</span>
                    </div>
                    <div className="mt-1 text-xs text-zinc-500">Creado: {formatDT(it.created_at)}</div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </main>
  )
}
