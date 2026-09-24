// ADMIN/CONTABILIDAD/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

function n(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: unknown) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null) {
  if (!v) return "-"
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? "-" : d.toLocaleString("es-VE")
}

type Resumen = {
  recargas_aprobadas: number
  recargas_pendientes: number
  retiros_pagados: number
  retiros_pendientes: number
  remates_liquidados: number
  remates_pozo_total: number
  remates_premio_total: number
  remates_casa_total: number
  saldo_usuarios: number
  dinero_casa: number
}

// casa_resumen(): la foto contable, con el cuadre entre el libro y los saldos.
type Casa = {
  caja_total: number
  obligaciones: number
  patrimonio: number
  capital_aportado: number
  utilidades_retiradas: number
  ajustes: number
  resultado_operativo: number
  perdida_usuarios: number
  descuadre: number
  cubierto: boolean
}

type LedgerRow = {
  id: string
  tipo: string
  monto: string | number
  motivo: string
  created_at: string | null
}

const ETIQUETA_TIPO: Record<string, string> = {
  aporte_capital: "Aporte de capital",
  retiro_utilidad: "Retiro de utilidad",
  ajuste: "Ajuste",
  resultado_remate: "Resultado de remate",
}

export default function AdminContabilidadPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState("")
  const [aviso, setAviso] = useState("")

  const [resumen, setResumen] = useState<Resumen | null>(null)
  const [casa, setCasa] = useState<Casa | null>(null)
  const [libro, setLibro] = useState<LedgerRow[]>([])

  // formulario de asiento manual
  const [tipo, setTipo] = useState("aporte_capital")
  const [monto, setMonto] = useState("")
  const [motivo, setMotivo] = useState("")
  const [guardando, setGuardando] = useState(false)

  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      const { data, error: rpcErr } = await supabase.rpc("admin_contabilidad_resumen")
      if (rpcErr) throw new Error(rpcErr.message)

      const raw = (data ?? {}) as Record<string, unknown>
      setResumen({
        recargas_aprobadas: n(raw.recargas_aprobadas),
        recargas_pendientes: n(raw.recargas_pendientes),
        retiros_pagados: n(raw.retiros_pagados),
        retiros_pendientes: n(raw.retiros_pendientes),
        remates_liquidados: n(raw.remates_liquidados),
        remates_pozo_total: n(raw.remates_pozo_total),
        remates_premio_total: n(raw.remates_premio_total),
        remates_casa_total: n(raw.remates_casa_total),
        saldo_usuarios: n(raw.saldo_usuarios),
        dinero_casa: n(raw.dinero_casa),
      })

      const { data: cData, error: cErr } = await supabase.rpc("casa_resumen")
      if (cErr) throw new Error(cErr.message)
      const c = Array.isArray(cData) ? cData[0] : null
      setCasa(
        c
          ? {
              caja_total: n(c.caja_total),
              obligaciones: n(c.obligaciones),
              patrimonio: n(c.patrimonio),
              capital_aportado: n(c.capital_aportado),
              utilidades_retiradas: n(c.utilidades_retiradas),
              ajustes: n(c.ajustes),
              resultado_operativo: n(c.resultado_operativo),
              perdida_usuarios: n(c.perdida_usuarios),
              descuadre: n(c.descuadre),
              cubierto: !!c.cubierto,
            }
          : null
      )

      const { data: lData, error: lErr } = await supabase
        .from("house_ledger")
        .select("id,tipo,monto,motivo,created_at")
        .order("created_at", { ascending: false })
        .limit(15)

      if (lErr) console.error("house_ledger err:", lErr.message)
      setLibro((lData ?? []) as LedgerRow[])
    } catch (e: any) {
      setError(e?.message || "Error cargando contabilidad")
      setResumen(null)
      setCasa(null)
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function registrarAsiento(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setAviso("")

    const valor = Number(monto)
    if (!Number.isFinite(valor) || valor === 0) {
      setError("Monto invalido.")
      return
    }
    if (motivo.trim().length < 3) {
      setError("El motivo es obligatorio.")
      return
    }

    // El signo lo fija el tipo, no el admin: un aporte siempre suma y un retiro
    // de utilidad siempre resta. La base tiene el mismo CHECK, esto es para no
    // gastar el viaje.
    const firmado =
      tipo === "retiro_utilidad" ? -Math.abs(valor) : tipo === "aporte_capital" ? Math.abs(valor) : valor

    setGuardando(true)
    const { error: rpcErr } = await supabase.rpc("registrar_movimiento_casa", {
      p_tipo: tipo,
      p_monto: firmado,
      p_motivo: motivo.trim(),
    })
    setGuardando(false)

    if (rpcErr) {
      setError(rpcErr.message)
      return
    }

    setMonto("")
    setMotivo("")
    setAviso("Asiento registrado.")
    void load(true)
  }

  const cards = useMemo(() => {
    if (!resumen) return []
    return [
      {
        title: "Recargas aprobadas",
        value: `${formatMoney(resumen.recargas_aprobadas)} Bs`,
        hint: `Pendientes: ${formatMoney(resumen.recargas_pendientes)} Bs`,
      },
      {
        title: "Retiros pagados",
        value: `${formatMoney(resumen.retiros_pagados)} Bs`,
        hint: `Pendientes: ${formatMoney(resumen.retiros_pendientes)} Bs`,
      },
      {
        title: "Saldo usuarios",
        value: `${formatMoney(resumen.saldo_usuarios)} Bs`,
        hint: "Lo que se les debe",
      },
      {
        title: "Pozo total (remates)",
        value: `${formatMoney(resumen.remates_pozo_total)} Bs`,
        hint: `Premios pagados: ${formatMoney(resumen.remates_premio_total)} Bs`,
      },
    ]
  }, [resumen])

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando contabilidad...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6 pb-24">
      <div className="mx-auto w-full max-w-md">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Contabilidad</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}

        {aviso ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {aviso}
          </div>
        ) : null}

        {/* ALARMA DE COBERTURA. Sin eufemismos: si el patrimonio es negativo,
            los premios se estan pagando con dinero de los usuarios. */}
        {casa && !casa.cubierto ? (
          <div className="mt-4 rounded-2xl bg-red-500/15 p-4 ring-1 ring-red-500/40">
            <div className="text-sm font-bold text-red-200">La casa no cubre lo que debe</div>
            <div className="mt-1 text-sm text-red-100">
              Faltan <span className="font-semibold">{formatMoney(Math.abs(casa.patrimonio))} Bs</span>. Estas pagando
              premios con dinero de los usuarios.
            </div>
            <div className="mt-2 text-[11px] text-red-200/80">
              Registra un aporte de capital abajo, o revisa por que la caja bajo.
            </div>
          </div>
        ) : null}

        {/* ALARMA DE CUADRE. El libro y los saldos tienen que contar la misma
            historia. Si no, hay un bug o alguien metio mano. */}
        {casa && Math.abs(casa.descuadre) > 0.009 ? (
          <div className="mt-4 rounded-2xl bg-amber-500/15 p-4 ring-1 ring-amber-500/40">
            <div className="text-sm font-bold text-amber-200">El libro no cuadra con los saldos</div>
            <div className="mt-1 text-sm text-amber-100">
              Diferencia de <span className="font-semibold">{formatMoney(casa.descuadre)} Bs</span>.
            </div>
            <div className="mt-2 text-[11px] text-amber-200/80">
              Libro: {formatMoney(casa.resultado_operativo)} Bs · Saldos: {formatMoney(casa.perdida_usuarios)} Bs.
              Esto no deberia pasar nunca: avisa antes de seguir operando.
            </div>
          </div>
        ) : null}

        {casa ? (
          <>
            <div className="mt-4 grid grid-cols-3 gap-2">
              <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
                <div className="text-xs text-zinc-500">Caja</div>
                <div className="mt-1 text-base font-semibold text-zinc-100">{formatMoney(casa.caja_total)}</div>
                <div className="mt-1 text-[10px] text-zinc-500">deberia haber en banco</div>
              </div>
              <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
                <div className="text-xs text-zinc-500">Se debe</div>
                <div className="mt-1 text-base font-semibold text-amber-300">{formatMoney(casa.obligaciones)}</div>
                <div className="mt-1 text-[10px] text-zinc-500">saldos + retiros</div>
              </div>
              <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
                <div className="text-xs text-zinc-500">Es tuyo</div>
                <div
                  className={`mt-1 text-base font-semibold ${
                    casa.patrimonio >= 0 ? "text-emerald-300" : "text-red-300"
                  }`}
                >
                  {formatMoney(casa.patrimonio)}
                </div>
                <div className="mt-1 text-[10px] text-zinc-500">patrimonio</div>
              </div>
            </div>

            <div className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
              <div className="text-xs text-zinc-500">De donde sale el patrimonio</div>
              <div className="mt-2 space-y-1 text-sm">
                <div className="flex justify-between">
                  <span className="text-zinc-400">Ganado en remates</span>
                  <span className="font-semibold">{formatMoney(casa.resultado_operativo)} Bs</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-zinc-400">Capital aportado</span>
                  <span className="font-semibold">{formatMoney(casa.capital_aportado)} Bs</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-zinc-400">Utilidades retiradas</span>
                  <span className="font-semibold">{formatMoney(casa.utilidades_retiradas)} Bs</span>
                </div>
                {casa.ajustes !== 0 ? (
                  <div className="flex justify-between">
                    <span className="text-zinc-400">Ajustes</span>
                    <span className="font-semibold">{formatMoney(casa.ajustes)} Bs</span>
                  </div>
                ) : null}
              </div>
              <div className="mt-3 text-[11px] text-zinc-500">
                Lo ganado en remates lo escribe el sistema al liquidar. No se registra a mano.
              </div>
            </div>
          </>
        ) : null}

        <div className="mt-3 grid grid-cols-2 gap-2">
          {cards.map((c) => (
            <div key={c.title} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
              <div className="text-xs text-zinc-500">{c.title}</div>
              <div className="mt-1 text-lg font-semibold text-amber-300">{c.value}</div>
              <div className="mt-2 text-[11px] text-zinc-400">{c.hint}</div>
            </div>
          ))}
        </div>

        <form onSubmit={registrarAsiento} className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="text-sm font-semibold">Registrar movimiento de la casa</div>

          <select
            value={tipo}
            onChange={(e) => setTipo(e.target.value)}
            className="mt-3 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
          >
            <option value="aporte_capital">Aporte de capital (entra dinero tuyo)</option>
            <option value="retiro_utilidad">Retiro de utilidad (sacas ganancia)</option>
            <option value="ajuste">Ajuste</option>
          </select>

          <input
            inputMode="decimal"
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            placeholder={tipo === "ajuste" ? "Monto (usa - para restar)" : "Monto"}
            className="mt-2 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
          />

          <input
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
            placeholder="Motivo (obligatorio)"
            className="mt-2 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
          />

          <button
            type="submit"
            disabled={guardando}
            className="mt-3 w-full rounded-xl bg-white text-zinc-950 font-semibold py-2 text-sm disabled:opacity-60"
          >
            {guardando ? "Registrando..." : "Registrar"}
          </button>

          <div className="mt-2 text-[11px] text-zinc-500">
            Queda en el libro con tu usuario y la fecha. No se puede borrar.
          </div>
        </form>

        <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="text-sm font-semibold">Ultimos movimientos del libro</div>
          {libro.length === 0 ? (
            <div className="mt-2 text-sm text-zinc-500">Todavia no hay movimientos.</div>
          ) : (
            <div className="mt-2 divide-y divide-zinc-800">
              {libro.map((it) => (
                <div key={it.id} className="py-2">
                  <div className="flex items-center justify-between">
                    <span className="text-sm text-zinc-300">{ETIQUETA_TIPO[it.tipo] ?? it.tipo}</span>
                    <span
                      className={`text-sm font-semibold ${
                        n(it.monto) >= 0 ? "text-emerald-300" : "text-red-300"
                      }`}
                    >
                      {formatMoney(it.monto)} Bs
                    </span>
                  </div>
                  <div className="text-[11px] text-zinc-500">{it.motivo}</div>
                  <div className="text-[11px] text-zinc-600">{formatDT(it.created_at)}</div>
                </div>
              ))}
            </div>
          )}
        </div>

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>
      </div>
    </main>
  )
}
