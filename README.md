# 🐴 Remate Catire Bello

Plataforma web completa para la gestión de remates de caballos de carrera, con sistema de pujas en tiempo real, wallet integrada y panel de administración.

## ✨ Funcionalidades

### Cliente
- Visualización de remates activos sin necesidad de registro
- Registro con username, teléfono y correo
- Wallet personal con saldo **disponible** y **bloqueado**
- Recarga de saldo con aprobación manual del admin
- Retiro de saldo con procesamiento manual
- Puja automática ("Ponerle") y puja manual por monto
- Historial de recargas, retiros y movimientos

### Administrador
- Creación de remates con datos de carrera (hipódromo, número, fecha y hora)
- Configuración de caballos con precio de salida, jinete y reglas de precios
- Reglas de precios por rangos (incrementos automáticos según precio actual)
- Soporte para reglas default y reglas propias por caballo
- Cierre de remates (detiene pujas y libera saldos bloqueados)
- Liquidación de remates con selección de caballo ganador y reparto automático del pozo
- Gestión de recargas y retiros pendientes con notificación por email al aprobar
- Panel de contabilidad con totales por período: recargas, retiros y ganancias de la casa

### Superadmin
- Control total del sistema incluyendo gestión de usuarios y roles

## 💡 Lógica de negocio

- Cada caballo tiene un precio que sube con cada puja según rangos configurables
- Al liquidar, el ganador recibe el pozo acumulado menos el **25% de la casa**
- Si el caballo ganador queda para la casa (sin pujas), la casa se queda con todo
- El saldo se bloquea mientras el usuario lidera una puja y se libera al cerrar el remate si no ganó

## 🛠️ Tech Stack

| Capa | Tecnología |
|------|-----------|
| Frontend | Next.js 15, TypeScript, Tailwind CSS |
| Backend | Supabase (PostgreSQL + Auth + RLS + RPC) |
| Email | Gmail SMTP (notificaciones de recargas) |
| Despliegue | Vercel (frontend) + Supabase (base de datos) |

## 📁 Estructura del proyecto

```
remates-catire-bello/
├── app/
│   ├── remates/          # Vista pública de remates activos
│   ├── login/            # Autenticación
│   ├── register/         # Registro de usuarios
│   ├── dashboard/        # Panel del cliente (wallet, recargas, retiros)
│   └── admin/            # Panel de administración completo
├── lib/                  # Utilidades y cliente Supabase
├── sql/                  # Scripts SQL (tablas, RLS, RPCs)
├── middleware.ts          # Protección de rutas por rol
└── public/               # Assets estáticos
```

## 🚀 Correr localmente

### Prerrequisitos
- Node.js 18+
- pnpm
- Cuenta en Supabase

### Instalación

```bash
git clone https://github.com/JotaEmeTrece/remates-catire-bello.git
cd remates-catire-bello
pnpm install
```

### Variables de entorno

Crea un archivo `.env.local` en la raíz:

```env
# Supabase
NEXT_PUBLIC_SUPABASE_URL=your_supabase_url
NEXT_PUBLIC_SUPABASE_ANON_KEY=your_anon_key
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key

# Email (Gmail SMTP)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=your_email@gmail.com
SMTP_PASS=your_gmail_app_password
NOTIFY_EMAIL_TO=your_email@gmail.com

# App
APP_URL=http://localhost:3000
```

> `SMTP_PASS` debe ser una contraseña de aplicación de Google (requiere verificación en dos pasos).

### Base de datos

Ejecuta los scripts de la carpeta `/sql` en tu proyecto de Supabase para crear las tablas, políticas RLS y funciones RPC necesarias.

### Ejecutar

```bash
pnpm dev
```

## 📄 Licencia
MIT — Desarrollado por Jercol Technologies © 2025

MIT — Desarrollado por **Jercol Technologies** © 2026e details.
