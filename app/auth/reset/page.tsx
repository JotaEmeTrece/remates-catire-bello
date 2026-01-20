"use client"

import { useEffect, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

function getHashParams() {
  if (typeof window === "undefined") return new URLSearchParams()
  const hash = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : window.location.hash
  return new URLSearchParams(hash)
}

export default function ResetPasswordPage() {
  const router = useRouter()
  const [checking, setChecking] = useState(true)
  const [ready, setReady] = useState(false)
  const [error, setError] = useState("")
  const [password, setPassword] = useState("")
  const [confirm, setConfirm] = useState("")
  const [saving, setSaving] = useState(false)
  const [done, setDone] = useState(false)

  useEffect(() => {
    const run = async () => {
      try {
        const params = getHashParams()
        const accessToken = params.get("access_token") || ""
        const refreshToken = params.get("refresh_token") || ""

        if (!accessToken || !refreshToken) {
          setError("Link invalido o expirado.")
          setChecking(false)
          return
        }

        const { error: sessionErr } = await supabase.auth.setSession({
          access_token: accessToken,
          refresh_token: refreshToken,
        })

        if (sessionErr) {
          setError(sessionErr.message)
          setChecking(false)
          return
        }

        setReady(true)
        setChecking(false)
      } catch (e: any) {
        setError(e?.message || "Error procesando el link.")
        setChecking(false)
      }
    }

    void run()
  }, [])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (saving) return
    setError("")

    if (password.length < 6) {
      setError("La contraseña debe tener al menos 6 caracteres.")
      return
    }
    if (password !== confirm) {
      setError("Las contraseñas no coinciden.")
      return
    }

    setSaving(true)
    const { error: updateErr } = await supabase.auth.updateUser({ password })
    if (updateErr) {
      setSaving(false)
      setError(updateErr.message)
      return
    }

    await supabase.auth.signOut()
    setSaving(false)
    setDone(true)
    setTimeout(() => router.replace("/login"), 1200)
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 flex items-center justify-center">
      <div className="w-full max-w-md rounded-2xl bg-zinc-900/60 border border-zinc-800 p-6">
        <h1 className="text-xl font-bold">Restablecer contraseña</h1>

        {checking ? (
          <p className="mt-3 text-sm text-zinc-300">Procesando link...</p>
        ) : error ? (
          <div className="mt-3 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}{" "}
            <Link href="/login" className="underline underline-offset-4">
              Volver al login
            </Link>
          </div>
        ) : done ? (
          <div className="mt-3 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            Contraseña actualizada. Redirigiendo...
          </div>
        ) : ready ? (
          <form onSubmit={handleSubmit} className="mt-4 space-y-3">
            <div>
              <label className="text-sm text-zinc-300">Nueva contraseña</label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
                placeholder="Minimo 6 caracteres"
              />
            </div>
            <div>
              <label className="text-sm text-zinc-300">Confirmar contraseña</label>
              <input
                type="password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-white/10"
                placeholder="Repite la contraseña"
              />
            </div>

            {error ? (
              <div className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
            ) : null}

            <button
              type="submit"
              disabled={saving}
              className="w-full rounded-xl bg-white px-4 py-2 text-sm font-semibold text-zinc-950 disabled:opacity-60"
            >
              {saving ? "Guardando..." : "Actualizar contraseña"}
            </button>
          </form>
        ) : (
          <p className="mt-3 text-sm text-zinc-300">No se pudo validar el link.</p>
        )}
      </div>
    </main>
  )
}
