// DASHBOARD/PAGE.TSX

"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type WalletRow = {
  id: string
  saldo_disponible: string | number
  saldo_bloqueado: string | number
}

type WalletMovementRow = {
  id: string
  wallet_id: string
  tipo: string
  monto: string | number
  descripcion: string | null
  ref_externa: string | null
  created_at: string | null
}

type DepositRequestRow = {
  id: string
  monto: string | number
  metodo: string
  telefono_pago: string
  referencia: string
  fecha_pago: string
  estado: string
  created_at: string | null
}

type WithdrawRequestRow = {
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

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null | undefined) {
  if (!v) return "—"
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString("es-VE")
}

function movementLabel(tipo: string) {
  const t = String(tipo || "").toLowerCase()
  if (t === "recarga") return "Recarga"
  if (t === "apuesta_bloqueo") return "Bloqueo por remate"
  if (t === "apuesta_liberacion") return "Liberación"
  if (t === "premio") return "Premio"
  if (t === "ajuste_manual") return "Ajuste"
  if (t === "retiro") return "Retiro"
  return tipo
}

function tipoPillClass(tipo: string) {
  const t = String(tipo || "").toLowerCase()
  if (t === "recarga" || t === "premio") return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (t === "retiro") return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  if (t.includes("bloqueo")) return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
  if (t.includes("liber")) return "bg-sky-500/10 text-sky-200 ring-1 ring-sky-500/20"
  return "bg-zinc-500/10 text-zinc-200 ring-1 ring-zinc-500/20"
}

function statusPill(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e.includes("aprob") || e.includes("pag")) return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e.includes("rech")) return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
}

