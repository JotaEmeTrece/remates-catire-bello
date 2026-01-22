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

function caracasNowParts() {
  const d = new Date()
  return {
    date: formatDateInTz(d, CARACAS_TZ),
    time: formatTimeInTz(d, CARACAS_TZ),
  }
}

function buildCaracasTs(dateStr: string, timeStr: string) {
  if (!dateStr) return null
  let t = (timeStr || "").trim()
  if (!t) t = "00:00:00"
  if (t.length === 5) t = `${t}:00`
  return `${dateStr}T${t}-04:00`
}

function uid() {
  return Math.random().toString(16).slice(2) + Date.now().toString(16)
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
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
  const [raceNombre, setRaceNombre] = useState("Carrera de Prueba")
  const [raceHipodromo, setRaceHipodromo] = useState("La Rinconada")
  const [raceNumeroCarrera, setRaceNumeroCarrera] = useState("1")
  const [raceFecha, setRaceFecha] = useState(() => {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, "0")
    const dd = String(d.getDate()).padStart(2, "0")
    return `${yyyy}-${mm}-${dd}`
  })
  const [raceHora, setRaceHora] = useState("15:00:00")

  // =========================
  // Form Remate (remates)
  // =========================
  const [remateNombre, setRemateNombre] = useState("Remate de Prueba")
  const [incrementoMinimo, setIncrementoMinimo] = useState("20")
  const [apuestaMinima, setApuestaMinima] = useState("60")
  const [porcentajeCasa, setPorcentajeCasa] = useState("25")
  const nowCaracas = caracasNowParts()
  const [remateTipo, setRemateTipo] = useState<"vivo" | "adelantado">("vivo")
  const [opensDate, setOpensDate] = useState(nowCaracas.date)
  const [opensTime, setOpensTime] = useState(nowCaracas.time)
  const [closesDate, setClosesDate] = useState(raceFecha)
  const [closesTime, setClosesTime] = useState(raceHora || nowCaracas.time)
  const [closeTouched, setCloseTouched] = useState(false)

  useEffect(() => {
    if (!closeTouched) setClosesDate(raceFecha)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [raceFecha])

  useEffect(() => {
    if (!closeTouched && raceHora.trim()) setClosesTime(raceHora)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [raceHora])

  // =========================
  // Caballos (horses) - lista dinámica
  // NOTA: precio_salida es obligatorio (precio inicial del caballo).
  // =========================
  const [horses, setHorses] = useState<HorseDraft[]>([
    { tempId: uid(), numero: "1", nombre: "Relámpago", jinete: "J1", comentarios: "Caballo veloz", precio_salida: "60" },
    { tempId: uid(), numero: "2", nombre: "Tormenta", jinete: "J2", comentarios: "", precio_salida: "60" },
  ])

  // =========================
  // Reglas de precio (default y por caballo)
  // =========================
  const [defaultRules, setDefaultRules] = useState<PriceRuleDraft[]>([
    { tempId: uid(), min_precio: "0", max_precio: "100", incremento: "20" },
    { tempId: uid(), min_precio: "100", max_precio: "300", incremento: "30" },
    { tempId: uid(), min_precio: "300", max_precio: "600", incremento: "40" },
    { tempId: uid(), min_precio: "600", max_precio: "1000", incremento: "50" },
    { tempId: uid(), min_precio: "1000", max_precio: "2000", incremento: "100" },
    { tempId: uid(), min_precio: "2000", max_precio: "5000", incremento: "200" },
    { tempId: uid(), min_precio: "5000", max_precio: "10000", incremento: "300" },
    { tempId: uid(), min_precio: "10000", max_precio: "20000", incremento: "500" },
    { tempId: uid(), min_precio: "20000", max_precio: "30000", incremento: "800" },
    { tempId: uid(), min_precio: "30000", max_precio: "", incremento: "1000" },
  ])
  const [useDefaultRules, setUseDefaultRules] = useState(true)
  const [horseRulesEnabled, setHorseRulesEnabled] = useState<Record<string, boolean>>({})
  const [horseRulesByTempId, setHorseRulesByTempId] = useState<Record<string, PriceRuleDraft[]>>({})

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
    if (!raceNombre.trim()) return false
    if (!raceFecha) return false
    if (!remateNombre.trim()) return false

    const inc = n(incrementoMinimo)
    const min = n(apuestaMinima)
    const casa = n(porcentajeCasa)

    if (!(inc > 0)) return false
    if (!(min > 0)) return false
    if (!(casa >= 0 && casa <= 100)) return false

    const o = buildCaracasTs(opensDate, opensTime)
    const c = buildCaracasTs(closesDate, closesTime)
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
    raceNombre,
    raceFecha,
    remateNombre,
    incrementoMinimo,
    apuestaMinima,
    porcentajeCasa,
    opensDate,
    opensTime,
    closesDate,
    closesTime,
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
      { tempId: uid(), numero: nextNum, nombre: "", jinete: "", comentarios: "", precio_salida: apuestaMinima || "" },
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
      const raceInsert: any = {
        nombre: raceNombre.trim(),
        fecha: raceFecha,
        estado: "programada",
      }

      // hipodromo / numero_carrera / hora_programada son nullables (según tu schema)
      raceInsert.hipodromo = raceHipodromo.trim() ? raceHipodromo.trim() : null
      raceInsert.numero_carrera = raceNumeroCarrera.trim() ? Number(raceNumeroCarrera) : null
      raceInsert.hora_programada = raceHora.trim() ? raceHora.trim() : null

      const { data: raceData, error: raceErr } = await supabase
        .from("races")
        .insert(raceInsert)
        .select("id")
        .single()

      if (raceErr) throw new Error(raceErr.message)
      const raceId = raceData.id as string
      setCreatedRaceId(raceId)

      // 2) Crear Remate (remates) para esa carrera
      const remateInsert: any = {
        race_id: raceId,
        nombre: remateNombre.trim(),
        estado: "abierto",
        incremento_minimo: n(incrementoMinimo),
        apuesta_minima: n(apuestaMinima),
        porcentaje_casa: n(porcentajeCasa),
        tipo: remateTipo,
        opens_at: buildCaracasTs(opensDate, opensTime),
        closes_at: buildCaracasTs(closesDate, closesTime),
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
      <div className="mx-auto w-full max-w-md">
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
            <div>
              <label className="text-sm text-zinc-200">Descripcion de la carrera</label>
              <input
                value={raceNombre}
                onChange={(e) => setRaceNombre(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="Ej: La Rinconada - Carrera 1 - Clasico..."
              />
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Hipódromo</label>
                <input
                  value={raceHipodromo}
                  onChange={(e) => setRaceHipodromo(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="La Rinconada"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">No. carrera</label>
                <input
                  inputMode="numeric"
                  value={raceNumeroCarrera}
                  onChange={(e) => setRaceNumeroCarrera(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="1"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Fecha</label>
                <input
                  type="date"
                  value={raceFecha}
                  onChange={(e) => setRaceFecha(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Hora (opcional)</label>
                <input
                  value={raceHora}
                  onChange={(e) => setRaceHora(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="15:00:00"
                />
              </div>
            </div>
          </div>
        </section>

        {/* Remate */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <h2 className="text-base font-semibold">2) Remate</h2>

          <div className="mt-3 space-y-3">
            <div>
              <label className="text-sm text-zinc-200">Nombre</label>
              <input
                value={remateNombre}
                onChange={(e) => setRemateNombre(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="Remate de Prueba"
              />
            </div>

            <div className="grid grid-cols-3 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Apuesta mínima</label>
                <input
                  inputMode="decimal"
                  value={apuestaMinima}
                  onChange={(e) => setApuestaMinima(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="60"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Incremento</label>
                <input
                  inputMode="decimal"
                  value={incrementoMinimo}
                  onChange={(e) => setIncrementoMinimo(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="20"
                />
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
                <input
                  type="date"
                  value={opensDate}
                  onChange={(e) => setOpensDate(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="text-sm text-zinc-200">Apertura (hora)</label>
                <input
                  value={opensTime}
                  onChange={(e) => setOpensTime(e.target.value)}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  placeholder="07:00:00"
                />
              </div>
              <div>
                <label className="text-sm text-zinc-200">Cierre (fecha)</label>
                <input
                  type="date"
                  value={closesDate}
                  onChange={(e) => {
                    setCloseTouched(true)
                    setClosesDate(e.target.value)
                  }}
                  className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                />
              </div>
            </div>

            <div>
              <label className="text-sm text-zinc-200">Cierre (hora)</label>
              <input
                value={closesTime}
                onChange={(e) => {
                  setCloseTouched(true)
                  setClosesTime(e.target.value)
                }}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                placeholder="19:00:00"
              />
              <p className="mt-1 text-xs text-zinc-400">
                Horario Venezuela (America/Caracas).
              </p>
            </div>
          </div>
        </section>

        {/* Reglas default */}
        <section className="mt-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div className="flex items-center justify-between">
            <h2 className="text-base font-semibold">3) Reglas default</h2>
            <label className="text-xs text-zinc-300 flex items-center gap-2">
              <input
                type="checkbox"
                checked={useDefaultRules}
                onChange={(e) => setUseDefaultRules(e.target.checked)}
              />
              Usar reglas default
            </label>
          </div>

          <p className="mt-2 text-xs text-zinc-400">
            Estas reglas aplican a caballos que no tengan reglas propias. Se usan rangos: min inclusive, max exclusivo.
          </p>

          {useDefaultRules ? (
            <div className="mt-3 space-y-2">
              {defaultRules.map((r) => (
                <div key={r.tempId} className="grid grid-cols-[1fr_1fr_1fr_auto] gap-2">
                  <input
                    inputMode="decimal"
                    value={r.min_precio}
                    onChange={(e) => updateRule(setDefaultRules, r.tempId, { min_precio: e.target.value })}
                    className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                    placeholder="Min"
                  />
                  <input
                    inputMode="decimal"
                    value={r.max_precio}
                    onChange={(e) => updateRule(setDefaultRules, r.tempId, { max_precio: e.target.value })}
                    className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                    placeholder="Max (opcional)"
                  />
                  <input
                    inputMode="decimal"
                    value={r.incremento}
                    onChange={(e) => updateRule(setDefaultRules, r.tempId, { incremento: e.target.value })}
                    className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                    placeholder="Incremento"
                  />
                  <button
                    onClick={() => removeRule(setDefaultRules, r.tempId)}
                    className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
                  >
                    Quitar
                  </button>
                </div>
              ))}
              <button
                onClick={() => addRule(setDefaultRules)}
                className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-xs"
              >
                + Agregar rango
              </button>
            </div>
          ) : null}
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
                      placeholder={apuestaMinima || "60"}
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
