// app/admin/remates/[id]/page.tsx
"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useParams, useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

const CARACAS_TZ = "America/Caracas"

function formatDateInTz(d: Date, timeZone: string) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d)
}

function formatTimeInTz(d: Date, timeZone: string) {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(d)
}

function toCaracasDate(ts?: string | null) {
  if (!ts) return ""
  return formatDateInTz(new Date(ts), CARACAS_TZ)
}

function toCaracasTime(ts?: string | null) {
  if (!ts) return ""
  return formatTimeInTz(new Date(ts), CARACAS_TZ)
}

function buildCaracasTs(dateStr: string, timeStr: string) {
  if (!dateStr) return null
  let t = (timeStr || "").trim()
  if (!t) t = "00:00:00"
  if (t.length === 5) t = `${t}:00`
  return `${dateStr}T${t}-04:00`
}

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
  archived_at?: string | null
  cancelled_at?: string | null
  opens_at?: string | null
  closes_at?: string | null
  tipo?: string | null
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
  numero: number | string
  nombre: string
  jinete: string | null
  comentarios: string | null
  precio_salida: string | number
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

type BidRow = {
  id: string
  remate_id: string
  horse_id: string
  user_id: string
  monto: string | number
  created_at: string | null
  usuario: {
    username: string | null
    telefono: string | null
  } | null
}

type RemateDraft = {
  nombre: string
  estado: string
  incremento_minimo: string
  apuesta_minima: string
  porcentaje_casa: string
  tipo: string
  opens_date: string
  opens_time: string
  closes_date: string
  closes_time: string
}

type RaceDraft = {
  nombre: string
  hipodromo: string
  numero_carrera: string
  fecha: string
  hora_programada: string
  estado: string
}

type HorseDraft = {
  id?: string
  tempId: string
  numero: string
  nombre: string
  jinete: string
  comentarios: string
  precio_salida: string
}

type PriceRuleDraft = {
  id?: string
  tempId: string
  min_precio: string
  max_precio: string
  incremento: string
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null | undefined) {
  if (!v) return "-"
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString("es-VE")
}

