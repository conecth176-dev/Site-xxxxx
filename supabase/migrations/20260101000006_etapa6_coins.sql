-- =====================================================================
-- XXV | ETAPA 6: carteira XXV Coins
-- =====================================================================
-- Execute DEPOIS das Etapas 2 a 5, no SQL Editor do Supabase.
-- NAO TESTADO: escrito, mas ainda nao executado em um banco real.
--
-- PRINCIPIOS
-- * O saldo so muda por funcoes do banco, nunca por UPDATE direto.
-- * Todo movimento gera uma linha imutavel em coin_transactions (livro-razao).
-- * Credito de compra so ocorre pelo SERVIDOR (SERVICE_ROLE_KEY), depois de
--   validar a assinatura do webhook do provedor de pagamento.
-- * Webhook repetido nao credita duas vezes (trava de linha + chave unica).
-- * Moedas desbloqueiam apenas recursos NAO explicitos (ver coin_products).
-- =====================================================================

-- Regra de negocio: video +18 e sempre gratuito (moedas nao desbloqueiam conteudo explicito)
alter table videos add constraint adult_must_be_free
  check (not is_adult or (is_free and coin_price = 0));

-- 1. Tabelas
create table coin_wallets (
  user_id    uuid primary key references profiles(id) on delete cascade,
  balance    bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);
insert into coin_wallets (user_id) select id from profiles on conflict do nothing;

create function create_wallet() returns trigger
language plpgsql security definer set search_path = public as $$
begin insert into coin_wallets (user_id) values (new.id) on conflict do nothing; return new; end $$;
create trigger profiles_wallet after insert on profiles
  for each row execute function create_wallet();

create table coin_packages (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  coins       int  not null check (coins > 0),
  price_cents int  not null check (price_cents > 0),
  currency    text not null default 'BRL',
  active      boolean not null default true,
  sort_order  int not null default 0
);

-- Recursos que as moedas desbloqueiam. "kind" nao inclui conteudo explicito.
create table coin_products (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  description   text,
  kind          text not null check (kind in ('chat_feature','profile_cosmetic','badge','other')),
  price_coins   int  not null check (price_coins > 0),
  duration_days int  check (duration_days is null or duration_days > 0),
  active        boolean not null default true
);

create table user_entitlements (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  product_id uuid not null references coin_products(id),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create index entitlements_user_idx on user_entitlements (user_id, product_id);

create table payment_transactions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references profiles(id),
  package_id          uuid not null references coin_packages(id),
  coins               int  not null check (coins > 0),
  amount_cents        int  not null check (amount_cents > 0),
  currency            text not null default 'BRL',
  provider            text not null,
  provider_payment_id text,
  status              text not null default 'pending'
                      check (status in ('pending','paid','failed','refunded','chargeback')),
  shortfall_coins     int not null default 0,   -- moedas ja gastas quando houve estorno
  raw_event           jsonb,                    -- so administradores leem
  created_at          timestamptz not null default now(),
  paid_at             timestamptz
);
create unique index payment_provider_unique
  on payment_transactions (provider, provider_payment_id) where provider_payment_id is not null;
create index payment_user_idx on payment_transactions (user_id, created_at desc);

