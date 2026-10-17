# Sistema Contable Multiempresa (Bolivia)

Aplicación web (React + TypeScript + Vite) con base de datos en Supabase, lista para publicar en Netlify.
Funciona en computadora y celular.

## Qué necesita
- Una cuenta gratuita en **Supabase** (https://supabase.com)
- Una cuenta gratuita en **Netlify** (https://netlify.com)
- Una cuenta en **GitHub** (https://github.com) — es la forma más fácil de publicar en Netlify

No necesita instalar nada en su computadora, ni usar la consola de Supabase, ni Edge Functions, ni crear tablas a mano.

---

## PASO 1 — Supabase (la base de datos)

1. Entre a Supabase y cree un **proyecto nuevo** (guarde la contraseña de base de datos que le pida; no la usará en este sistema).
2. Abra el archivo `supabase/01_instalar_base_de_datos.sql` con el Bloc de notas.
3. En las **dos primeras líneas marcadas con `<<<`** cambie:
   - `TU_CORREO@ejemplo.com` → **su correo** (será el administrador general)
   - `TU_CLAVE_SEGURA_AQUI` → **su clave** (mínimo 8 caracteres)
   Deje las comillas simples `' '` como están.
4. Seleccione **todo** el texto del archivo, cópielo.
5. En Supabase: menú izquierdo **SQL Editor → New query**, pegue y presione **Run**.
   Debe terminar con **Success**. Se ejecuta **una sola vez**. Si aparece un error, no pasa nada: corrija y vuelva a ejecutar en un proyecto nuevo.
6. Copie sus dos datos de conexión: **Project Settings → API**
   - **Project URL**
   - **anon public key** (o *Publishable key*)

**Almacenamiento de archivos (adjuntos):** el script ya crea el bucket. Si por alguna razón no aparece en *Storage*, créelo a mano con el nombre exacto **`attachments`** y déjelo **privado** (Public bucket = desactivado).

*(Recomendado)* En **Authentication → Providers → Email**, desactive "Allow new users to sign up": así nadie puede registrarse por su cuenta; los usuarios se crean desde el propio sistema.

## PASO 2 — Conectar el sistema (archivo `.env`)

Abra el archivo `.env` (en la carpeta principal) y escriba sus dos datos, sin comillas ni espacios:

```
VITE_SUPABASE_URL=https://xxxxxxxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJ...su-clave-publica...
```

Esa clave es **pública por diseño**; la seguridad la dan las reglas (RLS) que instaló el script. **Nunca** use la clave `service_role` en este sistema.

## PASO 3 — Netlify (publicar)

**Opción A (recomendada):**
1. Suba esta carpeta completa (con su `.env` ya completado) a un repositorio nuevo de GitHub.
2. En Netlify: **Add new site → Import an existing project → GitHub** y elija el repositorio. Netlify detecta solo la configuración (`netlify.toml`). Presione **Deploy**.

**Opción B (si prefiere no subir el `.env`):** haga lo mismo y, antes de publicar, en Netlify vaya a *Site configuration → Environment variables* y cree las mismas dos variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`. Luego **Deploys → Trigger deploy**.

## PASO 4 — Primer uso

1. Abra la dirección que le dio Netlify e ingrese con el correo y la clave del Paso 1.
2. Menú **Empresas → Nueva empresa**: cree su primera empresa (el sistema carga un plan de cuentas, impuestos, numeración, flujos de aprobación, periodos del año y plantillas de estados financieros como **ejemplos editables**).
3. **Administración → Usuarios → Nuevo usuario**: cree a sus colaboradores y asígneles un rol. No necesita volver a Supabase.

---

## Roles
Administrador · Contador · Auxiliar contable · Compras · Auditor (solo lectura). Los permisos de cada rol se ajustan en **Administración → Roles y permisos**.

## Flujo de documentos
Borrador → Enviado a aprobación → Rechazado / Aprobado → Contabilizado. Los documentos contabilizados no se editan: se **anulan** generando un asiento de reversión. Cada cambio queda en la bitácora de auditoría (inmutable).

## Importante — verifique con su contador
- Los **impuestos, el plan de cuentas y las plantillas de estados financieros** que trae el sistema son **ejemplos configurables**; el sistema no impone reglas tributarias. Revíselos con su contador antes de operar (IVA, IT, IUE, retenciones, formatos de libros).
- Esta versión **no genera** archivos oficiales del SIN (libros de compras/ventas IVA, facturación en línea). El campo “Integraciones” queda preparado para una fase posterior.

## Alcance de esta primera versión (decisiones simplificadas)
- El pago/cobro debe estar en la **misma moneda** que la factura y que la cuenta bancaria.
- No hay anticipos ni notas de crédito/débito: se anula y se vuelve a registrar.
- Gastos compartidos entre actividades: se reparten línea por línea.
- El método de valoración de inventario (promedio ponderado / PEPS) **no se puede cambiar** una vez que hay movimientos.
- La importación de extractos acepta **CSV y Excel (.xlsx)**; no .xls antiguo ni PDF.

## Para desarrolladores
```
npm install
npm run dev      # desarrollo local
npm run build    # compila a /dist
```
`supabase/partes/*.sql` son las partes del script; `supabase/build.py` las une en `01_instalar_base_de_datos.sql`.
