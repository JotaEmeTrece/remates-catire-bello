"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type SupportItem = {
  id: string
  label: string
  value: string
  type: "email" | "whatsapp" | "phone" | "social" | string
  href: string | null
  sort_order: number | null
  is_active: boolean
}

function buildHref(type: string, value: string) {
  const clean = value.replace(/\s+/g, "")
  if (type === "email") return `mailto:${clean}`
  if (type === "whatsapp") {
    const digits = clean.replace(/[^0-9]/g, "")
    return digits ? `https://wa.me/${digits}` : ""
  }
  if (type === "phone") {
    const digits = clean.replace(/[^0-9+]/g, "")
    return digits ? `tel:${digits}` : ""
  }
  return ""
}

export default function AdminSuperSoportePage() {
  const router = useRouter()
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState("")
  const [ok, setOk] = useState("")
  const [items, setItems] = useState<SupportItem[]>([])

  async function ensureSuperAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("id,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr) throw new Error(profErr.message)
    if (!prof?.es_super_admin) {
      router.replace("/admin")
      return null
    }
    return auth.user.id
  }

  useEffect(() => {
    ;(async () => {
      setLoading(true)
      setError("")
      try {
        const ok = await ensureSuperAdmin()
        if (!ok) return
        const { data, error: err } = await supabase
          .from("support_settings")
          .select("id,label,value,type,href,sort_order,is_active")
          .order("sort_order", { ascending: true })
          .order("created_at", { ascending: true })
        if (err) throw new Error(err.message)
        setItems((data as SupportItem[]) ?? [])
      } catch (e: any) {
        setError(e?.message || "Error cargando soporte")
      } finally {
        setLoading(false)
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function updateItem(id: string, patch: Partial<SupportItem>) {
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...patch } : i)))
  }

  function addItem() {
    const temp: SupportItem = {
      id: `tmp_${Math.random().toString(16).slice(2)}`,
      label: "",
      value: "",
      type: "whatsapp",
      href: "",
      sort_order: items.length ? Math.max(...items.map((i) => i.sort_order ?? 0)) + 10 : 10,
      is_active: true,
    }
    setItems((prev) => [...prev, temp])
  }

  function removeItem(id: string) {
    setItems((prev) => prev.filter((i) => i.id !== id))
  }

  const canSave = useMemo(() => {
    if (items.length === 0) return true
    return items.every((i) => i.label.trim() && i.value.trim())
  }, [items])

  async function onSave() {
    setError("")
    setOk("")
    if (!canSave) {
      setError("Completa label y valor en todos los ítems.")
      return
    }
    setSaving(true)
    try {
      const ok = await ensureSuperAdmin()
      if (!ok) return

      const existingIds = new Set(items.filter((i) => !i.id.startsWith("tmp_")).map((i) => i.id))
      const { data: current } = await supabase.from("support_settings").select("id")
      const toDelete = (current as any[] | null)?.filter((r) => !existingIds.has(r.id)).map((r) => r.id) ?? []
      if (toDelete.length) {
        const { error: delErr } = await supabase.from("support_settings").delete().in("id", toDelete)
        if (delErr) throw new Error(delErr.message)
      }

      for (const item of items) {
        const payload = {
          label: item.label.trim(),
          value: item.value.trim(),
          type: item.type,
          href: item.href?.trim() || buildHref(item.type, item.value.trim()),
          sort_order: item.sort_order ?? 0,
          is_active: item.is_active,
        }
        if (item.id.startsWith("tmp_")) {
          const { error: insErr } = await supabase.from("support_settings").insert(payload)
          if (insErr) throw new Error(insErr.message)
        } else {
          const { error: upErr } = await supabase.from("support_settings").update(payload).eq("id", item.id)
          if (upErr) throw new Error(upErr.message)
        }
      }

      setOk("Soporte actualizado.")
      const { data, error: err } = await supabase
        .from("support_settings")
        .select("id,label,value,type,href,sort_order,is_active")
        .order("sort_order", { ascending: true })
        .order("created_at", { ascending: true })
      if (err) throw new Error(err.message)
      setItems((data as SupportItem[]) ?? [])
    } catch (e: any) {
      setError(e?.message || "Error guardando soporte")
    } finally {
      setSaving(false)
    }
  }

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-zinc-50">Cargando...</div>
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-50 px-4 py-6">
      <div className="mx-auto w-full max-w-2xl">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-bold">Soporte (Superadmin)</h1>
          <Link href="/admin" className="text-xs text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">
            {error}
          </div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">
            {ok}
          </div>
        ) : null}

        <div className="mt-4 space-y-3">
          {items.map((item) => (
            <div key={item.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
              <div className="grid grid-cols-1 md:grid-cols-4 gap-2">
                <div>
                  <label className="text-xs text-zinc-400">Tipo</label>
                  <select
                    value={item.type}
                    onChange={(e) => updateItem(item.id, { type: e.target.value as SupportItem["type"] })}
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  >
                    <option value="email">email</option>
                    <option value="whatsapp">whatsapp</option>
                    <option value="phone">phone</option>
                    <option value="social">social</option>
                  </select>
                </div>
                <div>
                  <label className="text-xs text-zinc-400">Label</label>
                  <input
                    value={item.label}
                    onChange={(e) => updateItem(item.id, { label: e.target.value })}
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    placeholder="WhatsApp"
                  />
                </div>
                <div>
                  <label className="text-xs text-zinc-400">Valor</label>
                  <input
                    value={item.value}
                    onChange={(e) => updateItem(item.id, { value: e.target.value })}
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    placeholder="+58 0412..."
                  />
                </div>
                <div>
                  <label className="text-xs text-zinc-400">Orden</label>
                  <input
                    inputMode="numeric"
                    value={item.sort_order ?? 0}
                    onChange={(e) => updateItem(item.id, { sort_order: Number(e.target.value || 0) })}
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                  />
                </div>
              </div>

              <div className="mt-2 grid grid-cols-1 md:grid-cols-3 gap-2">
                <div>
                  <label className="text-xs text-zinc-400">Link (auto si vacío)</label>
                  <input
                    value={item.href ?? ""}
                    onChange={(e) => updateItem(item.id, { href: e.target.value })}
                    className="mt-1 w-full rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    placeholder="https://..."
                  />
                </div>
                <div className="flex items-end gap-2">
                  <label className="text-xs text-zinc-400 flex items-center gap-2">
                    <input
                      type="checkbox"
                      checked={item.is_active}
                      onChange={(e) => updateItem(item.id, { is_active: e.target.checked })}
                    />
                    Activo
                  </label>
                </div>
                <div className="flex items-end justify-end">
                  <button
                    onClick={() => removeItem(item.id)}
                    className="rounded-xl bg-red-500/10 text-red-200 ring-1 ring-red-500/20 px-3 py-2 text-xs"
                  >
                    Quitar
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>

        <div className="mt-3 flex items-center gap-2">
          <button
            onClick={addItem}
            className="rounded-xl bg-zinc-900/60 border border-zinc-800 px-3 py-2 text-sm"
          >
            + Agregar contacto
          </button>
          <button
            onClick={() => void onSave()}
            disabled={saving || !canSave}
            className="rounded-xl bg-white text-zinc-950 px-4 py-2 text-sm font-semibold disabled:opacity-60"
          >
            {saving ? "Guardando..." : "Guardar"}
          </button>
        </div>
      </div>
    </main>
  )
}
