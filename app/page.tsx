export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center justify-center bg-zinc-950 text-zinc-50">
      <h1 className="text-2xl font-bold">Remates Catire Bello</h1>
      <p className="mt-3 text-zinc-400 text-sm">
        Bienvenido a tu casa de remates digital.
      </p>

      <a
        href="/dashboard"
        className="mt-6 inline-block bg-green-600 px-4 py-2 rounded-lg text-sm font-semibold"
      >
        Ir al panel
      </a>
    </main>
  )
}
