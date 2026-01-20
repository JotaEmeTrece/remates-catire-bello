import { NextResponse } from "next/server"
import { createServerClient } from "@supabase/ssr"
import { cookies } from "next/headers"

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

export async function GET(request: Request) {
  const url = new URL(request.url)
  const redirect = (path: string) => NextResponse.redirect(new URL(path, url))

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

  const { data: auth } = await supabase.auth.getUser()
  const user = auth?.user ?? null

  if (!user) return redirect("/remates")

  const { data: prof } = await supabase
    .from("profiles")
    .select("es_admin,es_super_admin")
    .eq("id", user.id)
    .maybeSingle()

  if (prof?.es_admin || prof?.es_super_admin) {
    return redirect("/admin")
  }

  return redirect("/dashboard")
}
