-- =====================================================================
-- XXV | ETAPA 5: seguidores, curtidas, comentarios, favoritos, historico
-- =====================================================================
-- Execute DEPOIS das Etapas 2, 3 e 4, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- CORRECAO DA ETAPA 4: a politica "videos_read" consultava a tabela profiles
-- diretamente, mas cada usuario so enxerga o proprio perfil. Resultado:
-- ninguem veria videos de outros criadores. A correcao esta no bloco 1.
-- =====================================================================

-- 1. Correcao: verificar se o criador esta ativo sem depender da RLS de profiles
create function creator_is_active(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = p_id and state = 'active');
$$;

drop policy videos_read on videos;
create policy videos_read on videos for select using (
  creator_id = auth.uid() or is_admin()
  or (status = 'published'
      and (not is_adult or viewer_is_age_verified())
      and creator_is_active(creator_id))
);

-- 2. Contadores no video (o criador nao pode altera-los)
alter table videos
  add column likes_count    bigint not null default 0,
  add column comments_count bigint not null default 0;

create or replace function guard_video_columns() returns trigger language plpgsql as $$
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
  or new.likes_count       is distinct from old.likes_count
  or new.comments_count    is distinct from old.comments_count
  or new.rejection_reason  is distinct from old.rejection_reason
  or new.published_at      is distinct from old.published_at then
    raise exception 'Campo protegido: nao pode ser alterado diretamente.';
  end if;
  if old.status <> 'draft' and new.is_adult is distinct from old.is_adult then
    raise exception 'A marcacao +18 so pode mudar enquanto o video e rascunho.';
  end if;
  return new;
end $$;

-- 3. Tabelas
create table followers (
  follower_id uuid not null references profiles(id) on delete cascade,
  creator_id  uuid not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, creator_id),
  check (follower_id <> creator_id)
);
create index followers_creator_idx on followers (creator_id);

