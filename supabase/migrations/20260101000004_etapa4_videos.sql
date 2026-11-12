-- =====================================================================
-- XXV | ETAPA 4: publicacao e reproducao de videos
-- =====================================================================
-- Execute DEPOIS das Etapas 2 e 3, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- PROCESSAMENTO E REPRODUCAO: o Supabase Storage guarda o arquivo original,
-- mas nao converte nem entrega video em streaming. Use um servico
-- especializado (Mux, Cloudflare Stream, Bunny Stream ou similar) chamado
-- por um webhook no servidor com a SERVICE_ROLE_KEY. Ele atualiza
-- processing_status e playback_id. Antes de contratar, confirme que os
-- termos do servico permitem conteudo adulto: muitos nao permitem.
-- O limite de tamanho de upload tambem depende do plano do Supabase.
-- =====================================================================

create type video_status      as enum ('draft','pending_review','published','rejected','removed');
create type processing_status as enum ('uploaded','processing','ready','failed');

create table video_categories (
  id         serial primary key,
  slug       text not null unique,
  name       text not null,
  sort_order int  not null default 0,
  active     boolean not null default true
);
insert into video_categories (slug, name, sort_order) values
  ('mulheres','Mulheres',1),('homens','Homens',2),('casais','Casais',3),
  ('gays','Gays',4),('trans','Trans',5);

create table videos (
  id                uuid primary key default gen_random_uuid(),
  creator_id        uuid not null references profiles(id) on delete cascade,
  category_id       int  references video_categories(id),
  title             text not null check (char_length(title) between 3 and 120),
  description       text check (char_length(description) <= 2000),
  is_adult          boolean not null default true,
  is_free           boolean not null default true,
  coin_price        int not null default 0 check (coin_price >= 0),
  source_path       text,            -- bucket videos-source (privado)
  playback_id       text,            -- preenchido pelo servico de streaming
  thumbnail_url     text,
  duration_seconds  int,
  processing_status processing_status not null default 'uploaded',
  status            video_status not null default 'draft',
  rejection_reason  text,
  views_count       bigint not null default 0,
  published_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint published_needs_ready check (status <> 'published' or processing_status = 'ready'),
  constraint free_has_no_price check (not is_free or coin_price = 0)
);
create index videos_feed_idx    on videos (status, published_at desc);
create index videos_creator_idx on videos (creator_id, created_at desc);
create index videos_category_idx on videos (category_id, status);

create table video_views (
  id         bigserial primary key,
  video_id   uuid not null references videos(id) on delete cascade,
  viewer_id  uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index video_views_lookup on video_views (video_id, viewer_id, created_at desc);

-- Registro de consentimento de quem aparece em video +18 (dados privados)
create table video_consents (
  id             uuid primary key default gen_random_uuid(),
  video_id       uuid not null references videos(id) on delete cascade,
  performer_name text not null,
  document_path  text not null,   -- bucket consent-docs (privado)
  consent_path   text not null,
  verified_by    uuid references admin_users(user_id),
  verified_at    timestamptz,
  created_at     timestamptz not null default now()
);

create table reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles(id) on delete cascade,
  target_type text not null check (target_type in ('video','comment','user','conversation')),
  target_id   uuid not null,
  reason      text not null check (reason in ('menor_de_idade','sem_consentimento','ilegal','assedio','spam','outro')),
  details     text check (char_length(details) <= 1000),
  status      text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  resolved_by uuid references admin_users(user_id),
  created_at  timestamptz not null default now()
);
create index reports_queue on reports (status, created_at);

create table admin_logs (
  id          bigserial primary key,
  admin_id    uuid not null references admin_users(user_id),
  action      text not null,
  target_type text,
  target_id   uuid,
  details     jsonb,
  created_at  timestamptz not null default now()
);

-- Funcoes auxiliares
create function viewer_is_age_verified() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                  where id = auth.uid() and age_status = 'verified' and state = 'active');
$$;

create function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger videos_touch before update on videos
  for each row execute function set_updated_at();

-- O criador nao altera status, contadores nem a marcacao +18 depois do envio
create function guard_video_columns() returns trigger language plpgsql as $$
begin
  if current_setting('app.bypass_guard', true) = '1'
     or coalesce(auth.role(), 'service_role') = 'service_role'
     or is_admin() then
    return new;
  end if;
  if new.creator_id        is distinct from old.creator_id
  or new.status            is distinct from old.status
  or new.processing_status is distinct from old.processing_status
  or new.playback_id       is distinct from old.playback_id
  or new.views_count       is distinct from old.views_count
  or new.rejection_reason  is distinct from old.rejection_reason
  or new.published_at      is distinct from old.published_at then
    raise exception 'Campo protegido: nao pode ser alterado diretamente.';
  end if;
  if old.status <> 'draft' and new.is_adult is distinct from old.is_adult then
    raise exception 'A marcacao +18 so pode mudar enquanto o video e rascunho.';
  end if;
  return new;
end $$;
create trigger videos_guard before update on videos
  for each row execute function guard_video_columns();

