import { HeroLogo } from "@/app/components/BrandLogo"

export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center justify-center bg-zinc-950 text-zinc-50">
      <div className="mb-5">
        <HeroLogo />
      </div>
      <h1 className="text-2xl font-bold">Remates Catire Bello</h1>
      <p className="mt-3 text-zinc-400 text-sm">
        Bienvenido a tu casa de remates digital.
      </p>

      <div className="mt-6 grid w-full max-w-xs grid-cols-1 gap-2">
        <a
          href="/remates"
          className="inline-block rounded-lg bg-white px-4 py-2 text-center text-sm font-semibold text-zinc-950"
        >
          Ver remates en vivo
        </a>
        <a
          href="/login"
          className="inline-block rounded-lg bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-center text-sm font-semibold"
        >
          Iniciar sesión
        </a>
        <a
          href="/register"
          className="inline-block rounded-lg bg-zinc-900/60 border border-zinc-800 px-4 py-2 text-center text-sm font-semibold"
        >
          Registrarme
        </a>
      </div>
    </main>
  )
}
