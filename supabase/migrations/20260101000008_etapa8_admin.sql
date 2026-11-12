-- =====================================================================
-- XXV | ETAPA 8: painel administrativo (camada de dados e permissoes)
-- =====================================================================
-- Execute DEPOIS das Etapas 2 a 7, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- PRIMEIRO ADMINISTRADOR (rode uma vez, com o seu id de usuario):
--   insert into admin_users (user_id, role) values ('<SEU-UUID>', 'admin');
--
-- DOIS NIVEIS
--   admin     : tudo, inclusive financeiro, configuracoes, equipe e e-mails.
--   moderator : videos, denuncias, comentarios e suspensao de contas.
-- Toda acao administrativa pelas funcoes abaixo grava uma linha em admin_logs.
-- O painel (telas) usa estas funcoes; ele nunca recebe a SERVICE_ROLE_KEY.
-- =====================================================================

-- 1. Papeis
create function admin_role() returns text
language sql stable security definer set search_path = public as $$
  select role from admin_users where user_id = auth.uid();
$$;
create function is_full_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(admin_role() = 'admin', false);
$$;

create function admin_log(p_action text, p_type text, p_id uuid, p_details jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into admin_logs (admin_id, action, target_type, target_id, details)
  values (auth.uid(), p_action, p_type, p_id, p_details);
$$;
revoke execute on function admin_log(text,text,uuid,jsonb) from public, anon, authenticated;

-- 2. Fecha o acesso financeiro e de logs para moderadores; remove atalhos sem registro
drop policy wallet_read  on coin_wallets;
drop policy cointx_read  on coin_transactions;
drop policy ent_read     on user_entitlements;
drop policy pay_admin    on payment_transactions;
drop policy pkg_admin    on coin_packages;
drop policy prod_admin   on coin_products;
drop policy cat_admin    on video_categories;
drop policy logs_admin   on admin_logs;
drop policy reports_admin on reports;

create policy wallet_read on coin_wallets      for select using (user_id = auth.uid() or is_full_admin());
create policy cointx_read on coin_transactions for select using (user_id = auth.uid() or is_full_admin());
create policy ent_read    on user_entitlements for select using (user_id = auth.uid() or is_full_admin());
create policy pay_admin   on payment_transactions for select using (is_full_admin());
create policy pkg_admin   on coin_packages    for all using (is_full_admin()) with check (is_full_admin());
create policy prod_admin  on coin_products    for all using (is_full_admin()) with check (is_full_admin());
create policy cat_admin   on video_categories for all using (is_full_admin()) with check (is_full_admin());
create policy logs_admin  on admin_logs       for select using (is_full_admin());

create or replace function audit_wallets() returns table (user_id uuid, balance bigint, ledger_sum bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not (is_full_admin() or coalesce(auth.role(), 'service_role') = 'service_role') then
    raise exception 'Acesso negado.';
  end if;
  return query
    select w.user_id, w.balance, coalesce(sum(t.amount), 0)::bigint
      from coin_wallets w left join coin_transactions t on t.user_id = w.user_id
     group by w.user_id, w.balance
    having w.balance <> coalesce(sum(t.amount), 0);
end $$;

alter table reports add column resolution_note text, add column resolved_at timestamptz;

-- 3. Dashboard
create function admin_dashboard() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  r := jsonb_build_object(
    'users_total',       (select count(*) from profiles),
    'creators',          (select count(*) from profiles where account_type = 'creator'),
    'viewers',           (select count(*) from profiles where account_type = 'viewer'),
    'videos_total',      (select count(*) from videos),
    'videos_published',  (select count(*) from videos where status = 'published'),
    'videos_pending',    (select count(*) from videos where status = 'pending_review'),
    'views_total',       (select coalesce(sum(views_count), 0) from videos),
    'active_users_7d',   (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'open_reports',      (select count(*) from reports where status in ('open','reviewing')));
  if is_full_admin() then
    r := r || jsonb_build_object(
      'revenue_cents_30d',   (select coalesce(sum(amount_cents), 0) from payment_transactions
                               where status = 'paid' and paid_at > now() - interval '30 days'),
      'payments_paid_30d',   (select count(*) from payment_transactions
                               where status = 'paid' and paid_at > now() - interval '30 days'),
      'coins_in_circulation',(select coalesce(sum(balance), 0) from coin_wallets));
  end if;
  return r;
end $$;

create function admin_financial_summary(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = public as $$
declare since timestamptz := now() - make_interval(days => greatest(p_days, 1));
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  return jsonb_build_object(
    'days', p_days,
    'paid_count',       (select count(*) from payment_transactions where status = 'paid' and paid_at >= since),
    'paid_cents',       (select coalesce(sum(amount_cents), 0) from payment_transactions where status = 'paid' and paid_at >= since),
    'pending_count',    (select count(*) from payment_transactions where status = 'pending' and created_at >= since),
    'refunded_count',   (select count(*) from payment_transactions where status in ('refunded','chargeback') and created_at >= since),
    'coins_sold',       (select coalesce(sum(amount), 0) from coin_transactions where kind = 'purchase' and created_at >= since),
    'coins_spent',      (select coalesce(-sum(amount), 0) from coin_transactions where kind = 'spend' and created_at >= since),
    'shortfall_coins',  (select coalesce(sum(shortfall_coins), 0) from payment_transactions));
end $$;

-- 4. Usuarios
create function admin_list_users(p_search text default null, p_limit int default 25, p_offset int default 0)
returns table (id uuid, username text, display_name text, email text, account_type account_type,
               age_status age_status, state account_state, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  return query
    select p.id, p.username, p.display_name,
           case when is_full_admin() then u.email::text end,
           p.account_type, p.age_status, p.state, p.created_at
      from profiles p join auth.users u on u.id = p.id
     where p_search is null
        or p.username ilike '%' || p_search || '%'
        or p.display_name ilike '%' || p_search || '%'
        or (is_full_admin() and u.email ilike '%' || p_search || '%')
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end $$;

create function admin_user_history(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  return jsonb_build_object(
    'logs', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from
              (select action, details, created_at from admin_logs
                where target_id = p_user order by created_at desc limit 50) x),
    'reports', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from
              (select id, reason, status, created_at from reports
                where target_type = 'user' and target_id = p_user order by created_at desc limit 50) x),
    'videos', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from
              (select id, title, status, created_at from videos
                where creator_id = p_user order by created_at desc limit 20) x),
    'payments', case when is_full_admin() then
              (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from
                (select id, amount_cents, status, created_at from payment_transactions
                  where user_id = p_user order by created_at desc limit 20) x) end);
end $$;

create function admin_set_user_state(p_user uuid, p_state account_state, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Informe o motivo.'; end if;
  if p_user = auth.uid() then raise exception 'Voce nao pode alterar a propria conta.'; end if;
  if exists (select 1 from admin_users where user_id = p_user) and not is_full_admin() then
    raise exception 'Apenas administradores alteram a equipe.';
  end if;
  if p_state = 'blocked' and not is_full_admin() then
    raise exception 'Apenas administradores podem bloquear contas.';
  end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set state = p_state where id = p_user;
  perform admin_log('user_state_' || p_state, 'user', p_user, jsonb_build_object('reason', p_reason));
end $$;
-- Observacao: ao suspender ou bloquear, o servidor deve tambem encerrar as sessoes
-- da pessoa pela API de administracao do Supabase Auth (precisa da SERVICE_ROLE_KEY).

create function admin_set_account_type(p_user uuid, p_type account_type, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Informe o motivo.'; end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set account_type = p_type, account_type_locked = true where id = p_user;
  if p_type = 'creator' then
    insert into creator_profiles (profile_id) values (p_user) on conflict do nothing;
  end if;
  perform admin_log('account_type_changed', 'user', p_user,
                    jsonb_build_object('type', p_type, 'reason', p_reason));
end $$;

-- Revisao manual de idade ou identidade (alem do provedor de verificacao)
create function admin_set_verification(p_user uuid, p_kind text, p_status age_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Informe o motivo.'; end if;
  perform set_config('app.bypass_guard', '1', true);
  if p_kind = 'age' then
    update profiles set age_status = p_status,
           age_verified_at = case when p_status = 'verified' then now() end where id = p_user;
  elsif p_kind = 'identity' then
    update creator_profiles set identity_status = p_status,
           identity_checked_at = now() where profile_id = p_user;
    if not found then raise exception 'Este usuario nao e criador.'; end if;
  else
    raise exception 'Tipo de verificacao invalido.';
  end if;
  perform admin_log('verification_' || p_kind, 'user', p_user,
                    jsonb_build_object('status', p_status, 'reason', p_reason));
end $$;

create function admin_set_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  if p_user = auth.uid() then raise exception 'Voce nao pode alterar o proprio papel.'; end if;
  if p_role is null then
    delete from admin_users where user_id = p_user;
  elsif p_role in ('admin','moderator') then
    insert into admin_users (user_id, role) values (p_user, p_role)
      on conflict (user_id) do update set role = excluded.role;
  else
    raise exception 'Papel invalido.';
  end if;
  perform admin_log('role_changed', 'user', p_user, jsonb_build_object('role', p_role));
end $$;

-- 5. Videos e denuncias (aprovar/rejeitar ja existe: moderate_video, Etapa 4)
create function admin_remove_video(p_video uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Informe o motivo.'; end if;
  perform set_config('app.bypass_guard', '1', true);
  update videos set status = 'removed', rejection_reason = p_reason where id = p_video;
  perform admin_log('video_removed', 'video', p_video, jsonb_build_object('reason', p_reason));
end $$;

create function admin_resolve_report(p_report uuid, p_status text, p_note text, p_remove_target boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare r reports;
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  if p_status not in ('reviewing','resolved','dismissed') then raise exception 'Status invalido.'; end if;
  select * into r from reports where id = p_report for update;
  if not found then raise exception 'Denuncia nao encontrada.'; end if;
  perform set_config('app.bypass_guard', '1', true);
  if p_remove_target and p_status = 'resolved' then
    if r.target_type = 'video' then
      update videos set status = 'removed', rejection_reason = coalesce(p_note, 'Removido apos denuncia')
       where id = r.target_id;
    elsif r.target_type = 'comment' then
      update comments set status = 'removed' where id = r.target_id;
    end if;
  end if;
  update reports set status = p_status, resolution_note = p_note, resolved_by = auth.uid(),
         resolved_at = case when p_status <> 'reviewing' then now() end
   where id = p_report;
  perform admin_log('report_' || p_status, 'report', p_report,
                    jsonb_build_object('target_type', r.target_type, 'removed', p_remove_target));
end $$;

-- 6. Configuracoes da plataforma
create table platform_settings (
  key        text primary key,
  value      jsonb not null,
  is_public  boolean not null default false,
  updated_by uuid references admin_users(user_id),
  updated_at timestamptz not null default now()
);
insert into platform_settings (key, value, is_public) values
  ('platform_name', '"XXV"', true),
  ('logo_url', 'null', true);

create function settings_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := auth.uid(); new.updated_at := now();
  perform admin_log('setting_changed', 'setting', null,
                    jsonb_build_object('key', new.key, 'value', new.value));
  return new;
end $$;
create trigger settings_log before insert or update on platform_settings
  for each row execute function settings_audit();

alter table platform_settings enable row level security;
create policy settings_read  on platform_settings for select using (is_public or is_full_admin());
create policy settings_admin on platform_settings for all using (is_full_admin()) with check (is_full_admin());

-- Logotipo: leitura publica, escrita so de administrador
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', true, 2097152, array['image/png','image/svg+xml','image/webp'])
on conflict (id) do nothing;
create policy "branding_leitura" on storage.objects for select using (bucket_id = 'branding');
create policy "branding_escrita" on storage.objects for all to authenticated
  using (bucket_id = 'branding' and is_full_admin())
  with check (bucket_id = 'branding' and is_full_admin());

-- 7. Termos, privacidade e regras (com versoes e aceite, util para a LGPD)
create table legal_documents (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null check (slug in ('termos','privacidade','regras')),
  version      int  not null,
  title        text not null,
  body         text not null,
  published_at timestamptz not null default now(),
  created_by   uuid references admin_users(user_id),
  unique (slug, version)
);
alter table legal_documents enable row level security;
create policy legal_admin_read on legal_documents for select using (is_full_admin());

create view latest_legal_documents as
  select distinct on (slug) id, slug, version, title, body, published_at
    from legal_documents order by slug, version desc;
grant select on latest_legal_documents to anon, authenticated;

create function publish_legal_document(p_slug text, p_title text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v int; new_id uuid;
begin
  if not is_full_admin() then raise exception 'Acesso negado.'; end if;
  select coalesce(max(version), 0) + 1 into v from legal_documents where slug = p_slug;
  insert into legal_documents (slug, version, title, body, created_by)
  values (p_slug, v, p_title, p_body, auth.uid()) returning id into new_id;
  perform admin_log('legal_published', 'legal', new_id, jsonb_build_object('slug', p_slug, 'version', v));
  return new_id;
end $$;

create table user_consents (
  user_id     uuid not null references profiles(id) on delete cascade,
  document_id uuid not null references legal_documents(id),
  accepted_at timestamptz not null default now(),
  primary key (user_id, document_id)
);
alter table user_consents enable row level security;
create policy consents_read on user_consents for select using (user_id = auth.uid() or is_full_admin());

create function accept_legal(p_document uuid) returns void
language sql security definer set search_path = public as $$
  insert into user_consents (user_id, document_id) values (auth.uid(), p_document)
  on conflict do nothing;
$$;

-- 8. Permissoes das funcoes do painel (cada uma confere o papel por dentro)
revoke execute on function
  admin_dashboard(), admin_financial_summary(int), admin_list_users(text,int,int),
  admin_user_history(uuid), admin_set_user_state(uuid,account_state,text),
  admin_set_account_type(uuid,account_type,text), admin_set_verification(uuid,text,age_status,text),
  admin_set_role(uuid,text), admin_remove_video(uuid,text),
  admin_resolve_report(uuid,text,text,boolean), publish_legal_document(text,text,text), accept_legal(uuid)
  from public, anon;
grant execute on function
  admin_dashboard(), admin_financial_summary(int), admin_list_users(text,int,int),
  admin_user_history(uuid), admin_set_user_state(uuid,account_state,text),
  admin_set_account_type(uuid,account_type,text), admin_set_verification(uuid,text,age_status,text),
  admin_set_role(uuid,text), admin_remove_video(uuid,text),
  admin_resolve_report(uuid,text,text,boolean), publish_legal_document(text,text,text), accept_legal(uuid)
  to authenticated;
