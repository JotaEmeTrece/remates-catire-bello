import Image from "next/image"
import Link from "next/link"

type LogoProps = {
  href?: string
}

export function HeroLogo({ href = "/remates" }: LogoProps) {
  return (
    <Link href={href} aria-label="Ir a remates" className="mx-auto block w-fit">
      <Image
        src="/logo-hero.png"
        alt="Remate Catire Bello"
        width={240}
        height={240}
        priority
        className="h-auto w-[200px] sm:w-[240px]"
      />
    </Link>
  )
}

export function CornerLogo({ href = "/remates" }: LogoProps) {
  return (
    <div className="flex justify-end">
      <Link href={href} aria-label="Ir a remates" className="inline-flex">
        <Image
          src="/logo.png"
          alt="Remate Catire Bello"
          width={56}
          height={56}
          className="h-10 w-10 sm:h-12 sm:w-12"
        />
      </Link>
    </div>
  )
}

