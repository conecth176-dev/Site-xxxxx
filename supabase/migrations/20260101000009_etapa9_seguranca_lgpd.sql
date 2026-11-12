-- =====================================================================
-- XXV | ETAPA 9 (parte do banco): verificacao de idade, logs de seguranca, LGPD
-- =====================================================================
-- Execute DEPOIS das Etapas 2 a 8, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- IDADE "A CADA ACESSO": o ECA Digital exige verificacao confiavel a cada
-- acesso a conteudo pornografico. Aqui a verificacao vale por uma janela
-- curta (age_verified_until, definida pelo servidor). Antes de lancar, confirme
-- com um advogado e com a ANPD se essa janela atende a lei e ao decreto.
-- O banco guarda so o RESULTADO (verificado/rejeitado), nunca documentos.
-- =====================================================================

-- 1. Janela de verificacao de idade
alter table profiles add column age_verified_until timestamptz;

create or replace function viewer_is_age_verified() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                  where id = auth.uid() and age_status = 'verified' and state = 'active'
                    and age_verified_until is not null and age_verified_until > now());
$$;

-- Guarda de perfil atualizada com o novo campo protegido
create or replace function guard_profile_columns() returns trigger
language plpgsql as $$
begin
  if current_setting('app.bypass_guard', true) = '1'
     or coalesce(auth.role(), 'service_role') = 'service_role'
     or is_admin() then
    return new;
  end if;
  if new.id                  is distinct from old.id
  or new.username            is distinct from old.username
  or new.account_type        is distinct from old.account_type
  or new.account_type_locked is distinct from old.account_type_locked
  or new.age_status          is distinct from old.age_status
  or new.age_verified_at     is distinct from old.age_verified_at
  or new.age_verified_until  is distinct from old.age_verified_until
  or new.state               is distinct from old.state
  or new.username_changed_at is distinct from old.username_changed_at then
    raise exception 'Campo protegido: nao pode ser alterado diretamente.';
  end if;
  if new.avatar_url is distinct from old.avatar_url and new.avatar_url is not null
     and position('/avatars/' || auth.uid()::text || '/' in new.avatar_url) = 0 then
    raise exception 'A foto de perfil precisa estar na sua pasta de avatares.';
  end if;
  if new.cover_url is distinct from old.cover_url and new.cover_url is not null
     and position('/covers/' || auth.uid()::text || '/' in new.cover_url) = 0 then
    raise exception 'A capa precisa estar na sua pasta de capas.';
  end if;
  return new;
end $$;

-- Revisao manual do administrador agora tambem abre a janela de acesso
create or replace function admin_set_verification(p_user uuid, p_kind text, p_status age_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Informe o motivo.'; end if;
  perform set_config('app.bypass_guard', '1', true);
  if p_kind = 'age' then
    update profiles set age_status = p_status,
           age_verified_at    = case when p_status = 'verified' then now() end,
           age_verified_until = case when p_status = 'verified' then now() + interval '12 hours' end
     where id = p_user;
  elsif p_kind = 'identity' then
    update creator_profiles set identity_status = p_status, identity_checked_at = now()
     where profile_id = p_user;
    if not found then raise exception 'Este usuario nao e criador.'; end if;
  else
    raise exception 'Tipo de verificacao invalido.';
  end if;
  perform admin_log('verification_' || p_kind, 'user', p_user,
                    jsonb_build_object('status', p_status, 'reason', p_reason));
end $$;

-- Sessoes de verificacao: o SERVIDOR cria a linha ao abrir a sessao no provedor
create table age_verification_sessions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references profiles(id) on delete cascade,
  provider            text not null,
  provider_session_id text not null,
  status              age_status not null default 'pending',
  created_at          timestamptz not null default now(),
  completed_at        timestamptz,
  unique (provider, provider_session_id)
);

-- Chamada pelo webhook do provedor (somente servidor). O usuario vem da sessao, nunca do corpo do webhook.
create function apply_age_verification_session(
  p_provider text, p_session text, p_status age_status, p_valid_hours int default 12
) returns void language plpgsql security definer set search_path = public as $$
declare s age_verification_sessions;
begin
  if p_valid_hours < 1 or p_valid_hours > 168 then raise exception 'Janela invalida.'; end if;
  select * into s from age_verification_sessions
   where provider = p_provider and provider_session_id = p_session for update;
  if not found then raise exception 'Sessao de verificacao desconhecida.'; end if;
  if s.status in ('verified','rejected') then return; end if;          -- resultado final, webhook repetido
  update age_verification_sessions
     set status = p_status, completed_at = case when p_status <> 'pending' then now() end
   where id = s.id;
  if p_status <> 'pending' then
    perform set_config('app.bypass_guard', '1', true);
    update profiles set age_status = p_status,
           age_verified_at    = case when p_status = 'verified' then now() end,
           age_verified_until = case when p_status = 'verified'
                                     then now() + make_interval(hours => p_valid_hours) end
     where id = s.user_id;
  end if;
end $$;

-- 2. Registros de seguranca e de webhooks (so servidor escreve; so administrador le)
create table webhook_events (
  id          bigserial primary key,
  provider    text not null,
  event_id    text not null,
  payload     jsonb,
  processed   boolean not null default false,
  error       text,
  received_at timestamptz not null default now(),
  unique (provider, event_id)
);
create table security_events (
  id         bigserial primary key,
  user_id    uuid references profiles(id) on delete set null,
  kind       text not null,
  details    jsonb,
  created_at timestamptz not null default now()
);
create index security_events_idx on security_events (kind, created_at desc);

