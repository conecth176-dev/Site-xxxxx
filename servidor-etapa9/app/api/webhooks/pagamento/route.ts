// XXV | Webhook de pagamento. Caminho no projeto: app/api/webhooks/pagamento/route.ts
// Fluxo: assinatura -> deduplicacao -> confirmacao no provedor -> funcao do banco (credito unico).
import { NextResponse } from 'next/server'
import { supabaseAdmin, paymentAdapter, logSecurity, type PaymentEvent } from '@/lib/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const reply = (status: number, body: object = {}) => NextResponse.json(body, { status })

export async function POST(req: Request) {
  const raw = await req.text()
  if (raw.length > 100_000) return reply(413)

  // 1. Assinatura. Sem ela valida, nada e processado.
  let signed = false
  try {
    signed = paymentAdapter.verify(raw, req.headers)
  } catch (e) {
    await logSecurity('payment_webhook_adapter_error', { message: String(e) })
    return reply(500)
  }
  if (!signed) {
    await logSecurity('payment_webhook_bad_signature', { provider: paymentAdapter.name })
    return reply(401)
  }

  let ev: PaymentEvent
  let payload: unknown
  try {
    payload = JSON.parse(raw)
    ev = paymentAdapter.parse(raw)
  } catch {
    return reply(400)
  }

  // 2. Deduplicacao por evento: o provedor pode reenviar o mesmo aviso.
  const ins = await supabaseAdmin
    .from('webhook_events')
    .insert({ provider: paymentAdapter.name, event_id: ev.eventId, payload })
  if (ins.error) {
    if (ins.error.code !== '23505') return reply(500)
    const { data } = await supabaseAdmin
      .from('webhook_events').select('processed')
      .eq('provider', paymentAdapter.name).eq('event_id', ev.eventId).single()
    if (data?.processed) return reply(200, { ok: true, duplicate: true })
  }

  // 3. Processamento. Erro => 500, para o provedor tentar de novo.
  try {
    if (ev.status === 'paid') {
      // Nao confiamos so no corpo recebido: perguntamos ao provedor.
      const real = await paymentAdapter.confirmWithProvider(ev)
      if (real.status !== 'paid') throw new Error('O provedor nao confirma este pagamento.')
      const { error } = await supabaseAdmin.rpc('confirm_payment', {
        p_payment: real.ourPaymentId,
        p_provider_payment_id: real.providerPaymentId,
        p_amount_cents: real.amountCents,
      })
      if (error) throw error
    } else if (ev.status === 'refunded' || ev.status === 'chargeback') {
      const { error } = await supabaseAdmin.rpc('reverse_payment', {
        p_payment: ev.ourPaymentId,
        p_status: ev.status,
      })
      if (error) throw error
    }
    // 'pending' e 'failed': so registramos o evento.

    await supabaseAdmin.from('webhook_events').update({ processed: true, error: null })
      .eq('provider', paymentAdapter.name).eq('event_id', ev.eventId)
    return reply(200, { ok: true })
  } catch (e) {
    const message = e instanceof Error ? e.message : JSON.stringify(e)
    await supabaseAdmin.from('webhook_events').update({ error: message })
      .eq('provider', paymentAdapter.name).eq('event_id', ev.eventId)
    await logSecurity('payment_webhook_failed', { eventId: ev.eventId, message })
    return reply(500)
  }
}
