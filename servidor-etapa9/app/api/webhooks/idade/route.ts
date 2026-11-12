// XXV | Webhook da verificacao de idade. Caminho: app/api/webhooks/idade/route.ts
// O usuario NUNCA vem do corpo do webhook: vem da sessao que o nosso servidor criou
// (tabela age_verification_sessions). O banco guarda so o resultado, sem documentos.
import { NextResponse } from 'next/server'
import { supabaseAdmin, ageAdapter, logSecurity, type AgeEvent } from '@/lib/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const reply = (status: number, body: object = {}) => NextResponse.json(body, { status })

// Por quantas horas a verificacao libera o conteudo +18. Confirme o prazo com seu advogado.
const VALID_HOURS = 12

export async function POST(req: Request) {
  const raw = await req.text()
  if (raw.length > 100_000) return reply(413)

  let signed = false
  try {
    signed = ageAdapter.verify(raw, req.headers)
  } catch (e) {
    await logSecurity('age_webhook_adapter_error', { message: String(e) })
    return reply(500)
  }
  if (!signed) {
    await logSecurity('age_webhook_bad_signature', { provider: ageAdapter.name })
    return reply(401)
  }

  let ev: AgeEvent
  try {
    ev = ageAdapter.parse(raw)
  } catch {
    return reply(400)
  }

  const ins = await supabaseAdmin
    .from('webhook_events')
    .insert({ provider: ageAdapter.name, event_id: ev.eventId, payload: { sessionId: ev.sessionId, status: ev.status } })
  if (ins.error) {
    if (ins.error.code !== '23505') return reply(500)
    const { data } = await supabaseAdmin
      .from('webhook_events').select('processed')
      .eq('provider', ageAdapter.name).eq('event_id', ev.eventId).single()
    if (data?.processed) return reply(200, { ok: true, duplicate: true })
  }

  const { error } = await supabaseAdmin.rpc('apply_age_verification_session', {
    p_provider: ageAdapter.name,
    p_session: ev.sessionId,
    p_status: ev.status,
    p_valid_hours: VALID_HOURS,
  })
  if (error) {
    await supabaseAdmin.from('webhook_events').update({ error: error.message })
      .eq('provider', ageAdapter.name).eq('event_id', ev.eventId)
    await logSecurity('age_webhook_failed', { eventId: ev.eventId, message: error.message })
    return reply(500)
  }

  await supabaseAdmin.from('webhook_events').update({ processed: true, error: null })
    .eq('provider', ageAdapter.name).eq('event_id', ev.eventId)
  return reply(200, { ok: true })
}
