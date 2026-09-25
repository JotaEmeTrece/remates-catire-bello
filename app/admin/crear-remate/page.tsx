// ADMIN/CREAR-REMATE/PAGE.TSX

"use client"

import { useEffect, useMemo, useState } from "react"
import type { Dispatch, SetStateAction } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type HorseDraft = {
  tempId: string
  numero: string
  nombre: string
  jinete: string
  comentarios: string
  precio_salida: string
}

type PriceRuleDraft = {
  tempId: string
  min_precio: string
  max_precio: string
  incremento: string
}

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

function buildCaracasTs(dateIso: string, time24: string) {
  if (!dateIso) return null
  let t = (time24 || "").trim()
  if (!t) t = "00:00:00"
  if (t.length === 5) t = `${t}:00`
  return `${dateIso}T${t}-04:00`
}

function caracasNowParts() {
  const d = new Date()
  const dateIso = formatDateInTz(d, CARACAS_TZ)
  const time24 = formatTimeInTz(d, CARACAS_TZ)
  const { dd, mm, yy } = splitIsoDate(dateIso)
  return {
    dateIso,
    time24,
    dd,
    mm,
    yy,
    time12: formatTime12hFrom24(time24),
    weekday: weekdayInTz(d, CARACAS_TZ),
  }
}

