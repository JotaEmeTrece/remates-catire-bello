// app/admin/login/page.tsx
"use client"

import { useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

export default function AdminLoginPage() {
  const router = useRouter()
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState("")

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault()
    setError("")
    setLoading(true)

    const { data, error: loginErr } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password: password.trim(),
    })

    if (loginErr) {
      setLoading(false)
      return setError(loginErr.message)
    }

    const userId = data.user?.id
    if (!userId) {
      setLoading(false)
      return setError("Sesion invalida.")
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("es_admin,es_super_admin")
      .eq("id", userId)
      .maybeSingle()

    if (pErr) {
      await supabase.auth.signOut()
      setLoading(false)
      return setError(pErr.message)
    }

    if (!prof?.es_admin && !prof?.es_super_admin) {
      await supabase.auth.signOut()
      setLoading(false)
      return setError("No autorizado. Esta ruta es solo para administradores.")
    }

    setLoading(false)
    router.replace("/admin")
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 flex items-center justify-center">
      <div className="w-full max-w-sm rounded-2xl bg-zinc-900/60 border border-zinc-800 p-5">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Admin</h1>
          <Link href="/login" className="text-xs text-zinc-300 underline underline-offset-4">
            Login normal
          </Link>
        </div>

        <form onSubmit={handleLogin} className="mt-5 space-y-3">
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="admin@correo.com"
            className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
          />
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="contraseña"
            className="w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
          />

          {error ? (
            <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
              {error}
            </div>
          ) : null}

          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-xl bg-white text-zinc-950 font-semibold py-2 disabled:opacity-60"
          >
            {loading ? "Verificando..." : "Entrar como admin"}
          </button>
        </form>
      </div>
    </main>
  )
}
