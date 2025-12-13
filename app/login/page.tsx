"use client"

import { useState } from "react"
import { supabase } from "@/lib/supabaseClient"

export default function LoginPage() {
  const [email, setEmail] = useState("")
  const [sending, setSending] = useState(false)

  const handleLogin = async () => {
    if (!email) {
      alert("Escribe un correo primero")
      return
    }

    setSending(true)

    // ✅ Línea nueva (debug)
    console.log("RedirectTo:", `${window.location.origin}/auth/callback`)

    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        shouldCreateUser: true,
        emailRedirectTo: `${window.location.origin}/auth/callback`,
      },
    })

    setSending(false)

    if (error) {
      alert("Error enviando el link: " + error.message)
    } else {
      alert("Revisa tu correo, te enviamos un enlace para entrar.")
    }
  }

  return (
    <main className="min-h-screen flex flex-col items-center justify-center bg-zinc-950 text-zinc-50 px-4">
      <h1 className="text-xl font-bold mb-4">Iniciar sesión</h1>

      <input
        type="email"
        placeholder="tu@correo.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        className="w-full max-w-xs px-3 py-2 bg-zinc-900 rounded-lg border border-zinc-700 text-sm mb-4"
      />

      <button
        onClick={handleLogin}
        disabled={sending}
        className="w-full max-w-xs py-2 bg-green-600 rounded-lg text-sm font-semibold disabled:opacity-60"
      >
        {sending ? "Enviando..." : "Enviar enlace mágico"}
      </button>

      <p className="mt-4 text-xs text-zinc-500 text-center">
        Usa el mismo correo que registraste en Supabase.
      </p>
    </main>
  )
}

