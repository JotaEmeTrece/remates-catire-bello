import { NextResponse } from "next/server"
import { createServerClient } from "@supabase/ssr"
import { cookies } from "next/headers"
import tls from "node:tls"

export const runtime = "nodejs"

type NotifyAction = "approved" | "rejected"

function n(v: unknown) {
  const x = typeof v === "string" ? Number(v) : typeof v === "number" ? v : 0
  return Number.isFinite(x) ? x : 0
}

function formatMoney(v: unknown) {
  return n(v).toLocaleString("es-VE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function env(name: string) {
  const v = process.env[name]
  return v && v.trim() ? v.trim() : null
}

function b64(s: string) {
  return Buffer.from(s, "utf8").toString("base64")
}

async function smtpSendMail(opts: {
  host: string
  port: number
  user: string
  pass: string
  from: string
  to: string
  subject: string
  text: string
}) {
  const socket = tls.connect({
    host: opts.host,
    port: opts.port,
    servername: opts.host,
  })

  socket.setEncoding("utf8")

  const readLine = async () => {
    return await new Promise<string>((resolve, reject) => {
      const onData = (chunk: string) => {
        const idx = chunk.indexOf("\n")
        if (idx === -1) return
        socket.off("data", onData)
        resolve(chunk)
      }
      const onErr = (e: any) => {
        socket.off("data", onData)
        reject(e)
      }
      socket.once("error", onErr)
      socket.on("data", onData)
    })
  }

  const expect = async (code: number) => {
    // Read one or more lines until last line (no dash after code)
    let buf = ""
    for (;;) {
      const chunk = await readLine()
      buf += chunk
      const lines = buf.split(/\r?\n/).filter(Boolean)
      const last = lines[lines.length - 1] ?? ""
      const m = last.match(/^(\d{3})([ -])/)
      if (m && m[2] === " ") break
    }
    const m = buf.match(/^(\d{3})/m)
    const got = m ? Number(m[1]) : NaN
    if (got !== code) {
      throw new Error(`SMTP unexpected response: expected ${code}, got ${Number.isFinite(got) ? got : "?"}: ${buf}`)
    }
    return buf
  }

  const send = async (line: string) => {
    socket.write(line.endsWith("\r\n") ? line : `${line}\r\n`)
  }

  try {
    await expect(220)
    await send(`EHLO localhost`)
    await expect(250)

    const authPlain = b64(`\u0000${opts.user}\u0000${opts.pass}`)
    await send(`AUTH PLAIN ${authPlain}`)
    await expect(235)

    await send(`MAIL FROM:<${opts.from}>`)
    await expect(250)
    await send(`RCPT TO:<${opts.to}>`)
    await expect(250)
    await send(`DATA`)
    await expect(354)

    const date = new Date().toUTCString()
    const messageId = `<${Date.now()}.${Math.random().toString(16).slice(2)}@localhost>`

    const headers = [
      `From: ${opts.from}`,
      `To: ${opts.to}`,
      `Subject: ${opts.subject}`,
      `Date: ${date}`,
      `Message-ID: ${messageId}`,
      `MIME-Version: 1.0`,
      `Content-Type: text/plain; charset="utf-8"`,
      `Content-Transfer-Encoding: 8bit`,
    ].join("\r\n")

    const body = String(opts.text || "")
      .replace(/\r?\n/g, "\r\n")
      .replace(/^\./gm, "..")
    const data = `${headers}\r\n\r\n${body}\r\n.\r\n`

    socket.write(data)
    await expect(250)

    await send(`QUIT`)
    // Some servers respond 221, but not strictly necessary to await
    socket.end()
  } finally {
    socket.end()
  }
}

export async function POST(request: Request) {
  try {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
    const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
    if (!supabaseUrl || !supabaseAnonKey) {
      return NextResponse.json({ error: "Missing Supabase env" }, { status: 500 })
    }

    const cookieStore = await cookies()
    const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) => {
            cookieStore.set(name, value, options)
          })
        },
      },
    })

    const { data: auth, error: authErr } = await supabase.auth.getUser()
    if (authErr || !auth?.user) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 })
    }

    const { data: prof, error: profErr } = await supabase
      .from("profiles")
      .select("username,es_admin,es_super_admin")
      .eq("id", auth.user.id)
      .maybeSingle()

    if (profErr || (!prof?.es_admin && !prof?.es_super_admin)) {
      return NextResponse.json({ error: "Forbidden" }, { status: 403 })
    }

    const body = (await request.json().catch(() => null)) as
      | { depositId?: unknown; action?: unknown; reason?: unknown }
      | null

    const depositId = String(body?.depositId ?? "").trim()
    const action = String(body?.action ?? "").trim() as NotifyAction
    const reason = String(body?.reason ?? "").trim()

    if (!depositId) {
      return NextResponse.json({ error: "Missing depositId" }, { status: 400 })
    }
    if (action !== "approved" && action !== "rejected") {
      return NextResponse.json({ error: "Invalid action" }, { status: 400 })
    }

    const { data: reqRow, error: reqErr } = await supabase
      .from("deposit_requests")
      .select(
        `
        id,
        monto,
        metodo,
        telefono_pago,
        referencia,
        fecha_pago,
        estado,
        created_at,
        approved_at,
        user_id,
        usuario:profiles!deposit_requests_user_id_fkey(username,telefono)
      `
      )
      .eq("id", depositId)
      .maybeSingle()

    if (reqErr) {
      return NextResponse.json({ error: reqErr.message }, { status: 400 })
    }
    if (!reqRow) {
      return NextResponse.json({ error: "Deposit request not found" }, { status: 404 })
    }

    const smtpUser = env("SMTP_USER")
    const smtpPass = env("SMTP_PASS")
    const to = env("NOTIFY_EMAIL_TO") ?? smtpUser
    if (!smtpUser || !smtpPass || !to) {
      return NextResponse.json({ error: "Missing SMTP env" }, { status: 500 })
    }

    const host = env("SMTP_HOST") ?? "smtp.gmail.com"
    const port = Number(env("SMTP_PORT") ?? "465")

    const adminLabel = prof?.username && prof.username.trim() ? prof.username.trim() : auth.user.email ?? auth.user.id
    const userMini = (reqRow as any).usuario
    const userLabel = userMini?.username || reqRow.user_id
    const userTel = userMini?.telefono || "-"

    const subject =
      action === "approved" ? `Recarga aprobada - Bs ${formatMoney(reqRow.monto)}` : `Recarga rechazada - Bs ${formatMoney(reqRow.monto)}`

    const appUrl = env("APP_URL") ?? env("NEXT_PUBLIC_APP_URL")
    const linkPanel = appUrl ? `${appUrl.replace(/\/+$/, "")}/admin/recargas` : "/admin/recargas"

    const text = [
      `Evento: ${action === "approved" ? "RECARGA APROBADA" : "RECARGA RECHAZADA"}`,
      `Fecha: ${new Date().toLocaleString("es-VE")}`,
      ``,
      `Monto: Bs ${formatMoney(reqRow.monto)}`,
      `Metodo: ${reqRow.metodo}`,
      `Referencia: ${reqRow.referencia}`,
      `Telefono pago: ${reqRow.telefono_pago}`,
      `Fecha pago: ${reqRow.fecha_pago}`,
      ``,
      `Usuario: ${userLabel}`,
      `Telefono usuario: ${userTel}`,
      ``,
      `Procesado por: ${adminLabel}`,
      `Estado actual: ${reqRow.estado}`,
      reason ? `Motivo: ${reason}` : null,
      ``,
      `Panel: ${linkPanel}`,
      `ID: ${reqRow.id}`,
    ]
      .filter(Boolean)
      .join("\n")

    await smtpSendMail({
      host,
      port: Number.isFinite(port) ? port : 465,
      user: smtpUser,
      pass: smtpPass,
      from: smtpUser,
      to,
      subject,
      text,
    })

    return NextResponse.json({ ok: true })
  } catch (e: any) {
    return NextResponse.json({ error: e?.message || "Unknown error" }, { status: 500 })
  }
}
