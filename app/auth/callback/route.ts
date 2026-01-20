import { NextResponse } from "next/server"
import { createServerClient } from "@supabase/ssr"
import { cookies } from "next/headers"

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

export async function GET(request: Request) {
  const url = new URL(request.url)
  const code = url.searchParams.get("code")

  const redirect = (path: string) => NextResponse.redirect(new URL(path, url))

  if (!code) {
    return redirect("/login")
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

  const { data, error } = await supabase.auth.exchangeCodeForSession(code)
  if (error || !data?.user) {
    return redirect("/login")
  }

  const { data: prof, error: profErr } = await supabase
    .from("profiles")
    .select("es_admin,es_super_admin")
    .eq("id", data.user.id)
    .maybeSingle()

  if (!profErr && (prof?.es_admin || prof?.es_super_admin)) {
    return redirect("/panel")
  }

  return redirect("/panel")
}