function uid() {
  return Math.random().toString(16).slice(2) + Date.now().toString(16)
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

// Miles con punto y sin decimales: los precios de un remate son enteros.
function formatoBs(v: number) {
  if (!Number.isFinite(v)) return "0"
  return Math.round(v).toLocaleString("es-VE")
}

// ===========================================================================
//  LA ESCALERA DE INCREMENTOS
//
//  Antes esto eran 10 filas que el admin escribia a mano, arrancando en 0
//  aunque ningun caballo saliera nunca por debajo del precio de salida: la
//  mitad de los tramos no se usaban jamas.
//
//  Ahora la escalera se GENERA a partir del precio de salida. El admin elige
//  el ritmo y ve la simulacion; solo baja a la tabla si quiere algo raro.
//
//  Los tramos son multiplos del precio de salida (1x, 5x, 10x, 50x, 100x) y
//  el incremento de cada tramo es una fraccion del mismo precio de salida.
//  Asi la escalera se recalcula sola si cambias la salida, y el incremento
//  siempre queda entre el 5% y el 50% del precio en curso — que es el rango
//  en que una subasta avanza sin eternizarse ni pegar saltos brutales.
// ===========================================================================

export type RitmoEscalera = "suave" | "normal" | "agresiva"

// Los tramos, en multiplos del precio de salida. El ultimo no tiene techo.
const TRAMOS_EN_MULTIPLOS: Array<{ desde: number; hasta: number | null }> = [
  { desde: 1, hasta: 5 },
  { desde: 5, hasta: 10 },
  { desde: 10, hasta: 50 },
  { desde: 50, hasta: 100 },
  { desde: 100, hasta: null },
]

// El incremento de cada tramo, tambien en multiplos del precio de salida.
const FACTORES_POR_RITMO: Record<RitmoEscalera, number[]> = {
  suave: [0.25, 0.5, 1, 2.5, 5],
  normal: [0.5, 1, 2.5, 5, 10],
  agresiva: [1, 2, 5, 10, 20],
}

export const ETIQUETA_RITMO: Record<RitmoEscalera, string> = {
  suave: "Suave - muchas pujas, sube despacio",
  normal: "Normal - recomendado",
  agresiva: "Agresiva - pocas pujas, sube rapido",
}

// Redondea a un numero "de los que uno diria en voz alta": 1, 2, 5, 10, 20,
// 50, 100... Con salida 100 no hace falta, pero con salida 75 evita que el
// incremento salga en 37,5.
function aNumeroRedondo(v: number) {
  if (!Number.isFinite(v) || v <= 0) return 1
  const exp = Math.floor(Math.log10(v))
  const base = Math.pow(10, exp)
  // El 2,5 no sobra: sin el, 250 se redondeaba a 200. Y 250 es tan
  // "numero que uno dice en voz alta" como 200.
  const candidatos = [base, base * 2, base * 2.5, base * 5, base * 10]
  let mejor = candidatos[0]
  for (const c of candidatos) {
    if (Math.abs(c - v) < Math.abs(mejor - v)) mejor = c
  }
  return mejor
}

export function generarEscalera(salida: number, ritmo: RitmoEscalera): PriceRuleDraft[] {
  const s = salida > 0 ? salida : 100
  const factores = FACTORES_POR_RITMO[ritmo]
  return TRAMOS_EN_MULTIPLOS.map((t, i) => ({
    tempId: uid(),
    min_precio: String(Math.round(t.desde * s)),
    max_precio: t.hasta === null ? "" : String(Math.round(t.hasta * s)),
    incremento: String(aNumeroRedondo(factores[i] * s)),
  }))
}

// Que incremento aplica a este precio. MISMA regla que _incremento_aplicable()
// en la base: el tramo cuyo `desde` es el mayor que no pasa del precio.
function incrementoPara(precio: number, reglas: PriceRuleDraft[], respaldo: number) {
  let elegido: number | null = null
  let mejorDesde = -1
  for (const r of reglas) {
    const desde = n(r.min_precio)
    const hasta = r.max_precio.trim() ? n(r.max_precio) : null
    if (precio >= desde && (hasta === null || precio < hasta)) {
      if (desde > mejorDesde) {
        mejorDesde = desde
        elegido = n(r.incremento)
      }
    }
  }
  return elegido && elegido > 0 ? elegido : respaldo
}

// La simulacion que hace entendible la escalera: los primeros N precios.
export function simularPujas(
  salida: number,
  reglas: PriceRuleDraft[],
  respaldo: number,
  cuantas = 10
) {
  const pasos: number[] = []
  let p = salida > 0 ? salida : 0
  if (p <= 0) return pasos
  pasos.push(p)
  for (let i = 0; i < cuantas; i++) {
    const inc = incrementoPara(p, reglas, respaldo)
    if (!(inc > 0)) break
    p = p + inc
    pasos.push(p)
  }
  return pasos
}

// Cuantas pujas hacen falta para llegar a `objetivo`. Devuelve null si con
// esta escalera no se llega nunca (incremento cero o negativo).
export function pujasHasta(
  salida: number,
  reglas: PriceRuleDraft[],
  respaldo: number,
  objetivo: number
) {
  let p = salida > 0 ? salida : 0
  if (p <= 0 || objetivo <= p) return 0
  let cuenta = 0
  while (p < objetivo && cuenta < 5000) {
    const inc = incrementoPara(p, reglas, respaldo)
    if (!(inc > 0)) return null
    p += inc
    cuenta++
  }
  return cuenta >= 5000 ? null : cuenta
}


export default function AdminCrearRematePage() {
  const router = useRouter()

  // =========================
  // Estado general de la pantalla
  // =========================
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")

  // =========================
  // Datos creados (para linkear rápido al final)
  // =========================
  const [createdRaceId, setCreatedRaceId] = useState<string | null>(null)
  const [createdRemateId, setCreatedRemateId] = useState<string | null>(null)

  // =========================
  // Form Carrera (races)
  // =========================
  const [raceDescripcion, setRaceDescripcion] = useState("Carrera de Prueba")
  const [racePais, setRacePais] = useState("Venezuela")
  const [raceHipodromo, setRaceHipodromo] = useState("La Rinconada")
  const [raceNumeroCarreraText, setRaceNumeroCarreraText] = useState("1")
  const nowCaracas = caracasNowParts()
  const [raceFechaDD, setRaceFechaDD] = useState(nowCaracas.dd)
  const [raceFechaMM, setRaceFechaMM] = useState(nowCaracas.mm)
  const [raceFechaAA, setRaceFechaAA] = useState(nowCaracas.yy)
  const [raceHora, setRaceHora] = useState(formatTime12hFrom24("15:00:00"))
  const [raceDia, setRaceDia] = useState(nowCaracas.weekday ? nowCaracas.weekday.charAt(0).toUpperCase() + nowCaracas.weekday.slice(1) : "")
  const [raceDistancia, setRaceDistancia] = useState("")

  // =========================
  // Form Remate (remates)
  // =========================
  const [incrementoMinimo, setIncrementoMinimo] = useState("50")
  // Solo vive en el formulario: precarga el precio de salida de cada caballo.
  // NO se guarda en la base. Esa columna quedo sin uso en la tarea 2.17.
  const [salidaPorDefecto, setSalidaPorDefecto] = useState("100")
  const [porcentajeCasa, setPorcentajeCasa] = useState("25")
  const [remateTipo, setRemateTipo] = useState<"vivo" | "adelantado">("vivo")
  const [opensDD, setOpensDD] = useState(nowCaracas.dd)
  const [opensMM, setOpensMM] = useState(nowCaracas.mm)
  const [opensAA, setOpensAA] = useState(nowCaracas.yy)
  const [opensTime, setOpensTime] = useState(nowCaracas.time12 || "12:00 am")
  const [closesDD, setClosesDD] = useState(raceFechaDD)
  const [closesMM, setClosesMM] = useState(raceFechaMM)
  const [closesAA, setClosesAA] = useState(raceFechaAA)
  const [closesTime, setClosesTime] = useState(raceHora || nowCaracas.time12 || "12:00 am")
  const [closeTouched, setCloseTouched] = useState(false)

  useEffect(() => {
    if (!closeTouched) {
      setClosesDD(raceFechaDD)
      setClosesMM(raceFechaMM)
      setClosesAA(raceFechaAA)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [raceFechaDD, raceFechaMM, raceFechaAA])

  useEffect(() => {
    if (!closeTouched && raceHora.trim()) setClosesTime(raceHora)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [raceHora])

  const raceFechaISO = useMemo(() => parseDateParts(raceFechaDD, raceFechaMM, raceFechaAA), [raceFechaDD, raceFechaMM, raceFechaAA])
  const raceHora24 = useMemo(() => parseTime12hTo24(raceHora), [raceHora])
  const opensDateISO = useMemo(() => parseDateParts(opensDD, opensMM, opensAA), [opensDD, opensMM, opensAA])
  const closesDateISO = useMemo(() => parseDateParts(closesDD, closesMM, closesAA), [closesDD, closesMM, closesAA])
  const opensTime24 = useMemo(() => parseTime12hTo24(opensTime), [opensTime])
  const closesTime24 = useMemo(() => parseTime12hTo24(closesTime), [closesTime])

  // =========================
  // Caballos (horses) - lista dinámica
  // NOTA: precio_salida es obligatorio (precio inicial del caballo).
  // =========================
  // Sin caballos semilla. Antes nacian dos, "Relampago" y "Tormenta", con un
  // precio de 60 escrito a mano que no tenia nada que ver con el precio de
  // salida del remate. De ahi venia que la pantalla dijera 40 y los caballos
  // 60: no era un bug de logica, era que no habia logica — eran dos numeros
  // sueltos sin ninguna relacion.
  const [horses, setHorses] = useState<HorseDraft[]>([])

  // =========================
  // Reglas de precio (default y por caballo)
  // =========================
  const [ritmo, setRitmo] = useState<RitmoEscalera>("normal")
  const [escaleraTocadaAMano, setEscaleraTocadaAMano] = useState(false)
  const [verTablaEscalera, setVerTablaEscalera] = useState(false)
  const [defaultRules, setDefaultRules] = useState<PriceRuleDraft[]>(() =>
    generarEscalera(100, "normal")
  )
  const [useDefaultRules, setUseDefaultRules] = useState(true)
  const [horseRulesEnabled, setHorseRulesEnabled] = useState<Record<string, boolean>>({})
  const [horseRulesByTempId, setHorseRulesByTempId] = useState<Record<string, PriceRuleDraft[]>>({})

  // =========================================================================
  //  EL PRECIO DE SALIDA MANDA
  //
  //  Decision del 25/09: el precio de salida del remate es EL precio de todos
  //  los caballos. La unica forma de que un caballo tenga otro precio es
  //  activarle su regla individual. Asi no existe un tercer estado invisible
  //  ("caballo que toque a mano y ya no sigue al remate") que no se vea en
  //  pantalla.
  //
  //  Antes no habia ningun efecto que conectara las dos cosas: cambiabas el
  //  precio del remate y los caballos ya creados se quedaban donde estaban.
  // =========================================================================
  useEffect(() => {
    const valor = salidaPorDefecto.trim()
    if (!valor) return
    setHorses((prev) => {
      if (prev.length === 0) return prev
      if (prev.every((h) => h.precio_salida === valor)) return prev
      return prev.map((h) => ({ ...h, precio_salida: valor }))
    })
  }, [salidaPorDefecto])

  // La escalera se regenera sola con el precio de salida y el ritmo, salvo
  // que la hayas editado a mano — ahi se respeta lo que escribiste.
  useEffect(() => {
    if (escaleraTocadaAMano) return
    setDefaultRules(generarEscalera(n(salidaPorDefecto) || 100, ritmo))
  }, [salidaPorDefecto, ritmo, escaleraTocadaAMano])

  // La simulacion: lo que de verdad hace entendible la escalera.
  const simulacion = useMemo(
    () => simularPujas(n(salidaPorDefecto), useDefaultRules ? defaultRules : [], n(incrementoMinimo), 9),
    [salidaPorDefecto, defaultRules, useDefaultRules, incrementoMinimo]
  )
  const pujasPara1000 = useMemo(
    () => pujasHasta(n(salidaPorDefecto), useDefaultRules ? defaultRules : [], n(incrementoMinimo), 1000),
    [salidaPorDefecto, defaultRules, useDefaultRules, incrementoMinimo]
  )
  const pujasPara5000 = useMemo(
    () => pujasHasta(n(salidaPorDefecto), useDefaultRules ? defaultRules : [], n(incrementoMinimo), 5000),
    [salidaPorDefecto, defaultRules, useDefaultRules, incrementoMinimo]
  )

  // =========================
  // Guard: asegurar que es admin
  // =========================
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

  useEffect(() => {
    ;(async () => {
      setLoading(true)
      setError("")
      try {
        const aid = await ensureAdmin()
        if (!aid) return
      } catch (e: any) {
        setError(e?.message || "Error de sesion admin")
      } finally {
        setLoading(false)
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // =========================
  // Helpers UI
  // =========================
  const canSave = useMemo(() => {
    if (!raceDescripcion.trim()) return false
    if (!raceHipodromo.trim()) return false
    if (!raceNumeroCarreraText.trim()) return false
    if (!raceDia.trim()) return false
    if (!raceFechaISO) return false
    if (!raceHora24) return false
    if (!raceDistancia.trim()) return false
    if (!(n(raceDistancia) > 0)) return false

    const inc = n(incrementoMinimo)
    const casa = n(porcentajeCasa)

    if (!(inc > 0)) return false
    if (!(casa >= 0 && casa <= 100)) return false

    const o = buildCaracasTs(opensDateISO, opensTime24)
    const c = buildCaracasTs(closesDateISO, closesTime24)
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

    if (useDefaultRules && !validRules(defaultRules)) return false
    for (const h of horses) {
      if (horseRulesEnabled[h.tempId]) {
        const list = horseRulesByTempId[h.tempId] || []
        if (!validRules(list)) return false
      }
    }

    return true
  }, [
    raceDescripcion,
    raceHipodromo,
    raceNumeroCarreraText,
    raceDia,
    raceFechaDD,
    raceFechaMM,
    raceFechaAA,
    raceHora,
    raceDistancia,
    raceFechaISO,
    raceHora24,
    incrementoMinimo,
    salidaPorDefecto,
    porcentajeCasa,
    opensDD,
    opensMM,
    opensAA,
    opensTime,
    closesDD,
    closesMM,
    closesAA,
    closesTime,
    opensDateISO,
    opensTime24,
    closesDateISO,
    closesTime24,
    horses,
    useDefaultRules,
    defaultRules,
    horseRulesEnabled,
    horseRulesByTempId,
  ])

  function addHorse() {
    const nextNum =
      horses.length > 0
        ? String(Math.max(...horses.map((h) => Number(h.numero) || 0)) + 1)
        : "1"
    setHorses((prev) => [
      ...prev,
      { tempId: uid(), numero: nextNum, nombre: "", jinete: "", comentarios: "", precio_salida: salidaPorDefecto || "" },
    ])
  }

  function removeHorse(tempId: string) {
    setHorses((prev) => prev.filter((h) => h.tempId !== tempId))
    setHorseRulesEnabled((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
    setHorseRulesByTempId((prev) => {
      const next = { ...prev }
      delete next[tempId]
      return next
    })
  }

  function updateHorse(tempId: string, patch: Partial<HorseDraft>) {
    setHorses((prev) => prev.map((h) => (h.tempId === tempId ? { ...h, ...patch } : h)))
  }

  function addRule(setter: Dispatch<SetStateAction<PriceRuleDraft[]>>) {
    setter((prev) => [...prev, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }])
  }

  function updateRule(
    setter: Dispatch<SetStateAction<PriceRuleDraft[]>>,
    tempId: string,
    patch: Partial<PriceRuleDraft>
  ) {
    setter((prev) => prev.map((r) => (r.tempId === tempId ? { ...r, ...patch } : r)))
  }

  function removeRule(setter: Dispatch<SetStateAction<PriceRuleDraft[]>>, tempId: string) {
    setter((prev) => prev.filter((r) => r.tempId !== tempId))
  }

  function addHorseRule(horseTempId: string) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return { ...prev, [horseTempId]: [...list, { tempId: uid(), min_precio: "", max_precio: "", incremento: "" }] }
    })
  }

  function updateHorseRule(horseTempId: string, ruleTempId: string, patch: Partial<PriceRuleDraft>) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return {
        ...prev,
        [horseTempId]: list.map((r) => (r.tempId === ruleTempId ? { ...r, ...patch } : r)),
      }
    })
  }

  function removeHorseRule(horseTempId: string, ruleTempId: string) {
    setHorseRulesByTempId((prev) => {
      const list = prev[horseTempId] || []
      return { ...prev, [horseTempId]: list.filter((r) => r.tempId !== ruleTempId) }
    })
  }

  // =========================
  // Guardar TODO (race -> remate -> horses)
  // NOTA IMPORTANTE:
  // Sin RPC transaccional, esto NO es atómico:
  // si falla horses, ya quedan creados race/remate y los borras manual.
  // =========================
  async function onCreate() {
    setError("")
    setOk("")
    setCreatedRaceId(null)
    setCreatedRemateId(null)

    if (!canSave) {
      setError("Revisa los campos: hay datos faltantes o inválidos.")
      return
    }

    setSaving(true)

    try {
      // 0) Verificar admin antes de escribir
      const aid = await ensureAdmin()
      if (!aid) return

      // 1) Crear Carrera (races)
      const numeroCarreraText = raceNumeroCarreraText.trim()
      const numeroCarreraNum =
        numeroCarreraText && Number.isFinite(Number(numeroCarreraText)) ? Number(numeroCarreraText) : null

      const raceInsert: any = {
        nombre: raceDescripcion.trim(),
        fecha: raceFechaISO,
        estado: "programada",
        dia: raceDia.trim(),
        distancia_m: n(raceDistancia),
        numero_carrera_text: numeroCarreraText || null,
      }

      // hipodromo / numero_carrera / hora_programada son nullables (seg?n tu schema)
      raceInsert.hipodromo = raceHipodromo.trim() ? raceHipodromo.trim() : null
      raceInsert.numero_carrera = numeroCarreraNum
      raceInsert.hora_programada = raceHora24 ? raceHora24 : null

      const { data: raceData, error: raceErr } = await supabase
        .from("races")
        .insert(raceInsert)
        .select("id")
        .single()

      if (raceErr) throw new Error(raceErr.message)
      const raceId = raceData.id as string
      setCreatedRaceId(raceId)

      // 2) Crear Remate (remates) para esa carrera
      const remateNombreInterno =
        raceDescripcion.trim() ||
        (raceHipodromo.trim()
          ? `Remate ${raceHipodromo.trim()}`
          : `Remate ${numeroCarreraText || ""}`.trim())

      const remateInsert: any = {
        race_id: raceId,
        nombre: remateNombreInterno,
        estado: "abierto",
        incremento_minimo: n(incrementoMinimo),
        porcentaje_casa: n(porcentajeCasa),
        tipo: remateTipo,
        opens_at: buildCaracasTs(opensDateISO, opensTime24),
        closes_at: buildCaracasTs(closesDateISO, closesTime24),
      }

      const { data: remateData, error: remErr } = await supabase
        .from("remates")
        .insert(remateInsert)
        .select("id")
        .single()

      if (remErr) throw new Error(remErr.message)
      const remateId = remateData.id as string
      setCreatedRemateId(remateId)

      // 3) Insertar caballos (horses) asociados a la carrera
      const horsesPayload = horses.map((h) => {
        const obj: any = {
          race_id: raceId,
          numero: Number(h.numero),
          nombre: h.nombre.trim(),
          jinete: h.jinete.trim() ? h.jinete.trim() : null,
          precio_salida: n(h.precio_salida),
          comentarios: h.comentarios.trim() ? h.comentarios.trim() : null,
        }

        // precio_salida: lo mandamos SOLO si lo llenaron (para no romper si en algún ambiente no existe)
        // precio_salida ya va en el payload (obligatorio)

        return obj
      })

      const { error: horsesErr } = await supabase.from("horses").insert(horsesPayload)
      if (horsesErr) throw new Error(horsesErr.message)

      // 4) Insertar reglas de precios (default y por caballo)
      const horseIdByTemp: Record<string, string> = {}
      if (horsesPayload.length > 0) {
        const { data: insertedHorses, error: hsErr } = await supabase
          .from("horses")
          .select("id,numero")
          .eq("race_id", raceId)

        if (hsErr) throw new Error(hsErr.message)

        const byNumero = new Map<number, string>()
        ;(insertedHorses ?? []).forEach((row: any) => {
          if (row?.numero != null) byNumero.set(Number(row.numero), row.id)
        })

        horses.forEach((h) => {
          const id = byNumero.get(Number(h.numero))
          if (id) horseIdByTemp[h.tempId] = id
        })
      }

      const rulesPayload: any[] = []

      if (useDefaultRules) {
        for (const r of defaultRules) {
          if (!r.min_precio.trim() || !r.incremento.trim()) continue
          rulesPayload.push({
            remate_id: remateId,
            horse_id: null,
            min_precio: n(r.min_precio),
            max_precio: r.max_precio.trim() ? n(r.max_precio) : null,
            incremento: n(r.incremento),
          })
        }
      }

      for (const h of horses) {
        if (!horseRulesEnabled[h.tempId]) continue
        const horseId = horseIdByTemp[h.tempId]
        if (!horseId) continue
        const list = horseRulesByTempId[h.tempId] || []
        for (const r of list) {
          if (!r.min_precio.trim() || !r.incremento.trim()) continue
          rulesPayload.push({
            remate_id: remateId,
            horse_id: horseId,
            min_precio: n(r.min_precio),
            max_precio: r.max_precio.trim() ? n(r.max_precio) : null,
            incremento: n(r.incremento),
          })
        }
      }

      if (rulesPayload.length > 0) {
        const { error: rulesErr } = await supabase.from("remate_price_rules").insert(rulesPayload)
        if (rulesErr) throw new Error(rulesErr.message)
      }

      setOk("Listo. Carrera, remate y caballos creados.")
    } catch (e: any) {
      setError(e?.message || "Error creando remate")
    } finally {
      setSaving(false)
    }
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      {/* En movil se ve igual que antes; en PC deja de ser una columna
          de 448px con una rejilla de 3 columnas apretada adentro. */}
      <div className="mx-auto w-full max-w-md md:max-w-3xl">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Admin - Crear remate</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {/* Mensajes */}
        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
            {createdRemateId ? (
              <div className="mt-2">
                <Link href={`/remates/${createdRemateId}`} className="underline underline-offset-4 text-emerald-200">
                  Ir al remate
                </Link>
              </div>
            ) : null}
          </div>
        ) : null}

        {/* Carrera */}
        <section className="mt-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">1) Carrera</h2>

          <div className="mt-3 space-y-3">
            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">País</label>
                <select
                  value={racePais}
                  onChange={(e) => {
                    const next = e.target.value
                    setRacePais(next)
                    if (next !== "Venezuela") {
                      setRaceHipodromo("")
                    } else if (!raceHipodromo.trim()) {
                      setRaceHipodromo("La Rinconada")
                    }
                  }}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="Venezuela">Venezuela</option>
                  <option value="Estados Unidos" disabled>
                    Estados Unidos (próximamente)
                  </option>
                </select>
              </div>
              <div>
                <label className="text-sm text-zinc-200">Hipódromo</label>
                <select
                  value={raceHipodromo}
                  onChange={(e) => setRaceHipodromo(e.target.value)}
                  disabled={racePais !== "Venezuela"}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="La Rinconada">La Rinconada</option>
                  <option value="Valencia">Valencia</option>
                </select>
              </div>
            </div>

            <div>
              <label className="text-sm text-zinc-200">Descripción de la carrera</label>
              <input
                value={raceDescripcion}
                onChange={(e) => setRaceDescripcion(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="Ej: Cl?sico Especial de la Tarde"
              />
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Día</label>
                <input
                  value={raceDia}
                  onChange={(e) => setRaceDia(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="Domingo"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Fecha (DD/MM/AA)</label>
                <div className="mt-1 flex items-center gap-1">
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={raceFechaDD}
                    onChange={(e) => setRaceFechaDD(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="DD"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={raceFechaMM}
                    onChange={(e) => setRaceFechaMM(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="MM"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={raceFechaAA}
                    onChange={(e) => setRaceFechaAA(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="AA"
                  />
                </div>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Hora</label>
                <input
                  value={raceHora}
                  onChange={(e) => setRaceHora(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="1:30 pm"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Distancia (m)</label>
                <input
                  inputMode="numeric"
                  value={raceDistancia}
                  onChange={(e) => setRaceDistancia(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="1600"
                />
              </div>
            </div>

            <div>
              <label className="text-sm text-zinc-200">N° carrera (texto)</label>
              <input
                value={raceNumeroCarreraText}
                onChange={(e) => setRaceNumeroCarreraText(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="6 - PRIMERA VÁLIDA"
              />
            </div>
          </div>
        </section>
        {/* Remate */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">2) Remate</h2>

          <div className="mt-3 space-y-3">
            <div className="grid grid-cols-3 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Precio de salida</label>
                <input
                  inputMode="decimal"
                  value={salidaPorDefecto}
                  onChange={(e) => setSalidaPorDefecto(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="100"
                />
                <div className="mt-1 text-[11px] text-zinc-500">Salen todos los caballos</div>
              </div>
              <div>
                {/* Este campo SOLO se usa cuando no hay escalera. Con la
                    escalera puesta nunca aplica, porque siempre hay un tramo
                    que cubre el precio. Antes decia "Incremento" a secas y
                    parecia el incremento del remate — cambiarlo no hacia nada
                    y no habia forma de saber por que. */}
                <label className="text-sm text-zinc-200">Incremento fijo</label>
                <input
                  inputMode="decimal"
                  value={incrementoMinimo}
                  onChange={(e) => setIncrementoMinimo(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="50"
                />
                <div className="mt-1 text-[11px] text-zinc-500">Solo si apagas la escalera</div>
              </div>
              <div>
                <label className="text-sm text-zinc-200">% casa</label>
                <input
                  inputMode="decimal"
                  value={porcentajeCasa}
                  onChange={(e) => setPorcentajeCasa(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="25"
                />
              </div>
            </div>

            <div className="text-xs text-zinc-500">
              Este "crear rapido" deja el remate <span className="text-zinc-300">abierto</span> para que entres a probar de una.
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Tipo</label>
                <select
                  value={remateTipo}
                  onChange={(e) => setRemateTipo(e.target.value as "vivo" | "adelantado")}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                >
                  <option value="vivo">En vivo</option>
                  <option value="adelantado">Adelantado</option>
                </select>
              </div>
              <div>
                <label className="text-sm text-zinc-200">Apertura (fecha)</label>
                <div className="mt-1 flex items-center gap-1">
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={opensDD}
                    onChange={(e) => setOpensDD(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="DD"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={opensMM}
                    onChange={(e) => setOpensMM(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="MM"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={opensAA}
                    onChange={(e) => setOpensAA(e.target.value)}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="AA"
                  />
                </div>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Apertura (hora)</label>
                <input
                  value={opensTime}
                  onChange={(e) => setOpensTime(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="10:30 am"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Cierre (fecha)</label>
                <div className="mt-1 flex items-center gap-1">
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={closesDD}
                    onChange={(e) => {
                      setClosesDD(e.target.value)
                      setCloseTouched(true)
                    }}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="DD"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={closesMM}
                    onChange={(e) => {
                      setClosesMM(e.target.value)
                      setCloseTouched(true)
                    }}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="MM"
                  />
                  <span className="text-zinc-500">/</span>
                  <input
                    inputMode="numeric"
                    maxLength={2}
                    value={closesAA}
                    onChange={(e) => {
                      setClosesAA(e.target.value)
                      setCloseTouched(true)
                    }}
                    className="w-14 rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-center"
                    placeholder="AA"
                  />
                </div>
              </div>
            </div>

            <div>
              <label className="text-sm text-zinc-200">Cierre (hora)</label>
              <input
                value={closesTime}
                onChange={(e) => {
                  setClosesTime(e.target.value)
                  setCloseTouched(true)
                }}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="7:00 pm"
              />
            </div>
          </div>
        </section>
        {/* Como sube el precio */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <h2 className="text-base font-semibold">3) Cómo sube el precio</h2>
            <label className="text-xs text-zinc-300 flex items-center gap-2">
              <input
                type="checkbox"
                checked={useDefaultRules}
                onChange={(e) => setUseDefaultRules(e.target.checked)}
              />
              Usar escalera
            </label>
          </div>

          {!useDefaultRules ? (
            <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
              <div className="text-sm text-zinc-200">Incremento fijo de {formatoBs(n(incrementoMinimo))} Bs</div>
              <div className="mt-1 text-xs text-zinc-400">
                Sin escalera, el precio sube siempre lo mismo, vaya el caballo en 100 o en 10.000. El valor es el
                &quot;incremento mínimo&quot; que pusiste arriba.
              </div>
            </div>
          ) : (
            <>
              <div className="mt-3 space-y-2">
                {(["suave", "normal", "agresiva"] as RitmoEscalera[]).map((op) => (
                  <label
                    key={op}
                    className={`flex items-start gap-2 rounded-xl border px-3 py-2 text-sm cursor-pointer ${
                      ritmo === op && !escaleraTocadaAMano
                        ? "bg-zinc-950/70 border-zinc-600"
                        : "bg-zinc-950/40 border-zinc-800"
                    }`}
                  >
                    <input
                      type="radio"
                      name="ritmo"
                      className="mt-1"
                      checked={ritmo === op && !escaleraTocadaAMano}
                      onChange={() => {
                        setEscaleraTocadaAMano(false)
                        setRitmo(op)
                      }}
                    />
                    <span className="text-zinc-200">{ETIQUETA_RITMO[op]}</span>
                  </label>
                ))}
              </div>

              {escaleraTocadaAMano ? (
                <div className="mt-3 flex items-center justify-between gap-2 rounded-xl bg-amber-500/10 border border-amber-500/30 px-3 py-2">
                  <span className="text-xs text-amber-100">Escalera personalizada</span>
                  <button
                    type="button"
                    onClick={() => setEscaleraTocadaAMano(false)}
                    className="text-xs text-amber-100 underline underline-offset-4"
                  >
                    Volver a la automática
                  </button>
                </div>
              ) : null}

              {/* LA SIMULACION. Esto es lo que hace entendible la escalera:
                  cuatro columnas de numeros no te dicen nunca como se siente
                  pujar; una lista de precios si. */}
              <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                <div className="text-xs text-zinc-500">Así se vería una subasta</div>
                {simulacion.length > 1 ? (
                  <>
                    <div className="mt-2 flex flex-wrap items-center gap-x-1 gap-y-1 text-sm">
                      {simulacion.map((v, i) => (
                        <span key={i} className="flex items-center gap-1">
                          {i > 0 ? <span className="text-zinc-600">→</span> : null}
                          <span className={i === 0 ? "font-semibold text-zinc-100" : "text-zinc-300"}>
                            {formatoBs(v)}
                          </span>
                        </span>
                      ))}
                      <span className="text-zinc-600">→ …</span>
                    </div>
                    <div className="mt-2 text-[11px] text-zinc-400">
                      {pujasPara1000 !== null ? <>Llegar a 1.000 Bs: <b>{pujasPara1000} pujas</b>. </> : null}
                      {pujasPara5000 !== null ? <>Llegar a 5.000 Bs: <b>{pujasPara5000} pujas</b>.</> : null}
                    </div>
                  </>
                ) : (
                  <div className="mt-2 text-sm text-zinc-500">Pon un precio de salida para ver la simulación.</div>
                )}
              </div>

              <button
                type="button"
                onClick={() => setVerTablaEscalera((v) => !v)}
                className="mt-3 text-xs text-zinc-300 underline underline-offset-4"
              >
                {verTablaEscalera ? "Ocultar los tramos" : "Ver y editar los tramos"}
              </button>

              {verTablaEscalera ? (
                <div className="mt-3 space-y-2">
                  {/* Una tarjeta por tramo en vez de una rejilla de 4 columnas:
                      la rejilla se salia del contenedor en pantallas angostas. */}
                  {defaultRules.map((r, i) => (
                    <div key={r.tempId} className="rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                      <div className="flex items-center justify-between">
                        <span className="text-[11px] text-zinc-500">Tramo {i + 1}</span>
                        <button
                          type="button"
                          onClick={() => {
                            setEscaleraTocadaAMano(true)
                            removeRule(setDefaultRules, r.tempId)
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
                              setEscaleraTocadaAMano(true)
                              updateRule(setDefaultRules, r.tempId, { min_precio: e.target.value })
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
                              setEscaleraTocadaAMano(true)
                              updateRule(setDefaultRules, r.tempId, { max_precio: e.target.value })
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
                              setEscaleraTocadaAMano(true)
                              updateRule(setDefaultRules, r.tempId, { incremento: e.target.value })
                            }}
                            className="mt-1 w-full rounded-lg bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm"
                          />
                        </label>
                      </div>
                    </div>
                  ))}

                  <button
                    type="button"
                    onClick={() => {
                      setEscaleraTocadaAMano(true)
                      addRule(setDefaultRules)
                    }}
                    className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  >
                    + Agregar tramo
                  </button>
                </div>
              ) : null}
            </>
          )}
        </section>
        {/* Caballos */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between">
            <h2 className="text-base font-semibold">4) Caballos</h2>
            <button
              onClick={addHorse}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs font-semibold"
            >
              + Agregar caballo
            </button>
          </div>

          {horses.length === 0 ? (
            <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3 text-sm text-zinc-400">
              Todavía no hay caballos. Agrégalos con el botón de arriba; cada uno sale en{" "}
              <b className="text-zinc-200">{formatoBs(n(salidaPorDefecto))} Bs</b>, el precio de salida del remate.
            </div>
          ) : null}

          <div className="mt-3 space-y-3">
            {horses.map((h) => (
              <div key={h.tempId} className="rounded-2xl bg-zinc-950/40 border border-zinc-800 p-3">
                <div className="flex items-center justify-between">
                  <div className="text-sm font-semibold">Caballo</div>
                  <button
                    onClick={() => removeHorse(h.tempId)}
                    className="text-xs text-red-200 bg-red-500/10 ring-1 ring-red-500/20 rounded-lg px-2 py-1"
                  >
                    Quitar
                  </button>
                </div>

                <div className="mt-3 grid grid-cols-3 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">No.</label>
                    <input
                      inputMode="numeric"
                      value={h.numero}
                      onChange={(e) => updateHorse(h.tempId, { numero: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="1"
                    />
                  </div>
                  <div className="col-span-2">
                    <label className="text-xs text-zinc-300">Nombre</label>
                    <input
                      value={h.nombre}
                      onChange={(e) => updateHorse(h.tempId, { nombre: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="Relámpago"
                    />
                  </div>
                </div>

                <div className="mt-2 grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">Jinete</label>
                    <input
                      value={h.jinete}
                      onChange={(e) => updateHorse(h.tempId, { jinete: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="J1"
                    />
                  </div>
                </div>

                <div className="mt-2 grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs text-zinc-300">Precio salida</label>
                    <input
                      inputMode="decimal"
                      value={h.precio_salida}
                      onChange={(e) => updateHorse(h.tempId, { precio_salida: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder={salidaPorDefecto || "100"}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-zinc-300">Comentario (opcional)</label>
                    <input
                      value={h.comentarios}
                      onChange={(e) => updateHorse(h.tempId, { comentarios: e.target.value })}
                      className="mt-1 w-full rounded-xl bg-zinc-900/40 border border-zinc-800 px-3 py-2 text-sm"
                      placeholder="Caballo veloz"
                    />
                  </div>
                </div>

                <div className="mt-3 rounded-xl bg-zinc-950/40 border border-zinc-800 p-3">
                  <div className="flex items-center justify-between">
                    <div className="text-xs text-zinc-300">Reglas propias</div>
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

                  {horseRulesEnabled[h.tempId] ? (
                    <div className="mt-3 space-y-2">
                      <div className="grid grid-cols-[1fr_1fr_1fr_auto] gap-2 text-[11px] text-zinc-500">
                        <div>Desde</div>
                        <div>Hasta</div>
                        <div>Incremento</div>
                        <div>Acción</div>
                      </div>
                      {(horseRulesByTempId[h.tempId] || []).map((r) => (
                        <div key={r.tempId} className="grid grid-cols-[1fr_1fr_1fr_auto] gap-2">
                          <input
                            inputMode="decimal"
                            value={r.min_precio}
                            onChange={(e) => updateHorseRule(h.tempId, r.tempId, { min_precio: e.target.value })}
                            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                            placeholder="Min"
                          />
                          <input
                            inputMode="decimal"
                            value={r.max_precio}
                            onChange={(e) => updateHorseRule(h.tempId, r.tempId, { max_precio: e.target.value })}
                            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                            placeholder="Max (opcional)"
                          />
                          <input
                            inputMode="decimal"
                            value={r.incremento}
                            onChange={(e) => updateHorseRule(h.tempId, r.tempId, { incremento: e.target.value })}
                            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                            placeholder="Incremento"
                          />
                          <button
                            onClick={() => removeHorseRule(h.tempId, r.tempId)}
                            className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                          >
                            Quitar
                          </button>
                        </div>
                      ))}
                      <button
                        onClick={() => addHorseRule(h.tempId)}
                        className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                      >
                        + Agregar rango
                      </button>
                    </div>
                  ) : (
                    <div className="mt-2 text-xs text-zinc-500">Usara las reglas default.</div>
                  )}
                </div>
              </div>
            ))}
            <button
              onClick={addHorse}
              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs font-semibold"
            >
              + Agregar caballo
            </button>
          </div>

          <div className="mt-3 text-xs text-zinc-500">
            Regla rapida: usa reglas default o activa reglas propias por caballo si necesitas mas control.
          </div>
        </section>

        {/* Guardar */}
        <button
          onClick={() => void onCreate()}
          disabled={!canSave || saving}
          className="mt-4 w-full rounded-xl bg-white text-zinc-950 font-semibold py-3 disabled:opacity-60"
        >
          {saving ? "Creando..." : "Crear remate"}
        </button>

        {createdRaceId || createdRemateId ? (
          <div className="mt-4 text-xs text-zinc-500">
            {createdRaceId ? <div>Race ID: {createdRaceId}</div> : null}
            {createdRemateId ? <div>Remate ID: {createdRemateId}</div> : null}
          </div>
        ) : null}
      </div>
    </main>
  )
}