create table likes (
  user_id    uuid not null references profiles(id) on delete cascade,
  video_id   uuid not null references videos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create index likes_video_idx on likes (video_id);

create table favorites (
  user_id    uuid not null references profiles(id) on delete cascade,
  video_id   uuid not null references videos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create index favorites_user_idx on favorites (user_id, created_at desc);

create table comments (
  id         uuid primary key default gen_random_uuid(),
  video_id   uuid not null references videos(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  parent_id  uuid references comments(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 1000),
  status     text not null default 'visible' check (status in ('visible','hidden','removed')),
  created_at timestamptz not null default now(),
  edited_at  timestamptz
);
create index comments_video_idx on comments (video_id, created_at);
create index comments_parent_idx on comments (parent_id);

-- 4. Regras dos comentarios: resposta de um nivel so, mesmo video, limite de 20 por minuto
create function comment_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.parent_id is not null and not exists (
       select 1 from comments c
        where c.id = new.parent_id and c.video_id = new.video_id and c.parent_id is null) then
    raise exception 'Resposta invalida: o comentario original nao existe neste video ou ja e uma resposta.';
  end if;
  if (select count(*) from comments
       where user_id = new.user_id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Voce esta comentando rapido demais. Aguarde um instante.';
  end if;
  return new;
end $$;
create trigger comments_check before insert on comments
  for each row execute function comment_before_insert();

create function comment_before_update() returns trigger language plpgsql as $$
begin
  if current_setting('app.bypass_guard', true) = '1' or is_admin() then return new; end if;
  if new.video_id  is distinct from old.video_id
  or new.user_id   is distinct from old.user_id
  or new.parent_id is distinct from old.parent_id
  or new.status    is distinct from old.status
  or new.created_at is distinct from old.created_at then
    raise exception 'Apenas o texto do comentario pode ser editado.';
  end if;
  if new.body is distinct from old.body then new.edited_at = now(); end if;
  return new;
end $$;
create trigger comments_guard before update on comments
  for each row execute function comment_before_update();

-- 5. Contadores automaticos
create function bump_like_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.bypass_guard', '1', true);
  if tg_op = 'INSERT' then
    update videos set likes_count = likes_count + 1 where id = new.video_id;
  else
    update videos set likes_count = greatest(likes_count - 1, 0) where id = old.video_id;
  end if;
  perform set_config('app.bypass_guard', '0', true);
  return null;
end $$;
create trigger likes_count_trg after insert or delete on likes
  for each row execute function bump_like_count();

create function bump_comment_count() returns trigger
language plpgsql security definer set search_path = public as $$
declare delta int := 0; vid uuid;
begin
  if tg_op = 'INSERT' then
    vid := new.video_id; if new.status = 'visible' then delta := 1; end if;
  elsif tg_op = 'DELETE' then
    vid := old.video_id; if old.status = 'visible' then delta := -1; end if;
  else
    vid := new.video_id;
    if old.status <> 'visible' and new.status = 'visible' then delta := 1;
    elsif old.status = 'visible' and new.status <> 'visible' then delta := -1; end if;
  end if;
  if delta <> 0 then
    perform set_config('app.bypass_guard', '1', true);
    update videos set comments_count = greatest(comments_count + delta, 0) where id = vid;
    perform set_config('app.bypass_guard', '0', true);
  end if;
  return null;
end $$;
create trigger comments_count_trg after insert or update of status or delete on comments
  for each row execute function bump_comment_count();

-- 6. RLS
alter table followers enable row level security;
alter table likes     enable row level security;
alter table favorites enable row level security;
alter table comments  enable row level security;

create policy follow_read   on followers for select
  using (follower_id = auth.uid() or creator_id = auth.uid() or is_admin());
create policy follow_insert on followers for insert to authenticated
  with check (follower_id = auth.uid() and exists (select 1 from public_creators c where c.id = creator_id));
create policy follow_delete on followers for delete to authenticated using (follower_id = auth.uid());

create policy likes_read   on likes for select using (user_id = auth.uid() or is_admin());
create policy likes_insert on likes for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from videos v where v.id = video_id));
create policy likes_delete on likes for delete to authenticated using (user_id = auth.uid());

create policy fav_read   on favorites for select using (user_id = auth.uid() or is_admin());
create policy fav_insert on favorites for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from videos v where v.id = video_id));
create policy fav_delete on favorites for delete to authenticated using (user_id = auth.uid());

create policy comments_read on comments for select using (
  user_id = auth.uid() or is_admin()
  or (status = 'visible' and exists (select 1 from videos v where v.id = video_id)));
create policy comments_insert on comments for insert to authenticated with check (
  user_id = auth.uid() and status = 'visible'
  and exists (select 1 from videos v where v.id = video_id)
  and creator_is_active(auth.uid()));
create policy comments_update_own on comments for update to authenticated
  using (user_id = auth.uid() and status = 'visible') with check (user_id = auth.uid());
create policy comments_delete_own on comments for delete to authenticated using (user_id = auth.uid());
create policy comments_admin on comments for update using (is_admin()) with check (is_admin());

-- 7. Historico de visualizacao (o visualizador le e apaga o proprio)
create policy views_own_read   on video_views for select using (viewer_id = auth.uid());
create policy views_own_delete on video_views for delete to authenticated using (viewer_id = auth.uid());

create view my_watch_history with (security_invoker = true) as
  select video_id, max(created_at) as last_viewed_at
    from video_views
   where viewer_id = auth.uid()
   group by video_id;
grant select on my_watch_history to authenticated;

-- 8. Perfil publico do criador ganha os contadores prometidos na Etapa 3
create or replace view public_creators as
  select p.id, p.username, p.display_name, p.avatar_url, p.cover_url, p.bio, p.created_at,
         (select count(*) from followers f where f.creator_id = p.id) as followers_count,
         (select count(*) from videos v where v.creator_id = p.id and v.status = 'published') as videos_count
    from public_profiles p
   where p.account_type = 'creator';
grant select on public_creators to anon, authenticated;
