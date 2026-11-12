// XXV | middleware.ts (raiz do projeto Next.js)
// 1) limite de requisicoes por IP  2) rotas protegidas  3) /admin so para equipe
// 4) conteudo +18 so com idade verificada e valida  5) cabecalhos de seguranca
import { NextResponse, type NextRequest } from 'next/server'
import { createServerClient } from '@supabase/ssr'
import { Ratelimit } from '@upstash/ratelimit'
import { Redis } from '@upstash/redis'

const redis = process.env.UPSTASH_REDIS_REST_URL ? Redis.fromEnv() : null
const limitGeral = redis && new Ratelimit({ redis, limiter: Ratelimit.slidingWindow(120, '1 m'), prefix: 'xxv:geral' })
const limitSensivel = redis && new Ratelimit({ redis, limiter: Ratelimit.slidingWindow(10, '1 m'), prefix: 'xxv:sensivel' })

const SENSIVEL = ['/login', '/cadastro', '/api/auth', '/api/idade']
const LOGADO = ['/painel', '/carteira', '/configuracoes', '/mensagens', '/publicar']
const ADULTO = ['/explorar', '/video', '/criador', '/mensagens', '/publicar']
const starts = (path: string, list: string[]) => list.some((p) => path === p || path.startsWith(p + '/'))

function seguranca(res: NextResponse) {
  res.headers.set('X-Content-Type-Options', 'nosniff')
  res.headers.set('X-Frame-Options', 'DENY')
  res.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin')
  res.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
  res.headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload')
  // Content-Security-Policy: adicione depois, ajustada aos dominios reais
  // (Supabase, servico de video, provedor de pagamento e de idade).
  return res
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl

  // Webhooks vem dos provedores: so seguranca basica, sem login. A assinatura e conferida na propria rota.
  if (pathname.startsWith('/api/webhooks')) return seguranca(NextResponse.next())

  // 1. Limite de requisicoes
  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'desconhecido'
  const limiter = starts(pathname, SENSIVEL) ? limitSensivel : limitGeral
  if (limiter) {
    const { success, reset } = await limiter.limit(ip)
    if (!success) {
      const res = new NextResponse('Muitas requisicoes. Tente novamente em instantes.', { status: 429 })
      res.headers.set('Retry-After', String(Math.max(1, Math.ceil((reset - Date.now()) / 1000))))
      return seguranca(res)
    }
  }

  // 2. Sessao
  let response = NextResponse.next({ request })
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (items) => {
          items.forEach(({ name, value }) => request.cookies.set(name, value))
          response = NextResponse.next({ request })
          items.forEach(({ name, value, options }) => response.cookies.set(name, value, options))
        },
      },
    },
  )
  const { data: { user } } = await supabase.auth.getUser()   // valida o token no servidor do Supabase

  const ir = (path: string, withNext = false) => {
    const url = request.nextUrl.clone()
    url.pathname = path
    url.search = withNext ? `?next=${encodeURIComponent(pathname)}` : ''
    const res = NextResponse.redirect(url)
    response.cookies.getAll().forEach((c) => res.cookies.set(c))
    return seguranca(res)
  }

  // 3. Area administrativa: quem nao e da equipe recebe 404, sem pistas de que a rota existe
  if (starts(pathname, ['/admin'])) {
    if (!user) return ir('/login', true)
    const { data: papel } = await supabase.rpc('admin_role')
    if (!papel) return seguranca(NextResponse.rewrite(new URL('/404', request.url)))
    return seguranca(response)
  }

  // 4. Areas que exigem login
  if (starts(pathname, LOGADO) && !user) return ir('/login', true)

  // 5. Conteudo +18: login + idade verificada e dentro da janela de validade
  if (starts(pathname, ADULTO)) {
    if (!user) return ir('/login', true)
    const { data: idadeOk } = await supabase.rpc('viewer_is_age_verified')
    if (!idadeOk) return ir('/verificar-idade', true)
  }

  return seguranca(response)
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|jpg|jpeg|webp|svg|ico)$).*)'],
}
