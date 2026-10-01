// app/admin/remates/[id]/page.tsx
"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useParams, useRouter } from "next/navigation"
import { useSenal, topicoRemate, EVENTOS_REMATE } from "@/lib/realtime"
import { supabase } from "@/lib/supabaseClient"
import SelectorFechaHora, { nombreDiaDeIso } from "@/app/components/SelectorFechaHora"
// La misma escalera que crear-remate, no una copia (ADR-015).
import {
  type PriceRuleDraft,
  type RitmoEscalera,
  ETIQUETA_RITMO,
  RITMOS,
  generarEscalera,
  simularPujas,
  problemasEscalera,
} from "@/lib/escalera"

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

function weekdayInTz(d: Date, timeZone: string) {
  return new Intl.DateTimeFormat("es-VE", { timeZone, weekday: "long" }).format(d)
}

function splitIsoDate(dateIso: string) {
  if (!dateIso) return { dd: "", mm: "", yy: "" }
  const parts = dateIso.split("-")
  if (parts.length !== 3) return { dd: "", mm: "", yy: "" }
  return { dd: parts[2], mm: parts[1], yy: parts[0].slice(-2) }
}

function parseDateParts(ddRaw: string, mmRaw: string, yyRaw: string) {
  const dd = ddRaw.trim().padStart(2, "0")
  const mm = mmRaw.trim().padStart(2, "0")
  const yy = yyRaw.trim().padStart(2, "0")
  const d = Number(dd)
  const m = Number(mm)
  const y = Number(yy)
  if (!Number.isFinite(d) || !Number.isFinite(m) || !Number.isFinite(y)) return ""
  if (d < 1 || d > 31) return ""
  if (m < 1 || m > 12) return ""
  const yyyy = `20${yy}`
  return `${yyyy}-${mm}-${dd}`
}

function formatTime12hFrom24(time24: string) {
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

function parseTime12hTo24(raw: string) {
  const s = String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ")
  const m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/)
  if (!m) return ""
  let h = Number(m[1])
  const mins = m[2] ?? "00"
  const ap = m[3]
  if (!Number.isFinite(h) || h < 1 || h > 12) return ""
  const mm = Number(mins)
  if (!Number.isFinite(mm) || mm < 0 || mm > 59) return ""
  if (ap === "pm" && h !== 12) h += 12
  if (ap === "am" && h === 12) h = 0
  const hh = String(h).padStart(2, "0")
  const min = String(mm).padStart(2, "0")
  return `${hh}:${min}:00`
}

function toCaracasDateParts(ts?: string | null) {
  if (!ts) return { dd: "", mm: "", yy: "" }
  const iso = formatDateInTz(new Date(ts), CARACAS_TZ)
  return splitIsoDate(iso)
}

function toCaracasTime12(ts?: string | null) {
  if (!ts) return ""
  const time24 = formatTimeInTz(new Date(ts), CARACAS_TZ)
  return formatTime12hFrom24(time24)
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
  numero: number | string
  nombre: string
  jinete: string | null
  comentarios: string | null
  precio_salida: string | number
  retirado?: boolean | null
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
  estado: string
  incremento_minimo: string
  porcentaje_casa: string
  tipo: string
  opens_dd: string
  opens_mm: string
  opens_aa: string
  opens_time: string
  closes_dd: string
  closes_mm: string
  closes_aa: string
  closes_time: string
}

