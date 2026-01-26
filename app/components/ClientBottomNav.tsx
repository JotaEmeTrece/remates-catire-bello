"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"

type NavItem = {
  href: string
  label: string
  match?: (path: string) => boolean
}

const items: NavItem[] = [
  {
    href: "/remates",
    label: "Remates",
    match: (path) => path === "/remates" || path.startsWith("/remates/"),
  },
  {
    href: "/dashboard",
    label: "Panel",
    match: (path) => path === "/dashboard",
  },
  {
    href: "/dashboard/recargar",
    label: "Recargar",
  },
  {
    href: "/dashboard/retirar",
    label: "Retirar",
  },
  {
    href: "/contactanos",
    label: "Contactanos",
  },
]

export default function ClientBottomNav() {
  const pathname = usePathname()

  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-zinc-800 bg-zinc-950/95 backdrop-blur">
      <div className="mx-auto flex max-w-md items-center justify-between px-4 py-2">
        {items.map((item) => {
          const active = item.match ? item.match(pathname) : pathname === item.href
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex-1 rounded-lg px-2 py-2 text-center text-xs font-semibold ${
                active ? "bg-white text-zinc-950" : "text-zinc-300"
              }`}
            >
              {item.label}
            </Link>
          )
        })}
      </div>
    </nav>
  )
}
