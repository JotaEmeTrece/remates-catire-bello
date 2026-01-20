// APP/ADMIN/RECARGAS/PAGE.TSX
"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

/**
 * Joins mini
 * OJO: Supabase a veces retorna los joins como ARRAY aunque esperes 1:1
 * (depende del relationship/typing). Por eso normalizamos.
 */
type ProfileMini = {
  username: string | null
  telefono: string | null
}

type AdminMini = {
  username: string | null
}

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

  // Joins
  usuario: ProfileMini | null
  aprobado_por: AdminMini | null
}

/**
 * Tipo RAW para tolerar joins como array
 */
type DepositRowRaw = Omit<DepositRow, "usuario" | "aprobado_por"> & {
  usuario: ProfileMini | ProfileMini[] | null
  aprobado_por: AdminMini | AdminMini[] | null
}

function n(v: string | number) {
  const x = typeof v === "string" ? Number(v) : v
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(iso: string | null) {
  if (!iso) return "-"
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleString("es-VE")
}

function badgeClass(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e.includes("pend")) return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
  if (e.includes("apro") || e.includes("aprob")) return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e.includes("rech")) return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  return "bg-zinc-500/10 text-zinc-200 ring-1 ring-zinc-500/20"
}

export default function AdminRecargasPage() {
  const router = useRouter()

  // UI
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [actingId, setActingId] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")
  const [rejectingId, setRejectingId] = useState<string | null>(null)
  const [rejectReason, setRejectReason] = useState("")

  async function notifyByEmail(action: "approved" | "rejected", depositId: string, reason?: string) {
    const res = await fetch("/api/notify/recarga", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, depositId, reason }),
    })

    if (!res.ok) {
      const body = (await res.json().catch(() => null)) as any
      throw new Error(body?.error || `HTTP ${res.status}`)
    }
  }


  // Data
  const [items, setItems] = useState<DepositRow[]>([])

  // Filters
  const [tab, setTab] = useState<"pendientes" | "todos">("pendientes")
  const [q, setQ] = useState("")

  // ---- helper: gate admin ----
  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  // ---- load ----
  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setOk("")

    try {
      const aId = await ensureAdmin()
      if (!aId) return

      /**
       * Traemos:
       * - deposit_requests
       * - usuario (profiles del user_id)
       * - aprobado_por (profiles del approved_by)
       *
       * IMPORTANTE:
       * Los nombres de FK deben existir tal cual:
       *   deposit_requests_user_id_fkey
       *   deposit_requests_approved_by_fkey
       *
       * Si alguno difiere en tu DB, te lo ajusto rápido.
       */
      let query = supabase
        .from("deposit_requests")
        .select(
          `
          id,
          user_id,
          monto,
          metodo,
          telefono_pago,
          referencia,
          fecha_pago,
          estado,
          created_at,
          approved_at,
          approved_by,
          usuario:profiles!deposit_requests_user_id_fkey(username,telefono),
          aprobado_por:profiles!deposit_requests_approved_by_fkey(username)
        `
        )
        .order("created_at", { ascending: false })
        .limit(200)

      if (tab === "pendientes") {
        query = query.eq("estado", "pendiente")
      }

      const { data, error: listErr } = await query
      if (listErr) throw new Error(listErr.message)

      // Normalizar joins (array -> objeto)
      const normalized: DepositRow[] = ((data ?? []) as DepositRowRaw[]).map((r) => {
        const usuario = Array.isArray(r.usuario) ? (r.usuario[0] ?? null) : (r.usuario ?? null)
        const aprobado_por = Array.isArray(r.aprobado_por) ? (r.aprobado_por[0] ?? null) : (r.aprobado_por ?? null)

        return {
          ...r,
          usuario,
          aprobado_por,
        }
      })

      setItems(normalized)
    } catch (e: any) {
      setError(e?.message || "Error cargando recargas.")
      setItems([])
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab])

  // ---- filtered ----
  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase()
    if (!s) return items

    return items.filter((r) => {
      const u = (r.usuario?.username ?? "").toLowerCase()
      const telU = (r.usuario?.telefono ?? "").toLowerCase()

      return (
        r.id.toLowerCase().includes(s) ||
        String(r.referencia ?? "").toLowerCase().includes(s) ||
        String(r.telefono_pago ?? "").toLowerCase().includes(s) ||
        String(r.metodo ?? "").toLowerCase().includes(s) ||
        String(r.estado ?? "").toLowerCase().includes(s) ||
        u.includes(s) ||
        telU.includes(s)
      )
    })
  }, [items, q])

  // ---- actions ----
  async function aprobar(depositId: string) {
    setActingId(depositId)
    setError("")
    setOk("")

    // RPC: aprobar_recarga(p_deposit_request_id uuid)
    const { data, error: rpcErr } = await supabase.rpc("aprobar_recarga", {
      p_deposit_request_id: depositId,
    })

    if (rpcErr) {
      setActingId(null)
      setError(rpcErr.message || "Error aprobando recarga.")
      return
    }

    try {
      await notifyByEmail("approved", depositId)
      setOk(typeof data === "string" ? `${data} (Aviso enviado)` : "Recarga aprobada. (Aviso enviado)")
    } catch (e: any) {
      setOk(typeof data === "string" ? `${data} (Aviso NO enviado)` : "Recarga aprobada. (Aviso NO enviado)")
    }
    await load(true)
    setActingId(null)
  }

  function openRejectModal(depositId: string) {
    setError("")
    setOk("")
    setRejectReason("")
    setRejectingId(depositId)
  }

  function closeRejectModal() {
    setRejectingId(null)
    setRejectReason("")
  }

  async function confirmReject() {
    if (!rejectingId) return

    const reason = rejectReason.trim()
    if (!reason) {
      setError("Debes indicar un motivo para rechazar la recarga.")
      return
    }

    setActingId(rejectingId)

    const { data, error: rpcErr } = await supabase.rpc("rechazar_recarga", {
      p_deposit_request_id: rejectingId,
      p_reason: reason,
    })

    if (rpcErr) {
      setActingId(null)
      setError(rpcErr.message || "Error rechazando recarga.")
      return
    }

    try {
      await notifyByEmail("rejected", rejectingId, reason)
      setOk(typeof data === "string" ? `${data} (Aviso enviado)` : "Recarga rechazada. (Aviso enviado)")
    } catch (e: any) {
      setOk(typeof data === "string" ? `${data} (Aviso NO enviado)` : "Recarga rechazada. (Aviso NO enviado)")
    }
    await load(true)
    setActingId(null)
    closeRejectModal()
  }


  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-3xl">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold">Recargas</h1>
            <p className="mt-1 text-sm text-zinc-300">
              Aprueba o rechaza recargas. Aprobar llama <b>aprobar_recarga</b> y acredita la wallet.
            </p>
          </div>
          <Link href="/admin" className="text-sm text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {/* Controls */}
        <div className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
          <div className="grid gap-2 md:grid-cols-[260px_1fr_auto]">
            <div className="grid grid-cols-2 gap-2">
              <button
                onClick={() => setTab("pendientes")}
                className={`rounded-xl py-2 text-sm font-semibold border ${
                  tab === "pendientes"
                    ? "bg-white text-zinc-950 border-white"
                    : "bg-zinc-950/40 text-zinc-200 border-zinc-800"
                }`}
              >
                Pendientes
              </button>
              <button
                onClick={() => setTab("todos")}
                className={`rounded-xl py-2 text-sm font-semibold border ${
                  tab === "todos"
                    ? "bg-white text-zinc-950 border-white"
                    : "bg-zinc-950/40 text-zinc-200 border-zinc-800"
                }`}
              >
                Todos
              </button>
            </div>

            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Buscar: referencia, telefono, usuario..."
              className="w-full rounded-xl bg-zinc-950/40 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
            />

            <button
              onClick={() => void load(true)}
              disabled={refreshing}
              className="rounded-xl bg-zinc-950/40 border border-zinc-800 px-4 py-2 text-sm font-semibold disabled:opacity-60"
            >
              {refreshing ? "Actualizando..." : "Actualizar"}
            </button>
          </div>
        </div>

        {/* Alerts */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
          </div>
        ) : null}

        {/* List header */}
        <div className="mt-8 flex items-end justify-between">
          <h2 className="text-lg font-semibold">
            {tab === "pendientes" ? "Solicitudes pendientes" : "Ultimas solicitudes"}
          </h2>
          <div className="text-sm text-zinc-400">{filtered.length} resultado(s)</div>
        </div>

        {/* List */}
        {loading ? (
          <div className="mt-3 text-sm text-zinc-400">Cargando...</div>
        ) : filtered.length === 0 ? (
          <div className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-300">
            No hay recargas para mostrar.
          </div>
        ) : (
          <div className="mt-3 space-y-3">
            {filtered.map((r) => {
              const estado = String(r.estado || "").toLowerCase()
              const isPend = estado === "pendiente"
              const disabled = actingId === r.id || !isPend

              const username = r.usuario?.username ?? "-"
              const telUser = r.usuario?.telefono ?? "-"
              const aprobadoPor = r.aprobado_por?.username ?? "-"

              return (
                <div key={r.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <div className="text-base font-semibold">Bs {formatMoney(r.monto)}</div>

                      <div className="mt-1 text-sm text-zinc-300">
                        Usuario: <b className="text-zinc-100">{username}</b> - Tel: {telUser}
                      </div>

                      <div className="mt-1 text-sm text-zinc-300">
                        Pago desde: {r.telefono_pago} - Metodo: {r.metodo}
                      </div>

                      <div className="mt-1 text-sm text-zinc-300">
                        Ref: <b className="text-zinc-100">{r.referencia}</b> - Fecha pago: {r.fecha_pago}
                      </div>

                      <div className="mt-2 text-xs text-zinc-500">
                        Creado: {formatDT(r.created_at)}
                        {r.approved_at ? ` - Procesado: ${formatDT(r.approved_at)}` : ""}
                        {r.approved_at ? ` - Por: ${aprobadoPor}` : ""}
                      </div>
                    </div>

                    <div className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(r.estado)}`}>
                      {r.estado}
                    </div>
                  </div>

                  <div className="mt-4 grid grid-cols-2 gap-2">
                    <button
                      disabled={disabled}
                      onClick={() => void aprobar(r.id)}
                      className={`rounded-xl py-2 text-sm font-semibold ${
                        disabled ? "bg-white/40 text-zinc-900/60" : "bg-white text-zinc-950"
                      }`}
                    >
                      {actingId === r.id ? "Procesando..." : "Aprobar"}
                    </button>

                    <button
                      disabled={disabled}
                      onClick={() => openRejectModal(r.id)}
                      className={`rounded-xl py-2 text-sm font-semibold border ${
                        disabled ? "bg-zinc-950/20 border-zinc-800 text-zinc-500" : "bg-zinc-950/40 border-zinc-800"
                      }`}
                    >
                      {actingId === r.id ? "Procesando..." : "Rechazar"}
                    </button>
                  </div>

                  {!isPend ? (
                    <div className="mt-3 text-xs text-zinc-500">
                      Esta recarga ya fue procesada. Para "deshacer", habría que crear una acción admin especial (auditable).
                    </div>
                  ) : null}
                </div>
              )
            })}
          </div>
        )}
      </div>
      {rejectingId ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4">
          <div className="w-full max-w-md rounded-2xl bg-zinc-900/90 border border-zinc-800 p-4">
            <div className="text-lg font-semibold">Rechazar recarga</div>
            <p className="mt-1 text-sm text-zinc-300">Indica el motivo (obligatorio).</p>

            <textarea
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              rows={4}
              className="mt-3 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: pago no coincide"
            />

            <div className="mt-4 flex items-center justify-end gap-2">
              <button
                onClick={closeRejectModal}
                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-4 py-2 text-sm"
              >
                Cancelar
              </button>
              <button
                onClick={confirmReject}
                disabled={!rejectReason.trim() || actingId === rejectingId}
                className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-zinc-950 disabled:opacity-60"
              >
                Rechazar
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </main>
  )
}




