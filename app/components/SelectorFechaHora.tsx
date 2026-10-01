"use client"

// ===========================================================================
//  SelectorFechaHora
//
//  POR QUE EXISTE (01/10/2026)
//
//  Las fechas se escribian en tres cajas de texto (dd / mm / aa) y la hora en
//  una cuarta en formato libre ("7:00 pm"). Dos problemas que Jota encontro
//  usandolo:
//
//    1. Venian PRELLENADAS con el momento de entrar al formulario. Como crear
//       un remate toma unos minutos, la hora de apertura ya habia pasado
//       cuando le daba a Crear, y el boton se quedaba gris sin decir por que.
//    2. Se escriben a mano, asi que hay que teclear cuatro campos por fecha y
//       cada uno puede salir mal.
//
//  Peticion suya, literal: "pongamosla que empiecen vacias y que al admin las
//  ponga, pero hagamoslo con listas select para que no tengan que estar
//  escribiendo". El caso de uso que describio manda en el diseno: un admin
//  monta las carreras del sabado y el domingo el martes por la noche, asi que
//  la lista de fechas tiene que llegar comodamente a dos meses.
//
//  LO QUE ESTE COMPONENTE NO CAMBIA
//
//  Sigue hablando el mismo idioma que las pantallas: entrega `dd`, `mm`, `aa`
//  y una hora en 12h ("7:30 pm"), que es exactamente lo que ya guardan en su
//  estado y lo que ya saben parsear `parseDateParts` y `parseTime12hTo24`.
//  Cambia como se introduce el dato, no el dato. Asi el guardado, la
//  validacion y el calculo del timestamp de Caracas se quedan como estan.
//
//  EL CASO QUE SE ESCAPA SI NO SE PIENSA
//
//  La lista arranca HOY. Un remate viejo tiene fechas en el pasado, y si la
//  lista no las incluye, abrir ese remate para editarlo le borraria la fecha
//  en silencio. Por eso el valor que llega por props se anade siempre como
//  opcion, aunque caiga fuera del rango.
// ===========================================================================

const CARACAS_TZ = "America/Caracas"

function isoEnCaracas(d: Date) {
  // en-CA da yyyy-mm-dd, que es justo lo que necesitamos.
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: CARACAS_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d)
}

// Etiqueta legible: "sab 3 oct". Se construye a mediodia UTC a proposito: a
// las 00:00 cualquier desplazamiento de zona mueve el dia uno para atras.
function etiquetaDeIso(iso: string) {
  const [y, m, d] = iso.split("-").map(Number)
  if (!y || !m || !d) return iso
  const fecha = new Date(Date.UTC(y, m - 1, d, 12, 0, 0))
  const txt = new Intl.DateTimeFormat("es-VE", {
    timeZone: "UTC",
    weekday: "short",
    day: "numeric",
    month: "short",
  }).format(fecha)
  // es-VE mete puntos y comas segun el navegador: "sáb., 3 oct". Se limpia.
  return txt.replace(/\./g, "").replace(/,/g, "")
}

function sumarDias(iso: string, dias: number) {
  const [y, m, d] = iso.split("-").map(Number)
  const base = new Date(Date.UTC(y, m - 1, d, 12, 0, 0))
  base.setUTCDate(base.getUTCDate() + dias)
  const yy = base.getUTCFullYear()
  const mm = String(base.getUTCMonth() + 1).padStart(2, "0")
  const dd = String(base.getUTCDate()).padStart(2, "0")
  return `${yy}-${mm}-${dd}`
}

function isoDesdePartes(dd: string, mm: string, aa: string) {
  // OJO AL ORDEN: lo vacio se comprueba ANTES de rellenar con ceros.
  // La primera version padeaba primero, con lo cual "" se convertia en "00",
  // pasaba el control de "esta vacio?" y devolvia "2000-00-00". Esa fecha
  // fantasma no esta en la lista de opciones, asi que el select no encontraba
  // su valor y el placeholder "— elegir —" dejaba de salir seleccionado.
  // Lo caso una prueba de las funciones puras, no el compilador.
  const d = dd.trim()
  const m = mm.trim()
  const a = aa.trim()
  if (!d || !m || !a) return ""

  const dn = Number(d)
  const mn = Number(m)
  const an = Number(a)
  if (!Number.isFinite(dn) || !Number.isFinite(mn) || !Number.isFinite(an)) return ""
  if (dn < 1 || dn > 31) return ""
  if (mn < 1 || mn > 12) return ""
  if (an < 0 || an > 99) return ""

  return `20${String(an).padStart(2, "0")}-${String(mn).padStart(2, "0")}-${String(dn).padStart(2, "0")}`
}

function partesDesdeIso(iso: string) {
  const p = iso.split("-")
  if (p.length !== 3) return { dd: "", mm: "", aa: "" }
  return { dd: p[2], mm: p[1], aa: p[0].slice(-2) }
}

