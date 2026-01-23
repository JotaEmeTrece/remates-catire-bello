// app/register/page.tsx
"use client"

import { useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import { CornerLogo } from "@/app/components/BrandLogo"

export default function RegisterPage() {
  const router = useRouter()

  const [username, setUsername] = useState("")
  const [telefono, setTelefono] = useState("")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [password2, setPassword2] = useState("")

  const [loading, setLoading] = useState(false)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")

  async function handleRegister(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setOk("")

    const u = username.trim()
    const t = telefono.trim()
    const em = email.trim()
    const p1 = password
    const p2 = password2

    if (!u) return setError("Escribe tu nombre o apodo.")
    if (!t) return setError("Escribe tu teléfono.")
    if (!em) return setError("Escribe tu correo.")
    if (!p1) return setError("Escribe una contraseña.")
    if (p1.length < 8) return setError("La contraseña debe tener al menos 8 caracteres.")
    if (p1 !== p2) return setError("Las contraseñas no coinciden.")

    setLoading(true)

    /**
     * CLAVE:
     * - options.data => va a raw_user_meta_data
     * - tu trigger handle_new_user() toma username/telefono de ahí
     * - con Confirm Email ON, NO hay session en el signUp, pero el trigger igual crea profile/wallet
     *   (si tu trigger está bien, que ya te dio 1 y 1)
     */
    const { data, error: signErr } = await supabase.auth.signUp({
      email: em,
      password: p1,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback`,
        data: {
          username: u,
          telefono: t,
        },
      },
    })

    if (signErr) {
      setLoading(false)
      return setError(signErr.message)
    }

    const hasSession = !!data.session

    setLoading(false)

    if (hasSession) {
      router.replace("/dashboard")
      return
    }

    setOk("Cuenta creada. Revisa tu correo para confirmar y luego inicia sesión.")
    setUsername("")
    setTelefono("")
    setEmail("")
    setPassword("")
    setPassword2("")
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 flex items-center justify-center">
      <div className="w-full max-w-sm">
        <div className="mb-3">
          <CornerLogo />
        </div>
        <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-5">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Crear cuenta</h1>
          <div className="flex items-center gap-3 text-xs text-zinc-300">
            <Link href="/reglas" className="underline underline-offset-4">
              Reglas
            </Link>
            <Link href="/login" className="underline underline-offset-4">
              Volver
            </Link>
          </div>
        </div>

        <form onSubmit={handleRegister} className="mt-5 space-y-3">
          <div>
            <label className="text-sm text-zinc-200">Nombre o apodo</label>
            <input
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: Jota"
              autoComplete="nickname"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Teléfono</label>
            <input
              value={telefono}
              onChange={(e) => setTelefono(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="Ej: 0412xxxxxxx"
              autoComplete="tel"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Correo</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="tu@correo.com"
              autoComplete="email"
            />
            <p className="mt-1 text-[11px] text-zinc-500">Usa un correo real y que esté activo.</p>
          </div>

          <div>
            <label className="text-sm text-zinc-200">Contraseña</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="********"
              autoComplete="new-password"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Confirmar contraseña</label>
            <input
              type="password"
              value={password2}
              onChange={(e) => setPassword2(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
              placeholder="********"
              autoComplete="new-password"
            />
          </div>

          {error ? (
            <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
          ) : null}
          {ok ? (
            <div className="rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
              {ok}
            </div>
          ) : null}

          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
          >
            {loading ? "Creando..." : "Crear cuenta"}
          </button>
        </form>
        </div>
      </div>
    </main>
  )
}
