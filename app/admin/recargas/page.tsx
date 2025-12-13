// ADMIN/RECARGAS/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type DepositRow = {
  id: string
  user_id: string
  monto: string | number
  metodo: string
  telefono_pago: string
  referencia: string
  fecha_pago: string
  estado: string
  created_at: string | null
  approved_at: string | null
  approved_by: string | null
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
  if (e.includes("aprob")) return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e.includes("rech")) return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
}

export default function AdminRecargasPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [actingId, setActingId] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")

  const [adminId, setAdminId] = useState<string | null>(null)
  const [estado, setEstado] = useState<"pendiente" | "aprobado" | "rechazado">("pendiente")

  const [items, setItems] = useState<DepositRow[]>([])

  const estadoLabel = useMemo(() => {
    if (estado === "pendiente") return "Pendientes"
    if (estado === "aprobado") return "Aprobadas"
    return "Rechazadas"
  }, [estado])

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

    setAdminId(auth.user.id)
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
        .from("deposit_requests")
        .select("id,user_id,monto,metodo,telefono_pago,referencia,fecha_pago,estado,created_at,approved_at,approved_by")
        .eq("estado", estado)
        .order("created_at", { ascending: false })
        .limit(50)

      if (qErr) throw new Error(qErr.message)
      setItems((data ?? []) as DepositRow[])
    } catch (e: any) {
      setError(e?.message || "Error cargando recargas")
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

  async function aprobar(id: string) {
    setActingId(id)
    setError("")
    setNotice("")

    // ✅ Usa tu RPC real (debe: marcar aprobado y mover saldo / movimientos)
    const { data, error: rpcErr } = await supabase.rpc("aprobar_recarga", {
      p_deposit_request_id: id,
    })

    if (rpcErr) {
      setActingId(null)
      setError(rpcErr.message || "Error aprobando recarga")
      return
    }

    setNotice(typeof data === "string" ? data : "✅ Recarga aprobada.")
    await load(true)
    setActingId(null)
  }

  async function rechazar(id: string) {
    // No vimos RPC para rechazar recarga, así que: update directo (solo cambia estado)
    if (!adminId) {
      setError("Admin no válido.")
      return
    }

    setActingId(id)
    setError("")
    setNotice("")

    const { error: upErr } = await supabase
      .from("deposit_requests")
      .update({
        estado: "rechazado",
        approved_at: new Date().toISOString(),
        approved_by: adminId,
      })
      .eq("id", id)

    if (upErr) {
      setActingId(null)
      setError(upErr.message || "Error rechazando recarga")
      return
    }

    setNotice("✅ Recarga rechazada.")
    await load(true)
    setActingId(null)
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Admin · Recargas</h1>
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
          {(["pendiente", "aprobado", "rechazado"] as const).map((s) => {
            const active = estado === s
            return (
              <button
                key={s}
                onClick={() => setEstado(s)}
                className={`rounded-xl px-3 py-2 text-sm border ${
                  active ? "bg-white text-zinc-950 border-white" : "bg-zinc-900/60 text-zinc-200 border-zinc-800"
                }`}
              >
                {s === "pendiente" ? "Pend." : s === "aprobado" ? "Aprob." : "Rech."}
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
            <p className="mt-2 text-sm text-zinc-400">No hay recargas en este estado.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {items.map((it) => (
                <div key={it.id} className="rounded-2xl bg-zinc-900/50 border border-zinc-800 p-3">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-sm font-semibold">{formatMoney(it.monto)} Bs</div>
                      <div className="mt-1 text-xs text-zinc-400">
                        {it.metodo} · Tel: {it.telefono_pago}
                      </div>
                      <div className="mt-1 text-xs text-zinc-400">
                        Ref: {it.referencia} · Pago: {it.fecha_pago}
                      </div>
                      <div className="mt-1 text-[11px] text-zinc-500">
                        Creado: {formatDT(it.created_at)}
                      </div>
                      <div className="mt-1 text-[11px] text-zinc-500">
                        Usuario: {it.user_id}
                      </div>
                    </div>

                    <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${statusPillClass(it.estado)}`}>
                      {it.estado}
                    </span>
                  </div>

                  {/* Acciones (solo si está pendiente) */}
                  {String(it.estado).toLowerCase() === "pendiente" ? (
                    <div className="mt-3 grid grid-cols-2 gap-2">
                      <button
                        onClick={() => void aprobar(it.id)}
                        disabled={actingId === it.id}
                        className="rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
                      >
                        {actingId === it.id ? "Procesando..." : "Aprobar"}
                      </button>
                      <button
                        onClick={() => void rechazar(it.id)}
                        disabled={actingId === it.id}
                        className="rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm font-semibold disabled:opacity-60"
                      >
                        {actingId === it.id ? "Procesando..." : "Rechazar"}
                      </button>
                    </div>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="mt-6 text-xs text-zinc-500">
          Nota: “Aprobar” usa la RPC <span className="text-zinc-300">aprobar_recarga</span>. “Rechazar” es update directo
          (porque no vimos RPC para eso).
        </div>
      </div>
    </main>
  )
}
