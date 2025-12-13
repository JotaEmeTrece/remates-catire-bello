// REMATES/[ID]/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useParams, useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type RemateRow = {
  id: string
  race_id: string
  nombre: string
  estado: string
  incremento_minimo: string | number
  apuesta_minima: string | number
  porcentaje_casa: string | number
  created_at: string | null
  closed_at: string | null
}

type RaceRow = {
  id: string
  nombre: string
  hipodromo: string | null
  numero_carrera: number | null
  fecha: string
  hora_programada: string | null
  estado: string
}

type HorseRow = {
  id: string
  race_id: string
  numero: number
  nombre: string
  precio_salida: string | number
  jinete: string | null
  entrenador: string | null
  comentarios: string | null
}

type BidRow = {
  id: string
  remate_id: string
  horse_id: string
  user_id: string
  monto: string | number
  created_at: string | null
}

type WalletRow = {
  id: string
  saldo_disponible: string | number
  saldo_bloqueado: string | number
}

type PriceRuleRow = {
  id: string
  remate_id: string
  horse_id: string | null
  min_precio: string | number
  max_precio: string | number | null
  incremento: string | number
  created_at: string | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function badgeClass(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e.includes("abierto")) return "bg-emerald-500/15 text-emerald-200 ring-1 ring-emerald-500/25"
  if (e.includes("cerr")) return "bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/25"
  if (e.includes("liq") || e.includes("liquid")) return "bg-sky-500/15 text-sky-200 ring-1 ring-sky-500/25"
  return "bg-zinc-500/15 text-zinc-200 ring-1 ring-zinc-500/25"
}

