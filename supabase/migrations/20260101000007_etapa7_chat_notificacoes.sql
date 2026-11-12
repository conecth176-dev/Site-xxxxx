-- =====================================================================
-- XXV | ETAPA 7: chat e notificacoes
-- =====================================================================
-- Execute DEPOIS das Etapas 2 a 6, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- REGRAS DE SEGURANCA DESTE MODULO
-- * Conversar exige idade verificada dos DOIS lados.
-- * Ninguem escreve direto nas tabelas de mensagens: so pelas funcoes.
-- * Bloqueio vale nos dois sentidos e impede novas mensagens.
-- * A moderacao so le uma conversa se existir denuncia aberta sobre ela.
-- =====================================================================

-- 1. Tabelas
create table blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table conversations (
  id              uuid primary key default gen_random_uuid(),
  user_a          uuid not null references profiles(id) on delete cascade,
  user_b          uuid not null references profiles(id) on delete cascade,
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index conv_user_b_idx on conversations (user_b);

create table messages (
  id              bigserial primary key,
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id) on delete cascade,
  body            text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
create index messages_conv_idx on messages (conversation_id, created_at desc);
create index messages_unread_idx on messages (conversation_id) where read_at is null;

create table notifications (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references profiles(id) on delete cascade,
  type            text not null check (type in
                  ('new_follower','like','comment','reply','message','purchase','platform')),
  actor_id        uuid references profiles(id) on delete cascade,
  video_id        uuid references videos(id) on delete cascade,
  comment_id      uuid references comments(id) on delete cascade,
  conversation_id uuid references conversations(id) on delete cascade,
  data            jsonb,
  read_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index notif_user_idx on notifications (user_id, created_at desc);
create index notif_unread_idx on notifications (user_id) where read_at is null;

create table platform_announcements (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  body       text not null,
  created_by uuid references admin_users(user_id),
  created_at timestamptz not null default now()
);

-- 2. Funcoes auxiliares
create function users_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks
                  where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;

create function is_participant(p_conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversations
                  where id = p_conv and auth.uid() in (user_a, user_b));
$$;

create function moderator_can_read(p_conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() and exists (select 1 from reports
          where target_type = 'conversation' and target_id = p_conv
            and status in ('open','reviewing'));
$$;

-- Criacao de notificacoes (uso interno)
create function notify(
  p_user uuid, p_type text, p_actor uuid default null, p_video uuid default null,
  p_comment uuid default null, p_conv uuid default null, p_data jsonb default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_user = p_actor then return; end if;
  if p_actor is not null and exists (select 1 from blocks
        where blocker_id = p_user and blocked_id = p_actor) then return; end if;
  if p_type = 'message' and exists (select 1 from notifications
        where user_id = p_user and type = 'message' and conversation_id = p_conv and read_at is null) then return; end if;
  if p_type = 'like' and exists (select 1 from notifications
        where user_id = p_user and type = 'like' and actor_id = p_actor and video_id = p_video) then return; end if;
  insert into notifications (user_id, type, actor_id, video_id, comment_id, conversation_id, data)
  values (p_user, p_type, p_actor, p_video, p_comment, p_conv, p_data);
end $$;

-- 3. Conversas e mensagens
create function start_conversation(p_other uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pol text; a uuid; b uuid; cid uuid;
begin
  if me is null then raise exception 'Nao autenticado.'; end if;
  if me = p_other then raise exception 'Voce nao pode conversar consigo mesmo.'; end if;
  if not viewer_is_age_verified() then raise exception 'Verifique sua idade para usar o chat.'; end if;
  select allow_messages_from into pol from profiles
   where id = p_other and state = 'active' and age_status = 'verified';
  if not found or users_blocked(me, p_other) or pol = 'nobody' then
    raise exception 'Nao e possivel conversar com este usuario.';
  end if;
  if pol = 'followers' and not exists (select 1 from followers
        where follower_id = me and creator_id = p_other) then
    raise exception 'Este usuario so recebe mensagens de seguidores.';
  end if;
  a := least(me, p_other); b := greatest(me, p_other);
  insert into conversations (user_a, user_b) values (a, b) on conflict (user_a, user_b) do nothing;
  select id into cid from conversations where user_a = a and user_b = b;
  return cid;
end $$;

create function send_message(p_conversation uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c conversations; other uuid; mid bigint;
begin
  select * into c from conversations where id = p_conversation and me in (user_a, user_b);
  if not found then raise exception 'Conversa nao encontrada.'; end if;
  other := case when c.user_a = me then c.user_b else c.user_a end;
  if not viewer_is_age_verified() then raise exception 'Verifique sua idade para usar o chat.'; end if;
  if users_blocked(me, other) or not creator_is_active(other) then
    raise exception 'Nao e possivel enviar mensagem para este usuario.';
  end if;
  if (select count(*) from messages
       where sender_id = me and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Voce esta enviando mensagens rapido demais. Aguarde um instante.';
  end if;
  insert into messages (conversation_id, sender_id, body) values (p_conversation, me, btrim(p_body))
  returning id into mid;
  update conversations set last_message_at = now() where id = p_conversation;
  perform notify(other, 'message', me, null, null, p_conversation);
  return mid;
end $$;

create function mark_conversation_read(p_conversation uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_participant(p_conversation) then raise exception 'Conversa nao encontrada.'; end if;
  update messages set read_at = now()
   where conversation_id = p_conversation and sender_id <> auth.uid() and read_at is null;
  update notifications set read_at = now()
   where user_id = auth.uid() and type = 'message' and conversation_id = p_conversation and read_at is null;
end $$;

create function mark_notifications_read(p_ids uuid[] default null) returns void
language sql security definer set search_path = public as $$
  update notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
$$;

-- Lista de conversas com nao lidas (respeita a RLS de quem consulta)
create view my_conversations with (security_invoker = true) as
  select c.id, o.id as other_id, o.username, o.display_name, o.avatar_url, c.last_message_at,
         (select count(*) from messages m
           where m.conversation_id = c.id and m.sender_id <> auth.uid() and m.read_at is null) as unread_count
    from conversations c
    join public_profiles o on o.id = case when c.user_a = auth.uid() then c.user_b else c.user_a end
   where auth.uid() in (c.user_a, c.user_b);
grant select on my_conversations to authenticated;

-- 4. Bloqueio remove o vinculo de seguidor de quem foi bloqueado
create function after_block() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from followers where follower_id = new.blocked_id and creator_id = new.blocker_id;
  return null;
end $$;
create trigger blocks_cleanup after insert on blocks for each row execute function after_block();

-- Denuncia de conversa: so quem participa pode denunciar
create function report_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_type = 'conversation' and not exists (
       select 1 from conversations where id = new.target_id and new.reporter_id in (user_a, user_b)) then
    raise exception 'Voce so pode denunciar conversas das quais participa.';
  end if;
  return new;
end $$;
create trigger reports_conv_check before insert on reports for each row execute function report_check();

-- 5. Notificacoes automaticas
create function trg_notify_follow() returns trigger language plpgsql as $$
begin perform notify(new.creator_id, 'new_follower', new.follower_id); return null; end $$;
create trigger notify_follow after insert on followers for each row execute function trg_notify_follow();

create function trg_notify_like() returns trigger language plpgsql as $$
begin
  perform notify((select creator_id from videos where id = new.video_id), 'like', new.user_id, new.video_id);
  return null;
end $$;
create trigger notify_like after insert on likes for each row execute function trg_notify_like();

create function trg_notify_comment() returns trigger language plpgsql as $$
declare owner uuid; parent_author uuid;
begin
  select creator_id into owner from videos where id = new.video_id;
  if new.parent_id is null then
    perform notify(owner, 'comment', new.user_id, new.video_id, new.id);
  else
    select user_id into parent_author from comments where id = new.parent_id;
    perform notify(parent_author, 'reply', new.user_id, new.video_id, new.id);
    if owner is distinct from parent_author then
      perform notify(owner, 'comment', new.user_id, new.video_id, new.id);
    end if;
  end if;
  return null;
end $$;
create trigger notify_comment after insert on comments for each row execute function trg_notify_comment();

create function trg_notify_purchase() returns trigger language plpgsql as $$
begin
  if new.status = 'paid' and old.status <> 'paid' then
    perform notify(new.user_id, 'purchase', null, null, null, null, jsonb_build_object('coins', new.coins));
  end if;
  return null;
end $$;
create trigger notify_purchase after update of status on payment_transactions
  for each row execute function trg_notify_purchase();

-- 6. Permissoes das funcoes
revoke execute on function notify(uuid,text,uuid,uuid,uuid,uuid,jsonb) from public, anon, authenticated;
revoke execute on function start_conversation(uuid)         from public, anon;
revoke execute on function send_message(uuid,text)          from public, anon;
revoke execute on function mark_conversation_read(uuid)     from public, anon;
revoke execute on function mark_notifications_read(uuid[])  from public, anon;
grant  execute on function start_conversation(uuid)         to authenticated;
grant  execute on function send_message(uuid,text)          to authenticated;
grant  execute on function mark_conversation_read(uuid)     to authenticated;
grant  execute on function mark_notifications_read(uuid[])  to authenticated;

-- 7. RLS (sem politicas de INSERT/UPDATE em conversas, mensagens e notificacoes: so pelas funcoes)
alter table blocks                enable row level security;
alter table conversations         enable row level security;
alter table messages              enable row level security;
alter table notifications         enable row level security;
alter table platform_announcements enable row level security;

create policy blocks_read   on blocks for select using (blocker_id = auth.uid());
create policy blocks_insert on blocks for insert to authenticated with check (blocker_id = auth.uid());
create policy blocks_delete on blocks for delete to authenticated using (blocker_id = auth.uid());

create policy conv_read on conversations for select
  using (auth.uid() in (user_a, user_b) or moderator_can_read(id));
create policy msg_read on messages for select
  using (is_participant(conversation_id) or moderator_can_read(conversation_id));

create policy notif_read   on notifications for select using (user_id = auth.uid());
create policy notif_delete on notifications for delete to authenticated using (user_id = auth.uid());

create policy ann_read  on platform_announcements for select to authenticated using (true);
create policy ann_admin on platform_announcements for all using (is_admin()) with check (is_admin());

-- 8. Tempo real (o Supabase Realtime respeita as politicas acima)
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table notifications;
