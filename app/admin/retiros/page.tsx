// ADMIN/RETIROS/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type WithdrawRow = {
  id: string
  user_id: string
  monto: string | number
  metodo: string
  telefono_destino: string
  comentario: string | null
  estado: string
  created_at: string | null
  processed_at: string | null
  processed_by: string | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}
function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}
function formatDT(v: string | null | undefined) {
  if (!v) return "—"
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString("es-VE")
}
function statusPillClass(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e.includes("pag")) return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e.includes("rech")) return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
}

export default function AdminRetirosPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [actingId, setActingId] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")

  const [estado, setEstado] = useState<"pendiente" | "pagado" | "rechazado">("pendiente")
  const estadoLabel = useMemo(() => {
    if (estado === "pendiente") return "Pendientes"
    if (estado === "pagado") return "Pagados"
    return "Rechazados"
  }, [estado])

  const [items, setItems] = useState<WithdrawRow[]>([])

  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/login")
      return null
    }

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
    setNotice("")

    try {
      const aid = await ensureAdmin()
      if (!aid) return

      const { data, error: qErr } = await supabase
        .from("withdraw_requests")
        .select("id,user_id,monto,metodo,telefono_destino,comentario,estado,created_at,processed_at,processed_by")
        .eq("estado", estado)
        .order("created_at", { ascending: false })
        .limit(50)

      if (qErr) throw new Error(qErr.message)
      setItems((data ?? []) as WithdrawRow[])
    } catch (e: any) {
      setError(e?.message || "Error cargando retiros")
      setItems([])
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [estado])

  async function procesar(id: string, nuevoEstado: "pagado" | "rechazado") {
    setActingId(id)
    setError("")
    setNotice("")

    // ✅ Usa tu RPC real
    const { data, error: rpcErr } = await supabase.rpc("procesar_retiro", {
      p_withdraw_id: id,
      p_nuevo_estado: nuevoEstado, // enum withdraw_status
    })

    if (rpcErr) {
      setActingId(null)
      setError(rpcErr.message || "Error procesando retiro")
      return
    }

    setNotice(typeof data === "string" ? data : `✅ Retiro ${nuevoEstado}.`)
    await load(true)
    setActingId(null)
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Admin · Retiros</h1>
          <div className="flex items-center gap-3">
            <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
              Admin
            </Link>
            <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
              Panel
            </Link>
          </div>
        </div>

        {/* Filtros */}
        <div className="mt-4 grid grid-cols-3 gap-2">
          {(["pendiente", "pagado", "rechazado"] as const).map((s) => {
            const active = estado === s
            return (
              <button
                key={s}
                onClick={() => setEstado(s)}
                className={`rounded-xl px-3 py-2 text-sm border ${
                  active ? "bg-white text-zinc-950 border-white" : "bg-zinc-900/60 text-zinc-200 border-zinc-800"
                }`}
              >
                {s === "pendiente" ? "Pend." : s === "pagado" ? "Pag." : "Rech."}
              </button>
            )
          })}
        </div>

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : `Actualizar (${estadoLabel})`}
        </button>

        {/* Mensajes */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {notice ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {notice}
          </div>
        ) : null}

        {/* Listado */}
        <div className="mt-6">
          <h2 className="text-base font-semibold">{estadoLabel}</h2>

          {loading ? (
            <p className="mt-2 text-sm text-zinc-400">Cargando...</p>
          ) : items.length === 0 ? (
            <p className="mt-2 text-sm text-zinc-400">No hay retiros en este estado.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {items.map((it) => (
                <div key={it.id} className="rounded-2xl bg-zinc-900/50 border border-zinc-800 p-3">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-sm font-semibold">{formatMoney(it.monto)} Bs</div>
                      <div className="mt-1 text-xs text-zinc-400">
                        {it.metodo} · Tel: {it.telefono_destino}
                      </div>
                      {it.comentario ? <div className="mt-2 text-xs text-zinc-500">{it.comentario}</div> : null}
                      <div className="mt-1 text-[11px] text-zinc-500">Creado: {formatDT(it.created_at)}</div>
                      <div className="mt-1 text-[11px] text-zinc-500">Usuario: {it.user_id}</div>
                    </div>

                    <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${statusPillClass(it.estado)}`}>
                      {it.estado}
                    </span>
                  </div>

                  {/* Acciones (solo si está pendiente) */}
                  {String(it.estado).toLowerCase() === "pendiente" ? (
                    <div className="mt-3 grid grid-cols-2 gap-2">
                      <button
                        onClick={() => void procesar(it.id, "pagado")}
                        disabled={actingId === it.id}
                        className="rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
                      >
                        {actingId === it.id ? "Procesando..." : "Marcar pagado"}
                      </button>
                      <button
                        onClick={() => void procesar(it.id, "rechazado")}
                        disabled={actingId === it.id}
                        className="rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm font-semibold disabled:opacity-60"
                      >
                        {actingId === it.id ? "Procesando..." : "Rechazar"}
                      </button>
                    </div>
                  ) : null}

                  {it.processed_at ? (
                    <div className="mt-2 text-[11px] text-zinc-500">
                      Procesado: {formatDT(it.processed_at)} · Por: {it.processed_by ?? "—"}
                    </div>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="mt-6 text-xs text-zinc-500">
          Nota: aquí todo se procesa con la RPC <span className="text-zinc-300">procesar_retiro</span>.
        </div>
      </div>
    </main>
  )
}
