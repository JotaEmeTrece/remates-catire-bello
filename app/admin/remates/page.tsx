// app/admin/remates/page.tsx
"use client"

import { useEffect, useMemo, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabaseClient"

type RemateRow = {
  id: string
  nombre: string
  estado: "abierto" | "cerrado" | "liquidado" | string
  race_id: string
  created_at: string | null
  archived_at?: string | null
  cancelled_at?: string | null
}

type HorseRow = {
  id: string
  race_id: string
  numero: number | string
  nombre: string
  precio_salida: string | number
}

type BidRow = {
  id: string
  remate_id: string
  horse_id: string
  user_id: string
  monto: string | number
  created_at: string | null
  usuario: {
    username: string | null
    telefono: string | null
  } | null
}

function n(v: string | number | null | undefined) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: string | number | null | undefined) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatDT(v: string | null | undefined) {
  if (!v) return "-"
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString("es-VE")
}

function pillEstado(estado: string) {
  const e = String(estado || "").toLowerCase()
  if (e === "abierto") return "bg-emerald-500/10 text-emerald-200 ring-1 ring-emerald-500/20"
  if (e === "cerrado") return "bg-amber-500/10 text-amber-200 ring-1 ring-amber-500/20"
  if (e === "liquidado") return "bg-sky-500/10 text-sky-200 ring-1 ring-sky-500/20"
  if (e === "cancelado") return "bg-red-500/10 text-red-200 ring-1 ring-red-500/20"
  if (e === "archivado") return "bg-zinc-500/10 text-zinc-200 ring-1 ring-zinc-500/20"
  return "bg-zinc-500/10 text-zinc-200 ring-1 ring-zinc-500/20"
}