-- Enviar para publicacao: +18 exige idade e identidade verificadas, consentimentos e moderacao previa
create function submit_video(p_id uuid) returns video_status
language plpgsql security definer set search_path = public as $$
declare v videos; result video_status;
begin
  select * into v from videos where id = p_id and creator_id = auth.uid() for update;
  if not found then raise exception 'Video nao encontrado.'; end if;
  if v.status not in ('draft','rejected') then raise exception 'Este video ja foi enviado.'; end if;
  if v.processing_status <> 'ready' then raise exception 'O video ainda esta sendo processado.'; end if;
  if v.is_adult then
    if not viewer_is_age_verified() then raise exception 'Verifique sua idade para publicar.'; end if;
    if not exists (select 1 from creator_profiles
                    where profile_id = auth.uid() and identity_status = 'verified') then
      raise exception 'Verifique sua identidade para publicar conteudo +18.';
    end if;
    if not exists (select 1 from video_consents where video_id = p_id) then
      raise exception 'Envie o consentimento de todas as pessoas que aparecem no video.';
    end if;
  end if;
  result := case when v.is_adult then 'pending_review' else 'published' end;
  perform set_config('app.bypass_guard', '1', true);
  update videos set status = result, rejection_reason = null,
         published_at = case when result = 'published' then now() end
   where id = p_id;
  return result;
end $$;

-- Moderacao (somente administradores), com registro em admin_logs
create function moderate_video(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Acesso negado.'; end if;
  if not p_approve and coalesce(p_reason, '') = '' then
    raise exception 'Informe o motivo da rejeicao.';
  end if;
  perform set_config('app.bypass_guard', '1', true);
  update videos
     set status = case when p_approve then 'published' else 'rejected' end,
         rejection_reason = case when p_approve then null else p_reason end,
         published_at = case when p_approve then now() end
   where id = p_id;
  insert into admin_logs (admin_id, action, target_type, target_id, details)
  values (auth.uid(), case when p_approve then 'video_approved' else 'video_rejected' end,
          'video', p_id, jsonb_build_object('reason', p_reason));
end $$;

-- Visualizacao: uma por pessoa por video a cada hora; +18 so para idade verificada
create function register_view(p_video uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if not exists (select 1 from videos v where v.id = p_video and v.status = 'published'
                  and (not v.is_adult or viewer_is_age_verified())) then return; end if;
  if exists (select 1 from video_views where video_id = p_video and viewer_id = auth.uid()
                and created_at > now() - interval '1 hour') then return; end if;
  insert into video_views (video_id, viewer_id) values (p_video, auth.uid());
  perform set_config('app.bypass_guard', '1', true);
  update videos set views_count = views_count + 1 where id = p_video;
end $$;

-- RLS
alter table video_categories enable row level security;
alter table videos           enable row level security;
alter table video_views      enable row level security;
alter table video_consents   enable row level security;
alter table reports          enable row level security;
alter table admin_logs       enable row level security;

create policy cat_read   on video_categories for select using (active or is_admin());
create policy cat_admin  on video_categories for all using (is_admin()) with check (is_admin());

create policy videos_read on videos for select using (
  creator_id = auth.uid() or is_admin()
  or (status = 'published'
      and (not is_adult or viewer_is_age_verified())
      and exists (select 1 from profiles p where p.id = creator_id and p.state = 'active'))
);
create policy videos_insert on videos for insert to authenticated with check (
  creator_id = auth.uid() and status = 'draft' and processing_status = 'uploaded'
  and exists (select 1 from profiles p where p.id = auth.uid()
               and p.account_type = 'creator' and p.state = 'active')
);
create policy videos_update on videos for update to authenticated
  using (creator_id = auth.uid()) with check (creator_id = auth.uid());
create policy videos_delete on videos for delete to authenticated using (creator_id = auth.uid());

create policy consent_owner_read on video_consents for select using (
  is_admin() or exists (select 1 from videos v where v.id = video_id and v.creator_id = auth.uid()));
create policy consent_owner_insert on video_consents for insert to authenticated with check (
  exists (select 1 from videos v where v.id = video_id and v.creator_id = auth.uid() and v.status in ('draft','rejected')));
create policy views_admin on video_views for select using (is_admin());

create policy reports_insert on reports for insert to authenticated with check (reporter_id = auth.uid());
create policy reports_read   on reports for select using (reporter_id = auth.uid() or is_admin());
create policy reports_admin  on reports for update using (is_admin()) with check (is_admin());
create policy logs_admin     on admin_logs for select using (is_admin());

-- Armazenamento: videos originais e documentos sao PRIVADOS; miniaturas sao publicas
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('videos-source','videos-source', false, 2147483648, array['video/mp4','video/quicktime','video/webm']),
  ('thumbnails',   'thumbnails',    true,  2097152,    array['image/jpeg','image/png','image/webp']),
  ('consent-docs', 'consent-docs',  false, 10485760,   array['image/jpeg','image/png','application/pdf'])
on conflict (id) do nothing;

create policy "thumb_leitura_publica" on storage.objects for select using (bucket_id = 'thumbnails');
create policy "creator_upload_proprio" on storage.objects for insert to authenticated
  with check (bucket_id in ('videos-source','thumbnails','consent-docs')
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "creator_le_proprio_privado" on storage.objects for select to authenticated
  using (bucket_id in ('videos-source','consent-docs')
         and ((storage.foldername(name))[1] = auth.uid()::text or is_admin()));
create policy "creator_apaga_proprio" on storage.objects for delete to authenticated
  using (bucket_id in ('videos-source','thumbnails','consent-docs')
         and (storage.foldername(name))[1] = auth.uid()::text);
