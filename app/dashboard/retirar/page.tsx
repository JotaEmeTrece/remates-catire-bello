// DASHBOARD/RETIRAR/PAGE.TSX

"use client"

import { useEffect, useState, type FormEvent } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type WalletRow = {
  saldo_disponible: string | number
  saldo_bloqueado: string | number
}

type WithdrawRow = {
  id: string
  monto: string | number
  metodo: string
  telefono_destino: string
  comentario: string | null
  estado: string
  created_at: string | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function parseAmount(input: string) {
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
  if (e.includes("pag")) return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e.includes("rech")) return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
}

export default function RetirarPage() {
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
  const [wallet, setWallet] = useState<WalletRow | null>(null)
  const [items, setItems] = useState<WithdrawRow[]>([])

  /**
   * =========================
   * Form
   * =========================
   */
  const [monto, setMonto] = useState("")
  const [metodo, setMetodo] = useState("pago_movil")
  const [telefonoDestino, setTelefonoDestino] = useState("")
  const [comentario, setComentario] = useState("")

  /**
   * =========================
   * Load (wallet + listado)
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

    // 2) wallet
    const { data: w, error: wErr } = await supabase
      .from("wallets")
      .select("saldo_disponible,saldo_bloqueado")
      .eq("user_id", auth.user.id)
      .maybeSingle()

    if (wErr) setError(wErr.message)
    setWallet((w ?? null) as WalletRow | null)

    // 3) listado
    const { data: list, error: listErr } = await supabase
      .from("withdraw_requests")
      .select("id,monto,metodo,telefono_destino,comentario,estado,created_at")
      .eq("user_id", auth.user.id)
      .order("created_at", { ascending: false })
      .limit(10)

    if (listErr) setError(listErr.message)
    setItems((list ?? []) as WithdrawRow[])

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
    if (!telefonoDestino.trim()) return setError("Teléfono destino requerido.")
    if (!userId) return setError("Sesión no válida. Vuelve a iniciar.")

    const disponible = wallet ? n(wallet.saldo_disponible) : 0
    if (amount > disponible) {
      return setError(`No tienes saldo suficiente. Disponible: ${formatMoney(disponible)} Bs.`)
    }

    setSaving(true)
    const { error: insErr } = await supabase.from("withdraw_requests").insert({
      user_id: userId,
      monto: amount,
      metodo,
      telefono_destino: telefonoDestino.trim(),
      comentario: comentario.trim() ? comentario.trim() : null,
      // estado default: 'pendiente'
    })
    setSaving(false)

    if (insErr) return setError(insErr.message)

    setOk("✅ Solicitud enviada. Queda en estado pendiente.")
    setMonto("")
    setTelefonoDestino("")
    setComentario("")
    await load(true)
  }

  const disponible = wallet ? n(wallet.saldo_disponible) : 0
  const bloqueado = wallet ? n(wallet.saldo_bloqueado) : 0

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Retirar saldo</h1>
          <div className="flex items-center gap-3">
            <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
              Remates
            </Link>
            <Link href="/dashboard" className="text-xs text-zinc-300 underline underline-offset-4">
              Volver
            </Link>
          </div>
        </div>

        {/* Wallet resumen */}
        <div className="mt-4 grid grid-cols-2 gap-2">
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
            <div className="text-xs text-zinc-500">Disponible</div>
            <div className="mt-1 text-lg font-semibold text-emerald-300">{formatMoney(disponible)} Bs</div>
          </div>
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
            <div className="text-xs text-zinc-500">Bloqueado</div>
            <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(bloqueado)} Bs</div>
          </div>
        </div>

        {/* Form */}
        <form onSubmit={onSubmit} className="mt-5 space-y-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div>
            <label className="text-sm text-zinc-200">Monto a retirar (Bs)</label>
            <input
              inputMode="decimal"
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 100 o 100,50"
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
          </div>

          <div>
            <label className="text-sm text-zinc-200">Teléfono destino</label>
            <input
              value={telefonoDestino}
              onChange={(e) => setTelefonoDestino(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 0414xxxxxxx"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Comentario (opcional)</label>
            <textarea
              value={comentario}
              onChange={(e) => setComentario(e.target.value)}
              className="mt-1 w-full resize-none rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-white/10"
              rows={3}
              placeholder="Ej: Banco / nombre / notas..."
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
            <h2 className="text-base font-semibold">Tus últimos retiros</h2>
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
                        Tel: {it.telefono_destino} · {it.metodo}
                      </div>
                      <div className="mt-1 text-[11px] text-zinc-500">{formatDT(it.created_at)}</div>
                      {it.comentario ? <div className="mt-2 text-xs text-zinc-500">{it.comentario}</div> : null}
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
