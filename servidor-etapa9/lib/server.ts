// XXV | Etapa 9: utilitarios SOMENTE DE SERVIDOR (nunca importe isto em componente do navegador).
//
// Dependencias: npm i @supabase/supabase-js @supabase/ssr @upstash/ratelimit @upstash/redis server-only
// Variaveis de ambiente (configure no painel da hospedagem, nunca no codigo):
//   NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY   (podem ir ao navegador)
//   SUPABASE_SERVICE_ROLE_KEY                                 (SECRETA, so servidor)
//   PAYMENT_WEBHOOK_SECRET, AGE_WEBHOOK_SECRET                (SECRETAS)
//   UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN          (limite de requisicoes)
import 'server-only'
import { createClient } from '@supabase/supabase-js'
import { createHmac, timingSafeEqual } from 'node:crypto'

export const supabaseAdmin = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false, autoRefreshToken: false } },
)

// Comparacao de assinatura HMAC-SHA256 (hex) em tempo constante.
// Cada provedor monta a assinatura de um jeito: use como base e siga a documentacao dele.
export function hmacOk(raw: string, signatureHex: string | null, secret: string | undefined): boolean {
  if (!signatureHex || !secret) return false
  const expected = createHmac('sha256', secret).update(raw).digest()
  const given = Buffer.from(signatureHex, 'hex')
  return given.length === expected.length && timingSafeEqual(given, expected)
}

export async function logSecurity(kind: string, details: Record<string, unknown> = {}) {
  await supabaseAdmin.from('security_events').insert({ kind, details })
}

// ---- Contratos que o provedor escolhido precisa cumprir ----------------------------------

export type PaymentEvent = {
  eventId: string
  ourPaymentId: string        // id da linha em payment_transactions (enviado ao provedor como referencia)
  providerPaymentId: string
  status: 'paid' | 'refunded' | 'chargeback' | 'failed' | 'pending'
  amountCents: number
}

export interface PaymentAdapter {
  name: string
  verify(raw: string, headers: Headers): boolean
  parse(raw: string): PaymentEvent
  // Consulta o provedor pela API oficial e devolve o estado REAL do pagamento.
  confirmWithProvider(event: PaymentEvent): Promise<PaymentEvent>
}

export type AgeEvent = {
  eventId: string
  sessionId: string
  status: 'verified' | 'rejected' | 'pending'
}

export interface AgeAdapter {
  name: string
  verify(raw: string, headers: Headers): boolean
  parse(raw: string): AgeEvent
}

// ---- PENDENTE: implemente quando o provedor for escolhido --------------------------------
const pending = (what: string): never => {
  throw new Error(`Implemente ${what} conforme a documentacao do provedor escolhido.`)
}

export const paymentAdapter: PaymentAdapter = {
  name: 'PROVEDOR_DE_PAGAMENTO',
  verify: () => pending('paymentAdapter.verify'),
  parse: () => pending('paymentAdapter.parse'),
  confirmWithProvider: () => pending('paymentAdapter.confirmWithProvider'),
}

export const ageAdapter: AgeAdapter = {
  name: 'PROVEDOR_DE_IDADE',
  verify: () => pending('ageAdapter.verify'),
  parse: () => pending('ageAdapter.parse'),
}
