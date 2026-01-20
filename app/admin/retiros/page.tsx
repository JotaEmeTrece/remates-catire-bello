// APP/ADMIN/RETIROS/PAGE.TSX
"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

/**
 * Tipos base (segun tu schema real)
 */
type ProfileMini = {
  username: string | null
  telefono: string | null
}

type ProcessedByMini = {
  username: string | null
}

type WithdrawRow = {
  id: string
  user_id: string
  monto: string | number
  metodo: string
  telefono_destino: string
  comentario: string | null
  estado: "pendiente" | "pagado" | "rechazado" | string
  created_at: string | null
  processed_at: string | null
  processed_by: string | null

  usuario: ProfileMini | null
  procesado_por: ProcessedByMini | null
}

/**
 * Supabase / PostgREST a veces devuelve los embeds como arrays.
 * Este tipo representa ese "raw" para poder normalizar bien.
 */
type WithdrawRowRaw = Omit<WithdrawRow, "usuario" | "procesado_por"> & {
  usuario: ProfileMini[] | ProfileMini | null
  procesado_por: ProcessedByMini[] | ProcessedByMini | null
}

function n(v: string | number) {
  const x = typeof v === "string" ? Number(v) : v
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDateTime(iso: string | null) {
  if (!iso) return "-"
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleString("es-VE")
}

function pillClass(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e === "pendiente") return "bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/25"
  if (e === "pagado") return "bg-emerald-500/15 text-emerald-200 ring-1 ring-emerald-500/25"
  if (e === "rechazado") return "bg-red-500/15 text-red-200 ring-1 ring-red-500/25"
  return "bg-zinc-500/15 text-zinc-200 ring-1 ring-zinc-500/25"
}