export default function RemateDetallePage() {
  const params = useParams()
  const router = useRouter()
  const remateId = String((params as any)?.id || "")

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [placing, setPlacing] = useState<string | null>(null)
  const [error, setError] = useState<string>("")
  const [notice, setNotice] = useState<string>("")

  const [userId, setUserId] = useState<string | null>(null)
  const [wallet, setWallet] = useState<WalletRow | null>(null)

  const [remate, setRemate] = useState<RemateRow | null>(null)
  const [race, setRace] = useState<RaceRow | null>(null)
  const [horses, setHorses] = useState<HorseRow[]>([])
  const [bids, setBids] = useState<BidRow[]>([])
  const [priceRules, setPriceRules] = useState<PriceRuleRow[]>([])

  const [manualByHorse, setManualByHorse] = useState<Record<string, string>>({})

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setNotice("")

    // 1) Sesión
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

    // 2) Wallet
    const { data: w, error: wErr } = await supabase
      .from("wallets")
      .select("id,saldo_disponible,saldo_bloqueado")
      .eq("user_id", auth.user.id)
      .maybeSingle()

    if (wErr) console.error("wallet err:", wErr.message)
    setWallet((w ?? null) as WalletRow | null)

    // 3) Remate
    const { data: r, error: rErr } = await supabase
      .from("remates")
      .select("id,race_id,nombre,estado,incremento_minimo,apuesta_minima,porcentaje_casa,created_at,closed_at")
      .eq("id", remateId)
      .single()

    if (rErr) {
      setError(rErr.message)
      setRemate(null)
      setRace(null)
      setHorses([])
      setBids([])
      setPriceRules([])
      setLoading(false)
      setRefreshing(false)
      return
    }

    const rem = r as RemateRow
    setRemate(rem)

    // 4) Carrera
    const { data: ra, error: raErr } = await supabase
      .from("races")
      .select("id,nombre,hipodromo,numero_carrera,fecha,hora_programada,estado")
      .eq("id", rem.race_id)
      .maybeSingle()

    if (raErr) console.error("race err:", raErr.message)
    setRace((ra ?? null) as RaceRow | null)

    // 5) Caballos
    const { data: h, error: hErr } = await supabase
      .from("horses")
      .select("id,race_id,numero,nombre,precio_salida,jinete,entrenador,comentarios")
      .eq("race_id", rem.race_id)
      .order("numero", { ascending: true })

    if (hErr) {
      setError(hErr.message)
      setHorses([])
      setBids([])
      setPriceRules([])
      setLoading(false)
      setRefreshing(false)
      return
    }
    setHorses((h ?? []) as HorseRow[])

    // 6) Pujas (bids)
    const { data: b, error: bErr } = await supabase
      .from("bids")
      .select("id,remate_id,horse_id,user_id,monto,created_at")
      .eq("remate_id", remateId)
      .order("created_at", { ascending: false })
      .limit(500)

    if (bErr) {
      console.error("bids err:", bErr.message)
      setBids([])
    } else {
      setBids((b ?? []) as BidRow[])
    }

    // 7) Reglas (default + overrides por caballo)
    const { data: pr, error: prErr } = await supabase
      .from("remate_price_rules")
      .select("id,remate_id,horse_id,min_precio,max_precio,incremento,created_at")
      .eq("remate_id", remateId)
      .order("min_precio", { ascending: true })

    if (prErr) {
      console.error("price rules err:", prErr.message)
      setPriceRules([])
    } else {
      setPriceRules((pr ?? []) as PriceRuleRow[])
    }

    setLoading(false)
    setRefreshing(false)
  }

  useEffect(() => {
    if (!remateId) return
    void load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [remateId])

  const computed = useMemo(() => {
    // 1) Index de bids (max por caballo + tu max por caballo)
    const maxBidByHorse: Record<string, number> = {}
    const hasBidByHorse: Record<string, boolean> = {}
    const myMaxByHorse: Record<string, number> = {}

    for (const bid of bids) {
      const m = n(bid.monto)
      hasBidByHorse[bid.horse_id] = true

      if (maxBidByHorse[bid.horse_id] === undefined || m > maxBidByHorse[bid.horse_id]) {
        maxBidByHorse[bid.horse_id] = m
      }

      if (userId && bid.user_id === userId) {
        if (myMaxByHorse[bid.horse_id] === undefined || m > myMaxByHorse[bid.horse_id]) {
          myMaxByHorse[bid.horse_id] = m
        }
      }
    }

    // 2) Separar reglas default vs por caballo
    const defaultRules: PriceRuleRow[] = []
    const rulesByHorse: Record<string, PriceRuleRow[]> = {}

    for (const r of priceRules) {
      if (!r.horse_id) defaultRules.push(r)
      else {
        if (!rulesByHorse[r.horse_id]) rulesByHorse[r.horse_id] = []
        rulesByHorse[r.horse_id].push(r)
      }
    }

    // 3) Selección de incremento (mismo criterio del backend)
    const incFallback = remate ? n(remate.incremento_minimo) : 1
    const minApuesta = remate ? n(remate.apuesta_minima) : 1

    function pickIncrement(horseId: string, ultimoMonto: number) {
      const specific = rulesByHorse[horseId] ?? []
      const candidatesSpecific = specific.filter((r) => {
        const min = n(r.min_precio)
        const max = r.max_precio === null ? null : n(r.max_precio)
        return ultimoMonto >= min && (max === null || ultimoMonto < max)
      })

      if (candidatesSpecific.length > 0) {
        candidatesSpecific.sort((a, b) => n(b.min_precio) - n(a.min_precio))
        return n(candidatesSpecific[0].incremento)
      }

      const candidatesDefault = defaultRules.filter((r) => {
        const min = n(r.min_precio)
        const max = r.max_precio === null ? null : n(r.max_precio)
        return ultimoMonto >= min && (max === null || ultimoMonto < max)
      })

      if (candidatesDefault.length > 0) {
        candidatesDefault.sort((a, b) => n(b.min_precio) - n(a.min_precio))
        return n(candidatesDefault[0].incremento)
      }

      return incFallback
    }

    // 4) Construir current y nextMin por caballo
    const salidaByHorse: Record<string, number> = {}
    const currentByHorse: Record<string, number> = {}
    const nextMinByHorse: Record<string, number> = {}

    for (const h of horses) {
      const salida = Math.max(0, n(h.precio_salida))
      const hasBid = !!hasBidByHorse[h.id]
      const current = hasBid ? (maxBidByHorse[h.id] ?? 0) : salida

      const inc = pickIncrement(h.id, current)

      let nextMin = current + inc
      if (nextMin < minApuesta) nextMin = minApuesta

      salidaByHorse[h.id] = salida
      currentByHorse[h.id] = current
      nextMinByHorse[h.id] = nextMin
    }

    return { myMaxByHorse, salidaByHorse, currentByHorse, nextMinByHorse }
  }, [bids, horses, priceRules, remate, userId])

  async function placeBid(horseId: string, monto: number, esManual: boolean) {
    if (!remate) return
    if (!userId) return

    setPlacing(horseId)
    setError("")
    setNotice("")

    const disponible = wallet ? n(wallet.saldo_disponible) : 0
    if (monto > disponible) {
      setPlacing(null)
      setError(`Saldo insuficiente. Disponible: ${formatMoney(disponible)} Bs`)
      return
    }

    const { error: rpcErr } = await supabase.rpc("hacer_puja", {
      p_remate_id: remate.id,
      p_horse_id: horseId,
      p_monto: monto,
      p_es_manual: esManual,
    })

    if (rpcErr) {
      setPlacing(null)
      setError(rpcErr.message || "Error rematando")
      return
    }

    setNotice("✅ Remate registrado.")
    setManualByHorse((prev) => ({ ...prev, [horseId]: "" }))
    await load(true)
    setPlacing(null)
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando remate...</div>
  }

  if (!remate) {
    return (
      <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
        <div className="mx-auto w-full max-w-md">
          <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
          <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <p className="text-sm text-zinc-200">No se encontró el remate.</p>
          </div>
        </div>
      </main>
    )
  }

  const disponible = wallet ? n(wallet.saldo_disponible) : 0
  const bloqueado = wallet ? n(wallet.saldo_bloqueado) : 0
  const isOpen = String(remate.estado).toLowerCase().includes("abierto")

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-md">
        <div className="flex items-center justify-between">
          <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
          <span className={`rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(remate.estado)}`}>
            {remate.estado}
          </span>
        </div>

        <h1 className="mt-3 text-xl font-bold">{remate.nombre}</h1>

        <div className="mt-2 text-xs text-zinc-400">
          {race ? (
            <>
              {race.hipodromo ? `${race.hipodromo} · ` : ""}
              {race.numero_carrera != null ? `Carrera ${race.numero_carrera} · ` : ""}
              {race.fecha}
              {race.hora_programada ? ` ${race.hora_programada}` : ""}
            </>
          ) : (
            "—"
          )}
        </div>

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

        <button
          onClick={() => void load(true)}
          disabled={refreshing}
          className="mt-3 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 py-2 text-sm text-zinc-200 disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar precios"}
        </button>

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

        <div className="mt-6">
          <h2 className="text-base font-semibold">Caballos</h2>

          {horses.length === 0 ? (
            <p className="mt-2 text-sm text-zinc-400">No hay caballos cargados en esta carrera.</p>
          ) : (
            <div className="mt-3 space-y-3">
              {horses.map((h) => {
                const salida = computed.salidaByHorse[h.id] ?? 0
                const current = computed.currentByHorse[h.id] ?? 0
                const nextMin = computed.nextMinByHorse[h.id] ?? 1
                const my = computed.myMaxByHorse[h.id] ?? 0

                const manual = manualByHorse[h.id] ?? ""
                const manualNum = manual.trim() ? Number(manual) : NaN
                const manualValid = Number.isFinite(manualNum) && manualNum >= nextMin

                return (
                  <div key={h.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm text-zinc-400">#{h.numero}</div>
                        <div className="text-base font-semibold">{h.nombre}</div>
                        <div className="mt-1 text-xs text-zinc-400">
                          {h.jinete ? `J: ${h.jinete}` : ""}
                          {h.jinete && h.entrenador ? " · " : ""}
                          {h.entrenador ? `E: ${h.entrenador}` : ""}
                        </div>
                        <div className="mt-1 text-[11px] text-zinc-500">Salida: {formatMoney(salida)} Bs</div>
                      </div>

                      <div className="text-right">
                        <div className="text-xs text-zinc-500">Actual</div>
                        <div className="text-lg font-semibold text-zinc-50">{formatMoney(current)} Bs</div>
                        <div className="mt-1 text-[11px] text-zinc-500">
                          Próxima mínima: {formatMoney(nextMin)} Bs
                        </div>
                      </div>
                    </div>

                    <div className="mt-3 text-xs text-zinc-400">
                      Tu mejor remate: <span className="font-semibold text-zinc-200">{formatMoney(my)} Bs</span>
                    </div>

                    <div className="mt-4 grid grid-cols-2 gap-2">
                      <button
                        disabled={!isOpen || placing === h.id}
                        onClick={() => void placeBid(h.id, nextMin, false)}
                        className="rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
                      >
                        {placing === h.id ? "Rematando..." : "Rematar mínimo"}
                      </button>

                      <div className="flex gap-2">
                        <input
                          inputMode="decimal"
                          value={manual}
                          onChange={(e) => setManualByHorse((prev) => ({ ...prev, [h.id]: e.target.value }))}
                          placeholder={`${formatMoney(nextMin)}`}
                          className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-white/10"
                        />
                        <button
                          disabled={!isOpen || placing === h.id || !manualValid}
                          onClick={() => void placeBid(h.id, manualNum, true)}
                          className="shrink-0 rounded-xl bg-zinc-800 border border-zinc-700 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                        >
                          Rematar
                        </button>
                      </div>
                    </div>

                    {!isOpen ? <div className="mt-3 text-xs text-zinc-500">Este remate no está abierto.</div> : null}
                    {h.comentarios ? <div className="mt-3 text-xs text-zinc-500">{h.comentarios}</div> : null}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </main>
  )
}