-- Antifraude basico: no maximo 10 pagamentos pendentes por usuario na ultima hora
create function payment_rate_limit() returns trigger language plpgsql as $$
begin
  if (select count(*) from payment_transactions
       where user_id = new.user_id and status = 'pending'
         and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Muitas tentativas de compra. Tente novamente mais tarde.';
  end if;
  return new;
end $$;
create trigger payment_limit before insert on payment_transactions
  for each row execute function payment_rate_limit();

-- Livro-razao: so insere, nunca altera nem apaga
create table coin_transactions (
  id              bigserial primary key,
  user_id         uuid not null references profiles(id),
  kind            text not null check (kind in ('purchase','spend','reversal','adjustment')),
  amount          bigint not null check (amount <> 0),
  balance_after   bigint not null check (balance_after >= 0),
  payment_id      uuid references payment_transactions(id),
  reference_type  text,
  reference_id    text,
  description     text,
  idempotency_key text not null unique,
  created_at      timestamptz not null default now(),
  check ((kind = 'purchase' and amount > 0)
      or (kind in ('spend','reversal') and amount < 0)
      or kind = 'adjustment')
);
create index coin_tx_user_idx on coin_transactions (user_id, created_at desc);

create function ledger_immutable() returns trigger language plpgsql as $$
begin raise exception 'O extrato de moedas nao pode ser alterado nem apagado.'; end $$;
create trigger coin_tx_no_change before update or delete on coin_transactions
  for each row execute function ledger_immutable();

-- 2. Funcao central: unico caminho para mexer no saldo
create function ledger_post(
  p_user uuid, p_kind text, p_amount bigint, p_key text, p_desc text,
  p_ref_type text default null, p_ref_id text default null, p_payment uuid default null
) returns boolean language plpgsql security definer set search_path = public as $$
declare w coin_wallets; nb bigint;
begin
  select * into w from coin_wallets where user_id = p_user for update;   -- trava a carteira
  if not found then raise exception 'Carteira nao encontrada.'; end if;
  if exists (select 1 from coin_transactions where idempotency_key = p_key) then
    return false;                                                         -- ja processado
  end if;
  nb := w.balance + p_amount;
  if nb < 0 then raise exception 'Saldo insuficiente.'; end if;
  update coin_wallets set balance = nb, updated_at = now() where user_id = p_user;
  insert into coin_transactions
    (user_id, kind, amount, balance_after, payment_id, reference_type, reference_id, description, idempotency_key)
  values (p_user, p_kind, p_amount, nb, p_payment, p_ref_type, p_ref_id, p_desc, p_key);
  return true;
end $$;

-- 3. Webhook (somente servidor): confirma pagamento e credita uma unica vez
create function confirm_payment(p_payment uuid, p_provider_payment_id text, p_amount_cents int)
returns boolean language plpgsql security definer set search_path = public as $$
declare pay payment_transactions;
begin
  select * into pay from payment_transactions where id = p_payment for update;
  if not found then raise exception 'Pagamento nao encontrado.'; end if;
  if pay.status = 'paid' then return false; end if;                       -- webhook repetido
  if pay.status <> 'pending' then raise exception 'Pagamento nao esta pendente.'; end if;
  if p_amount_cents <> pay.amount_cents then raise exception 'Valor pago diverge do pedido.'; end if;
  update payment_transactions
     set status = 'paid', paid_at = now(), provider_payment_id = p_provider_payment_id
   where id = p_payment;
  perform ledger_post(pay.user_id, 'purchase', pay.coins, 'payment:' || pay.id,
                      'Compra de ' || pay.coins || ' XXV Coins', 'payment', pay.id::text, pay.id);
  return true;
end $$;

-- Estorno ou chargeback (somente servidor): tira o que ainda houver de saldo e registra a diferenca
create function reverse_payment(p_payment uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare pay payment_transactions; bal bigint; take bigint;
begin
  if p_status not in ('refunded','chargeback') then raise exception 'Status invalido.'; end if;
  select * into pay from payment_transactions where id = p_payment for update;
  if not found or pay.status <> 'paid' then raise exception 'Pagamento nao esta pago.'; end if;
  select balance into bal from coin_wallets where user_id = pay.user_id;
  take := least(bal, pay.coins);
  if take > 0 then
    perform ledger_post(pay.user_id, 'reversal', -take, 'reversal:' || pay.id,
                        'Estorno da compra', 'payment', pay.id::text, pay.id);
  end if;
  update payment_transactions set status = p_status, shortfall_coins = pay.coins - take::int
   where id = p_payment;
end $$;

-- 4. Gastar moedas (usuario logado): so em produtos ativos; repetir a mesma chave nao cobra de novo
create function spend_coins(p_product uuid, p_key text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare prod coin_products; created boolean; exp timestamptz;
begin
  if auth.uid() is null then raise exception 'Nao autenticado.'; end if;
  if char_length(coalesce(p_key, '')) < 8 then raise exception 'Chave de operacao invalida.'; end if;
  if not creator_is_active(auth.uid()) then raise exception 'Conta indisponivel.'; end if;
  select * into prod from coin_products where id = p_product and active;
  if not found then raise exception 'Recurso indisponivel.'; end if;
  created := ledger_post(auth.uid(), 'spend', -prod.price_coins::bigint,
                         'spend:' || auth.uid() || ':' || p_key, prod.name, 'product', prod.id::text);
  if created then
    exp := case when prod.duration_days is null then null
                else now() + make_interval(days => prod.duration_days) end;
    insert into user_entitlements (user_id, product_id, expires_at) values (auth.uid(), prod.id, exp);
    return exp;
  end if;
  return (select expires_at from user_entitlements
           where user_id = auth.uid() and product_id = prod.id order by created_at desc limit 1);
end $$;

create function has_entitlement(p_slug text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_entitlements e join coin_products p on p.id = e.product_id
                  where e.user_id = auth.uid() and p.slug = p_slug
                    and (e.expires_at is null or e.expires_at > now()));
$$;

-- Auditoria: carteiras cujo saldo nao bate com a soma do extrato (deve retornar vazio)
create function audit_wallets() returns table (user_id uuid, balance bigint, ledger_sum bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not (is_admin() or coalesce(auth.role(), 'service_role') = 'service_role') then
    raise exception 'Acesso negado.';
  end if;
  return query
    select w.user_id, w.balance, coalesce(sum(t.amount), 0)::bigint
      from coin_wallets w left join coin_transactions t on t.user_id = w.user_id
     group by w.user_id, w.balance
    having w.balance <> coalesce(sum(t.amount), 0);
end $$;

-- 5. Permissoes das funcoes
revoke execute on function ledger_post(uuid,text,bigint,text,text,text,text,uuid) from public, anon, authenticated;
revoke execute on function confirm_payment(uuid,text,int)  from public, anon, authenticated;
revoke execute on function reverse_payment(uuid,text)      from public, anon, authenticated;
revoke execute on function spend_coins(uuid,text)          from public, anon;
revoke execute on function has_entitlement(text)           from public, anon;
grant  execute on function ledger_post(uuid,text,bigint,text,text,text,text,uuid) to service_role;
grant  execute on function confirm_payment(uuid,text,int)  to service_role;
grant  execute on function reverse_payment(uuid,text)      to service_role;
grant  execute on function spend_coins(uuid,text)          to authenticated;
grant  execute on function has_entitlement(text)           to authenticated;

-- 6. RLS: usuarios leem o que e seu; ninguem grava direto
alter table coin_wallets         enable row level security;
alter table coin_transactions    enable row level security;
alter table coin_packages        enable row level security;
alter table coin_products        enable row level security;
alter table user_entitlements    enable row level security;
alter table payment_transactions enable row level security;

create policy wallet_read  on coin_wallets      for select using (user_id = auth.uid() or is_admin());
create policy cointx_read  on coin_transactions for select using (user_id = auth.uid() or is_admin());
create policy ent_read     on user_entitlements for select using (user_id = auth.uid() or is_admin());
create policy pay_admin    on payment_transactions for select using (is_admin());   -- inclui raw_event
create policy pkg_read     on coin_packages for select using (active or is_admin());
create policy pkg_admin    on coin_packages for all using (is_admin()) with check (is_admin());
create policy prod_read    on coin_products for select using (active or is_admin());
create policy prod_admin   on coin_products for all using (is_admin()) with check (is_admin());

-- Compras do proprio usuario, sem o campo raw_event
create view my_payments as
  select id, package_id, coins, amount_cents, currency, status, created_at, paid_at
    from payment_transactions where user_id = auth.uid();
grant select on my_payments to authenticated;

-- Exemplo para testar (valores sao decisao de negocio; ajuste pelo painel na Etapa 8):
-- insert into coin_packages (name, coins, price_cents, sort_order) values ('Pacote inicial', 100, 1000, 1);
-- insert into coin_products (slug, name, kind, price_coins, duration_days)
--   values ('chat_premium_30d', 'Chat premium por 30 dias', 'chat_feature', 50, 30);
