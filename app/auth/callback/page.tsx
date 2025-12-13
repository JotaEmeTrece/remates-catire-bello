"use client"

import { useEffect } from "react"
import { supabase } from "@/lib/supabaseClient"

export default function AuthCallbackPage() {
  useEffect(() => {
    const run = async () => {
      const url = new URL(window.location.href)

      // Caso A: PKCE flow -> ?code=...
      const code = url.searchParams.get("code")
      if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code)
        if (error) {
          console.error("exchangeCodeForSession error:", error.message)
          window.location.href = "/login"
          return
        }
        window.location.href = "/dashboard"
        return
      }

      // Caso B: Implicit flow -> #access_token=...&refresh_token=...
      // Supabase-js puede leer el hash y setear la sesión
      const { data, error } = await supabase.auth.getSession()
      if (error) {
        console.error("getSession error:", error.message)
        window.location.href = "/login"
        return
      }

      if (data.session) {
        window.location.href = "/dashboard"
        return
      }

      // Si no hay ni code ni session, algo falló
      window.location.href = "/login"
    }

    run()
  }, [])

  return (
    <main className="min-h-screen flex items-center justify-center bg-zinc-950 text-zinc-50">
      Procesando inicio de sesión...
    </main>
  )
}
