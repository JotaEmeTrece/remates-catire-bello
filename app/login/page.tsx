"use client"

import { useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"
import { HeroLogo } from "@/app/components/BrandLogo"

export default function LoginPage() {
  const router = useRouter()

  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string>("")
  const [info, setInfo] = useState<string>("")

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setInfo("")

    if (!email.trim()) return setError("Escribe tu correo.")
    if (!password) return setError("Escribe tu contraseña.")

    setLoading(true)

    const { data, error: authErr } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })

    if (authErr) {
      setLoading(false)

      const msg = authErr.message?.toLowerCase() || ""
      if (msg.includes("email not confirmed") || msg.includes("not confirmed")) {
        setError("Tu correo aún no está confirmado. Revisa tu email y confirma tu cuenta.")
        return
      }

      setError(authErr.message || "Error iniciando sesión.")
      return
    }

    const user = data.user
    if (!user) {
      setLoading(false)
      setError("No se pudo obtener el usuario. Intenta de nuevo.")
      return
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("es_admin,es_super_admin")
      .eq("id", user.id)
      .maybeSingle()

    setLoading(false)

    if (pErr) {
      router.replace("/dashboard")
      return
    }

    if (prof?.es_admin || prof?.es_super_admin) router.replace("/admin")
    else router.replace("/dashboard")
  }

  async function handleForgot() {
    setError("")
    setInfo("")

    const mail = email.trim()
    if (!mail) {
      setError("Escribe tu correo para recuperar la contraseña.")
      return
    }

    const { error: resetErr } = await supabase.auth.resetPasswordForEmail(mail, {
      redirectTo: `${window.location.origin}/auth/reset`,
    })

    if (resetErr) {
      setError(resetErr.message || "Error enviando el correo de recuperación.")
      return
    }

    setInfo("Te enviamos un link de recuperación. Revisa tu correo.")
  }

  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50 px-4 py-10">
      <div className="mx-auto w-full max-w-md">
        <div className="mb-6">
          <HeroLogo />
        </div>
        <h1 className="text-2xl font-bold">Iniciar sesión</h1>
        <p className="mt-2 text-sm text-zinc-300">Usa un correo real y que esté activo.</p>

        <form onSubmit={handleLogin} className="mt-6 space-y-3 rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
          <div>
            <label className="text-sm text-zinc-200">Correo</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/50 border border-zinc-800 px-3 py-2 text-base outline-none focus:ring-2 focus:ring-white/10"
              placeholder="tu@correo.com"
            />
          </div>

          <div>
            <label className="text-sm text-zinc-200">Contraseña</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full rounded-xl bg-zinc-950/50 border border-zinc-800 px-3 py-2 text-base outline-none focus:ring-2 focus:ring-white/10"
              placeholder="********"
            />
          </div>

          {error ? (
            <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
              {error}
            </div>
          ) : null}
          {info ? (
            <div className="rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
              {info}
            </div>
          ) : null}

          <button
            type="button"
            onClick={() => void handleForgot()}
            className="text-left text-xs text-zinc-300 underline underline-offset-4"
          >
            Olvidé mi contraseña
          </button>

          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-xl bg-white px-4 py-2 text-base font-semibold text-zinc-950 disabled:opacity-60"
          >
            {loading ? "Entrando..." : "Entrar"}
          </button>

          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>¿No tienes cuenta?</span>
            <Link href="/register" className="text-zinc-200 underline underline-offset-4">
              Registrarme
            </Link>
          </div>
        </form>
      </div>
    </main>
  )
}
