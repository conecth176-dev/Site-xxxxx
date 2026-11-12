-- =====================================================================
-- XXV | ETAPA 2: cadastro, login e tipo de conta (Supabase / PostgreSQL)
-- =====================================================================
-- COMO APLICAR
-- 1. Crie um projeto em supabase.com.
-- 2. Authentication > Providers: ative "Email" e "Google"
--    (crie as credenciais OAuth no Google Cloud Console e cole o Client ID/Secret).
-- 3. SQL Editor: cole e execute este arquivo inteiro.
-- 4. No Next.js, use apenas NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY
--    no navegador. A SERVICE_ROLE_KEY fica só no servidor (nunca no front-end).
-- NAO TESTADO: este script foi escrito mas ainda nao foi executado em um banco real.
-- =====================================================================

create type account_type  as enum ('creator', 'viewer');
create type age_status    as enum ('unverified', 'pending', 'verified', 'rejected');
create type account_state as enum ('active', 'suspended', 'blocked');

-- Administradores (painel da Etapa 8)
create table admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'admin' check (role in ('admin','moderator')),
  created_at timestamptz not null default now()
);

create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_users where user_id = auth.uid());
$$;

-- Perfil base de todo usuario
create table profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  username            text not null,
  display_name        text,
  avatar_url          text,
  cover_url           text,
  bio                 text check (char_length(bio) <= 500),
  account_type        account_type,                 -- null ate o usuario escolher
  account_type_locked boolean not null default false,
  age_status          age_status not null default 'unverified',
  age_verified_at     timestamptz,
  state               account_state not null default 'active',
  created_at          timestamptz not null default now(),
  constraint username_format check (username ~ '^[a-z0-9_]{3,20}$')
);
create unique index profiles_username_key on profiles (lower(username));

-- Dados extras so de criadores (verificacao de identidade exigida para video +18)
create table creator_profiles (
  profile_id       uuid primary key references profiles(id) on delete cascade,
  identity_status  age_status not null default 'unverified',
  identity_checked_at timestamptz,
  created_at       timestamptz not null default now()
);

-- Cria o perfil automaticamente quando alguem se cadastra (e-mail ou Google)
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    'user_' || substr(replace(new.id::text, '-', ''), 1, 10),
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Impede que o usuario altere campos sensiveis direto pela API
create function guard_profile_columns() returns trigger
language plpgsql as $$
begin
  if current_setting('app.bypass_guard', true) = '1'
     or coalesce(auth.role(), 'service_role') = 'service_role'
     or is_admin() then
    return new;
  end if;
  if new.id               is distinct from old.id
  or new.account_type     is distinct from old.account_type
  or new.account_type_locked is distinct from old.account_type_locked
  or new.age_status       is distinct from old.age_status
  or new.age_verified_at  is distinct from old.age_verified_at
  or new.state            is distinct from old.state then
    raise exception 'Campo protegido: nao pode ser alterado pelo usuario.';
  end if;
  return new;
end $$;

create trigger profiles_guard
  before update on profiles
  for each row execute function guard_profile_columns();

-- Primeira entrada: escolher nome de usuario e tipo de conta (uma unica vez)
create function complete_onboarding(p_username text, p_type account_type)
returns void language plpgsql security definer set search_path = public as $$
declare cur profiles;
begin
  if auth.uid() is null then raise exception 'Nao autenticado.'; end if;
  select * into cur from profiles where id = auth.uid() for update;
  if cur.account_type_locked then
    raise exception 'O tipo de conta ja foi escolhido. Mudancas passam pela moderacao.';
  end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles
     set username = lower(p_username), account_type = p_type, account_type_locked = true
   where id = auth.uid();
  if p_type = 'creator' then
    insert into creator_profiles (profile_id) values (auth.uid()) on conflict do nothing;
  end if;
end $$;

-- Seguranca em nivel de linha (RLS)
alter table admin_users      enable row level security;
alter table profiles         enable row level security;
alter table creator_profiles enable row level security;

create policy profiles_select_own   on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_update_own   on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy creator_select_own    on creator_profiles for select using (profile_id = auth.uid() or is_admin());
create policy admin_users_admin_only on admin_users for select using (is_admin());

-- Visao publica: so campos seguros e so contas ativas (nunca expoe age_status)
create view public_profiles as
  select id, username, display_name, avatar_url, cover_url, bio, account_type, created_at
    from profiles
   where state = 'active' and account_type is not null;
grant select on public_profiles to anon, authenticated;
