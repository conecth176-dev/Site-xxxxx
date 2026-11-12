-- =====================================================================
-- XXV | ETAPA 3: perfis de criadores e visualizadores
-- =====================================================================
-- Execute DEPOIS do arquivo da Etapa 2, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
-- Os contadores de seguidores e de videos do perfil publico dependem das
-- tabelas das Etapas 4 e 5 e serao adicionados la.
-- =====================================================================

-- Privacidade e preferencias (visiveis so para o dono da conta)
alter table profiles
  add column show_history    boolean not null default false,
  add column show_favorites  boolean not null default false,
  add column allow_messages_from text not null default 'followers'
         check (allow_messages_from in ('everyone','followers','nobody')),
  add column username_changed_at timestamptz;

-- Nomes de usuario reservados
create table reserved_usernames (name text primary key);
insert into reserved_usernames (name) values
  ('admin'),('administrador'),('suporte'),('support'),('xxv'),('moderacao'),
  ('api'),('login'),('cadastro'),('perfil'),('explorar'),('publicar');
alter table reserved_usernames enable row level security;

-- Consulta publica de disponibilidade (usada no formulario, em tempo real)
create function is_username_available(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_username ~ '^[a-z0-9_]{3,20}$'
     and not exists (select 1 from reserved_usernames where name = lower(p_username))
     and not exists (select 1 from profiles where lower(username) = lower(p_username));
$$;
grant execute on function is_username_available(text) to anon, authenticated;

-- Troca de nome de usuario: no maximo 1 vez a cada 30 dias
create function change_username(p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare cur profiles;
begin
  if auth.uid() is null then raise exception 'Nao autenticado.'; end if;
  select * into cur from profiles where id = auth.uid() for update;
  if cur.username_changed_at is not null
     and cur.username_changed_at > now() - interval '30 days' then
    raise exception 'O nome de usuario so pode ser trocado a cada 30 dias.';
  end if;
  if not is_username_available(p_username) then
    raise exception 'Nome de usuario indisponivel.';
  end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set username = lower(p_username), username_changed_at = now()
   where id = auth.uid();
end $$;

-- Guarda reforcada: username so muda pela funcao acima;
-- avatar e capa so podem apontar para a pasta do proprio usuario.
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

-- Armazenamento de imagens (limites e tipos validados no servidor)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', true, 2097152, array['image/jpeg','image/png','image/webp']),
  ('covers',  'covers',  true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- Cada usuario so escreve dentro da pasta com o proprio id: <bucket>/<user_id>/arquivo
create policy "imagens_leitura_publica" on storage.objects for select
  using (bucket_id in ('avatars','covers'));
create policy "imagens_upload_proprio" on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars','covers') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "imagens_update_proprio" on storage.objects for update to authenticated
  using (bucket_id in ('avatars','covers') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "imagens_delete_proprio" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars','covers') and (storage.foldername(name))[1] = auth.uid()::text);

-- Lista publica de criadores (a pagina /@usuario e as secoes da home usam isto)
create view public_creators as
  select id, username, display_name, avatar_url, cover_url, bio, created_at
    from public_profiles
   where account_type = 'creator';
grant select on public_creators to anon, authenticated;
