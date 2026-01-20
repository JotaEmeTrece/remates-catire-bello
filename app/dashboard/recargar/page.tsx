// app/dashboard/recargar/page.tsx
"use client"

import { useEffect, useMemo, useState, type FormEvent } from "react"
import Link from "next/link"
import { supabase } from "@/lib/supabaseClient"
import ClientBottomNav from "@/app/components/ClientBottomNav"
import { CornerLogo } from "@/app/components/BrandLogo"

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

function formatMoney(v: string | number) {
  const n = typeof v === "string" ? Number(v) : v
  if (!Number.isFinite(n)) return String(v)
  return n.toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export default function RecargarPage() {
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>("")
  const [ok, setOk] = useState<string>("")
  const [userId, setUserId] = useState<string | null>(null)

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

  const [items, setItems] = useState<DepositRow[]>([])

  const metodoLabel = useMemo(() => {
    if (metodo === "pago_movil") return "Pago Móvil"
    return metodo
  }, [metodo])

  async function load() {
    setLoading(true)
    setError("")
    setOk("")
    setUserId(null)
    setItems([])

    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr || !auth?.user) {
      setLoading(false)
      return
    }
    setUserId(auth.user.id)

    const { data, error: listErr } = await supabase
      .from("deposit_requests")
      .select("id,monto,metodo,telefono_pago,referencia,fecha_pago,estado,created_at")
      .eq("user_id", auth.user.id)
      .order("created_at", { ascending: false })
      .limit(10)

    if (listErr) setError(listErr.message)
    setItems((data ?? []) as DepositRow[])
    setLoading(false)
  }

  useEffect(() => {
    void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError("")
    setOk("")

    const n = Number(monto)
    if (!Number.isFinite(n) || n <= 0) return setError("Monto inválido.")
    if (!telefonoPago.trim()) return setError("Teléfono de pago requerido.")
    if (!referencia.trim()) return setError("Referencia requerida.")
    if (!fechaPago) return setError("Fecha de pago requerida.")

    setSaving(true)

    const { error: rpcErr } = await supabase.rpc("solicitar_recarga", {
      p_monto: n,
      p_metodo: metodo,
      p_telefono_pago: telefonoPago.trim(),
      p_referencia: referencia.trim(),
      p_fecha_pago: fechaPago,
    })

    setSaving(false)

    if (rpcErr) return setError(rpcErr.message)

    setOk("Solicitud enviada. Queda en estado pendiente.")
    setMonto("")
    setTelefonoPago("")
    setReferencia("")
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
            <h1 className="text-xl font-semibold">Recargar saldo</h1>
            <Link href="/remates" className="text-sm text-gray-300 underline underline-offset-4">
              Ver remates
            </Link>
          </div>
          <div className="mt-4 rounded-2xl bg-gray-900/60 p-4 ring-1 ring-white/10 text-sm text-gray-200">
            Inicia sesión para recargar saldo.
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

  return (
    <>
      <div className="min-h-dvh bg-gray-950 text-gray-50">
        <div className="mx-auto w-full max-w-md px-4 py-6 pb-24">
          <div className="mb-3">
            <CornerLogo />
          </div>
          <div className="flex items-center justify-between">
            <h1 className="text-xl font-semibold">Recargar saldo</h1>
            <Link href="/dashboard" className="text-sm text-gray-300 underline underline-offset-4">
              Volver
            </Link>
        </div>

        <p className="mt-2 text-sm text-gray-300">Registra tu pago y el admin lo aprueba manualmente.</p>

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
            <p className="mt-1 text-xs text-gray-400">Actual: {metodoLabel}</p>
          </div>

          <div>
            <label className="text-sm text-gray-200">Teléfono desde donde pagaste</label>
            <input
              value={telefonoPago}
              onChange={(e) => setTelefonoPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 0412xxxxxxx"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Referencia</label>
            <input
              value={referencia}
              onChange={(e) => setReferencia(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
              placeholder="Ej: 123456"
            />
          </div>

          <div>
            <label className="text-sm text-gray-200">Fecha del pago</label>
            <input
              type="date"
              value={fechaPago}
              onChange={(e) => setFechaPago(e.target.value)}
              className="mt-1 w-full rounded-xl bg-gray-950 px-3 py-2 text-base ring-1 ring-white/10 focus:outline-none focus:ring-2 focus:ring-white/20"
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
                  <div className="mt-1 text-xs text-gray-400">
                    Ref: {it.referencia} - Fecha: {it.fecha_pago}
                  </div>
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