export default function AdminRetirosPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")

  const [tab, setTab] = useState<"pendientes" | "todos">("pendientes")
  const [q, setQ] = useState("")
  const [actingId, setActingId] = useState<string | null>(null)

  const [rows, setRows] = useState<WithdrawRow[]>([])
  const [isAdmin, setIsAdmin] = useState<boolean>(false)

  async function load(isRefresh = false) {
    try {
      if (isRefresh) setRefreshing(true)
      else setLoading(true)

      setError("")
      setOk("")

      const { data: auth, error: authErr } = await supabase.auth.getUser()
      if (authErr) throw new Error(authErr.message)

      if (!auth?.user) {
        router.replace("/admin/login")
        return
      }

      const { data: prof, error: pErr } = await supabase
        .from("profiles")
        .select("es_admin,es_super_admin")
        .eq("id", auth.user.id)
        .maybeSingle()

      if (pErr) throw new Error(pErr.message)

      const admin = !!(prof?.es_admin || prof?.es_super_admin)
      setIsAdmin(admin)

      if (!admin) {
        router.replace("/dashboard")
        return
      }

      let query = supabase
        .from("withdraw_requests")
        .select(
          `
          id,
          user_id,
          monto,
          metodo,
          telefono_destino,
          comentario,
          estado,
          created_at,
          processed_at,
          processed_by,
          usuario:profiles!withdraw_requests_user_id_fkey(username,telefono),
          procesado_por:profiles!withdraw_requests_processed_by_fkey(username)
        `
        )
        .order("created_at", { ascending: false })
        .limit(200)

      if (tab === "pendientes") {
        query = query.eq("estado", "pendiente")
      }

      const { data, error: listErr } = await query
      if (listErr) throw new Error(listErr.message)

      const raw = (data ?? []) as WithdrawRowRaw[]
      const normalized: WithdrawRow[] = raw.map((r) => ({
        ...r,
        usuario: Array.isArray(r.usuario) ? (r.usuario[0] ?? null) : (r.usuario ?? null),
        procesado_por: Array.isArray(r.procesado_por) ? (r.procesado_por[0] ?? null) : (r.procesado_por ?? null),
      }))

      setRows(normalized)
    } catch (e: any) {
      setError(e?.message || "Error cargando retiros.")
      setRows([])
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab])

  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase()
    if (!s) return rows

    return rows.filter((r) => {
      const a = String(r.telefono_destino || "").toLowerCase()
      const b = String(r.comentario || "").toLowerCase()
      const c = String(r.usuario?.username || "").toLowerCase()
      const d = String(r.usuario?.telefono || "").toLowerCase()
      const e = String(r.metodo || "").toLowerCase()
      return a.includes(s) || b.includes(s) || c.includes(s) || d.includes(s) || e.includes(s)
    })
  }, [q, rows])

  async function procesar(id: string, nuevo: "pagado" | "rechazado") {
    setActingId(id)
    setError("")
    setOk("")

    const { error: rpcErr } = await supabase.rpc("procesar_retiro", {
      p_withdraw_id: id,
      p_nuevo_estado: nuevo,
    })

    if (rpcErr) {
      setActingId(null)
      setError(rpcErr.message || "Error procesando retiro.")
      return
    }

    setOk(nuevo === "pagado" ? "Retiro marcado como pagado." : "Retiro rechazado.")
    await load(true)
    setActingId(null)
  }

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center text-zinc-50">
        Cargando retiros...
      </div>
    )
  }

  if (!isAdmin) {
    return (
      <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
        <div className="mx-auto w-full max-w-3xl">
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <p className="text-sm text-zinc-200">No autorizado.</p>
            <Link href="/dashboard" className="mt-2 inline-block text-xs text-zinc-300 underline underline-offset-4">
              Volver al panel
            </Link>
          </div>
        </div>
      </main>
    )
  }

  const title = tab === "pendientes" ? "Solicitudes pendientes" : "Ultimas solicitudes"

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-8">
      <div className="mx-auto w-full max-w-4xl">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold">Retiros</h1>
            <p className="mt-1 text-sm text-zinc-300">
              Marca retiros como <b>pagados</b> o <b>rechazados</b>. Esto debe reflejarse en wallet y movimientos.
            </p>
          </div>

          <Link href="/admin" className="text-sm text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <div className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
          <div className="grid gap-2 md:grid-cols-[1fr_1fr_auto]">
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
              placeholder="Buscar: telefono, usuario, comentario..."
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

        <div className="mt-8 flex items-end justify-between">
          <h2 className="text-lg font-semibold">{title}</h2>
          <div className="text-sm text-zinc-400">{filtered.length} resultado(s)</div>
        </div>

        {filtered.length === 0 ? (
          <div className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-300">
            No hay retiros para mostrar.
          </div>
        ) : (
          <div className="mt-3 space-y-3">
            {filtered.map((r) => {
              const disabled = actingId === r.id || r.estado !== "pendiente"
              const username = r.usuario?.username ?? "-"
              const telPerfil = r.usuario?.telefono ?? "-"

              return (
                <div key={r.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <div className="text-base font-semibold">Bs {formatMoney(r.monto)}</div>
                      <div className="mt-1 text-sm text-zinc-300">
                        Usuario: <b className="text-zinc-100">{username}</b> - Tel: {telPerfil}
                      </div>
                      <div className="mt-1 text-sm text-zinc-300">
                        Destino: {r.telefono_destino} - Metodo: {r.metodo}
                      </div>
                      {r.comentario ? (
                        <div className="mt-2 text-sm text-zinc-400">
                          Comentario: <span className="text-zinc-300">{r.comentario}</span>
                        </div>
                      ) : null}

                      <div className="mt-2 text-xs text-zinc-500">
                        Creado: {formatDateTime(r.created_at)}
                        {r.processed_at ? ` - Procesado: ${formatDateTime(r.processed_at)}` : ""}
                        {r.procesado_por?.username ? ` - Por: ${r.procesado_por.username}` : ""}
                      </div>
                    </div>

                    <div className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${pillClass(r.estado)}`}>
                      {r.estado}
                    </div>
                  </div>

                  <div className="mt-4 grid grid-cols-2 gap-2">
                    <button
                      disabled={disabled}
                      onClick={() => void procesar(r.id, "pagado")}
                      className={`rounded-xl py-2 text-sm font-semibold ${
                        disabled ? "bg-white/40 text-zinc-900/60" : "bg-white text-zinc-950"
                      }`}
                    >
                      {actingId === r.id ? "Procesando..." : "Marcar pagado"}
                    </button>

                    <button
                      disabled={disabled}
                      onClick={() => void procesar(r.id, "rechazado")}
                      className={`rounded-xl py-2 text-sm font-semibold border ${
                        disabled ? "bg-zinc-950/20 border-zinc-800 text-zinc-500" : "bg-zinc-950/40 border-zinc-800"
                      }`}
                    >
                      {actingId === r.id ? "Procesando..." : "Rechazar"}
                    </button>
                  </div>

                  {r.estado !== "pendiente" ? (
                    <div className="mt-3 text-xs text-zinc-500">
                      Este retiro ya fue procesado. Para "deshacer", haria falta una accion admin especial.
                    </div>
                  ) : null}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </main>
  )
}