type RaceDraft = {
  descripcion: string
  hipodromo: string
  numero_carrera_text: string
  dia: string
  distancia_m: string
  fecha_dd: string
  fecha_mm: string
  fecha_aa: string
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
  retirado?: boolean
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

function formatDateShort(iso: string | null | undefined) {
  if (!iso) return ""
  const parts = iso.split("-")
  if (parts.length !== 3) return iso
  return `${parts[2]}/${parts[1]}/${parts[0].slice(-2)}`
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
  // Hubo movimiento en el remate mientras esta pantalla estaba abierta.
  const [hayCambios, setHayCambios] = useState(false)
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

  // =========================================================================
  //  LA ESCALERA GENERAL SE FUE DE AQUI TAMBIEN (01/10/2026)
  //
  //  Habia una seccion "4) Escalera para los caballos sin reglas propias" con
  //  su casilla y su tabla. Era CODIGO MUERTO y vale la pena entender por que,
  //  porque no se ve de un vistazo:
  //
  //  al cargar el remate, `useDefaultRules` se ponia en
  //  `defaults.length > 0`, donde `defaults` eran las filas de
  //  remate_price_rules con `horse_id` NULO. Desde la migracion
  //  20260930100000 esa columna es NOT NULL, asi que esas filas no pueden
  //  existir: la casilla salia siempre apagada y la expansion del guardado
  //  nunca se ejecutaba.
  //
  //  Un control que no puede hacer nada es peor que no tenerlo: promete una
  //  funcion que no existe. Fuera.
  //
  //  La regla general es ahora `remates.incremento_minimo`, un numero.
  // =========================================================================
  const [horseRulesEnabled, setHorseRulesEnabled] = useState<Record<string, boolean>>({})
  const [horseRulesByKey, setHorseRulesByKey] = useState<Record<string, PriceRuleDraft[]>>({})

  // Ritmo y estado de la escalera propia de cada caballo. Mismo mecanismo que
  // en crear-remate: se elige un ritmo, se genera desde el precio de salida DE
  // ESE caballo, y la tabla cruda queda detras de un enlace para quien quiera
  // algo raro.
  const [horseRitmo, setHorseRitmo] = useState<Record<string, RitmoEscalera>>({})
  const [horseEscaleraTocada, setHorseEscaleraTocada] = useState<Record<string, boolean>>({})
  const [horseTablaAbierta, setHorseTablaAbierta] = useState<Record<string, boolean>>({})

  // Los minimos los pone la instalacion (migracion 20261001100000). La base los
  // defiende con triggers; esta pantalla los lee para avisar ANTES de guardar.
  const [minIncremento, setMinIncremento] = useState<number | null>(null)
  const [minSalida, setMinSalida] = useState<number | null>(null)

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
          "id,race_id,nombre,estado,incremento_minimo,porcentaje_casa,created_at,closed_at,archived_at,cancelled_at,opens_at,closes_at,tipo"
        )
        .eq("id", remateId)
        .single()

      if (rErr) throw new Error(rErr.message)
      const rem = r as RemateRow
      setRemate(rem)
      const openTs = rem.opens_at || rem.created_at
      const closeTs = rem.closes_at || rem.closed_at || rem.created_at
      const openParts = toCaracasDateParts(openTs)
      const closeParts = toCaracasDateParts(closeTs)
      setRemateDraft({
        estado: rem.estado ?? "abierto",
        incremento_minimo: String(rem.incremento_minimo ?? ""),
        porcentaje_casa: String(rem.porcentaje_casa ?? ""),
        tipo: rem.tipo ?? "vivo",
        opens_dd: openParts.dd,
        opens_mm: openParts.mm,
        opens_aa: openParts.yy,
        // Vacio si la base lo tiene vacio. Antes caia en "7:00 am" / "7:00 pm",
        // asi que un remate SIN cierre se iba con un cierre inventado en cuanto
        // alguien abria esta pantalla y guardaba cualquier otro cambio.
        opens_time: toCaracasTime12(rem.opens_at) || "",
        closes_dd: closeParts.dd,
        closes_mm: closeParts.mm,
        closes_aa: closeParts.yy,
        closes_time: toCaracasTime12(rem.closes_at) || "",
      })

      const { data: ra, error: raErr } = await supabase
        .from("races")
        .select("id,nombre,hipodromo,numero_carrera,numero_carrera_text,dia,distancia_m,fecha,hora_programada,estado")
        .eq("id", rem.race_id)
        .maybeSingle()

      if (raErr) throw new Error(raErr.message)
      const raceRow = ra as RaceRow
      setRace(raceRow)
      const raceFechaParts = splitIsoDate(raceRow?.fecha ?? "")
      const hora12 = raceRow?.hora_programada ? formatTime12hFrom24(raceRow.hora_programada) : ""
      setRaceDraft({
        descripcion: raceRow?.nombre ?? "",
        hipodromo: raceRow?.hipodromo ?? "",
        numero_carrera_text:
          raceRow?.numero_carrera_text ?? (raceRow?.numero_carrera ? String(raceRow.numero_carrera) : ""),
        dia: raceRow?.dia ?? "",
        distancia_m: raceRow?.distancia_m != null ? String(raceRow.distancia_m) : "",
        fecha_dd: raceFechaParts.dd,
        fecha_mm: raceFechaParts.mm,
        fecha_aa: raceFechaParts.yy,
        hora_programada: hora12,
        estado: raceRow?.estado ?? "programada",
      })

      const { data: hs, error: hsErr } = await supabase
        .from("horses")
        .select("id,race_id,numero,nombre,jinete,comentarios,precio_salida,retirado")
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
        retirado: !!h.retirado,
      }))
      setHorses(horseDrafts)
      setDeletedHorseIds([])

      const { data: pr, error: prErr } = await supabase
        .from("remate_price_rules")
        .select("id,remate_id,horse_id,min_precio,max_precio,incremento,created_at")
        .eq("remate_id", rem.id)
        .order("min_precio", { ascending: true })

      if (prErr) throw new Error(prErr.message)

      // Toda regla pertenece a un caballo: `horse_id` es NOT NULL desde la
      // migracion 20260930100000. Si alguna vez apareciera una fila sin
      // caballo seria un dato imposible, asi que se avisa en consola en vez
      // de ignorarla en silencio.
      const byHorse: Record<string, PriceRuleDraft[]> = {}

      for (const row of (pr ?? []) as PriceRuleRow[]) {
        if (!row.horse_id) {
          console.warn("[escalera] regla sin horse_id, imposible desde 20260930100000:", row.id)
          continue
        }
        const draft = toRuleDraft(row)
        if (!byHorse[row.horse_id]) byHorse[row.horse_id] = []
        byHorse[row.horse_id].push(draft)
      }

      const enabled: Record<string, boolean> = {}
      for (const h of horseDrafts) {
        enabled[h.tempId] = (byHorse[h.tempId] ?? []).length > 0
      }
      setHorseRulesEnabled(enabled)
      setHorseRulesByKey(byHorse)
      // Las escaleras que ya estaban guardadas se respetan tal cual: se marcan
      // como "tocadas a mano" para que elegir un ritmo no las sobreescriba sin
      // que el admin lo pida.
      const tocadas: Record<string, boolean> = {}
      for (const h of horseDrafts) {
        if ((byHorse[h.tempId] ?? []).length > 0) tocadas[h.tempId] = true
      }
      setHorseEscaleraTocada(tocadas)

      const { data: aj, error: ajErr } = await supabase
        .from("ajustes_instalacion")
        .select("clave,valor")
        .in("clave", ["minimo_incremento", "minimo_precio_salida"])

      if (ajErr) {
        console.warn("[ajustes] no se pudieron leer los minimos:", ajErr.message)
      } else {
        for (const row of (aj ?? []) as { clave: string; valor: string }[]) {
          const v = Number(row.valor)
          if (!Number.isFinite(v)) continue
          if (row.clave === "minimo_incremento") setMinIncremento(v)
          if (row.clave === "minimo_precio_salida") setMinSalida(v)
        }
      }

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

  // EN VIVO, PERO SIN RECARGAR SOLO.
  //
  // Esta pantalla es un formulario: el admin puede estar a mitad de cambiar
  // el incremento o la escalera de un caballo. Un loadAll() automatico le
  // borraria el borrador sin avisar, y perder trabajo escrito es peor que
  // ver un dato con diez segundos de retraso.
  //
  // Asi que la senal solo enciende un aviso, y el admin decide cuando.
  useSenal(remateId ? topicoRemate(remateId) : null, EVENTOS_REMATE, () => {
    setHayCambios(true)
  })


  // =========================================================================
  //  LA MISMA LISTA DE FALTANTES QUE EN CREAR-REMATE
  //
  //  Esta pantalla tenia el mismo defecto: `canSave` devolvia un booleano, el
  //  boton se quedaba gris y el admin tenia que adivinar cual de los treinta
  //  campos faltaba. Y el mismo `||` de mas que exigia la hora de cierre
  //  aunque sea opcional -- Jota pidio comprobar "si en los remates
  //  adelantados tambien esta igual". Si: estaba igual.
  // =========================================================================
  const faltantes = useMemo(() => {
    const f: string[] = []
    if (!remateDraft || !raceDraft) return ["Cargando el remate"]

    const estadoActual = String(remate?.estado || "").toLowerCase()
    if (estadoActual === "cancelado") return ["Este remate está cancelado y no se puede editar"]
    if (remate?.archived_at) return ["Este remate está archivado y no se puede editar"]

    if (!raceDraft.descripcion.trim()) f.push("Descripción de la carrera")
    if (!raceDraft.hipodromo.trim()) f.push("Hipódromo")
    if (!raceDraft.numero_carrera_text.trim()) f.push("Número de carrera")
    if (!raceDraft.dia.trim()) f.push("Día")
    if (!parseDateParts(raceDraft.fecha_dd, raceDraft.fecha_mm, raceDraft.fecha_aa)) {
      f.push("Fecha de la carrera")
    }
    if (!parseTime12hTo24(raceDraft.hora_programada)) f.push("Hora de la carrera")
    if (!raceDraft.distancia_m.trim() || !(n(raceDraft.distancia_m) > 0)) f.push("Distancia en metros")

    const inc = n(remateDraft.incremento_minimo)
    if (!(inc > 0)) {
      f.push("Incremento")
    } else if (minIncremento !== null && inc < minIncremento) {
      f.push(`El incremento no puede ser menor a ${formatMoney(minIncremento)} Bs`)
    }

    const casa = n(remateDraft.porcentaje_casa)
    if (!(casa >= 0 && casa <= 100)) f.push("% de la casa (entre 0 y 100)")

    // Apertura obligatoria, cierre OPCIONAL.
    const oDateISO = parseDateParts(remateDraft.opens_dd, remateDraft.opens_mm, remateDraft.opens_aa)
    const oTime24 = parseTime12hTo24(remateDraft.opens_time)
    const o = oDateISO && oTime24 ? buildCaracasTs(oDateISO, oTime24) : null
    if (!o) f.push("Fecha y hora de apertura del remate")

    const cDateISO = parseDateParts(remateDraft.closes_dd, remateDraft.closes_mm, remateDraft.closes_aa)
    const cTime24 = parseTime12hTo24(remateDraft.closes_time)
    const hayAlgoDeCierre =
      !!remateDraft.closes_dd.trim() || !!remateDraft.closes_mm.trim() ||
      !!remateDraft.closes_aa.trim() || !!remateDraft.closes_time.trim()

    if (hayAlgoDeCierre && (!cDateISO || !cTime24)) {
      f.push("El cierre está a medias: ponlo completo o déjalo vacío")
    } else if (cDateISO && cTime24 && o) {
      const c = buildCaracasTs(cDateISO, cTime24)
      if (c && new Date(c).getTime() <= new Date(o).getTime()) {
        f.push("El cierre tiene que ser después de la apertura")
      }
    }

    if (horses.length === 0) f.push("Al menos un caballo")
    for (const h of horses) {
      const quien = h.numero.trim() ? `Caballo ${h.numero.trim()}` : "Un caballo"
      if (!h.numero.trim()) f.push("Número de un caballo")
      if (!h.nombre.trim()) f.push(`${quien}: nombre`)
      if (!h.jinete.trim()) f.push(`${quien}: jinete`)
      if (!h.precio_salida.trim() || !(n(h.precio_salida) > 0)) {
        f.push(`${quien}: precio de salida`)
      } else if (minSalida !== null && n(h.precio_salida) < minSalida) {
        f.push(`${quien}: el precio de salida no puede ser menor a ${formatMoney(minSalida)} Bs`)
      }
    }

    for (const h of horses) {
      if (!horseRulesEnabled[h.tempId]) continue
      const quien = h.numero.trim() ? `Caballo ${h.numero.trim()}` : "Un caballo"
      f.push(...problemasEscalera(horseRulesByKey[h.tempId] || [], minIncremento, quien))
    }

    return Array.from(new Set(f))
  }, [
    remateDraft,
    raceDraft,
    horses,
    horseRulesEnabled,
    horseRulesByKey,
    remate,
    minIncremento,
    minSalida,
  ])

  const canSave = faltantes.length === 0

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
          precio_salida: "",
          retirado: false,
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
      if (faltantes.length > 0) {
        setError("Falta: " + faltantes.join(" · "))
        return
      }
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

      const raceFechaISO = parseDateParts(raceDraft.fecha_dd, raceDraft.fecha_mm, raceDraft.fecha_aa)
      const raceHora24 = parseTime12hTo24(raceDraft.hora_programada)
      const numeroCarreraText = raceDraft.numero_carrera_text.trim()
      const numeroCarreraNum =
        numeroCarreraText && Number.isFinite(Number(numeroCarreraText)) ? Number(numeroCarreraText) : null

      const raceUpdate: any = {
        nombre: raceDraft.descripcion.trim(),
        fecha: raceFechaISO,
        estado: raceDraft.estado.trim() || race.estado,
        dia: raceDraft.dia.trim(),
        distancia_m: n(raceDraft.distancia_m),
        numero_carrera_text: numeroCarreraText || null,
      }
      raceUpdate.hipodromo = raceDraft.hipodromo.trim() ? raceDraft.hipodromo.trim() : null
      raceUpdate.numero_carrera = numeroCarreraNum
      raceUpdate.hora_programada = raceHora24 ? raceHora24 : null

      const { error: raceErr } = await supabase.from("races").update(raceUpdate).eq("id", race.id)
      if (raceErr) throw new Error(raceErr.message)

      const opensDateISO = parseDateParts(remateDraft.opens_dd, remateDraft.opens_mm, remateDraft.opens_aa)
      const closesDateISO = parseDateParts(remateDraft.closes_dd, remateDraft.closes_mm, remateDraft.closes_aa)
      const opensTime24 = parseTime12hTo24(remateDraft.opens_time)
      const closesTime24 = parseTime12hTo24(remateDraft.closes_time)

      // ANTES: un UPDATE directo sobre `remates`, con `estado` incluido.
      //
      // Ese campo era el agujero entero de la tarea 3.2: poner estado a
      // 'cerrado' a mano NO le cobra a nadie, y liquidar_remate() solo exige
      // que el estado sea 'cerrado'. Se pagaba un premio con dinero que nadie
      // habia aportado.
      //
      // AHORA: la RPC editar_remate(), que no recibe el estado siquiera. El
      // estado se cambia con cerrar / cancelar / archivar, que son las que
      // mueven el dinero. Y la base ya no acepta el UPDATE directo: se revoco
      // en la migracion 20260928100000.
      const { error: remErr } = await supabase.rpc("editar_remate", {
        p_remate_id: remate.id,
        p_porcentaje_casa: n(remateDraft.porcentaje_casa),
        p_incremento_minimo: n(remateDraft.incremento_minimo),
        p_tipo: remateDraft.tipo || remate.tipo || "vivo",
        p_opens_at: buildCaracasTs(opensDateISO, opensTime24),
        p_closes_at: buildCaracasTs(closesDateISO, closesTime24),
      })
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
              retirado: !!h.retirado,
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
              retirado: !!h.retirado,
            })
            .select("id")
            .single()
          if (hErr) throw new Error(hErr.message)
          newIdByTemp[h.tempId] = hData.id as string
        }
      }

      const rulesPayload: any[] = []

      // Aqui ya NO se expande ninguna escalera general. Un caballo sin reglas
      // propias no recibe ninguna fila, y por eso la base le aplica
      // `remates.incremento_minimo`. Esa es toda la regla general.
      //
      // Los caballos borrados en esta misma edicion ya salieron de `horses`
      // (removeHorse) y se fueron en `deletedHorseIds` arriba, asi que no
      // reciben reglas. Los que se acaban de crear ya tienen su id en
      // newIdByTemp.

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
    // ANTES: `const casaPct = 25`, clavado.
    //
    // Es el defecto C2 otra vez -- el `round(pozo * 0.75)` clavado que se
    // arreglo en liquidar_remate y en la pantalla del jugador. Esta se quedo
    // fuera, y es la peor de las tres: es donde el admin DECIDE. Le mostraba
    // un premio que no era el que se iba a pagar.
    //
    // Encontrado el 28/09 por Jota, mirando que 30% de 200 no daba 50.
    const casaPct = n(remateDraft?.porcentaje_casa ?? remate?.porcentaje_casa ?? 25)
    const casa = (bruto * casaPct) / 100
    const neto = bruto - casa
    return { bruto, casa, neto, casaPct }
  }, [topByHorse, horses, remateDraft?.porcentaje_casa, remate?.porcentaje_casa])

  const raceLabel = useMemo(() => {
    if (raceDraft) {
      const dateIso = parseDateParts(raceDraft.fecha_dd, raceDraft.fecha_mm, raceDraft.fecha_aa)
      return [
        raceDraft.hipodromo || "Hipódromo",
        raceDraft.dia || null,
        dateIso ? formatDateShort(dateIso) : null,
        raceDraft.hora_programada ? raceDraft.hora_programada : null,
        raceDraft.numero_carrera_text || null,
        raceDraft.distancia_m ? `${raceDraft.distancia_m} m` : null,
      ]
        .filter(Boolean)
        .join(" - ")
    }
    if (race) {
      return [
        race.hipodromo ?? "Hipódromo",
        race.dia ? race.dia : null,
        formatDateShort(race.fecha),
        race.hora_programada ? formatTime12hFrom24(race.hora_programada) : null,
        race.numero_carrera_text
          ? race.numero_carrera_text
          : race.numero_carrera != null
          ? `Carrera ${race.numero_carrera}`
          : null,
        race.distancia_m ? `${race.distancia_m} m` : null,
      ]
        .filter(Boolean)
        .join(" - ")
    }
    return "Carrera"
  }, [raceDraft, race])

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

        {/* Lo que falta, a la vista. El boton gris sin explicacion era, en
            palabras de Jota, "una deficiencia de UX terrible". */}
        {faltantes.length > 0 ? (
          <div className="mt-4 rounded-xl bg-amber-500/10 border border-amber-500/30 p-3">
            <div className="text-xs font-semibold text-amber-100">
              {faltantes.length === 1
                ? "Falta esto para poder guardar:"
                : `Falta esto (${faltantes.length}) para poder guardar:`}
            </div>
            <ul className="mt-2 space-y-1">
              {faltantes.map((m) => (
                <li key={m} className="text-xs text-amber-100/90">
                  · {m}
                </li>
              ))}
            </ul>
          </div>
        ) : null}

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

        {hayCambios ? (
          <div className="mt-4 flex items-center justify-between gap-3 rounded-xl bg-amber-500/10 p-3 text-sm text-amber-200 ring-1 ring-amber-500/20">
            <span>Hubo movimiento en este remate mientras lo tenias abierto.</span>
            <button
              onClick={() => {
                setHayCambios(false)
                void loadAll(true)
              }}
              className="shrink-0 rounded-lg bg-amber-400/20 px-3 py-1.5 font-medium text-amber-100 hover:bg-amber-400/30"
            >
              Actualizar
            </button>
          </div>
        ) : null}

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

          <div className="mt-4 space-y-3">
            <div>
              <label className="text-xs text-zinc-400">Descripci?n de la carrera</label>
              <input
                value={raceDraft?.descripcion ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, descripcion: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-xs text-zinc-400">Hip?dromo</label>
                <select
                  value={raceDraft?.hipodromo ?? ""}
                  onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, hipodromo: e.target.value } : prev))}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="">Selecciona?</option>
                  <option value="La Rinconada">La Rinconada</option>
                  <option value="Valencia">Valencia</option>
                </select>
              </div>
              <div>
                <label className="text-xs text-zinc-400">D?a</label>
                <input
                  value={raceDraft?.dia ?? ""}
                  onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, dia: e.target.value } : prev))}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="Domingo"
                />
              </div>
            </div>

            <SelectorFechaHora
              etiqueta="Cuándo corre la carrera"
              valor={{
                dd: raceDraft?.fecha_dd ?? "",
                mm: raceDraft?.fecha_mm ?? "",
                aa: raceDraft?.fecha_aa ?? "",
                hora12: raceDraft?.hora_programada ?? "",
              }}
              onChange={(v) =>
                setRaceDraft((prev) =>
                  prev
                    ? {
                        ...prev,
                        fecha_dd: v.dd,
                        fecha_mm: v.mm,
                        fecha_aa: v.aa,
                        hora_programada: v.hora12,
                        // El dia sigue a la fecha, como en crear-remate.
                        dia: v.dd && v.mm && v.aa ? nombreDiaDeIso(`20${v.aa}-${v.mm}-${v.dd}`) : prev.dia,
                      }
                    : prev
                )
              }
            />

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-xs text-zinc-400">N? carrera (texto)</label>
                <input
                  value={raceDraft?.numero_carrera_text ?? ""}
                  onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, numero_carrera_text: e.target.value } : prev))}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="6 - PRIMERA V?LIDA"
                />
              </div>
              <div>
                <label className="text-xs text-zinc-400">Distancia (m)</label>
                <input
                  inputMode="numeric"
                  value={raceDraft?.distancia_m ?? ""}
                  onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, distancia_m: e.target.value } : prev))}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="1600"
                />
              </div>
            </div>

            <div>
              <label className="text-xs text-zinc-400">Estado</label>
              <input
                value={raceDraft?.estado ?? ""}
                onChange={(e) => setRaceDraft((prev) => (prev ? { ...prev, estado: e.target.value } : prev))}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
              />
            </div>
          </div>
        </section>


                <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">2) Remate</h2>

          <div className="mt-4 grid grid-cols-1 md:grid-cols-2 gap-3">
            {/* El estado dejo de ser editable a mano, y no es una restriccion
                de pantalla: la base ya no acepta el UPDATE (migracion
                20260928100000).

                Ponerlo en 'cerrado' desde aqui NO le cobraba a nadie, y
                liquidar_remate() solo exige que el estado sea 'cerrado'. Se
                pagaba un premio con dinero que nadie habia aportado.

                Se muestra, no se edita. Para cambiarlo estan los botones de
                abajo, que son los que mueven el dinero. */}
            <div>
              <label className="text-xs text-zinc-400">Estado</label>
              <div className="mt-1 w-full rounded-xl bg-zinc-950/40 border border-zinc-800 px-3 py-2 text-sm text-zinc-200">
                {remateDraft?.estado ?? "abierto"}
              </div>
              <div className="mt-1 text-[11px] text-zinc-500">
                Se cambia con los botones de cerrar, cancelar o archivar — no a mano.
              </div>
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
              <label className="text-xs text-zinc-400">Incremento</label>
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

            <SelectorFechaHora
              etiqueta="Apertura del remate"
              valor={{
                dd: remateDraft?.opens_dd ?? "",
                mm: remateDraft?.opens_mm ?? "",
                aa: remateDraft?.opens_aa ?? "",
                hora12: remateDraft?.opens_time ?? "",
              }}
              onChange={(v) =>
                setRemateDraft((prev) =>
                  prev
                    ? { ...prev, opens_dd: v.dd, opens_mm: v.mm, opens_aa: v.aa, opens_time: v.hora12 }
                    : prev
                )
              }
              ayuda="Desde este momento se puede pujar."
            />

            <SelectorFechaHora
              etiqueta="Cierre del remate"
              opcional
              valor={{
                dd: remateDraft?.closes_dd ?? "",
                mm: remateDraft?.closes_mm ?? "",
                aa: remateDraft?.closes_aa ?? "",
                hora12: remateDraft?.closes_time ?? "",
              }}
              onChange={(v) => {
                setCloseTouched(true)
                setRemateDraft((prev) =>
                  prev
                    ? { ...prev, closes_dd: v.dd, closes_mm: v.mm, closes_aa: v.aa, closes_time: v.hora12 }
                    : prev
                )
              }}
              ayuda="Déjalo vacío si vas a cerrar el remate a mano."
            />
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
                    <div className="flex items-center gap-3">
                      <label className="text-xs text-zinc-300 flex items-center gap-2">
                        <input
                          type="checkbox"
                          checked={!!h.retirado}
                          onChange={(e) => updateHorse(h.tempId, { retirado: e.target.checked })}
                        />
                        Retirado
                      </label>
                      <button
                        onClick={() => removeHorse(h.tempId)}
                        className="rounded-xl bg-red-500/10 text-red-200 ring-1 ring-red-500/20 px-3 py-1 text-xs"
                      >
                        Quitar
                      </button>
                    </div>
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
                          onChange={(e) => {
                            const activar = e.target.checked
                            setHorseRulesEnabled((prev) => ({ ...prev, [h.tempId]: activar }))
                            // Nace con una escalera valida, no con la tabla en
                            // blanco: una casilla que al marcarla te deja un
                            // formulario vacio no te ha ayudado en nada.
                            if (activar && (horseRulesByKey[h.tempId] || []).length === 0) {
                              const r = horseRitmo[h.tempId] ?? "normal"
                              setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                              setHorseRulesByKey((prev) => ({
                                ...prev,
                                [h.tempId]: generarEscalera(n(h.precio_salida) || 100, r),
                              }))
                            }
                          }}
                        />
                        Activar
                      </label>
                    </div>

                    {!horseRulesEnabled[h.tempId] ? (
                      <div className="mt-2 text-xs text-zinc-400">
                        Sube de {formatMoney(n(remateDraft?.incremento_minimo))} Bs en{" "}
                        {formatMoney(n(remateDraft?.incremento_minimo))} Bs, como el resto del remate.
                      </div>
                    ) : (
                      <>
                        {/* LOS TRES RITMOS, igual que en crear-remate.
                            Antes aqui habia una rejilla de cuatro columnas con
                            min / max / incremento / quitar: la misma regla con
                            dos interfaces distintas, y esta era la peor. Ahora
                            las dos pantallas usan lib/escalera.ts. */}
                        <div className="mt-3 space-y-2">
                          {RITMOS.map((op) => {
                            const activo =
                              (horseRitmo[h.tempId] ?? "normal") === op && !horseEscaleraTocada[h.tempId]
                            return (
                              <label
                                key={op}
                                className={`flex items-start gap-2 rounded-xl border px-3 py-2 text-xs cursor-pointer ${
                                  activo ? "bg-zinc-950/70 border-zinc-600" : "bg-zinc-950/40 border-zinc-800"
                                }`}
                              >
                                <input
                                  type="radio"
                                  name={`ritmo-${h.tempId}`}
                                  className="mt-0.5"
                                  checked={activo}
                                  onChange={() => {
                                    setHorseRitmo((prev) => ({ ...prev, [h.tempId]: op }))
                                    setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                                    setHorseRulesByKey((prev) => ({
                                      ...prev,
                                      [h.tempId]: generarEscalera(n(h.precio_salida) || 100, op),
                                    }))
                                  }}
                                />
                                <span className="text-zinc-200">{ETIQUETA_RITMO[op]}</span>
                              </label>
                            )
                          })}
                        </div>

                        {horseEscaleraTocada[h.tempId] ? (
                          <div className="mt-3 flex items-center justify-between gap-2 rounded-xl bg-amber-500/10 border border-amber-500/30 px-3 py-2">
                            <span className="text-[11px] text-amber-100">Escalera personalizada</span>
                            <button
                              type="button"
                              onClick={() => {
                                const r = horseRitmo[h.tempId] ?? "normal"
                                setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: false }))
                                setHorseRulesByKey((prev) => ({
                                  ...prev,
                                  [h.tempId]: generarEscalera(n(h.precio_salida) || 100, r),
                                }))
                              }}
                              className="text-[11px] text-amber-100 underline underline-offset-4"
                            >
                              Volver a la automática
                            </button>
                          </div>
                        ) : null}

                        {/* La simulacion: una lista de precios dice como se
                            siente pujar; cuatro columnas de numeros no. */}
                        <div className="mt-3 rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
                          <div className="text-[11px] text-zinc-500">Así subiría este caballo</div>
                          <div className="mt-2 flex flex-wrap items-center gap-x-1 gap-y-1 text-xs">
                            {simularPujas(
                              n(h.precio_salida),
                              horseRulesByKey[h.tempId] || [],
                              n(remateDraft?.incremento_minimo),
                              7
                            ).map((v, i) => (
                              <span key={i} className="flex items-center gap-1">
                                {i > 0 ? <span className="text-zinc-600">→</span> : null}
                                <span className={i === 0 ? "font-semibold text-zinc-100" : "text-zinc-300"}>
                                  {formatMoney(v)}
                                </span>
                              </span>
                            ))}
                            <span className="text-zinc-600">→ …</span>
                          </div>
                        </div>

                        <button
                          type="button"
                          onClick={() =>
                            setHorseTablaAbierta((prev) => ({ ...prev, [h.tempId]: !prev[h.tempId] }))
                          }
                          className="mt-3 text-[11px] text-zinc-300 underline underline-offset-4"
                        >
                          {horseTablaAbierta[h.tempId] ? "Ocultar los tramos" : "Ver y editar los tramos"}
                        </button>

                        {horseTablaAbierta[h.tempId] ? (
                          <div className="mt-3 space-y-2">
                            {(horseRulesByKey[h.tempId] || []).map((r, i) => (
                              <div
                                key={r.tempId}
                                className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3"
                              >
                                <div className="flex items-center justify-between">
                                  <span className="text-[11px] text-zinc-500">Tramo {i + 1}</span>
                                  <button
                                    type="button"
                                    onClick={() => {
                                      setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                      removeHorseRule(h.tempId, r.tempId)
                                    }}
                                    className="text-[11px] text-zinc-400 underline underline-offset-4"
                                  >
                                    Quitar
                                  </button>
                                </div>
                                <div className="mt-2 grid grid-cols-3 gap-2">
                                  <label className="block">
                                    <span className="block text-[11px] text-zinc-500">Desde</span>
                                    <input
                                      inputMode="decimal"
                                      value={r.min_precio}
                                      onChange={(e) => {
                                        setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                        updateHorseRule(h.tempId, r.tempId, { min_precio: e.target.value })
                                      }}
                                      className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm"
                                    />
                                  </label>
                                  <label className="block">
                                    <span className="block text-[11px] text-zinc-500">Hasta</span>
                                    <input
                                      inputMode="decimal"
                                      value={r.max_precio}
                                      onChange={(e) => {
                                        setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                        updateHorseRule(h.tempId, r.tempId, { max_precio: e.target.value })
                                      }}
                                      placeholder="sin tope"
                                      className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm"
                                    />
                                  </label>
                                  <label className="block">
                                    <span className="block text-[11px] text-zinc-500">Sube de</span>
                                    <input
                                      inputMode="decimal"
                                      value={r.incremento}
                                      onChange={(e) => {
                                        setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                        updateHorseRule(h.tempId, r.tempId, { incremento: e.target.value })
                                      }}
                                      className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm"
                                    />
                                  </label>
                                </div>
                                {minIncremento !== null &&
                                n(r.incremento) > 0 &&
                                n(r.incremento) < minIncremento ? (
                                  <div className="mt-2 rounded-lg bg-red-500/10 border border-red-500/30 px-2 py-1 text-[11px] text-red-200">
                                    El mínimo de esta instalación es {formatMoney(minIncremento)} Bs.
                                  </div>
                                ) : null}
                              </div>
                            ))}

                            <button
                              type="button"
                              onClick={() => {
                                setHorseEscaleraTocada((prev) => ({ ...prev, [h.tempId]: true }))
                                addHorseRule(h.tempId)
                              }}
                              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                            >
                              + Agregar tramo
                            </button>
                          </div>
                        ) : null}
                      </>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">4) Resumen en vivo</h2>

          <div className="mt-3 grid grid-cols-1 md:grid-cols-3 gap-2">
            <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
              <div className="text-xs text-zinc-500">Pozo bruto</div>
              <div className="mt-1 text-lg font-semibold">{formatMoney(totals.bruto)} Bs</div>
            </div>
            <div className="rounded-xl bg-zinc-950/60 border border-zinc-800 p-3">
              {/* El porcentaje a la vista: si la cifra no cuadra, que se vea
                  con que numero se calculo. Asi se encontro que estaba
                  clavado en 25. */}
              <div className="text-xs text-zinc-500">Casa ({totals.casaPct}%)</div>
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
