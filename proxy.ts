import { NextResponse, type NextRequest } from "next/server"
import { createServerClient } from "@supabase/ssr"

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl

  if (pathname.startsWith("/admin/login")) {
    return NextResponse.next()
  }

  let response = NextResponse.next()

  const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          response.cookies.set(name, value, options)
        })
      },
    },
  })

  const { data: authData, error: authErr } = await supabase.auth.getUser()
  const user = authData?.user

  if (authErr || !user) {
    const loginUrl = request.nextUrl.clone()
    loginUrl.pathname = "/admin/login"
    return NextResponse.redirect(loginUrl)
  }

  const { data: prof, error: profErr } = await supabase
    .from("profiles")
    .select("es_admin,es_super_admin")
    .eq("id", user.id)
    .maybeSingle()

  if (profErr || (!prof?.es_admin && !prof?.es_super_admin)) {
    const dashUrl = request.nextUrl.clone()
    dashUrl.pathname = "/dashboard"
    return NextResponse.redirect(dashUrl)
  }

  return response
}

export const config = {
  matcher: ["/admin/:path*"],
}
