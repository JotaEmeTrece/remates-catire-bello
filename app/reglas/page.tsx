// app/reglas/page.tsx
"use client"

import Link from "next/link"
import { CornerLogo } from "@/app/components/BrandLogo"

export default function ReglasPage() {
  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-2xl">
        <div className="mb-3">
          <CornerLogo />
        </div>

        <div className="flex items-center justify-between">
          <h1 className="text-2xl font-bold">Reglas del Remate</h1>
          <Link href="/remates" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver a remates
          </Link>
        </div>

        <div className="mt-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-200">
          Este sistema permite pujar por caballos en carreras reales. Las reglas de funcionamiento están aquí para que
          todos tengan claridad y transparencia.
        </div>

        <section className="mt-6 space-y-4">
          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">1) Qué es un remate</h2>
            <p className="mt-2 text-sm text-zinc-300">
              Cada remate corresponde a una carrera real. Los usuarios pujan por cada caballo mientras el remate está
              abierto. Al cerrar el remate, queda un ganador por cada caballo (la puja más alta).
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">2) Tipos de remate</h2>
            <ul className="mt-2 text-sm text-zinc-300 list-disc pl-5 space-y-1">
              <li>
                <span className="font-semibold">En vivo:</span> se usa el día de la carrera (cierra minutos antes de
                iniciar).
              </li>
              <li>
                <span className="font-semibold">Adelantado:</span> se abre días antes para pujar con anticipación.
              </li>
            </ul>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">3) Horarios (Venezuela)</h2>
            <ul className="mt-2 text-sm text-zinc-300 list-disc pl-5 space-y-1">
              <li>Todos los horarios del sistema se manejan en hora de Venezuela (America/Caracas).</li>
              <li>Solo se puede pujar dentro de la ventana de apertura y cierre del remate.</li>
              <li>El cierre es automático, pero la liquidación nunca es automática.</li>
            </ul>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">4) Cómo se puja</h2>
            <ul className="mt-2 text-sm text-zinc-300 list-disc pl-5 space-y-1">
              <li>
                <span className="font-semibold">Ponerle (auto):</span> sube al mínimo permitido según las reglas del
                remate.
              </li>
              <li>
                <span className="font-semibold">Manual:</span> el usuario escribe un monto y luego presiona Ponerle para
                enviar esa puja.
              </li>
            </ul>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">5) Reglas de incrementos (rangos)</h2>
            <p className="mt-2 text-sm text-zinc-300">
              El admin define incrementos por rangos de precio (por ejemplo: de 0 a 100 sube de 20, de 100 a 300 sube de
              30, etc.). Si un caballo tiene reglas propias, se usan esas; si no, se aplican las reglas por defecto.
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">6) Mínimos permitidos</h2>
            <ul className="mt-2 text-sm text-zinc-300 list-disc pl-5 space-y-1">
              <li>Auto mínimo = precio actual + incremento del rango.</li>
              <li>Manual mínimo = auto mínimo + 10 Bs.</li>
              <li>El sistema no permite pujas por debajo del mínimo.</li>
            </ul>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">7) Transparencia y privacidad</h2>
            <p className="mt-2 text-sm text-zinc-300">
              Las pujas son públicas por transparencia, pero solo se muestra el username. No se muestran datos privados
              como email, teléfono o ID real.
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">8) Dinero disponible vs bloqueado</h2>
            <p className="mt-2 text-sm text-zinc-300">
              Para pujar necesitas saldo disponible. Cada puja bloquea saldo. Si vuelves a pujar por el mismo caballo y
              ya ibas ganando, solo se bloquea la diferencia. Si otro usuario te supera, tu saldo no se libera hasta el
              cierre del remate.
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">9) Qué pasa al cerrar el remate</h2>
            <p className="mt-2 text-sm text-zinc-300">
              Al cerrar, queda definido el ganador por cada caballo. Se devuelven las apuestas perdedoras y se mantiene
              bloqueado el saldo de los caballos que cada usuario ganó.
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">10) Pozo total y 25% casa</h2>
            <p className="mt-2 text-sm text-zinc-300">
              El pozo total es la suma del precio final de cada caballo (mejor puja o precio de salida si no hubo pujas).
              La casa retiene 25% y el 75% es el premio si gana un usuario.
            </p>
          </div>

          <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
            <h2 className="text-base font-semibold">11) Liquidación (después de la carrera)</h2>
            <p className="mt-2 text-sm text-zinc-300">
              El admin selecciona el caballo ganador. Si ese caballo fue ganado por un usuario, recibe el pozo menos 25%
              de la casa. Si el caballo ganador quedó para la casa, la casa recibe el 100% del pozo.
            </p>
          </div>
        </section>
      </div>
    </main>
  )
}