alter table age_verification_sessions enable row level security;
alter table webhook_events           enable row level security;
alter table security_events          enable row level security;
create policy webhook_admin  on webhook_events  for select using (is_full_admin());
create policy security_admin on security_events for select using (is_full_admin());
create policy agesess_own    on age_verification_sessions for select using (user_id = auth.uid() or is_full_admin());

-- 3. LGPD: exportar os proprios dados
create function export_my_data() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Nao autenticado.'; end if;
  return jsonb_build_object(
    'exportado_em', now(),
    'perfil',        (select to_jsonb(p) from profiles p where p.id = me),
    'videos',        (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from videos x where x.creator_id = me),
    'comentarios',   (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from comments x where x.user_id = me),
    'curtidas',      (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from likes x where x.user_id = me),
    'favoritos',     (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from favorites x where x.user_id = me),
    'seguindo',      (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from followers x where x.follower_id = me),
    'bloqueios',     (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from blocks x where x.blocker_id = me),
    'mensagens_enviadas', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from messages x where x.sender_id = me),
    'notificacoes',  (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from notifications x where x.user_id = me),
    'historico_de_visualizacao', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from video_views x where x.viewer_id = me),
    'carteira',      (select to_jsonb(w) from coin_wallets w where w.user_id = me),
    'extrato_de_moedas', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from coin_transactions x where x.user_id = me),
    'compras',       (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from
                       (select id, package_id, coins, amount_cents, currency, status, created_at, paid_at
                          from payment_transactions where user_id = me) x),
    'aceites_legais',(select coalesce(jsonb_agg(to_jsonb(x)), '[]') from user_consents x where x.user_id = me));
end $$;

-- 4. LGPD: exclusao de conta (30 dias para o usuario desistir)
create table deletion_requests (
  user_id       uuid primary key references profiles(id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending','cancelled','done')),
  requested_at  timestamptz not null default now(),
  scheduled_for timestamptz not null default now() + interval '30 days'
);
alter table deletion_requests enable row level security;
create policy deletion_own on deletion_requests for select using (user_id = auth.uid() or is_full_admin());

create function request_account_deletion() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare d timestamptz := now() + interval '30 days';
begin
  if auth.uid() is null then raise exception 'Nao autenticado.'; end if;
  insert into deletion_requests (user_id, status, requested_at, scheduled_for)
  values (auth.uid(), 'pending', now(), d)
  on conflict (user_id) do update set status = 'pending', requested_at = now(), scheduled_for = d
   where deletion_requests.status <> 'done';
  return d;
end $$;

create function cancel_account_deletion() returns void
language sql security definer set search_path = public as $$
  update deletion_requests set status = 'cancelled' where user_id = auth.uid() and status = 'pending';
$$;

-- Rotina diaria (servidor/cron). Anonimiza o que e pessoal e MANTEM o que a lei manda guardar
-- (compras e extrato financeiro; comprovantes de consentimento de videos +18).
-- Retorna os usuarios processados: o servidor entao apaga os arquivos de avatars, covers,
-- thumbnails e videos-source deles (NAO apagar consent-docs) e desativa o login em auth.users.
-- Prazos de guarda: defina com seu advogado.
create function process_account_deletions() returns table (deleted_user uuid)
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  perform set_config('app.bypass_guard', '1', true);
  for r in select d.user_id as uid from deletion_requests d
            where d.status = 'pending' and d.scheduled_for <= now() loop
    delete from likes          where user_id = r.uid;
    delete from favorites      where user_id = r.uid;
    delete from followers      where follower_id = r.uid or creator_id = r.uid;
    delete from blocks         where blocker_id = r.uid or blocked_id = r.uid;
    delete from video_views    where viewer_id = r.uid;
    delete from notifications  where user_id = r.uid or actor_id = r.uid;
    delete from user_entitlements where user_id = r.uid;
    delete from admin_users    where user_id = r.uid;
    perform set_config('app.bypass_guard', '1', true);   -- os gatilhos de contador o desligam
    update comments set body = '[comentario removido]', status = 'removed' where user_id = r.uid;
    perform set_config('app.bypass_guard', '1', true);
    update messages set body = '[mensagem removida]' where sender_id = r.uid;
    update videos set status = 'removed', source_path = null, thumbnail_url = null,
           playback_id = null, rejection_reason = 'Conta excluida'
     where creator_id = r.uid;
    update profiles set username = 'removido_' || substr(md5(r.uid::text), 1, 10),
           display_name = null, avatar_url = null, cover_url = null, bio = null,
           state = 'blocked', age_verified_until = null
     where id = r.uid;
    update deletion_requests set status = 'done' where user_id = r.uid;
    deleted_user := r.uid;
    return next;
  end loop;
end $$;

-- Limpeza periodica (ajuste os prazos com seu advogado)
create function purge_old_data() returns void
language sql security definer set search_path = public as $$
  delete from notifications where read_at is not null and read_at < now() - interval '90 days';
  delete from video_views   where created_at < now() - interval '365 days';
$$;

-- 5. Permissoes
revoke execute on function apply_age_verification_session(text,text,age_status,int) from public, anon, authenticated;
revoke execute on function process_account_deletions() from public, anon, authenticated;
revoke execute on function purge_old_data()            from public, anon, authenticated;
grant  execute on function apply_age_verification_session(text,text,age_status,int) to service_role;
grant  execute on function process_account_deletions() to service_role;
grant  execute on function purge_old_data()            to service_role;
revoke execute on function export_my_data()            from public, anon;
revoke execute on function request_account_deletion()  from public, anon;
revoke execute on function cancel_account_deletion()   from public, anon;
grant  execute on function export_my_data()            to authenticated;
grant  execute on function request_account_deletion()  to authenticated;
grant  execute on function cancel_account_deletion()   to authenticated;
