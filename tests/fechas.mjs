// ===========================================================================
//  tests/fechas.mjs
//
//  PARA QUE: la aritmetica de fechas y horas de
//  app/components/SelectorFechaHora.tsx. Es el tipo de codigo donde un dia de
//  diferencia no se nota mirando la pantalla, y donde el compilador no ayuda
//  porque todo son strings bien tipados.
//
//  LO QUE YA CAZO (01/10/2026): `isoDesdePartes("","","")` devolvia
//  "2000-00-00" en vez de "". Rellenaba con ceros ANTES de comprobar si estaba
//  vacio, asi que "" se convertia en "00" y pasaba el control. En pantalla eso
//  significaba que un valor vacio no coincidia con ninguna opcion del select y
//  el "— elegir —" dejaba de salir seleccionado. No lo habria visto el
//  compilador ni el arnes de SQL.
//
//  COMO: se transpila el archivo REAL con el propio TypeScript y se extraen
//  sus funciones del JS resultante. No hay una copia de las funciones aqui, a
//  proposito: una copia se separa del original y entonces la prueba miente.
//
//  COMO SE CORRE, desde la raiz del repo:
//
//      node tests/fechas.mjs
//
//  Sale 0 si todo esta en verde y 1 si algo falla, asi que vale para CI.
// ===========================================================================

import fs from "fs"
import ts from "typescript"

const ARCHIVO = "app/components/SelectorFechaHora.tsx"
const src = fs.readFileSync(ARCHIVO, "utf8")

const js = ts.transpileModule(src, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None, jsx: ts.JsxEmit.None },
}).outputText

const nombres = [
  "isoEnCaracas", "etiquetaDeIso", "sumarDias", "isoDesdePartes",
  "partesDesdeIso", "partesDeHora12", "hora12DesdePartes", "nombreDiaDeIso",
]

function saca(nombre) {
  const i = js.indexOf(`function ${nombre}(`)
  if (i < 0) throw new Error(`no se encontro ${nombre} en ${ARCHIVO}`)
  const j = js.indexOf("\n}\n", i) + 2
  return js.slice(i, j)
}

const f = new Function(nombres.map(saca).join("\n") + `\nreturn {${nombres.join(",")}}`)()

let fallos = 0
function ok(nombre, real, esperado) {
  const bien = JSON.stringify(real) === JSON.stringify(esperado)
  if (!bien) fallos++
  console.log(
    `${bien ? "ok   " : "FALLA"} ${nombre}: ${JSON.stringify(real)}` +
    (bien ? "" : `  <- esperado ${JSON.stringify(esperado)}`)
  )
}

// --------------------------------------------------- sumar dias
ok("31 ene + 1",                 f.sumarDias("2026-01-31", 1),  "2026-02-01")
ok("28 feb + 1 (anio normal)",   f.sumarDias("2026-02-28", 1),  "2026-03-01")
ok("28 feb + 1 (bisiesto)",      f.sumarDias("2028-02-28", 1),  "2028-02-29")
ok("31 dic + 1",                 f.sumarDias("2026-12-31", 1),  "2027-01-01")
ok("+59 (final de la lista)",    f.sumarDias("2026-10-01", 59), "2026-11-29")
ok("+0 no mueve",                f.sumarDias("2026-10-01", 0),  "2026-10-01")

// --------------------------------------------------- partes <-> iso
ok("iso desde partes",     f.isoDesdePartes("03","10","26"), "2026-10-03")
ok("partes desde iso",     f.partesDesdeIso("2026-10-03"), {dd:"03",mm:"10",aa:"26"})
ok("todo vacio",           f.isoDesdePartes("","",""), "")
ok("una parte vacia",      f.isoDesdePartes("03","","26"), "")
ok("dia 00 invalido",      f.isoDesdePartes("00","10","26"), "")
ok("dia 32 invalido",      f.isoDesdePartes("32","10","26"), "")
ok("mes 13 invalido",      f.isoDesdePartes("03","13","26"), "")
ok("sin ceros delante",    f.isoDesdePartes("3","1","26"), "2026-01-03")

// --------------------------------------------------- dia de la semana
ok("3 oct 2026 es sabado", f.nombreDiaDeIso("2026-10-03"), "Sábado")
ok("1 oct 2026 es jueves", f.nombreDiaDeIso("2026-10-01"), "Jueves")
ok("dia de vacio",         f.nombreDiaDeIso(""), "")

// --------------------------------------------------- horas
ok("12h -> partes (pm)",   f.partesDeHora12("7:30 pm"), {hora24:"19",minuto:"30"})
ok("12h -> partes (am)",   f.partesDeHora12("7:05 am"), {hora24:"07",minuto:"05"})
ok("medianoche",           f.partesDeHora12("12:00 am"), {hora24:"00",minuto:"00"})
ok("mediodia",             f.partesDeHora12("12:00 pm"), {hora24:"12",minuto:"00"})
ok("basura -> vacio",      f.partesDeHora12("asdf"), {hora24:"",minuto:""})
ok("vacio -> vacio",       f.partesDeHora12(""), {hora24:"",minuto:""})
ok("partes -> 12h",        f.hora12DesdePartes("19","30"), "7:30 pm")
ok("partes -> 12h (00)",   f.hora12DesdePartes("00","00"), "12:00 am")
ok("partes -> 12h (12)",   f.hora12DesdePartes("12","15"), "12:15 pm")
ok("sin hora -> vacio",    f.hora12DesdePartes("","30"), "")

// Ida y vuelta de todas las combinaciones que el selector puede producir.
// Si alguna no vuelve igual, el admin elige una hora y se guarda otra.
let rt = 0
for (let h = 0; h < 24; h++) {
  for (const m of ["00","05","10","15","20","25","30","35","40","45","50","55"]) {
    const hh = String(h).padStart(2,"0")
    const v = f.partesDeHora12(f.hora12DesdePartes(hh, m))
    if (v.hora24 === hh && v.minuto === m) rt++
    else { console.log(`FALLA ida y vuelta ${hh}:${m}`); fallos++ }
  }
}
ok("ida y vuelta de las 288 combinaciones", rt, 288)

// --------------------------------------------------- la lista de 60 dias
const lista = Array.from({length:60}, (_,i) => f.sumarDias("2026-10-01", i))
ok("60 fechas distintas", new Set(lista).size, 60)
ok("ninguna mal formada", lista.filter(x => !/^\d{4}-\d{2}-\d{2}$/.test(x)).length, 0)

console.log("\netiquetas de muestra:")
for (const x of ["2026-10-03","2026-11-29","2027-01-01"]) {
  console.log(`   ${x} -> ${JSON.stringify(f.etiquetaDeIso(x))}`)
}

console.log(fallos === 0 ? "\n=== TODO EN VERDE ===" : `\n=== ${fallos} FALLO(S) ===`)
process.exit(fallos ? 1 : 0)
