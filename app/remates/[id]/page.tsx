// REMATES/[ID]/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useParams } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import ClientBottomNav from "@/app/components/ClientBottomNav"
import { CornerLogo } from "@/app/components/BrandLogo"

type RemateRow = {
  id: string
  race_id: string
  nombre: string
  estado: string
  incremento_minimo: string | number
  porcentaje_casa: string | number
  created_at: string | null
  closed_at: string | null
  archived_at?: string | null
  opens_at?: string | null
  closes_at?: string | null
  tipo?: string | null
}

type RaceRow = {
  id: string
  nombre: string
  hipodromo: string | null
  numero_carrera: number | null
  numero_carrera_text?: string | null
  dia?: string | null
  distancia_m?: string | number | null
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
  retirado?: boolean | null
}

type BidRow = {
  horse_id: string
  monto: string | number
  created_at: string | null
  username: string | null
  is_me: boolean
}

type WalletRow = {
  id: string
  saldo_disponible: string | number
  comprometido: string | number
  disponible_para_retirar: string | number
}

// Una fila de remate_minimos(). La pantalla muestra estos numeros; no los
// calcula. Es el contrato con la base.
type MinimoRow = {
  horse_id: string
  numero: number
  retirado: boolean
  precio_salida: string | number
  hay_pujas: boolean
  monto_actual: string | number
  lider_user_id: string | null
  soy_lider: boolean
  incremento: string | number
  minimo_auto: string | number
  minimo_manual: string | number
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function parseAmount(raw: string) {
  const s = String(raw ?? "").trim()
  if (!s) return NaN
  const hasComma = s.includes(",")
  const hasDot = s.includes(".")
  if (hasComma && !hasDot) return Number(s.replace(",", "."))
  return Number(s)
}

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDate(v: string | null) {
  if (!v) return "-"
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? "-" : d.toLocaleString("es-VE")
}

function formatDateShort(iso: string | null | undefined) {
  if (!iso) return ""
  const parts = iso.split("-")
  if (parts.length !== 3) return iso
  return `${parts[2]}/${parts[1]}/${parts[0].slice(-2)}`
}

function formatTime12hFrom24(time24: string | null | undefined) {
  if (!time24) return ""
  const parts = time24.split(":")
  if (parts.length < 2) return ""
  const h24 = Number(parts[0])
  const m = parts[1]
  if (!Number.isFinite(h24)) return ""
  const isPm = h24 >= 12
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12
  return `${h12}:${m} ${isPm ? "pm" : "am"}`
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
  const remateId = String((params as any)?.id || "")

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [placing, setPlacing] = useState<string | null>(null)
  const [error, setError] = useState<string>("")
  const [notice, setNotice] = useState<string>("")

  const [userId, setUserId] = useState<string | null>(null)
  const [isAdmin, setIsAdmin] = useState(false)
  const [wallet, setWallet] = useState<WalletRow | null>(null)

  const [remate, setRemate] = useState<RemateRow | null>(null)
  const [race, setRace] = useState<RaceRow | null>(null)
  const [horses, setHorses] = useState<HorseRow[]>([])
  const [bids, setBids] = useState<BidRow[]>([])
  // Los minimos ya NO se calculan aqui. Los da la base con remate_minimos()
  // (tarea 2.20). Tener la escalera de precios implementada dos veces -una en
  // SQL y otra en TypeScript- fue como llegamos al defecto 1.10: la pantalla
  // elegia la regla del caballo y la base la general, y el usuario leia un
  // numero mientras la base cobraba otro.
  const [minimos, setMinimos] = useState<Record<string, MinimoRow>>({})

  const [manualByHorse, setManualByHorse] = useState<Record<string, string>>({})

  async function load(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setNotice("")

    let sessionUserId: string | null = null
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) {
      if (authErr.message !== "Auth session missing!") {
        console.error("auth err:", authErr.message)
        setError(authErr.message)
      }
    } else if (auth?.user) {
      sessionUserId = auth.user.id
    }
    setUserId(sessionUserId)

    if (sessionUserId) {
      const { data: prof, error: profErr } = await supabase
        .from("profiles")
        .select("es_admin,es_super_admin")
        .eq("id", sessionUserId)
        .maybeSingle()

      if (profErr) console.error("profile err:", profErr.message)
      const adminFlag = !!(prof?.es_admin || prof?.es_super_admin)
      setIsAdmin(adminFlag)

      if (!adminFlag) {
        // Los tres numeros los da la base. Esta pantalla no los calcula.
        const { data: w, error: wErr } = await supabase.rpc("mi_wallet_resumen")

        if (wErr) console.error("wallet err:", wErr.message)
        const wFirst = Array.isArray(w) ? w[0] : null
        setWallet(wFirst ? (wFirst as WalletRow) : null)
      } else {
        setWallet(null)
      }
    } else {
      setIsAdmin(false)
      setWallet(null)
    }

    const { data: r, error: rErr } = await supabase
      .from("remates")
      .select("id,race_id,nombre,estado,incremento_minimo,porcentaje_casa,created_at,closed_at,archived_at,opens_at,closes_at,tipo")
      .eq("id", remateId)
      .single()

    if (rErr) {
      setError(rErr.message)
      setRemate(null)
      setRace(null)
      setHorses([])
      setBids([])
      setMinimos({})
      setLoading(false)
      setRefreshing(false)
      return
    }

    const rem = r as RemateRow
    setRemate(rem)

    const { data: ra, error: raErr } = await supabase
      .from("races")
      .select("id,nombre,hipodromo,numero_carrera,numero_carrera_text,dia,distancia_m,fecha,hora_programada,estado")
      .eq("id", rem.race_id)
      .maybeSingle()

    if (raErr) console.error("race err:", raErr.message)
    setRace(ra ? (ra as RaceRow) : null)

    const { data: h, error: hErr } = await supabase
      .from("horses")
      .select("id,race_id,numero,nombre,precio_salida,jinete,entrenador,comentarios,retirado")
      .eq("race_id", rem.race_id)
      .order("numero", { ascending: true })

    if (hErr) {
      setError(hErr.message)
      setHorses([])
      setBids([])
      setMinimos({})
      setLoading(false)
      setRefreshing(false)
      return
    }
    setHorses((h ?? []) as HorseRow[])

    const { data: b, error: bErr } = await supabase.rpc("listar_pujas_publicas", {
      p_remate_id: remateId,
    })

    if (bErr) {
      console.error("bids err:", bErr.message)
      setBids([])
    } else {
      setBids((b ?? []) as BidRow[])
    }

    const { data: mins, error: minErr } = await supabase.rpc("remate_minimos", {
      p_remate_id: remateId,
    })

    if (minErr) {
      console.error("remate_minimos err:", minErr.message)
      setMinimos({})
    } else {
      const map: Record<string, MinimoRow> = {}
      for (const row of (mins ?? []) as MinimoRow[]) map[row.horse_id] = row
      setMinimos(map)
    }

    setLoading(false)
    setRefreshing(false)
  }

  useEffect(() => {
    if (!remateId) return
    void load(false)
  }, [remateId])

  const horsesById = useMemo(() => {
    const map: Record<string, HorseRow> = {}
    for (const h of horses) map[h.id] = h
    return map
  }, [horses])

  const computed = useMemo(() => {
    const maxBidByHorse: Record<string, number> = {}
    const hasBidByHorse: Record<string, boolean> = {}
    const leaderByHorse: Record<
      string,
      { monto: number; created_at: string | null; username: string; is_me: boolean }
    > = {}

    for (const bid of bids) {
      const m = n(bid.monto)
      hasBidByHorse[bid.horse_id] = true

      if (maxBidByHorse[bid.horse_id] === undefined || m > maxBidByHorse[bid.horse_id]) {
        maxBidByHorse[bid.horse_id] = m
      }

      const prevLeader = leaderByHorse[bid.horse_id]
      if (!prevLeader || m > prevLeader.monto) {
        leaderByHorse[bid.horse_id] = {
          monto: m,
          created_at: bid.created_at ?? null,
          username: bid.username ?? "",
          is_me: !!bid.is_me,
        }
      } else if (m === prevLeader.monto) {
        const prevTs = prevLeader.created_at ? new Date(prevLeader.created_at).getTime() : NaN
        const nextTs = bid.created_at ? new Date(bid.created_at).getTime() : NaN
        if (Number.isFinite(nextTs) && (!Number.isFinite(prevTs) || nextTs < prevTs)) {
          leaderByHorse[bid.horse_id] = {
            monto: m,
            created_at: bid.created_at ?? null,
            username: bid.username ?? "",
            is_me: !!bid.is_me,
          }
        }
      }
    }

    return { leaderByHorse }
  }, [bids])

  // Pozo: cada caballo no retirado aporta su puja lider, o su precio de salida
  // si nadie lo pujo (queda con la casa). Los montos salen de remate_minimos().
  const pozoTotal = useMemo(() => {
    let total = 0
    for (const h of horses) {
      if (h.retirado) continue
      const m = minimos[h.id]
      total += m ? n(m.monto_actual) : n(h.precio_salida)
    }
    return total
  }, [horses, minimos])

  // El porcentaje sale del remate, no de un 0.25 clavado. Cada instalacion
  // pone el suyo, y la liquidacion usa esta misma columna.
  const pctCasa = remate ? n(remate.porcentaje_casa) : 25
  const casaTotal = Math.round(pozoTotal * (pctCasa / 100) * 100) / 100

  async function placeBid(horseId: string, monto: number, esManual: boolean) {
    if (!remate) return
    if (!userId) {
      setError("Debes iniciar sesión para pujar.")
      return
    }
    if (!wallet) {
      setError("No se pudo cargar tu wallet.")
      return
    }

    setPlacing(horseId)
    setError("")
    setNotice("")

    // MISMA cuenta que hace la base en hacer_puja: el compromiso de este
    // usuario, descontando lo que ya lidera en ESTE caballo (porque subir la
    // propia puja la reemplaza, no la suma), mas el monto nuevo, contra el
    // saldo total.
    //
    // Antes se restaba `myMaxByHorse`, que es la puja mas alta que el usuario
    // hizo en ese caballo ALGUNA VEZ, fuera o no el lider actual. El SQL solo
    // resta si es el lider AHORA. Por eso la pantalla decia que hacia falta
    // menos de lo que el servidor exigia, el usuario apretaba el boton y le
    // salia "Saldo insuficiente" sin entender por que. Defecto R4 del diseno.
    const min = minimos[horseId]
    const saldoTotal = wallet ? n(wallet.saldo_disponible) : 0
    const comprometidoActual = wallet ? n(wallet.comprometido) : 0
    const miPujaEnEste = min?.soy_lider ? n(min.monto_actual) : 0
    const comprometidoSinEste = Math.max(0, comprometidoActual - miPujaEnEste)
    if (saldoTotal < comprometidoSinEste + monto) {
      setPlacing(null)
      setError(
        `Saldo insuficiente. Tienes ${formatMoney(saldoTotal)} Bs, ` +
        `${formatMoney(comprometidoSinEste)} Bs comprometidos en otras pujas, ` +
        `y esta puja son ${formatMoney(monto)} Bs.`
      )
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

    setManualByHorse((prev) => ({ ...prev, [horseId]: "" }))
    await load(true)
    setNotice("Remate registrado.")
    setPlacing(null)
  }

  async function handlePonerle(horseId: string, nextMin: number, manualMin: number) {
    const raw = (manualByHorse[horseId] ?? "").trim()

    if (raw) {
      const manualNum = parseAmount(raw)
      if (!Number.isFinite(manualNum)) {
        setError("Monto manual invalido.")
        return
      }
      if (manualNum < manualMin) {
        setError(`Puja manual mínima: ${formatMoney(manualMin)} Bs`)
        return
      }
      await placeBid(horseId, manualNum, true)
      return
    }

    await placeBid(horseId, nextMin, false)
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando remate...</div>
  }

  const isCancelled = remate && String(remate.estado || "").toLowerCase() === "cancelado"
  const isArchived = !!remate?.archived_at
  if (remate && (isCancelled || isArchived)) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-zinc-950 text-zinc-50 px-4">
        <div className="w-full max-w-md rounded-2xl bg-zinc-900/60 border border-zinc-800 p-5 text-center">
          <h1 className="text-lg font-semibold">Remate no disponible</h1>
          <p className="mt-2 text-sm text-zinc-300">
            {isCancelled ? "Este remate fue cancelado." : "Este remate fue archivado."}
          </p>
          <Link href="/remates" className="mt-4 inline-block text-xs text-zinc-300 underline underline-offset-4">
            Volver a remates
          </Link>
        </div>
      </div>
    )
  }

  const nowTs = Date.now()
  const opensOk = remate?.opens_at ? nowTs >= new Date(remate.opens_at).getTime() : true
  const closesOk = remate?.closes_at ? nowTs < new Date(remate.closes_at).getTime() : true
  const isWindowOpen = opensOk && closesOk

  if (remate && !isAdmin && (!isWindowOpen || String(remate.estado || "").toLowerCase() !== "abierto")) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-zinc-950 text-zinc-50 px-4">
        <div className="w-full max-w-md rounded-2xl bg-zinc-900/60 border border-zinc-800 p-5 text-center">
          <h1 className="text-lg font-semibold">Remate no disponible</h1>
          <p className="mt-2 text-sm text-zinc-300">Este remate no está abierto para pujar en este momento.</p>
          <Link href="/remates" className="mt-4 inline-block text-xs text-zinc-300 underline underline-offset-4">
            Volver a remates
          </Link>
        </div>
      </div>
    )
  }

  if (!remate) {
    return (
      <>
        <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6 pb-24">
          <div className="mx-auto w-full max-w-md">
            <div className="mb-3">
              <CornerLogo />
            </div>
            <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
              Volver
            </Link>
            <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
              <p className="text-sm text-zinc-200">No se encontró el remate.</p>
            </div>
          </div>
        </main>
        {userId && !isAdmin ? <ClientBottomNav /> : null}
      </>
    )
  }

  const disponible = wallet ? n(wallet.saldo_disponible) : 0
  const comprometido = wallet ? n(wallet.comprometido) : 0
  const retirable = wallet ? n(wallet.disponible_para_retirar) : 0
  const isOpen = String(remate.estado).toLowerCase().includes("abierto")
  const canBid = isOpen && !!userId && !isAdmin

  return (
    <>
      <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6 pb-24">
        <div className="mx-auto w-full max-w-md">
          <div className="mb-3">
            <CornerLogo />
          </div>
          <div className="flex items-center justify-between">
            <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
              Volver
            </Link>
            <span className={`rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(remate.estado)}`}>
              {remate.estado}
            </span>
          </div>

        <h1 className="mt-3 text-xl font-bold">
          {race ? (
            <>
              {race.hipodromo ? `${race.hipodromo} - ` : ""}
              {race.dia ? `${race.dia} - ` : ""}
              {formatDateShort(race.fecha)}
              {race.hora_programada ? ` ${formatTime12hFrom24(race.hora_programada)}` : ""}
              {race.numero_carrera_text
                ? ` - ${race.numero_carrera_text}`
                : race.numero_carrera != null
                ? ` - Carrera ${race.numero_carrera}`
                : ""}
              {race.distancia_m ? ` - ${race.distancia_m} m` : ""}
            </>
          ) : (
            "Carrera"
          )}
        </h1>

        <div className="mt-2 text-xs text-zinc-400">{race?.nombre || "-"}</div>

        {!userId ? (
          <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-200">
            Inicia sesión para ver tu saldo y pujar.
            <Link href="/login" className="ml-2 text-zinc-100 underline underline-offset-4">
              Iniciar sesión
            </Link>
          </div>
        ) : isAdmin ? (
          <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-200">
            Vista solo lectura (admin). Para operar este remate usa el panel admin.
            <Link href={`/admin/remates/${remate.id}`} className="ml-2 text-zinc-100 underline underline-offset-4">
              Ir al panel
            </Link>
          </div>
        ) : (
          <div className="mt-4 grid grid-cols-2 gap-2">
            <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Disponible</div>
              <div className="mt-1 text-lg font-semibold text-emerald-300">{formatMoney(disponible)} Bs</div>
            </div>
            <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">En pujas</div>
              <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(comprometido)} Bs</div>
            </div>
            <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Puedes retirar</div>
              <div className="mt-1 text-lg font-semibold text-sky-300">{formatMoney(retirable)} Bs</div>
            </div>
          </div>
        )}

        <div className="mt-3 grid grid-cols-2 gap-2">
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
            <div className="text-xs text-zinc-500">Pozo actual</div>
            <div className="mt-1 text-lg font-semibold">{formatMoney(pozoTotal)} Bs</div>
          </div>
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-3">
            <div className="text-xs text-zinc-500">Casa {pctCasa}%</div>
            <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(casaTotal)} Bs</div>
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
            <div className="mt-3 rounded-2xl overflow-hidden border border-zinc-800 bg-zinc-900/60">
              <div className="md:hidden grid grid-cols-[52px_1fr_140px] bg-zinc-950/40 border-b border-zinc-800">
                <div className="px-3 py-3 text-xs text-zinc-400">#</div>
                <div className="px-3 py-3 text-xs text-zinc-400">Caballo</div>
                <div className="px-3 py-3 text-xs text-zinc-400 text-right">Va ganando</div>
              </div>

              <div className="hidden md:grid grid-cols-[60px_1.4fr_1fr_1fr_1.6fr] bg-zinc-950/40 border-b border-zinc-800">
                <div className="px-4 py-3 text-xs text-zinc-400">#</div>
                <div className="px-4 py-3 text-xs text-zinc-400">Caballo</div>
                <div className="px-4 py-3 text-xs text-zinc-400">Jinete</div>
                <div className="px-4 py-3 text-xs text-zinc-400">Va ganando</div>
                <div className="px-4 py-3 text-xs text-zinc-400">Accion</div>
              </div>

              {horses.map((h) => {
                const m = minimos[h.id]
                const salida = m ? n(m.precio_salida) : n(h.precio_salida)
                const current = m ? n(m.monto_actual) : salida
                const nextMin = m ? n(m.minimo_auto) : current
                const leader = computed.leaderByHorse[h.id]
                const isRetirado = !!h.retirado
                const leaderLabel = leader
                  ? leader.is_me
                    ? "Tu"
                    : leader.username || "Usuario"
                  : "Casa"

                const manual = manualByHorse[h.id] ?? ""
                const manualMin = m ? n(m.minimo_manual) : nextMin
                const disabled = !canBid || placing === h.id || isRetirado

                return (
                    <div key={h.id} className="border-b border-zinc-800 last:border-b-0">
                      <div className="md:hidden grid grid-cols-[52px_1fr_140px]">
                        <div className="px-3 py-4">
                          <div className="h-9 w-9 rounded-full bg-zinc-950/60 border border-zinc-800 flex items-center justify-center text-sm text-zinc-200">
                            {h.numero}
                          </div>
                        </div>

                        <div className="px-3 py-4 min-w-0">
                          <div className="text-base font-semibold truncate">{h.nombre}</div>
                          <div className="mt-1 text-xs text-zinc-400">{h.jinete ? `J: ${h.jinete}` : "J: -"}</div>
                        </div>

                        <div className="px-3 py-4 text-right">
                          <div className="text-lg font-semibold text-amber-300">{formatMoney(current)} Bs</div>
                          <div className={isRetirado ? "text-sm text-red-300" : "text-sm text-amber-200"}>
                            {isRetirado ? "Retirado" : leaderLabel}
                          </div>
                        </div>

                        <div className="px-3 pb-4 col-start-2 col-span-2">
                          {isRetirado ? (
                            <div className="text-[11px] text-red-300">Caballo retirado</div>
                          ) : isAdmin ? (
                            <div className="text-[11px] text-zinc-500">Solo lectura (admin)</div>
                          ) : (
                            <>
                              <div className="flex gap-2 items-center">
                                <input
                                  inputMode="decimal"
                                  value={manual}
                                  disabled={disabled}
                                  onChange={(e) => setManualByHorse((prev) => ({ ...prev, [h.id]: e.target.value }))}
                                  placeholder="Monto manual"
                                  className="w-32 rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-white/10 disabled:opacity-60"
                                />
                                <button
                                  disabled={disabled}
                                  onClick={() => void handlePonerle(h.id, nextMin, manualMin)}
                                  className="shrink-0 rounded-xl bg-white text-zinc-950 font-semibold px-4 py-2 text-sm disabled:opacity-60"
                                >
                                  {placing === h.id ? "Rematando..." : "Ponerle"}
                                </button>
                              </div>

                              <div className="mt-1 text-[11px] text-zinc-500">
                                Puja manual mínima: {formatMoney(manualMin)} Bs
                              </div>
                            </>
                          )}
                        </div>
                      </div>

                    <div className="hidden md:grid grid-cols-[60px_1.4fr_1fr_1fr_1.6fr]">
                      <div className="px-4 py-4 text-sm text-zinc-200">{h.numero}</div>
                      <div className="px-4 py-4">
                        <div className="text-sm font-semibold text-zinc-50">{h.nombre}</div>
                      </div>
                      <div className="px-4 py-4 text-sm text-zinc-200">{h.jinete ?? "-"}</div>
                      <div className="px-4 py-4">
                        <div className="text-base font-semibold text-amber-300">{formatMoney(current)} Bs</div>
                        <div className={isRetirado ? "text-xs text-red-300" : "text-xs text-amber-200"}>
                          {isRetirado ? "Retirado" : leaderLabel}
                        </div>
                      </div>
                      <div className="px-4 py-4">
                        {isRetirado ? (
                          <div className="text-xs text-red-300">Caballo retirado</div>
                        ) : isAdmin ? (
                          <div className="text-xs text-zinc-500">Solo lectura (admin)</div>
                        ) : (
                          <div className="flex items-start gap-2">
                            <div className="flex-1">
                              <input
                                inputMode="decimal"
                                value={manual}
                                disabled={disabled}
                                onChange={(e) => setManualByHorse((prev) => ({ ...prev, [h.id]: e.target.value }))}
                                placeholder="Monto manual"
                                className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-white/10 disabled:opacity-60"
                              />
                              <div className="mt-1 text-[11px] text-zinc-500">
                                Puja manual mínima: {formatMoney(manualMin)} Bs
                              </div>
                            </div>
                            <button
                              disabled={disabled}
                              onClick={() => void handlePonerle(h.id, nextMin, manualMin)}
                              className="rounded-xl bg-white text-zinc-950 font-semibold px-4 py-2 text-sm disabled:opacity-60"
                            >
                              {placing === h.id ? "Rematando..." : "Ponerle"}
                            </button>
                          </div>
                        )}
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        <div className="mt-6">
          <h2 className="text-base font-semibold">Pujas</h2>

          {bids.length === 0 ? (
            <p className="mt-2 text-sm text-zinc-400">Aún no hay pujas para este remate.</p>
          ) : (
            <div className="mt-3 space-y-2">
              {bids.map((b, idx) => {
                const horse = horsesById[b.horse_id]
                const horseLabel = horse ? `#${horse.numero} ${horse.nombre}` : b.horse_id
                const username = b.username && b.username.trim() ? b.username : "Sin nombre"
                const timeLabel = formatDate(b.created_at)

                return (
                  <div
                    key={`${b.horse_id}-${b.created_at ?? idx}-${idx}`}
                    className={`rounded-xl border p-3 text-sm ${
                      b.is_me ? "border-emerald-500/40 bg-emerald-500/10" : "border-zinc-800 bg-zinc-900/60"
                    }`}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="text-zinc-200">{horseLabel}</div>
                      <div className="font-semibold text-zinc-50">{formatMoney(b.monto)} Bs</div>
                    </div>
                    <div className="mt-1 text-xs text-zinc-400">
                      {username} - {timeLabel}
                      {b.is_me ? " - Tú" : ""}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
      </main>
      {userId && !isAdmin ? <ClientBottomNav /> : null}
    </>
  )
}
