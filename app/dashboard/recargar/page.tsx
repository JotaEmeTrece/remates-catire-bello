// DASHBOARD/RECARGAR/PAGE.TSX

"use client"

import { useEffect, useMemo, useState, type FormEvent } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type DepositRow = {
  id: string
  monto: string | number
  metodo: string
  telefono_pago: string
  referencia: string
  fecha_pago: string
  estado: string
  created_at: string | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function parseAmount(input: string) {
  // Acepta "100,50" o "100.50"
  const cleaned = input.trim().replace(/\./g, "").replace(",", ".")
  const val = Number(cleaned)
  return Number.isFinite(val) ? val : NaN
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

export default function RecargarPage() {
  const router = useRouter()

  /**
   * =========================
   * State UI
   * =========================
   */
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>("")
  const [ok, setOk] = useState<string>("")

  /**
   * =========================
   * Data
   * =========================
   */
  const [userId, setUserId] = useState<string | null>(null)
  const [items, setItems] = useState<DepositRow[]>([])

  /**
   * =========================
   * Form
   * =========================
   */
  const [monto, setMonto] = useState("")
  const [metodo, setMetodo] = useState("pago_movil")
  const [telefonoPago, setTelefonoPago] = useState("")
  const [referencia, setReferencia] = useState("")
  const [fechaPago, setFechaPago] = useState(() => {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, "0")
    const dd = String(d.getDate()).padStart(2, "0")
    return `${yyyy}-${mm}-${dd}`
  })

  const metodoLabel = useMemo(() => {
    if (metodo === "pago_movil") return "Pago Móvil"
    if (metodo === "otro") return "Otro"
    return metodo
  }, [metodo])

  /**
   * =========================
   * Load (auth + listado)
   * =========================
   */
  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setOk("")

    // 1) sesión
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) {
      setError(authErr.message)
      setLoading(false)
      setRefreshing(false)
      return
    }
    if (!auth?.user) {
      router.replace("/login")
      return
    }
    setUserId(auth.user.id)

    // 2) listado
    const { data, error: listErr } = await supabase
      .from("deposit_requests")
      .select("id,monto,metodo,telefono_pago,referencia,fecha_pago,estado,created_at")
      .eq("user_id", auth.user.id)
      .order("created_at", { ascending: false })
      .limit(10)

    if (listErr) setError(listErr.message)
    setItems((data ?? []) as DepositRow[])

    setLoading(false)
    setRefreshing(false)
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  /**
   * =========================
   * Submit (crear solicitud)
   * =========================
   */
  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError("")
    setOk("")

    const amount = parseAmount(monto)
    if (!Number.isFinite(amount) || amount <= 0) return setError("Monto inválido.")
    if (!telefonoPago.trim()) return setError("Teléfono desde donde pagaste requerido.")
    if (!referencia.trim()) return setError("Referencia requerida.")
    if (!fechaPago) return setError("Fecha de pago requerida.")
    if (!userId) return setError("Sesión no válida. Vuelve a iniciar.")

    setSaving(true)
    const { error: insErr } = await supabase.from("deposit_requests").insert({
      user_id: userId,
      monto: amount,
      metodo,
      telefono_pago: telefonoPago.trim(),
      referencia: referencia.trim(),
      fecha_pago: fechaPago,
      // estado default: 'pendiente'
    })
    setSaving(false)

    if (insErr) return setError(insErr.message)

    setOk("✅ Solicitud enviada. Queda en estado pendiente.")
    setMonto("")
    setTelefonoPago("")
    setReferencia("")
    // fechaPago se mantiene
    await load(true)
  }

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Recargar saldo</h1>
          <div className="flex items-center gap-3">
            <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
              Remates
            </Link>
            <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
              Volver
            </Link>
          </div>
        </div>

        <p className="mt-2 text-sm text-zinc-300">
          Registra tu pago y el admin lo aprueba manualmente.
        </p>

        {/* Form */}
        <form onSubmit={onSubmit} className="mt-5 space-y-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div>
            <label className="text-sm text-zinc-200">Monto (Bs)</label>
            <input
              inputMode="decimal"
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 200 o 200,50"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Método</label>
            <select
              value={metodo}
              onChange={(e) => setMetodo(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
            >
              <option value="pago_movil">Pago Móvil</option>
              <option value="otro">Otro</option>
            </select>
            <p className="mt-1 text-xs text-zinc-400">Actual: {metodoLabel}</p>
          </div>

          <div>
            <label className="text-sm text-zinc-200">Teléfono desde donde pagaste</label>
            <input
              value={telefonoPago}
              onChange={(e) => setTelefonoPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 0412xxxxxxx"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Referencia</label>
            <input
              value={referencia}
              onChange={(e) => setReferencia(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 123456"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Fecha del pago</label>
            <input
              type="date"
              value={fechaPago}
              onChange={(e) => setFechaPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
            />
          </div>

          {error ? (
            <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
          ) : null}
          {ok ? (
            <div className="rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
              {ok}
            </div>
          ) : null}

          <button
            type="submit"
            disabled={saving}
            className="w-full rounded-xl bg-white px-4 py-2 text-base font-semibold text-zinc-950 disabled:opacity-60"
          >
            {saving ? "Enviando..." : "Enviar solicitud"}
          </button>
        </form>

        {/* Listado + Refresh */}
        <div className="mt-6">
          <div className="flex items-center justify-between">
            <h2 className="text-base font-semibold">Tus últimas solicitudes</h2>
            <button
              onClick={() => void load(true)}
              disabled={refreshing}
              className="text-xs text-zinc-300 underline underline-offset-4 disabled:opacity-60"
            >
              {refreshing ? "Actualizando..." : "Actualizar"}
            </button>
          </div>

          {loading ? (
            <p className="mt-2 text-sm text-zinc-400">Cargando...</p>
          ) : items.length === 0 ? (
            <p className="mt-2 text-sm text-zinc-400">Aún no tienes solicitudes.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {items.map((it) => (
                <div key={it.id} className="rounded-2xl bg-zinc-900/50 border border-zinc-800 p-3">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-sm font-semibold">{formatMoney(it.monto)} Bs</div>
                      <div className="mt-1 text-xs text-zinc-400">
                        {it.metodo} · Ref: {it.referencia}
                      </div>
                      <div className="mt-1 text-[11px] text-zinc-500">
                        Pago: {it.fecha_pago} · {formatDT(it.created_at)}
                      </div>
                    </div>

                    <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${statusPillClass(it.estado)}`}>
                      {it.estado}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </main>
  )
}