function uid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  return `tmp-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

export default function AdminRemateDetailPage() {
  const router = useRouter()
  const params = useParams()
  const remateId = String((params as any)?.id || "")

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [acting, setActing] = useState<null | { action: "cerrar" | "liquidar" | "cancelar" | "archivar" }>(null)

  const [error, setError] = useState("")
  const [ok, setOk] = useState("")
  const [showLiquidar, setShowLiquidar] = useState(false)
  const [winnerNumber, setWinnerNumber] = useState("")
  const [liquidarError, setLiquidarError] = useState("")

  const [remate, setRemate] = useState<RemateRow | null>(null)
  const [closeTouched, setCloseTouched] = useState(false)
  const [race, setRace] = useState<RaceRow | null>(null)
  const [bids, setBids] = useState<BidRow[]>([])

  const [remateDraft, setRemateDraft] = useState<RemateDraft | null>(null)
  const [raceDraft, setRaceDraft] = useState<RaceDraft | null>(null)

  const [horses, setHorses] = useState<HorseDraft[]>([])
  const [deletedHorseIds, setDeletedHorseIds] = useState<string[]>([])

  const [useDefaultRules, setUseDefaultRules] = useState(true)
  const [defaultRules, setDefaultRules] = useState<PriceRuleDraft[]>([])
  const [horseRulesEnabled, setHorseRulesEnabled] = useState<Record<string, boolean>>({})
  const [horseRulesByKey, setHorseRulesByKey] = useState<Record<string, PriceRuleDraft[]>>({})

  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (pErr) throw new Error(pErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  function toRuleDraft(row: PriceRuleRow): PriceRuleDraft {
    return {
      id: row.id,
      tempId: row.id,
      min_precio: String(row.min_precio ?? ""),
      max_precio: row.max_precio === null ? "" : String(row.max_precio),
      incremento: String(row.incremento ?? ""),
    }
  }

  async function loadAll(isRefresh = false) {
    if (!remateId) return
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setOk("")

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      const { data: r, error: rErr } = await supabase
        .from("remates")
        .select(
          "id,race_id,nombre,estado,incremento_minimo,apuesta_minima,porcentaje_casa,created_at,closed_at,archived_at,cancelled_at,opens_at,closes_at,tipo"
        )
        .eq("id", remateId)
        .single()

      if (rErr) throw new Error(rErr.message)
      const rem = r as RemateRow
      setRemate(rem)
      setRemateDraft({
        nombre: rem.nombre ?? "",
        estado: rem.estado ?? "abierto",
        incremento_minimo: String(rem.incremento_minimo ?? ""),
        apuesta_minima: String(rem.apuesta_minima ?? ""),
        porcentaje_casa: String(rem.porcentaje_casa ?? ""),
        tipo: rem.tipo ?? "vivo",
        opens_date: toCaracasDate(rem.opens_at) || toCaracasDate(rem.created_at),
        opens_time: toCaracasTime(rem.opens_at) || "07:00:00",
        closes_date: toCaracasDate(rem.closes_at) || toCaracasDate(rem.closed_at) || toCaracasDate(rem.created_at),
        closes_time: toCaracasTime(rem.closes_at) || "19:00:00",
      })

      const { data: ra, error: raErr } = await supabase
        .from("races")
        .select("id,nombre,hipodromo,numero_carrera,fecha,hora_programada,estado")
        .eq("id", rem.race_id)
        .maybeSingle()

      if (raErr) throw new Error(raErr.message)
      const raceRow = ra as RaceRow
      setRace(raceRow)
      setRaceDraft({
        nombre: raceRow?.nombre ?? "",
        hipodromo: raceRow?.hipodromo ?? "",
        numero_carrera: raceRow?.numero_carrera ? String(raceRow.numero_carrera) : "",
        fecha: raceRow?.fecha ?? "",
        hora_programada: raceRow?.hora_programada ?? "",
        estado: raceRow?.estado ?? "programada",
      })

      const { data: hs, error: hsErr } = await supabase
        .from("horses")
        .select("id,race_id,numero,nombre,jinete,comentarios,precio_salida")
        .eq("race_id", rem.race_id)
        .order("numero", { ascending: true })

      if (hsErr) throw new Error(hsErr.message)
      const horseDrafts = (hs ?? []).map((h: HorseRow) => ({
        id: h.id,
        tempId: h.id,
        numero: String(h.numero ?? ""),
        nombre: h.nombre ?? "",
        jinete: h.jinete ?? "",
        comentarios: h.comentarios ?? "",
        precio_salida: String(h.precio_salida ?? ""),
      }))
      setHorses(horseDrafts)
      setDeletedHorseIds([])

      const { data: pr, error: prErr } = await supabase
        .from("remate_price_rules")
        .select("id,remate_id,horse_id,min_precio,max_precio,incremento,created_at")
        .eq("remate_id", rem.id)
        .order("min_precio", { ascending: true })

      if (prErr) throw new Error(prErr.message)

      const defaults: PriceRuleDraft[] = []
      const byHorse: Record<string, PriceRuleDraft[]> = {}

      for (const row of (pr ?? []) as PriceRuleRow[]) {
        const draft = toRuleDraft(row)
        if (!row.horse_id) defaults.push(draft)
        else {
          if (!byHorse[row.horse_id]) byHorse[row.horse_id] = []
          byHorse[row.horse_id].push(draft)
        }
      }

      setUseDefaultRules(defaults.length > 0)
      setDefaultRules(defaults)

      const enabled: Record<string, boolean> = {}
      for (const h of horseDrafts) {
        enabled[h.tempId] = (byHorse[h.tempId] ?? []).length > 0
      }
      setHorseRulesEnabled(enabled)
      setHorseRulesByKey(byHorse)

      const { data: bd, error: bdErr } = await supabase
        .from("bids")
        .select(
          `
          id,
          remate_id,
          horse_id,
          user_id,
          monto,
          created_at,
          usuario:profiles!bids_user_id_fkey(username,telefono)
        `
        )
        .eq("remate_id", rem.id)
        .order("created_at", { ascending: true })

      if (bdErr) throw new Error(bdErr.message)

      const normalized: BidRow[] = (bd ?? []).map((row: any) => ({
        id: row.id,
        remate_id: row.remate_id,
        horse_id: row.horse_id,
        user_id: row.user_id,
        monto: row.monto,
        created_at: row.created_at ?? null,
        usuario: Array.isArray(row.usuario) ? (row.usuario[0] ?? null) : (row.usuario ?? null),
      }))
      setBids(normalized)
    } catch (e: any) {
      setError(e?.message || "Error cargando el remate.")
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  useEffect(() => {
    void loadAll(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [remateId])

  function validRules(list: PriceRuleDraft[]) {
    if (!list || list.length === 0) return false
    for (const r of list) {
      const min = n(r.min_precio)
      const inc = n(r.incremento)
      const max = r.max_precio.trim() ? n(r.max_precio) : null
      if (!(min >= 0)) return false
      if (!(inc > 0)) return false
      if (max !== null && !(max > min)) return false
    }
    return true
  }

  const canSave = useMemo(() => {
    if (!remateDraft || !raceDraft) return false
    const estadoActual = String(remate?.estado || "").toLowerCase()
    if (estadoActual === "cancelado" || remate?.archived_at) return false
    if (!raceDraft.nombre.trim()) return false
    if (!raceDraft.fecha) return false
    if (!remateDraft.nombre.trim()) return false

    const inc = n(remateDraft.incremento_minimo)
    const min = n(remateDraft.apuesta_minima)
    const casa = n(remateDraft.porcentaje_casa)

    if (!(inc > 0)) return false
    if (!(min > 0)) return false
    if (!(casa >= 0 && casa <= 100)) return false

    if (!remateDraft.opens_date || !remateDraft.opens_time) return false
    if (!remateDraft.closes_date || !remateDraft.closes_time) return false
    const o = buildCaracasTs(remateDraft.opens_date, remateDraft.opens_time)
    const c = buildCaracasTs(remateDraft.closes_date, remateDraft.closes_time)
    if (!o || !c) return false
    if (new Date(o).getTime() >= new Date(c).getTime()) return false

    if (horses.length === 0) return false
    for (const h of horses) {
      if (!h.numero.trim()) return false
      if (!h.nombre.trim()) return false
      if (!h.jinete.trim()) return false
      if (!h.precio_salida.trim()) return false
      if (!(n(h.precio_salida) > 0)) return false
    }

    if (useDefaultRules && !validRules(defaultRules)) return false

    for (const h of horses) {
      if (horseRulesEnabled[h.tempId]) {
        const list = horseRulesByKey[h.tempId] || []
        if (!validRules(list)) return false
      }
    }

    return true
  }, [remateDraft, raceDraft, horses, useDefaultRules, defaultRules, horseRulesEnabled, horseRulesByKey, remate])

  function addHorse() {
    const nextNum =
      horses.length > 0 ? String(Math.max(...horses.map((h) => Number(h.numero) || 0)) + 1) : "1"
    const tempId = uid()
    setHorses((prev) => [
      ...prev,
      {
        tempId,
        numero: nextNum,
        nombre: "",
        jinete: "",
        comentarios: "",
        precio_salida: remateDraft?.apuesta_minima || "",
      },
    ])
    setHorseRulesEnabled((prev) => ({ ...prev, [tempId]: false }))
  }

  function updateHorse(tempId: string, patch: Partial<HorseDraft>) {
    setHorses((prev) => prev.map((h) => (h.tempId === tempId ? { ...h, ...patch } : h)))
  }

  function removeHorse(tempId: string) {
    const target = horses.find((h) => h.tempId === tempId)
    if (target?.id) {
      setDeletedHorseIds((prev) => [...prev, target.id as string])
    }
    setHorses((prev) => prev.filter((h) => h.tempId !== tempId))
    setHorseRulesEnabled((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
    setHorseRulesByKey((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
  }

  function addRule(setter: React.Dispatch<React.SetStateAction<PriceRuleDraft[]>>) {
    setter((prev) => [...prev, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }])
  }

  function updateRule(
    setter: React.Dispatch<React.SetStateAction<PriceRuleDraft[]>>,
    tempId: string,
    patch: Partial<PriceRuleDraft>
  ) {
    setter((prev) => prev.map((r) => (r.tempId === tempId ? { ...r, ...patch } : r)))
  }

  function removeRule(setter: React.Dispatch<React.SetStateAction<PriceRuleDraft[]>>, tempId: string) {
    setter((prev) => prev.filter((r) => r.tempId !== tempId))
  }

  function addHorseRule(horseKey: string) {
    setHorseRulesByKey((prev) => {
      const list = prev[horseKey] || []
      return { ...prev, [horseKey]: [...list, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }] }
    })
  }

  function updateHorseRule(horseKey: string, ruleTempId: string, patch: Partial<PriceRuleDraft>) {
    setHorseRulesByKey((prev) => {
      const list = prev[horseKey] || []
      return { ...prev, [horseKey]: list.map((r) => (r.tempId === ruleTempId ? { ...r, ...patch } : r)) }
    })
  }

  function removeHorseRule(horseKey: string, ruleTempId: string) {
    setHorseRulesByKey((prev) => {
      const list = prev[horseKey] || []
      return { ...prev, [horseKey]: list.filter((r) => r.tempId !== ruleTempId) }
    })
  }

  async function saveAll() {
    setError("")
    setOk("")

    if (!canSave) {
      setError("Revisa los campos: hay datos faltantes o invalidos.")
      return
    }

    if (!remate || !race || !remateDraft || !raceDraft) {
      setError("No se pudo cargar el remate.")
      return
    }

    setSaving(true)

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      const raceUpdate: any = {
        nombre: raceDraft.nombre.trim(),
        fecha: raceDraft.fecha,
        estado: raceDraft.estado.trim() || race.estado,
      }
      raceUpdate.hipodromo = raceDraft.hipodromo.trim() ? raceDraft.hipodromo.trim() : null
      raceUpdate.numero_carrera = raceDraft.numero_carrera.trim() ? Number(raceDraft.numero_carrera) : null
      raceUpdate.hora_programada = raceDraft.hora_programada.trim() ? raceDraft.hora_programada.trim() : null

      const { error: raceErr } = await supabase.from("races").update(raceUpdate).eq("id", race.id)
      if (raceErr) throw new Error(raceErr.message)

      const remateUpdate: any = {
        nombre: remateDraft.nombre.trim(),
        estado: remateDraft.estado.trim() || remate.estado,
        incremento_minimo: n(remateDraft.incremento_minimo),
        apuesta_minima: n(remateDraft.apuesta_minima),
        porcentaje_casa: n(remateDraft.porcentaje_casa),
        tipo: remateDraft.tipo || remate.tipo || "vivo",
        opens_at: buildCaracasTs(remateDraft.opens_date, remateDraft.opens_time),
        closes_at: buildCaracasTs(remateDraft.closes_date, remateDraft.closes_time),
      }
      const { error: remErr } = await supabase.from("remates").update(remateUpdate).eq("id", remate.id)
      if (remErr) throw new Error(remErr.message)

      if (deletedHorseIds.length > 0) {
        const { error: delErr } = await supabase.from("horses").delete().in("id", deletedHorseIds)
        if (delErr) throw new Error(delErr.message)
      }

      const newIdByTemp: Record<string, string> = {}
      for (const h of horses) {
        if (h.id) {
          const { error: hErr } = await supabase
            .from("horses")
            .update({
              numero: Number(h.numero),
              nombre: h.nombre.trim(),
              jinete: h.jinete.trim(),
              comentarios: h.comentarios.trim() ? h.comentarios.trim() : null,
              precio_salida: n(h.precio_salida),
            })
            .eq("id", h.id)
          if (hErr) throw new Error(hErr.message)
        } else {
          const { data: hData, error: hErr } = await supabase
            .from("horses")
            .insert({
              race_id: remate.race_id,
              numero: Number(h.numero),
              nombre: h.nombre.trim(),
              jinete: h.jinete.trim(),
              comentarios: h.comentarios.trim() ? h.comentarios.trim() : null,
              precio_salida: n(h.precio_salida),
            })
            .select("id")
            .single()
          if (hErr) throw new Error(hErr.message)
          newIdByTemp[h.tempId] = hData.id as string
        }
      }

      const rulesPayload: any[] = []

      if (useDefaultRules && defaultRules.length > 0) {
        for (const r of defaultRules) {
          rulesPayload.push({
            remate_id: remate.id,
            horse_id: null,
            min_precio: n(r.min_precio),
            max_precio: r.max_precio.trim() ? n(r.max_precio) : null,
            incremento: n(r.incremento),
          })
        }
      }

      for (const [horseKey, list] of Object.entries(horseRulesByKey)) {
        if (!horseRulesEnabled[horseKey]) continue
        if (!list || list.length === 0) continue

        const resolvedHorseId = newIdByTemp[horseKey] || horseKey
        for (const r of list) {
          rulesPayload.push({
            remate_id: remate.id,
            horse_id: resolvedHorseId,
            min_precio: n(r.min_precio),
            max_precio: r.max_precio.trim() ? n(r.max_precio) : null,
            incremento: n(r.incremento),
          })
        }
      }

      const { error: rulesDelErr } = await supabase.from("remate_price_rules").delete().eq("remate_id", remate.id)
      if (rulesDelErr) throw new Error(rulesDelErr.message)

      if (rulesPayload.length > 0) {
        const { error: rulesInsErr } = await supabase.from("remate_price_rules").insert(rulesPayload)
        if (rulesInsErr) throw new Error(rulesInsErr.message)
      }

      setOk("Cambios guardados.")
      await loadAll(true)
    } catch (e: any) {
      setError(e?.message || "Error guardando cambios.")
    } finally {
      setSaving(false)
    }
  }

  async function cerrarRemate() {
    if (!remate) return
    setActing({ action: "cerrar" })
    setError("")
    setOk("")

    try {
      const yes = window.confirm("Cerrar este remate (lo marca como cerrado)")
      if (!yes) return

      const { data, error: rpcErr } = await supabase.rpc("cerrar_remate", { p_remate_id: remate.id })
      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate cerrado.")
      await loadAll(true)
    } catch (e: any) {
      setError(e?.message || "Error cerrando remate.")
    } finally {
      setActing(null)
    }
  }

  async function cancelarRemate() {
    if (!remate) return
    setActing({ action: "cancelar" })
    setError("")
    setOk("")

    try {
      const confirmTxt = window.prompt("Escribe CANCELAR para confirmar la cancelación del remate")
      if (confirmTxt !== "CANCELAR") return

      const motivo = window.prompt("Motivo de cancelación (obligatorio)")
      if (!motivo || !motivo.trim()) {
        setError("Debes indicar un motivo para cancelar el remate.")
        return
      }

      const { data, error: rpcErr } = await supabase.rpc("cancelar_remate", {
        p_remate_id: remate.id,
        p_motivo: motivo.trim(),
      })
      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate cancelado.")
      await loadAll(true)
    } catch (e: any) {
      setError(e?.message || "Error cancelando remate.")
    } finally {
      setActing(null)
    }
  }

  async function archivarRemate() {
    if (!remate) return
    setActing({ action: "archivar" })
    setError("")
    setOk("")

    try {
      const motivo = window.prompt("Motivo de archivo (obligatorio)")
      if (!motivo || !motivo.trim()) {
        setError("Debes indicar un motivo para archivar el remate.")
        return
      }

      const yes = window.confirm("Archivar este remate (quedará solo en histórico)")
      if (!yes) return

      const { data, error: rpcErr } = await supabase.rpc("archivar_remate", {
        p_remate_id: remate.id,
        p_motivo: motivo.trim(),
      })
      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate archivado.")
      await loadAll(true)
    } catch (e: any) {
      setError(e?.message || "Error archivando remate.")
    } finally {
      setActing(null)
    }
  }

  async function liquidarRemate() {
    if (!remate) return
    setWinnerNumber("")
    setLiquidarError("")
    setShowLiquidar(true)
  }

  async function confirmLiquidarRemate() {
    if (!remate) return
    setLiquidarError("")
    setError("")
    setOk("")

    const num = Number(winnerNumber)
    if (!Number.isFinite(num) || num <= 0 || !Number.isInteger(num)) {
      setLiquidarError("Ingresa el numero del caballo ganador.")
      return
    }

    const horse = horses.find((h) => Number(h.numero) === num)
    if (!horse) {
      setLiquidarError("No existe un caballo con ese numero en esta carrera.")
      return
    }

    setActing({ action: "liquidar" })

    try {
      const { error: setErr } = await supabase.rpc("set_ganador_carrera", {
        p_remate_id: remate.id,
        p_horse_num: num,
      })
      if (setErr) throw new Error(setErr.message)

      const { error: rpcErr } = await supabase.rpc("liquidar_remate", { p_remate_id: remate.id })
      if (rpcErr) throw new Error(rpcErr.message)

      const top = horse.id ? (topByHorse.get(horse.id) ?? null) : null
      const ganadorLabel = top?.usuario?.username
        ? top.usuario.username
        : top
          ? `${top.user_id.slice(0, 8)}...`
          : "Casa"
      const premio = top ? totals.neto : 0
      const resumen = [
        "Remate liquidado.",
        `Ganador: #${horse.numero} ${horse.nombre} - ${ganadorLabel}`,
        `Pozo total: ${formatMoney(totals.bruto)} Bs`,
        `Casa 25%: ${formatMoney(totals.casa)} Bs`,
        `Premio: ${formatMoney(premio)} Bs`,
      ].join("\n")

      setShowLiquidar(false)
      await loadAll(true)
      setOk(resumen)
    } catch (e: any) {
      setLiquidarError(e?.message || "Error liquidando remate.")
    } finally {
      setActing(null)
    }
  }

  const topByHorse = useMemo(() => {
    const map = new Map<string, BidRow>()
    for (const b of bids) {
      const prev = map.get(b.horse_id)
      if (!prev) {
        map.set(b.horse_id, b)
        continue
      }
      const a = n(prev.monto)
      const c = n(b.monto)
      if (c > a) {
        map.set(b.horse_id, b)
      } else if (c === a) {
        const tPrev = prev.created_at ? new Date(prev.created_at).getTime() : Number.MAX_SAFE_INTEGER
        const tNew = b.created_at ? new Date(b.created_at).getTime() : Number.MAX_SAFE_INTEGER
        if (tNew < tPrev) map.set(b.horse_id, b)
      }
    }
    return map
  }, [bids])

  const totals = useMemo(() => {
    let bruto = 0
    for (const h of horses) {
      const bid = h.id ? topByHorse.get(h.id) : undefined
      bruto += bid ? n(bid.monto) : n(h.precio_salida)
    }
    const casaPct = 25
    const casa = (bruto * casaPct) / 100
    const neto = bruto - casa
    return { bruto, casa, neto }
  }, [topByHorse, horses])

  const raceInfo = raceDraft ?? race
  const raceLabel = raceInfo
    ? `${raceInfo.hipodromo ?? "Hipodromo"} - Carrera #${raceInfo.numero_carrera ?? "-"} - ${raceInfo.fecha || ""}${
        raceInfo.hora_programada ? ` ${raceInfo.hora_programada}` : ""
      }`.trim()
    : "Carrera"

  if (loading) {
    return <div className="min-h-dvh flex items-center justify-center text-zinc-50">Cargando remate...</div>
  }

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50">
      <div className="mx-auto w-full max-w-5xl px-4 py-6">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold">Panel admin - Remate</h1>
            <p className="mt-1 text-sm text-zinc-300">
              Edita carrera, remate, caballos y reglas. Cierra o liquida cuando corresponda.
            </p>
          </div>
          <Link href="/admin/remates" className="text-sm text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <div className="mt-4 flex flex-wrap gap-2">
          <button
            onClick={() => void loadAll(true)}
            disabled={refreshing}
            className="rounded-xl bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-sm disabled:opacity-60"
          >
            {refreshing ? "Actualizando..." : "Actualizar"}
          </button>

          <button
            onClick={() => void saveAll()}
            disabled={!canSave || saving}
            className="rounded-xl bg-white text-zinc-950 px-4 py-2 text-sm font-semibold disabled:opacity-60"
          >
            {saving ? "Guardando..." : "Guardar cambios"}
          </button>

          <button
            onClick={() => void cerrarRemate()}
            disabled={acting?.action === "cerrar" || String(remate?.estado || "").toLowerCase() !== "abierto"}
            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-4 py-2 text-sm font-semibold disabled:opacity-60"
          >
            {acting?.action === "cerrar" ? "Cerrando..." : "Cerrar remate"}
          </button>

          <button
            onClick={() => void cancelarRemate()}
            disabled={acting?.action === "cancelar" || String(remate?.estado || "").toLowerCase() !== "abierto"}
            className="rounded-xl bg-red-500/10 text-red-200 border border-red-500/30 px-4 py-2 text-sm font-semibold disabled:opacity-60"
          >
            {acting?.action === "cancelar" ? "Cancelando..." : "Cancelar remate"}
          </button>

          <button
            onClick={() => void liquidarRemate()}
            disabled={acting?.action === "liquidar" || String(remate?.estado || "").toLowerCase() !== "cerrado"}
            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-4 py-2 text-sm font-semibold disabled:opacity-60"
            title={
              String(remate?.estado || "").toLowerCase() !== "cerrado"
                ? "Solo puedes liquidar remates cerrados"
                : ""
            }
          >
            {acting?.action === "liquidar" ? "Liquidando..." : "Liquidar remate"}
          </button>

          <button
            onClick={() => void archivarRemate()}
            disabled={acting?.action === "archivar" || String(remate?.estado || "").toLowerCase() === "abierto" || !!remate?.archived_at}
            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-4 py-2 text-sm font-semibold disabled:opacity-60"
          >
            {acting?.action === "archivar" ? "Archivando..." : "Archivar"}
          </button>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20 whitespace-pre-line">
            {ok}
          </div>
        ) : null}

        {showLiquidar ? (
          <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4">
            <div className="w-full max-w-md rounded-2xl bg-zinc-950 border border-zinc-800 p-4">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <h2 className="text-base font-semibold">Liquidar remate</h2>
                  <p className="mt-1 text-xs text-zinc-400">{raceLabel}</p>
                </div>
                <button
                  onClick={() => setShowLiquidar(false)}
                  className="text-xs text-zinc-400 underline underline-offset-4"
                >
                  Cerrar
                </button>
              </div>

              <div className="mt-4">
                <label className="text-xs text-zinc-400">Caballo ganador</label>
                <select
                  value={winnerNumber}
                  onChange={(e) => setWinnerNumber(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-900/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="">Selecciona el caballo ganador...</option>
                  {horses
                    .slice()
                    .sort((a, b) => Number(a.numero) - Number(b.numero))
                    .map((h) => (
                      <option key={h.tempId} value={String(h.numero)}>
                        #{h.numero} - {h.nombre}
                        {h.jinete ? ` (J: ${h.jinete})` : ""}
                      </option>
                    ))}
                </select>
              </div>

              {liquidarError ? (
                <div className="mt-3 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
                  {liquidarError}
                </div>
              ) : null}

              <div className="mt-4 flex gap-2">
                <button
                  onClick={() => setShowLiquidar(false)}
                  className="flex-1 rounded-xl bg-zinc-900/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  Cancelar
                </button>
                <button
                  onClick={() => void confirmLiquidarRemate()}
                  disabled={acting?.action === "liquidar"}
                  className="flex-1 rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                >
                  {acting?.action === "liquidar" ? "Liquidando..." : "Confirmar"}
                </button>
              </div>
            </div>
          </div>
        ) : null}

        <section className="mt-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">1) Carrera</h2>

          <div className="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
            <div>
              <label className="text-xs text-zinc-400">Descripcion de la carrera</label>
              <input
                value={raceDraft?.nombre ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, nombre: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Hipodromo</label>
              <input
                value={raceDraft?.hipodromo ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, hipodromo: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">No. carrera</label>
              <input
                inputMode="numeric"
                value={raceDraft?.numero_carrera ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, numero_carrera: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Estado</label>
              <input
                value={raceDraft?.estado ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, estado: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Fecha</label>
              <input
                type="date"
                value={raceDraft?.fecha ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, fecha: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Hora (opcional)</label>
              <input
                type="time"
                value={raceDraft?.hora_programada ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, hora_programada: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>
          </div>
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">2) Remate</h2>

          <div className="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
            <div>
              <label className="text-xs text-zinc-400">Nombre</label>
              <input
                value={remateDraft?.nombre ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, nombre: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Estado</label>
              <select
                value={remateDraft?.estado ?? "abierto"}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, estado: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              >
                <option value="abierto">abierto</option>
                <option value="cerrado">cerrado</option>
                <option value="liquidado">liquidado</option>
              </select>
            </div>

            <div>
              <label className="text-xs text-zinc-400">Apuesta minima</label>
              <input
                inputMode="decimal"
                value={remateDraft?.apuesta_minima ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, apuesta_minima: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Incremento minimo</label>
              <input
                inputMode="decimal"
                value={remateDraft?.incremento_minimo ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, incremento_minimo: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">% casa</label>
              <input
                inputMode="decimal"
                value={remateDraft?.porcentaje_casa ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, porcentaje_casa: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Tipo</label>
              <select
                value={remateDraft?.tipo ?? "vivo"}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, tipo: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              >
                <option value="vivo">En vivo</option>
                <option value="adelantado">Adelantado</option>
              </select>
            </div>

            <div>
              <label className="text-xs text-zinc-400">Apertura (fecha)</label>
              <input
                type="date"
                value={remateDraft?.opens_date ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, opens_date: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Apertura (hora)</label>
              <input
                value={remateDraft?.opens_time ?? ""}
                onChange={(e) => setRemateDraft((prev) => (prev ? { ...prev, opens_time: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="07:00:00"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Cierre (fecha)</label>
              <input
                type="date"
                value={remateDraft?.closes_date ?? ""}
                onChange={(e) => {
                  setCloseTouched(true)
                  setRemateDraft((prev) => (prev ? { ...prev, closes_date: e.target.value } : prev))
                }}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div>
              <label className="text-xs text-zinc-400">Cierre (hora)</label>
              <input
                value={remateDraft?.closes_time ?? ""}
                onChange={(e) => {
                  setCloseTouched(true)
                  setRemateDraft((prev) => (prev ? { ...prev, closes_time: e.target.value } : prev))
                }}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="19:00:00"
              />
            </div>
            <div className="md:col-span-2 text-[11px] text-zinc-500">
              Horario Venezuela (America/Caracas).
            </div>
          </div>
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between gap-3">
            <h2 className="text-base font-semibold">3) Caballos</h2>
            <button
              onClick={() => addHorse()}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
            >
              + Agregar caballo
            </button>
          </div>

          {horses.length === 0 ? (
            <div className="mt-3 text-sm text-zinc-400">No hay caballos en esta carrera.</div>
          ) : (
            <div className="mt-4 space-y-4">
              {horses.map((h) => (
                <div key={h.tempId} className="rounded-2xl bg-zinc-950/50 border border-zinc-800 p-4">
                  <div className="flex items-center justify-between gap-3">
                    <div className="text-sm font-semibold">Caballo</div>
                    <button
                      onClick={() => removeHorse(h.tempId)}
                      className="rounded-xl bg-red-500/10 text-red-200 ring-1 ring-red-500/20 px-3 py-1 text-xs"
                    >
                      Quitar
                    </button>
                  </div>

                  <div className="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
                    <div>
                      <label className="text-xs text-zinc-400">No.</label>
                      <input
                        inputMode="numeric"
                        value={h.numero}
                        onChange={(e) => updateHorse(h.tempId, { numero: e.target.value })}
                        className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      />
                    </div>

                    <div>
                      <label className="text-xs text-zinc-400">Nombre</label>
                      <input
                        value={h.nombre}
                        onChange={(e) => updateHorse(h.tempId, { nombre: e.target.value })}
                        className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      />
                    </div>

                    <div>
                      <label className="text-xs text-zinc-400">Jinete</label>
                      <input
                        value={h.jinete}
                        onChange={(e) => updateHorse(h.tempId, { jinete: e.target.value })}
                        className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      />
                    </div>

                    <div>
                      <label className="text-xs text-zinc-400">Precio salida</label>
                      <input
                        inputMode="decimal"
                        value={h.precio_salida}
                        onChange={(e) => updateHorse(h.tempId, { precio_salida: e.target.value })}
                        className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      />
                    </div>

                    <div className="md:col-span-2">
                      <label className="text-xs text-zinc-400">Comentario (opcional)</label>
                      <input
                        value={h.comentarios}
                        onChange={(e) => updateHorse(h.tempId, { comentarios: e.target.value })}
                        className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      />
                    </div>
                  </div>

                  <div className="mt-4 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                    <div className="flex items-center justify-between gap-3">
                      <div className="text-sm font-semibold">Reglas propias</div>
                      <label className="text-xs text-zinc-300 flex items-center gap-2">
                        <input
                          type="checkbox"
                          checked={!!horseRulesEnabled[h.tempId]}
                          onChange={(e) =>
                            setHorseRulesEnabled((prev) => ({ ...prev, [h.tempId]: e.target.checked }))
                          }
                        />
                        Activar
                      </label>
                    </div>

                    {!horseRulesEnabled[h.tempId] ? (
                      <div className="mt-2 text-xs text-zinc-400">Usa reglas default si existen.</div>
                    ) : (
                      <>
                        <div className="mt-3 grid grid-cols-4 gap-2 text-xs text-zinc-500">
                          <div>Min</div>
                          <div>Max (opcional)</div>
                          <div>Incremento</div>
                          <div>Accion</div>
                        </div>

                        <div className="mt-2 space-y-2">
                          {(horseRulesByKey[h.tempId] || []).map((r) => (
                            <div key={r.tempId} className="grid grid-cols-4 gap-2">
                              <input
                                inputMode="decimal"
                                value={r.min_precio}
                                onChange={(e) => updateHorseRule(h.tempId, r.tempId, { min_precio: e.target.value })}
                                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                              />
                              <input
                                inputMode="decimal"
                                value={r.max_precio}
                                onChange={(e) => updateHorseRule(h.tempId, r.tempId, { max_precio: e.target.value })}
                                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                                placeholder="Max"
                              />
                              <input
                                inputMode="decimal"
                                value={r.incremento}
                                onChange={(e) => updateHorseRule(h.tempId, r.tempId, { incremento: e.target.value })}
                                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                              />
                              <button
                                onClick={() => removeHorseRule(h.tempId, r.tempId)}
                                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                              >
                                Quitar
                              </button>
                            </div>
                          ))}
                        </div>

                        <button
                          onClick={() => addHorseRule(h.tempId)}
                          className="mt-3 rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                        >
                          + Agregar rango
                        </button>
                      </>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between gap-3">
            <h2 className="text-base font-semibold">4) Reglas default</h2>
            <label className="text-xs text-zinc-300 flex items-center gap-2">
              <input
                type="checkbox"
                checked={useDefaultRules}
                onChange={(e) => setUseDefaultRules(e.target.checked)}
              />
              Usar reglas default
            </label>
          </div>

          {!useDefaultRules ? (
            <div className="mt-2 text-xs text-zinc-400">Sin reglas default. Cada caballo debe tener reglas propias.</div>
          ) : (
            <>
              <div className="mt-3 grid grid-cols-4 gap-2 text-xs text-zinc-500">
                <div>Min</div>
                <div>Max (opcional)</div>
                <div>Incremento</div>
                <div>Accion</div>
              </div>

              <div className="mt-2 space-y-2">
                {defaultRules.map((r) => (
                  <div key={r.tempId} className="grid grid-cols-4 gap-2">
                    <input
                      inputMode="decimal"
                      value={r.min_precio}
                      onChange={(e) => updateRule(setDefaultRules, r.tempId, { min_precio: e.target.value })}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    />
                    <input
                      inputMode="decimal"
                      value={r.max_precio}
                      onChange={(e) => updateRule(setDefaultRules, r.tempId, { max_precio: e.target.value })}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="Max"
                    />
                    <input
                      inputMode="decimal"
                      value={r.incremento}
                      onChange={(e) => updateRule(setDefaultRules, r.tempId, { incremento: e.target.value })}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    />
                    <button
                      onClick={() => removeRule(setDefaultRules, r.tempId)}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    >
                      Quitar
                    </button>
                  </div>
                ))}
              </div>

              <button
                onClick={() => addRule(setDefaultRules)}
                className="mt-3 rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              >
                + Agregar rango
              </button>
            </>
          )}
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">5) Resumen en vivo</h2>

          <div className="mt-3 grid grid-cols-1 md:grid-cols-3 gap-2">
            <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Pozo bruto</div>
              <div className="mt-1 text-lg font-semibold">{formatMoney(totals.bruto)} Bs</div>
            </div>
            <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Casa</div>
              <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(totals.casa)} Bs</div>
            </div>
            <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Neto</div>
              <div className="mt-1 text-lg font-semibold text-emerald-300">{formatMoney(totals.neto)} Bs</div>
            </div>
          </div>

          <div className="mt-4 text-sm font-semibold">Caballos y ganador actual</div>
          {horses.length === 0 ? (
            <div className="mt-2 text-sm text-zinc-400">No hay caballos cargados.</div>
          ) : (
            <div className="mt-3 space-y-2">
              {horses.map((h) => {
                const top = topByHorse.get(h.id || "") || null
                const monto = top ? n(top.monto) : 0
                const username = top?.usuario?.username ?? (top ? top.user_id.slice(0, 8) + "..." : "Casa")
                const tel = top?.usuario?.telefono ?? "-"
                return (
                  <div key={h.tempId} className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold">
                          Caballo #{h.numero} - {h.nombre}
                        </div>
                        <div className="mt-1 text-xs text-zinc-400">
                          Va ganando: <span className="text-zinc-200 font-medium">{username}</span> - Tel: {tel}
                        </div>
                        <div className="mt-1 text-xs text-zinc-400">
                          Puja actual: <span className="text-zinc-200 font-semibold">{formatMoney(monto)} Bs</span>
                          {top?.created_at ? <span className="text-zinc-500"> - {formatDT(top.created_at)}</span> : null}
                        </div>
                      </div>
                      <div className="text-xs text-zinc-500">{top ? "Puja" : "Sin pujas"}</div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">6) Ultimas pujas</h2>
          {bids.length === 0 ? (
            <div className="mt-2 text-sm text-zinc-400">Sin pujas aun.</div>
          ) : (
            <div className="mt-3 space-y-2">
              {[...bids].slice(-20).reverse().map((b) => (
                <div key={b.id} className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3 text-sm">
                  <div className="flex items-center justify-between gap-3">
                    <div>
                      <div className="text-zinc-200 font-medium">
                        {b.usuario?.username ?? b.user_id.slice(0, 8) + "..."} - {formatMoney(b.monto)} Bs
                      </div>
                      <div className="text-xs text-zinc-500">
                        Caballo: {b.horse_id.slice(0, 6)}... - {formatDT(b.created_at)}
                      </div>
                    </div>
                    <div className="text-xs text-zinc-500">{b.usuario?.telefono ?? "-"}</div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  )
}