export default function DashboardPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")

  const [wallet, setWallet] = useState<WalletRow | null>(null)
  const [history, setHistory] = useState<WalletMovementRow[]>([])

  const [lastDeposits, setLastDeposits] = useState<DepositRequestRow[]>([])
  const [lastWithdraws, setLastWithdraws] = useState<WithdrawRequestRow[]>([])

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")

    // 1) Auth
    const {
      data: { user },
      error: authErr,
    } = await supabase.auth.getUser()

    if (authErr) {
      setError(authErr.message)
      setLoading(false)
      setRefreshing(false)
      return
    }

    if (!user) {
      router.replace("/login")
      return
    }

    // 2) Wallet
    const { data: w, error: wErr } = await supabase
      .from("wallets")
      .select("id,saldo_disponible,saldo_bloqueado")
      .eq("user_id", user.id)
      .maybeSingle()

    if (wErr) {
      setError(wErr.message)
      setWallet(null)
      setHistory([])
      setLastDeposits([])
      setLastWithdraws([])
      setLoading(false)
      setRefreshing(false)
      return
    }

    const walletRow = (w ?? null) as WalletRow | null
    setWallet(walletRow)

    // 3) Historial (IMPORTANTÍSIMO)
    // wallet_movements NO tiene user_id, tiene wallet_id
    if (walletRow?.id) {
      const { data: mv, error: mvErr } = await supabase
        .from("wallet_movements")
        .select("id,wallet_id,tipo,monto,descripcion,ref_externa,created_at")
        .eq("wallet_id", walletRow.id)
        .order("created_at", { ascending: false })
        .limit(25)

      if (mvErr) {
        console.error("Error cargando historial:", mvErr.message)
        setHistory([])
      } else {
        setHistory((mv ?? []) as WalletMovementRow[])
      }
    } else {
      setHistory([])
    }

    // 4) Últimas solicitudes de recarga (para que el usuario vea estado)
    const { data: dr, error: drErr } = await supabase
      .from("deposit_requests")
      .select("id,monto,metodo,telefono_pago,referencia,fecha_pago,estado,created_at")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(5)

    if (drErr) console.error("deposit_requests err:", drErr.message)
    setLastDeposits((dr ?? []) as DepositRequestRow[])

    // 5) Últimas solicitudes de retiro
    const { data: wr, error: wrErr } = await supabase
      .from("withdraw_requests")
      .select("id,monto,metodo,telefono_destino,comentario,estado,created_at")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(5)

    if (wrErr) console.error("withdraw_requests err:", wrErr.message)
    setLastWithdraws((wr ?? []) as WithdrawRequestRow[])

    setLoading(false)
    setRefreshing(false)
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function logout() {
    await supabase.auth.signOut()
    router.replace("/login")
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando dashboard...</div>
  }

  const disponible = wallet ? n(wallet.saldo_disponible) : 0
  const bloqueado = wallet ? n(wallet.saldo_bloqueado) : 0

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Mi Panel</h1>
          <button onClick={logout} className="text-xs text-zinc-300 underline underline-offset-4">
            Cerrar sesión
          </button>
        </div>

        {/* Error */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {/* Saldos */}
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

        {/* Acciones rápidas */}
        <div className="mt-3 grid grid-cols-3 gap-2">
          <Link
            href="/remates"
            className="rounded-xl bg-white text-zinc-950 font-semibold py-2 text-sm text-center"
          >
            Remates
          </Link>

          <Link
            href="/dashboard/recargar"
            className="rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-center text-zinc-200"
          >
            Recargar
          </Link>

          <Link
            href="/dashboard/retirar"
            className="rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-center text-zinc-200"
          >
            Retirar
          </Link>
        </div>

        {/* Refresh */}
        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>

        {/* Últimas solicitudes */}
        <div className="mt-6 space-y-3">
          {/* Recargas */}
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-semibold">Recargas recientes</h2>
              <Link href="/dashboard/recargar" className="text-xs text-zinc-300 underline underline-offset-4">
                Ver
              </Link>
            </div>

            {lastDeposits.length === 0 ? (
              <div className="mt-2 text-sm text-zinc-400">No tienes recargas recientes.</div>
            ) : (
              <div className="mt-3 space-y-2">
                {lastDeposits.map((d) => (
                  <div key={d.id} className="rounded-xl bg-zinc-950/50 border border-zinc-800 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold">{formatMoney(d.monto)} Bs</div>
                        <div className="mt-1 text-xs text-zinc-400">
                          {d.metodo} · {d.referencia}
                        </div>
                        <div className="mt-1 text-[11px] text-zinc-500">
                          Pago: {d.fecha_pago} · {formatDT(d.created_at)}
                        </div>
                      </div>
                      <span className={`rounded-full px-3 py-1 text-xs font-semibold ${statusPill(d.estado)}`}>
                        {d.estado}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Retiros */}
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-semibold">Retiros recientes</h2>
              <Link href="/dashboard/retirar" className="text-xs text-zinc-300 underline underline-offset-4">
                Ver
              </Link>
            </div>

            {lastWithdraws.length === 0 ? (
              <div className="mt-2 text-sm text-zinc-400">No tienes retiros recientes.</div>
            ) : (
              <div className="mt-3 space-y-2">
                {lastWithdraws.map((w) => (
                  <div key={w.id} className="rounded-xl bg-zinc-950/50 border border-zinc-800 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold">{formatMoney(w.monto)} Bs</div>
                        <div className="mt-1 text-xs text-zinc-400">
                          {w.metodo} · {w.telefono_destino}
                        </div>
                        <div className="mt-1 text-[11px] text-zinc-500">{formatDT(w.created_at)}</div>
                      </div>
                      <span className={`rounded-full px-3 py-1 text-xs font-semibold ${statusPill(w.estado)}`}>
                        {w.estado}
                      </span>
                    </div>
                    {w.comentario ? <div className="mt-2 text-xs text-zinc-500">{w.comentario}</div> : null}
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Historial wallet */}
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-sm font-semibold">Historial</h2>

            {history.length === 0 ? (
              <div className="mt-2 text-sm text-zinc-400">Aún no hay movimientos.</div>
            ) : (
              <div className="mt-3 space-y-2">
                {history.map((m) => (
                  <div key={m.id} className="rounded-xl bg-zinc-950/50 border border-zinc-800 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold">{formatMoney(m.monto)} Bs</div>
                        <div className="mt-1 text-xs text-zinc-400">
                          {m.descripcion ? m.descripcion : movementLabel(m.tipo)}
                        </div>
                        <div className="mt-1 text-[11px] text-zinc-500">{formatDT(m.created_at)}</div>
                      </div>

                      <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${tipoPillClass(m.tipo)}`}>
                        {movementLabel(m.tipo)}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </main>
  )
}

