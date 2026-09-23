import path from "node:path"
import type { NextConfig } from "next"

// Next detecta la raiz del proyecto buscando el lockfile mas cercano hacia
// arriba. En esta maquina hay un pnpm-lock.yaml en C:\Users\mapog, de otro
// proyecto con su propio package.json y node_modules, asi que Next elegia la
// carpeta de usuario como raiz del workspace y trazaba los archivos desde ahi.
// Eso puede hacer que el build de Vercel no salga igual al local, que es de
// los fallos mas dificiles de diagnosticar.
//
// Fijandola a mano, la raiz es esta carpeta y punto, sin depender de que
// lockfiles anden sueltos en la maquina de quien compile. Importa el dia que
// esto lo compile otra persona o un licenciatario.
//
// El doble camino es por el modulo: si next.config.ts se carga como CommonJS
// existe __dirname; si se carga como ESM, no. `typeof` sobre una variable no
// declarada no lanza, asi que la comprobacion es segura en los dos casos.
// El respaldo es process.cwd(), que con `pnpm build` y con Vercel siempre es
// la raiz del paquete.
const raizDelProyecto =
  typeof __dirname !== "undefined" ? __dirname : process.cwd()

const nextConfig: NextConfig = {
  turbopack: {
    root: path.resolve(raizDelProyecto),
  },
}

export default nextConfig