export default function AdminRematesPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [detailLoading, setDetailLoading] = useState(false)

  const [error, setError] = useState("")
  const [ok, setOk] = useState("")

  const [remates, setRemates] = useState<RemateRow[]>([])
  const [openId, setOpenId] = useState<string | null>(null)

  const [horses, setHorses] = useState<HorseRow[]>([])
  const [bids, setBids] = useState<BidRow[]>([])

  const [acting, setActing] = useState<null | { id: string; action: "cerrar" | "cancelar" | "archivar" }>(null)

  async function ensureAdmin() {
    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr) throw new Error(authErr.message)
    if (!auth?.user) {
      router.replace("/admin/login")
      return null
    }

    const { data: prof, error: pErr } = await supabase
      .from("profiles")
      .select("id,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (pErr) throw new Error(pErr.message)
    if (!prof?.es_admin && !prof?.es_super_admin) {
      router.replace("/dashboard")
      return null
    }

    return auth.user.id
  }

  async function loadRemates(isRefresh = false) {
    if (isRefresh) setRefreshing(true)
    else setLoading(true)

    setError("")
    setOk("")

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      const { data, error: listErr } = await supabase
        .from("remates")
        .select("id,nombre,estado,race_id,created_at,archived_at,cancelled_at")
        .order("created_at", { ascending: false })
        .limit(200)

      if (listErr) throw new Error(listErr.message)
      setRemates((data ?? []) as RemateRow[])
    } catch (e: any) {
      setError(e?.message || "Error cargando remates.")
      setRemates([])
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }

  async function loadRemateDetail(remate: RemateRow) {
    setDetailLoading(true)
    setError("")
    setOk("")
    setHorses([])
    setBids([])

    try {
      const adminId = await ensureAdmin()
      if (!adminId) return

      // Caballos de la carrera del remate
      const { data: hs, error: hsErr } = await supabase
        .from("horses")
        .select("id,race_id,numero,nombre,precio_salida")
        .eq("race_id", remate.race_id)
        .order("numero", { ascending: true })

      if (hsErr) throw new Error(hsErr.message)
      setHorses((hs ?? []) as HorseRow[])

      // Pujas del remate (join con profiles por FK)
      const { data: bd, error: bdErr } = await supabase
        .from("bids")
        .select(
          `
          id,
          remate_id,
          horse_id,
          user_id,
          monto,
          created_at,
          usuario:profiles!bids_user_id_fkey(username,telefono)
        `
        )
        .eq("remate_id", remate.id)
        .order("created_at", { ascending: true })

      if (bdErr) throw new Error(bdErr.message)

      // FIX PRO: join a veces viene como array -> normalizamos siempre a objeto o null
      const normalized: BidRow[] = (bd ?? []).map((row: any) => ({
        id: row.id,
        remate_id: row.remate_id,
        horse_id: row.horse_id,
        user_id: row.user_id,
        monto: row.monto,
        created_at: row.created_at ?? null,
        usuario: Array.isArray(row.usuario) ? (row.usuario[0] ?? null) : (row.usuario ?? null),
      }))

      setBids(normalized)
    } catch (e: any) {
      setError(e?.message || "Error cargando detalle del remate.")
    } finally {
      setDetailLoading(false)
    }
  }

  useEffect(() => {
    void loadRemates(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const topByHorse = useMemo(() => {
    // mayor monto; empate -> el más viejo (created_at asc) gana
    const map = new Map<string, BidRow>()
    for (const b of bids) {
      const prev = map.get(b.horse_id)
      if (!prev) {
        map.set(b.horse_id, b)
        continue
      }

      const a = n(prev.monto)
      const c = n(b.monto)

      if (c > a) {
        map.set(b.horse_id, b)
      } else if (c === a) {
        const tPrev = prev.created_at ? new Date(prev.created_at).getTime() : Number.MAX_SAFE_INTEGER
        const tNew = b.created_at ? new Date(b.created_at).getTime() : Number.MAX_SAFE_INTEGER
        if (tNew < tPrev) map.set(b.horse_id, b)
      }
    }
    return map
  }, [bids])

  const totals = useMemo(() => {
    let bruto = 0
    for (const [, bid] of topByHorse) bruto += n(bid.monto)

    const casa = bruto * 0.25
    const neto = bruto - casa
    return { bruto, casa, neto }
  }, [topByHorse])

  async function toggleDetail(remate: RemateRow) {
    if (openId === remate.id) {
      setOpenId(null)
      setHorses([])
      setBids([])
      setError("")
      setOk("")
      return
    }
    setOpenId(remate.id)
    await loadRemateDetail(remate)
  }

  // NOTE: cerrar remate via RPC
  async function cerrarRemate(remateId: string) {
    setActing({ id: remateId, action: "cerrar" })
    setError("")
    setOk("")

    try {
      const yes = window.confirm("Cerrar este remate (esto lo marca como 'cerrado')")
      if (!yes) return

      const { data, error: rpcErr } = await supabase.rpc("cerrar_remate", {
        p_remate_id: remateId,
      })

      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate cerrado.")
      await loadRemates(true)

      const current = remates.find((x) => x.id === remateId)
      if (openId === remateId && current) {
        await loadRemateDetail({ ...current, estado: "cerrado" })
      }
    } catch (e: any) {
      setError(e?.message || "Error cerrando remate.")
    } finally {
      setActing(null)
    }
  }

  async function cancelarRemate(remateId: string) {
    setActing({ id: remateId, action: "cancelar" })
    setError("")
    setOk("")

    try {
      const confirmTxt = window.prompt("Escribe CANCELAR para confirmar la cancelación del remate")
      if (confirmTxt !== "CANCELAR") {
        setActing(null)
        return
      }

      const motivo = window.prompt("Motivo de cancelación (obligatorio)")
      if (!motivo || !motivo.trim()) {
        setError("Debes indicar un motivo para cancelar el remate.")
        return
      }

      const { data, error: rpcErr } = await supabase.rpc("cancelar_remate", {
        p_remate_id: remateId,
        p_motivo: motivo.trim(),
      })

      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate cancelado.")
      await loadRemates(true)
      if (openId === remateId) setOpenId(null)
    } catch (e: any) {
      setError(e?.message || "Error cancelando remate.")
    } finally {
      setActing(null)
    }
  }

  async function archivarRemate(remateId: string) {
    setActing({ id: remateId, action: "archivar" })
    setError("")
    setOk("")

    try {
      const motivo = window.prompt("Motivo de archivo (obligatorio)")
      if (!motivo || !motivo.trim()) {
        setError("Debes indicar un motivo para archivar el remate.")
        return
      }

      const yes = window.confirm("Archivar este remate (quedará solo en histórico)")
      if (!yes) return

      const { data, error: rpcErr } = await supabase.rpc("archivar_remate", {
        p_remate_id: remateId,
        p_motivo: motivo.trim(),
      })

      if (rpcErr) throw new Error(rpcErr.message)

      setOk(typeof data === "string" ? data : "Remate archivado.")
      await loadRemates(true)
      if (openId === remateId) setOpenId(null)
    } catch (e: any) {
      setError(e?.message || "Error archivando remate.")
    } finally {
      setActing(null)
    }
  }


  return (
    <main className="min-h-dvh bg-zinc-950 text-zinc-50">
      <div className="mx-auto w-full max-w-4xl px-4 py-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-bold">Gestionar remates</h1>
            <p className="mt-1 text-sm text-zinc-300">Aquí ves caballos, pujadores, monto y el pozo (bruto / 25% / neto).</p>
          </div>
          <Link href="/admin" className="text-sm text-zinc-300 underline underline-offset-4">
            Volver
          </Link>
        </div>

        <button
          onClick={() => void loadRemates(true)}
          disabled={refreshing}
          className="mt-4 rounded-xl bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-sm disabled:opacity-60"
        >
          {refreshing ? "Actualizando..." : "Actualizar"}
        </button>

        {error ? (
          <div className="mt-4 rounded-xl bg-red-500/10 p-3 text-sm text-red-200 ring-1 ring-red-500/20">{error}</div>
        ) : null}
        {ok ? (
          <div className="mt-4 rounded-xl bg-emerald-500/10 p-3 text-sm text-emerald-200 ring-1 ring-emerald-500/20">{ok}</div>
        ) : null}

        {(() => {
          const activeRemates = remates.filter((r) => {
            const estado = String(r.estado || "").toLowerCase()
            const archived = !!r.archived_at
            return !archived && (estado === "abierto" || estado === "cerrado")
          })
          const historicoRemates = remates.filter((r) => {
            const estado = String(r.estado || "").toLowerCase()
            return !!r.archived_at || estado === "liquidado" || estado === "cancelado"
          })

          return (
            <>
              <div className="mt-6 space-y-3">
              {loading ? (
                <div className="text-sm text-zinc-400">Cargando...</div>
          ) : activeRemates.length === 0 ? (
            <div className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4 text-sm text-zinc-300">
              No hay remates activos.
            </div>
          ) : (
            activeRemates.map((r) => {
              const isOpen = openId === r.id

              const estado = String(r.estado || "").toLowerCase()
              const canCerrar = estado === "abierto"
              const canCancelar = estado === "abierto"
              const canArchivar = estado !== "abierto" && !r.archived_at
              const isActingCerrar = acting?.id === r.id && acting.action === "cerrar"
              const isActingCancelar = acting?.id === r.id && acting.action === "cancelar"
              const isActingArchivar = acting?.id === r.id && acting.action === "archivar"
              const estadoLabel = r.archived_at ? "archivado" : r.estado

              return (
                <div key={r.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-base font-semibold">{r.nombre}</div>
                      <div className="mt-1 text-xs text-zinc-500">
                        ID: {r.id.slice(0, 8)}... - Race: {r.race_id.slice(0, 8)}... - {formatDT(r.created_at)}
                      </div>
                    </div>
                    <div className={`rounded-full px-3 py-1 text-xs font-semibold ${pillEstado(estadoLabel)}`}>{estadoLabel}</div>
                  </div>

                  <div className="mt-4 flex flex-col md:flex-row gap-2">
                    <button
                      onClick={() => void toggleDetail(r)}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                    >
                      {isOpen ? "Ocultar detalle" : "Ver detalle"}
                    </button>

                    <Link
                      href={`/admin/remates/${r.id}`}
                      className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold text-center"
                    >
                      Abrir panel
                    </Link>

                    <button
                      disabled={!canCerrar || isActingCerrar}
                      onClick={() => void cerrarRemate(r.id)}
                      className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                      title={!canCerrar ? "Solo puedes cerrar remates abiertos" : ""}
                    >
                      {isActingCerrar ? "Cerrando..." : "Cerrar remate"}
                    </button>

                    <button
                      disabled={!canCancelar || isActingCancelar}
                      onClick={() => void cancelarRemate(r.id)}
                      className="rounded-xl bg-red-500/10 text-red-200 border border-red-500/30 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                      title={!canCancelar ? "Solo puedes cancelar remates abiertos" : ""}
                    >
                      {isActingCancelar ? "Cancelando..." : "Cancelar remate"}
                    </button>

                    <button
                      disabled={!canArchivar || isActingArchivar}
                      onClick={() => void archivarRemate(r.id)}
                      className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                      title={!canArchivar ? "Solo puedes archivar remates cerrados o liquidados" : ""}
                    >
                      {isActingArchivar ? "Archivando..." : "Archivar"}
                    </button>
                  </div>

                  {isOpen ? (
                    <div className="mt-5 rounded-2xl bg-zinc-950/40 border border-zinc-800 p-4">
                      {detailLoading ? (
                        <div className="text-sm text-zinc-400">Cargando detalle...</div>
                      ) : (
                        <>
                          <div className="grid grid-cols-3 gap-2">
                            <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                              <div className="text-xs text-zinc-500">Pozo bruto</div>
                              <div className="mt-1 text-lg font-semibold">{formatMoney(totals.bruto)} Bs</div>
                            </div>
                            <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                              <div className="text-xs text-zinc-500">Casa (25%)</div>
                              <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(totals.casa)} Bs</div>
                            </div>
                            <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                              <div className="text-xs text-zinc-500">Neto</div>
                              <div className="mt-1 text-lg font-semibold text-emerald-300">{formatMoney(totals.neto)} Bs</div>
                            </div>
                          </div>

                          <div className="mt-4 text-sm font-semibold">Caballos</div>

                          {horses.length === 0 ? (
                            <div className="mt-2 text-sm text-zinc-400">No hay caballos en esta carrera.</div>
                          ) : (
                            <div className="mt-3 space-y-2">
                              {horses.map((h) => {
                                const top = topByHorse.get(h.id) || null
                                const monto = top ? n(top.monto) : 0

                                const username = top?.usuario?.username ?? (top ? top.user_id.slice(0, 8) + "..." : "Casa")
                                const tel = top?.usuario?.telefono ?? "-"

                                return (
                                  <div key={h.id} className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                                    <div className="flex items-start justify-between gap-3">
                                      <div>
                                        <div className="text-sm font-semibold">
                                          Caballo #{h.numero}{" "}
                                          <span className="text-xs text-zinc-500">(salida: {formatMoney(h.precio_salida)} Bs)</span>
                                        </div>

                                        <div className="mt-1 text-xs text-zinc-400">
                                          Va ganando: <span className="text-zinc-200 font-medium">{username}</span> - Tel: {tel}
                                        </div>

                                        <div className="mt-1 text-xs text-zinc-400">
                                          Puja actual: <span className="text-zinc-200 font-semibold">{formatMoney(monto)} Bs</span>
                                          {top?.created_at ? <span className="text-zinc-500"> - {formatDT(top.created_at)}</span> : null}
                                        </div>
                                      </div>

                                      <div className="text-xs text-zinc-500">{top ? "Puja" : "Sin pujas"}</div>
                                    </div>
                                  </div>
                                )
                              })}
                            </div>
                          )}
                        </>
                      )}
                    </div>
                  ) : null}
                </div>
              )
            })
          )}
              </div>

              {historicoRemates.length > 0 ? (
                <div className="mt-10">
                  <h2 className="text-base font-semibold">Histórico</h2>
                  <div className="mt-3 space-y-3">
                    {historicoRemates.map((r) => {
                      const isOpen = openId === r.id
                      const estadoLabel = r.archived_at ? "archivado" : r.estado
                      const canArchivar = String(r.estado || "").toLowerCase() !== "abierto" && !r.archived_at
                      const isActingArchivar = acting?.id === r.id && acting.action === "archivar"
                      return (
                        <div key={r.id} className="rounded-2xl bg-zinc-900/60 border border-zinc-800 p-4">
                          <div className="flex items-start justify-between gap-3">
                            <div>
                              <div className="text-base font-semibold">{r.nombre}</div>
                              <div className="mt-1 text-xs text-zinc-500">
                                ID: {r.id.slice(0, 8)}... - Race: {r.race_id.slice(0, 8)}... - {formatDT(r.created_at)}
                              </div>
                            </div>
                            <div className={`rounded-full px-3 py-1 text-xs font-semibold ${pillEstado(estadoLabel)}`}>
                              {estadoLabel}
                            </div>
                          </div>

                          <div className="mt-4 flex flex-col md:flex-row gap-2">
                            <button
                              onClick={() => void toggleDetail(r)}
                              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm"
                            >
                              {isOpen ? "Ocultar detalle" : "Ver detalle"}
                            </button>
                            <Link
                              href={`/admin/remates/${r.id}`}
                              className="rounded-xl bg-white text-zinc-950 px-3 py-2 text-sm font-semibold text-center"
                            >
                              Abrir panel
                            </Link>

                            <button
                              disabled={!canArchivar || isActingArchivar}
                              onClick={() => void archivarRemate(r.id)}
                              className="rounded-xl bg-zinc-950/60 border border-zinc-800 px-3 py-2 text-sm font-semibold disabled:opacity-60"
                              title={!canArchivar ? "Solo puedes archivar remates cerrados o liquidados" : ""}
                            >
                              {isActingArchivar ? "Archivando..." : "Archivar"}
                            </button>
                          </div>

                          {isOpen ? (
                            <div className="mt-5 rounded-2xl bg-zinc-950/40 border border-zinc-800 p-4">
                              {detailLoading ? (
                                <div className="text-sm text-zinc-400">Cargando detalle...</div>
                              ) : (
                                <>
                                  <div className="grid grid-cols-3 gap-2">
                                    <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                                      <div className="text-xs text-zinc-500">Pozo bruto</div>
                                      <div className="mt-1 text-lg font-semibold">{formatMoney(totals.bruto)} Bs</div>
                                    </div>
                                    <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                                      <div className="text-xs text-zinc-500">Casa (25%)</div>
                                      <div className="mt-1 text-lg font-semibold text-amber-300">{formatMoney(totals.casa)} Bs</div>
                                    </div>
                                    <div className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                                      <div className="text-xs text-zinc-500">Neto</div>
                                      <div className="mt-1 text-lg font-semibold text-emerald-300">{formatMoney(totals.neto)} Bs</div>
                                    </div>
                                  </div>

                                  <div className="mt-4 text-sm font-semibold">Caballos</div>

                                  {horses.length === 0 ? (
                                    <div className="mt-2 text-sm text-zinc-400">No hay caballos en esta carrera.</div>
                                  ) : (
                                    <div className="mt-2 space-y-2">
                                      {horses.map((h) => {
                                        const bid = topByHorse.get(h.id)
                                        return (
                                          <div key={h.id} className="rounded-xl bg-zinc-900/60 border border-zinc-800 p-3">
                                            <div className="flex items-center justify-between">
                                              <div className="text-sm font-semibold">
                                                #{h.numero} - {h.nombre}
                                              </div>
                                              <div className="text-sm text-zinc-200">
                                                {bid ? `${formatMoney(bid.monto)} Bs` : `${formatMoney(h.precio_salida)} Bs`}
                                              </div>
                                            </div>
                                            <div className="mt-1 text-xs text-zinc-500">
                                              {bid?.usuario?.username ? `Ganando: ${bid.usuario.username}` : "Sin pujas"}
                                            </div>
                                          </div>
                                        )
                                      })}
                                    </div>
                                  )}
                                </>
                              )}
                            </div>
                          ) : null}
                        </div>
                      )
                    })}
                  </div>
                </div>
              ) : null}
            </>
          )
        })()}
      </div>
    </main>
  )
}