// De "7:30 pm" a { hora24: "19", minuto: "30" }. Devuelve vacios si no se
// entiende, que es lo correcto: un campo vacio se ve vacio.
function partesDeHora12(hora12: string) {
  const s = String(hora12 || "").trim().toLowerCase().replace(/\s+/g, " ")
  const m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/)
  if (!m) return { hora24: "", minuto: "" }
  let h = Number(m[1])
  const min = m[2] ?? "00"
  if (!Number.isFinite(h) || h < 1 || h > 12) return { hora24: "", minuto: "" }
  if (m[3] === "pm" && h !== 12) h += 12
  if (m[3] === "am" && h === 12) h = 0
  return { hora24: String(h).padStart(2, "0"), minuto: min }
}

function hora12DesdePartes(hora24: string, minuto: string) {
  if (!hora24) return ""
  const h = Number(hora24)
  if (!Number.isFinite(h)) return ""
  const min = (minuto || "00").padStart(2, "0")
  const pm = h >= 12
  const h12 = h % 12 === 0 ? 12 : h % 12
  return `${h12}:${min} ${pm ? "pm" : "am"}`
}

// El nombre del dia de una fecha, capitalizado: "Sábado". Lo usa el formulario
// para rellenar el campo "Día" a partir de la fecha elegida, en vez de tenerlo
// como un segundo dato que el admin escribe y que puede contradecir a la fecha.
export function nombreDiaDeIso(iso: string) {
  const [y, m, d] = String(iso || "").split("-").map(Number)
  if (!y || !m || !d) return ""
  const fecha = new Date(Date.UTC(y, m - 1, d, 12, 0, 0))
  const txt = new Intl.DateTimeFormat("es-VE", { timeZone: "UTC", weekday: "long" }).format(fecha)
  return txt.charAt(0).toUpperCase() + txt.slice(1)
}

const MINUTOS = ["00", "05", "10", "15", "20", "25", "30", "35", "40", "45", "50", "55"]

export type ValorFechaHora = { dd: string; mm: string; aa: string; hora12: string }

export default function SelectorFechaHora({
  etiqueta,
  valor,
  onChange,
  diasAdelante = 60,
  opcional = false,
  ayuda,
}: {
  etiqueta: string
  valor: ValorFechaHora
  onChange: (v: ValorFechaHora) => void
  diasAdelante?: number
  opcional?: boolean
  ayuda?: string
}) {
  const isoActual = isoDesdePartes(valor.dd, valor.mm, valor.aa)
  const hoy = isoEnCaracas(new Date())

  const fechas: string[] = []
  for (let i = 0; i < diasAdelante; i++) fechas.push(sumarDias(hoy, i))
  // El valor que ya tenia el remate, aunque sea del pasado. Sin esto, editar
  // un remate viejo le borraria la fecha al abrirlo.
  if (isoActual && !fechas.includes(isoActual)) fechas.unshift(isoActual)

  const { hora24, minuto } = partesDeHora12(valor.hora12)

  const clase =
    "mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-2 py-2 text-sm text-zinc-100"

  function cambiarFecha(iso: string) {
    if (!iso) return onChange({ ...valor, dd: "", mm: "", aa: "" })
    const p = partesDesdeIso(iso)
    onChange({ ...valor, ...p })
  }

  function cambiarHora(h: string) {
    if (!h) return onChange({ ...valor, hora12: "" })
    // Al elegir una hora, los minutos arrancan en 00 si no habia nada: pedir
    // dos clics para "a las 7 en punto" es pedir uno de mas.
    onChange({ ...valor, hora12: hora12DesdePartes(h, minuto || "00") })
  }

  function cambiarMinuto(min: string) {
    if (!hora24) return
    onChange({ ...valor, hora12: hora12DesdePartes(hora24, min) })
  }

  return (
    <div>
      <div className="flex items-baseline justify-between gap-2">
        <label className="text-sm text-zinc-200">{etiqueta}</label>
        {opcional ? <span className="text-[11px] text-zinc-500">opcional</span> : null}
      </div>

      <div className="mt-1 grid grid-cols-[1fr_auto_auto] gap-2 items-end">
        <div>
          <span className="block text-[11px] text-zinc-500">Día</span>
          <select value={isoActual} onChange={(e) => cambiarFecha(e.target.value)} className={clase}>
            <option value="">— elegir —</option>
            {fechas.map((f) => (
              <option key={f} value={f}>
                {etiquetaDeIso(f)}
                {f === hoy ? " (hoy)" : ""}
              </option>
            ))}
          </select>
        </div>

        <div>
          <span className="block text-[11px] text-zinc-500">Hora</span>
          <select value={hora24} onChange={(e) => cambiarHora(e.target.value)} className={clase}>
            <option value="">—</option>
            {Array.from({ length: 24 }, (_, h) => String(h).padStart(2, "0")).map((h) => (
              <option key={h} value={h}>
                {hora12DesdePartes(h, "00").replace(":00 ", " ")}
              </option>
            ))}
          </select>
        </div>

        <div>
          <span className="block text-[11px] text-zinc-500">Min</span>
          <select
            value={minuto}
            onChange={(e) => cambiarMinuto(e.target.value)}
            disabled={!hora24}
            className={`${clase} disabled:opacity-50`}
          >
            <option value="">—</option>
            {MINUTOS.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </div>
      </div>

      {ayuda ? <div className="mt-1 text-[11px] text-zinc-500">{ayuda}</div> : null}
    </div>
  )
}
