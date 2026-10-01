// ===========================================================================
//  lib/escalera.ts  -  LA ESCALERA DE INCREMENTOS, UNA SOLA VEZ
//
//  POR QUE ESTE ARCHIVO EXISTE (01/10/2026)
//
//  Esta maquinaria vivia dentro de app/admin/crear-remate/page.tsx. La
//  pantalla de MODIFICAR un remate no la tenia, asi que alli la escalera
//  propia de un caballo se editaba con la tabla cruda de min/max/incremento:
//  la misma regla con dos interfaces distintas, y la de editar era la peor.
//
//  Copiarla de un archivo a otro habria sido crear la segunda implementacion
//  de algo que ya existe, que es literalmente el defecto que persigue el
//  ADR-015. Asi que se saca aqui y las dos pantallas la importan.
//
//  OJO CON EL ALCANCE. Esto es PRESENTACION, no una regla de dinero. Lo que
//  la base va a cobrar lo decide `_incremento_aplicable()` y lo publica
//  `remate_minimos()`; el frontend muestra, no calcula (ADR-008, ADR-015).
//  Lo que hay aqui es el generador de una propuesta de tramos y la simulacion
//  que la hace entendible. El unico trozo que replica a la base es
//  `incrementoPara`, y esta ahi para que la SIMULACION diga la verdad; si
//  algun dia divergen, la que manda es la base y esto es el que esta mal.
//
//  COMO FUNCIONAN LOS TRAMOS
//
//  Antes eran 10 filas escritas a mano que arrancaban en 0, aunque ningun
//  caballo saliera nunca por debajo de su precio de salida: media tabla no se
//  usaba jamas. Ahora se GENERAN desde el precio de salida. Los tramos son
//  multiplos de la salida (1x, 5x, 10x, 50x, 100x) y el incremento de cada
//  tramo es una fraccion de la misma salida, asi que la escalera se recalcula
//  sola si cambias la salida y el incremento siempre queda entre el 5% y el
//  50% del precio en curso -- el rango en que una subasta avanza sin
//  eternizarse ni pegar saltos brutales.
// ===========================================================================

export type PriceRuleDraft = {
  // `id` solo lo trae la pantalla de editar, que lee reglas ya guardadas.
  id?: string
  tempId: string
  min_precio: string
  max_precio: string
  incremento: string
}

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

export const RITMOS: RitmoEscalera[] = ["suave", "normal", "agresiva"]

function uid() {
  return Math.random().toString(36).slice(2, 10)
}

function n(v: string | number | null | undefined) {
  if (v === null || v === undefined || v === "") return 0
  const x = Number(String(v).replace(",", "."))
  return Number.isFinite(x) ? x : 0
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

// Valida una escalera: devuelve la lista de problemas, vacia si esta bien.
// `minIncremento` es el minimo de la INSTALACION (ajustes_instalacion); se
// pasa como null cuando no se pudo leer, y entonces no se comprueba.
export function problemasEscalera(
  lista: PriceRuleDraft[],
  minIncremento: number | null,
  etiqueta: string
): string[] {
  const p: string[] = []
  if (!lista || lista.length === 0) {
    p.push(`${etiqueta}: reglas propias activadas pero sin ningún tramo`)
    return p
  }
  for (const r of lista) {
    const min = n(r.min_precio)
    const inc = n(r.incremento)
    const max = r.max_precio.trim() ? n(r.max_precio) : null
    if (!(min >= 0)) p.push(`${etiqueta}: un tramo sin "desde"`)
    if (!(inc > 0)) {
      p.push(`${etiqueta}: un tramo sin incremento`)
    } else if (minIncremento !== null && inc < minIncremento) {
      p.push(`${etiqueta}: un tramo sube ${inc} Bs y el mínimo es ${minIncremento} Bs`)
    }
    if (max !== null && !(max > min)) p.push(`${etiqueta}: un tramo con "hasta" menor que "desde"`)
  }
  return Array.from(new Set(p))
}
