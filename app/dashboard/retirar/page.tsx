// app/dashboard/retirar/page.tsx
"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { supabase } from "@/lib/supabaseClient"
import ClientBottomNav from "@/app/components/ClientBottomNav"
import { CornerLogo } from "@/app/components/BrandLogo"

/**
 * Tipos mínimos para mostrar el saldo.
 * OJO: aquí NO consultamos wallets directo para evitar problemas con RLS.
 * Leemos saldo vía RPC: mi_wallet_resumen().
 */
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

function n(v: string | number) {
  const x = typeof v === "string" ? Number(v) : v
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function RetirarPage() {
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>("")
  const [ok, setOk] = useState<string>("")
  const [userId, setUserId] = useState<string | null>(null)

  const [wallet, setWallet] = useState<WalletRow | null>(null)
  const [items, setItems] = useState<WithdrawRow[]>([])

  const [monto, setMonto] = useState("")
  const [metodo, setMetodo] = useState("pago_movil")
  const [telefonoDestino, setTelefonoDestino] = useState("")
  const [comentario, setComentario] = useState("")

  async function load() {
    setLoading(true)
    setError("")
    setOk("")
    setUserId(null)
    setWallet(null)
    setItems([])

    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr || !auth?.user) {
      setLoading(false)
      return
    }
    setUserId(auth.user.id)

    const { data: wData, error: wErr } = await supabase.rpc("mi_wallet_resumen")

    if (wErr) {
      setError(wErr.message)
      setWallet(null)
    } else {
      const first = Array.isArray(wData) ? wData[0] : null
      setWallet(first ? { saldo_disponible: first.saldo_disponible, saldo_bloqueado: first.saldo_bloqueado } : null)
    }

    const { data: list, error: listErr } = await supabase
      .from("withdraw_requests")
      .select("id,monto,metodo,telefono_destino,comentario,estado,created_at")
      .order("created_at", { ascending: false })
      .limit(10)

    if (listErr) setError(listErr.message)
    setItems((list ?? []) as WithdrawRow[])

    setLoading(false)
  }

  useEffect(() => {
    void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setOk("")

    const amount = Number(monto)
    if (!Number.isFinite(amount) || amount <= 0) return setError("Monto inválido.")
    if (!telefonoDestino.trim()) return setError("Teléfono destino requerido.")

    const disponible = wallet ? n(wallet.saldo_disponible) : 0
    if (amount > disponible) return setError("Saldo insuficiente para este retiro.")

    setSaving(true)

    const { error: rpcErr } = await supabase.rpc("solicitar_retiro", {
      p_monto: amount,
      p_metodo: metodo,
      p_telefono_destino: telefonoDestino.trim(),
      p_comentario: comentario.trim() ? comentario.trim() : null,
    })

    setSaving(false)

    if (rpcErr) return setError(rpcErr.message)

    setOk("Solicitud enviada. Queda en estado pendiente.")
    setMonto("")
    setTelefonoDestino("")
    setComentario("")
    await load()
  }

  if (loading) {
    return <div className="min-h-dvh bg-gray-950 text-gray-50 flex items-center justify-center">Cargando...</div>
  }

  if (!userId) {
    return (
      <div className="min-h-dvh bg-gray-950 text-gray-50">
        <div className="mx-auto w-full max-w-md px-4 py-6">
          <div className="mb-3">
            <CornerLogo />
          </div>
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold">Retirar saldo</h1>
            <Link href="/remates" className="text-sm text-gray-300 underline underline-offset-4">
              Ver remates
            </Link>
          </div>
          <div className="mt-4 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10 text-sm text-gray-200">
            Inicia sesión para retirar saldo.
          </div>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Link href="/remates" className="rounded-xl bg-white text-gray-950 font-semibold py-2 text-sm text-center">
              Ver remates
            </Link>
            <Link
              href="/login"
              className="rounded-xl bg-gray-900/60 border border-gray-800 py-2 text-sm text-center text-gray-200"
            >
              Iniciar sesión
            </Link>
          </div>
          <div className="mt-2 text-center">
            <Link href="/register" className="text-xs text-gray-300 underline underline-offset-4">
              Crear cuenta
            </Link>
          </div>
        </div>
      </div>
    )
  }

  const disponible = wallet ? n(wallet.saldo_disponible) : 0
  const bloqueado = wallet ? n(wallet.saldo_bloqueado) : 0

  return (
    <>
      <div className="min-h-dvh bg-gray-950 text-gray-50">
        <div className="mx-auto w-full max-w-md px-4 py-6 pb-24">
          <div className="mb-3">
            <CornerLogo />
          </div>
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold">Retirar saldo</h1>
            <Link href="/dashboard" className="text-sm text-gray-300 underline underline-offset-4">
              Volver
            </Link>
        </div>

        <p className="mt-2 text-sm text-gray-300">Solicita tu retiro y el admin lo procesa manualmente.</p>

        <div className="mt-4 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10">
          <div className="text-sm text-gray-400">Disponible: Bs {formatMoney(disponible)}</div>
          <div className="mt-2 text-xs text-gray-400">Bloqueado: Bs {formatMoney(bloqueado)}</div>
        </div>

        <form onSubmit={onSubmit} className="mt-5 space-y-3 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10">
          <div>
            <label className="text-sm text-gray-200">Monto (Bs)</label>
            <input
              inputMode="decimal"
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 200"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Método</label>
            <select
              value={metodo}
              onChange={(e) => setMetodo(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
            >
              <option value="pago_movil">Pago Móvil</option>
              <option value="otro">Otro</option>
            </select>
          </div>

          <div>
            <label className="text-sm text-gray-200">Teléfono destino</label>
            <input
              value={telefonoDestino}
              onChange={(e) => setTelefonoDestino(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 0412xxxxxxx"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Comentario (opcional)</label>
            <textarea
              value={comentario}
              onChange={(e) => setComentario(e.target.value)}
              className="mt-1 w-full resize-none rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              rows={3}
              placeholder="Ej: Banco, referencia o notas"
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
            className="w-full rounded-xl bg-white px-4 py-2 text-base font-semibold text-gray-950 disabled:opacity-60"
          >
            {saving ? "Enviando..." : "Enviar solicitud"}
          </button>
        </form>

        <div className="mt-6">
          <h2 className="text-base font-semibold">Tus últimas solicitudes</h2>

          {loading ? (
            <p className="mt-2 text-sm text-gray-400">Cargando...</p>
          ) : items.length === 0 ? (
            <p className="mt-2 text-sm text-gray-400">Aún no tienes solicitudes.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {items.map((it) => (
                <div key={it.id} className="rounded-2xl bg-gray-900/50 p-3 ring-1 ring-white/10">
                  <div className="flex items-center justify-between">
                    <div className="text-sm font-semibold">Bs {formatMoney(it.monto)}</div>
                    <div className="text-xs text-gray-300">{it.estado}</div>
                  </div>
                  <div className="mt-1 text-xs text-gray-400">Tel: {it.telefono_destino}</div>
                  <div className="mt-1 text-xs text-gray-400">Método: {it.metodo}</div>
                  {it.created_at ? (
                    <div className="mt-1 text-[11px] text-gray-500">
                      Creado: {new Date(it.created_at).toLocaleString("es-VE")}
                    </div>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </div>
        </div>
      </div>
      {userId ? <ClientBottomNav /> : null}
    </>
  )
}
