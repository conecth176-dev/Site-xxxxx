-- =====================================================================
-- XXV | ETAPA 10: testes automatizados do banco
-- =====================================================================
-- COMO USAR
-- 1. Rode SOMENTE em um projeto Supabase de TESTE, com as Etapas 2 a 9 ja aplicadas.
--    Nunca em producao: o script cria usuarios, pagamentos e mensagens de mentira.
-- 2. Cole tudo no SQL Editor e execute uma vez.
-- 3. O resultado aparece como uma MENSAGEM DE ERRO, de proposito: ela desfaz tudo
--    e nada fica gravado. Ela diz "TODOS OS N TESTES PASSARAM" ou lista os que falharam.
-- 4. Se o editor reclamar de "current transaction is aborted", rode:  rollback;
--
-- LIMITES: este script NAO testa duas requisicoes simultaneas (concorrencia), nem o
-- Supabase Auth, nem o Storage, nem os webhooks do servidor. Veja o LEIA-ME_XXV.md.
-- NAO TESTADO ainda: escrito, mas nunca executado. Se algo der erro de sintaxe,
-- me envie a mensagem para corrigir.
-- =====================================================================
begin;

create schema xxv_test;
create table xxv_test.results (id serial primary key, name text not null, passed boolean not null);
grant usage on schema xxv_test to public;
grant all on all tables in schema xxv_test to public;
grant all on all sequences in schema xxv_test to public;

-- Entra como um usuario comum logado
create function xxv_test.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

-- Volta a ser o servidor (service_role)
create function xxv_test.as_service() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
end $$;

create function xxv_test.ok(cond boolean, test_name text) returns void language plpgsql as $$
begin
  insert into xxv_test.results (name, passed) values (test_name, coalesce(cond, false));
end $$;

-- Passa se o comando der erro
create function xxv_test.raises(sql_text text, test_name text) returns void language plpgsql as $$
begin
  begin
    execute sql_text;
  exception when others then
    insert into xxv_test.results (name, passed) values (test_name, true);
    return;
  end;
  insert into xxv_test.results (name, passed) values (test_name || ' (deveria ter dado erro)', false);
end $$;

do $$
declare
  a uuid := gen_random_uuid();   -- criador
  b uuid := gen_random_uuid();   -- visualizador
  c uuid := gen_random_uuid();   -- administrador
  d uuid := gen_random_uuid();   -- moderador
  e uuid := gen_random_uuid();   -- usuario sem idade verificada
  v_video uuid; v_comment uuid; v_reply uuid; v_pkg uuid; v_pay uuid;
  v_prod uuid; v_prod2 uuid; v_conv uuid;
  v_n bigint; v_text text; v_bool boolean; v_total int; v_fails int; v_list text;
begin
  ---------------------------------------------------------------- preparacao
  perform xxv_test.as_service();
  insert into auth.users (id, email, raw_user_meta_data, aud, role) values
    (a, 'a@teste.local', '{}', 'authenticated', 'authenticated'),
    (b, 'b@teste.local', '{}', 'authenticated', 'authenticated'),
    (c, 'c@teste.local', '{}', 'authenticated', 'authenticated'),
    (d, 'd@teste.local', '{}', 'authenticated', 'authenticated'),
    (e, 'e@teste.local', '{}', 'authenticated', 'authenticated');
  insert into admin_users (user_id, role) values (c, 'admin'), (d, 'moderator');

  ---------------------------------------------------------------- 2. cadastro e perfis
  select account_type::text into v_text from profiles where id = a;
  perform xxv_test.ok(v_text is null, 'cadastro cria perfil sem tipo de conta');
  select count(*) into v_n from coin_wallets where user_id = a;
  perform xxv_test.ok(v_n = 1, 'cadastro cria carteira de moedas');

  perform xxv_test.as_user(a);
  perform complete_onboarding('creator_a', 'creator');
  perform xxv_test.raises('select complete_onboarding(''outro_nome'', ''creator'')',
    'tipo de conta so pode ser escolhido uma vez');
  perform xxv_test.raises(format('update profiles set age_status = %L where id = %L', 'verified', a),
    'usuario nao altera a propria verificacao de idade');
  perform xxv_test.raises(format('update profiles set avatar_url = %L where id = %L',
    'https://x/storage/avatars/outro-usuario/a.png', a),
    'foto de perfil precisa estar na propria pasta');
  perform xxv_test.ok(not is_username_available('admin'), 'nome reservado indisponivel');
  perform xxv_test.ok(not is_username_available('AB'), 'nome de usuario invalido recusado');
  perform xxv_test.ok(not is_username_available('creator_a'), 'nome em uso indisponivel');
  perform xxv_test.ok(is_username_available('nome_livre'), 'nome livre disponivel');

  perform xxv_test.as_user(b);
  perform complete_onboarding('viewer_b', 'viewer');

  ---------------------------------------------------------------- 4. videos
  perform xxv_test.raises(format('insert into videos (creator_id, title) values (%L, %L)', b, 'Teste'),
    'visualizador nao cria video');

  perform xxv_test.as_user(a);
  insert into videos (creator_id, title, is_adult, category_id)
  values (a, 'Video de teste', true, 1) returning id into v_video;
  perform xxv_test.raises(format(
    'insert into videos (creator_id, title, status) values (%L, %L, %L)', a, 'Burlando', 'pending_review'),
    'criador nao cria video ja aprovado');
  perform xxv_test.raises(format(
    'insert into videos (creator_id, title, is_adult, is_free, coin_price) values (%L, %L, true, false, 10)',
    a, 'Pago +18'), 'video +18 nao pode ser pago');
  perform xxv_test.raises(format('update videos set likes_count = 999 where id = %L', v_video),
    'criador nao altera contador de curtidas');
  perform xxv_test.raises(format('update videos set status = %L where id = %L', 'published', v_video),
    'criador nao publica por conta propria');
  perform xxv_test.raises(format('select submit_video(%L)', v_video),
    'nao envia video ainda em processamento');

  perform xxv_test.as_service();
  update videos set processing_status = 'ready' where id = v_video;

  perform xxv_test.as_user(a);
  perform xxv_test.raises(format('select submit_video(%L)', v_video),
    'video +18 exige idade verificada do criador');

  perform xxv_test.as_service();
  update profiles set age_status = 'verified', age_verified_at = now(),
         age_verified_until = now() + interval '1 hour' where id = a;
  update creator_profiles set identity_status = 'verified' where profile_id = a;

  perform xxv_test.as_user(a);
  perform xxv_test.raises(format('select submit_video(%L)', v_video),
    'video +18 exige consentimento registrado');
  insert into video_consents (video_id, performer_name, document_path, consent_path)
  values (v_video, 'Pessoa de teste', a || '/doc.pdf', a || '/termo.pdf');
  select submit_video(v_video)::text into v_text;
  perform xxv_test.ok(v_text = 'pending_review', 'video +18 vai para moderacao previa');

  perform xxv_test.as_service();
  update profiles set age_status = 'verified', age_verified_at = now(),
         age_verified_until = now() + interval '1 hour' where id in (b, c, d);

  perform xxv_test.as_user(b);
  select count(*) into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 0, 'video pendente nao aparece para o publico');

  perform xxv_test.as_user(d);
  perform xxv_test.raises(format('select moderate_video(%L, false, %L)', v_video, ''),
    'rejeitar video exige motivo');
  perform xxv_test.as_user(c);
  perform moderate_video(v_video, true, null);

  perform xxv_test.as_user(b);
  select count(*) into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 1, 'video aprovado aparece para quem tem idade verificada');

  perform xxv_test.as_user(e);
  select count(*) into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 0, 'video +18 nao aparece sem idade verificada');

  perform xxv_test.as_service();
  update profiles set age_verified_until = now() - interval '1 minute' where id = b;
  perform xxv_test.as_user(b);
  select count(*) into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 0, 'video +18 some quando a janela de idade expira');

  perform xxv_test.as_service();
  update profiles set age_verified_until = now() + interval '1 hour' where id = b;

  ---------------------------------------------------------------- 5. social
  perform xxv_test.as_user(b);
  perform register_view(v_video);
  perform register_view(v_video);
  select views_count into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 1, 'visualizacao repetida na mesma hora conta uma vez');

  insert into likes (user_id, video_id) values (b, v_video);
  select likes_count into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 1, 'curtida aumenta o contador');
  perform xxv_test.raises(format('insert into likes (user_id, video_id) values (%L, %L)', b, v_video),
    'nao curte duas vezes');
  delete from likes where user_id = b and video_id = v_video;
  select likes_count into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 0, 'descurtir diminui o contador');

  insert into comments (video_id, user_id, body) values (v_video, b, 'Ola') returning id into v_comment;
  insert into comments (video_id, user_id, parent_id, body)
  values (v_video, b, v_comment, 'Resposta') returning id into v_reply;
  select comments_count into v_n from videos where id = v_video;
  perform xxv_test.ok(v_n = 2, 'comentario e resposta aumentam o contador');
  perform xxv_test.raises(format(
    'insert into comments (video_id, user_id, parent_id, body) values (%L, %L, %L, %L)',
    v_video, b, v_reply, 'Resposta da resposta'), 'resposta de resposta e recusada');

  insert into followers (follower_id, creator_id) values (b, a);
  select followers_count into v_n from public_creators where id = a;
  perform xxv_test.ok(v_n = 1, 'seguir aumenta a contagem do criador');
  perform xxv_test.as_user(a);
  perform xxv_test.raises(format('insert into followers (follower_id, creator_id) values (%L, %L)', a, a),
    'ninguem segue a si mesmo');
  select count(*) into v_n from notifications where user_id = a and type = 'new_follower';
  perform xxv_test.ok(v_n = 1, 'criador recebe notificacao de novo seguidor');

  ---------------------------------------------------------------- 6. moedas
  perform xxv_test.as_service();
  insert into coin_packages (name, coins, price_cents) values ('Teste', 100, 1000) returning id into v_pkg;
  insert into payment_transactions (user_id, package_id, coins, amount_cents, provider)
  values (b, v_pkg, 100, 1000, 'teste') returning id into v_pay;

  perform xxv_test.raises(format('select confirm_payment(%L, %L, 999)', v_pay, 'prov-1'),
    'pagamento com valor diferente e recusado');
  select confirm_payment(v_pay, 'prov-1', 1000) into v_bool;
  perform xxv_test.ok(v_bool, 'primeira confirmacao credita');
  select confirm_payment(v_pay, 'prov-1', 1000) into v_bool;
  perform xxv_test.ok(not v_bool, 'segunda confirmacao nao credita de novo');
  select balance into v_n from coin_wallets where user_id = b;
  perform xxv_test.ok(v_n = 100, 'saldo certo depois de confirmar duas vezes');
  select count(*) into v_n from coin_transactions where payment_id = v_pay;
  perform xxv_test.ok(v_n = 1, 'so uma linha no extrato para o pagamento');
  select count(*) into v_n from notifications where user_id = b and type = 'purchase';
  perform xxv_test.ok(v_n = 1, 'compra gera notificacao');

  insert into coin_products (slug, name, kind, price_coins, duration_days)
  values ('teste_chat', 'Chat de teste', 'chat_feature', 30, 30) returning id into v_prod;
  insert into coin_products (slug, name, kind, price_coins) values ('caro', 'Caro', 'other', 500)
  returning id into v_prod2;

  perform xxv_test.as_user(b);
  perform spend_coins(v_prod, 'chave-0001');
  perform spend_coins(v_prod, 'chave-0001');
  select balance into v_n from coin_wallets where user_id = b;
  perform xxv_test.ok(v_n = 70, 'mesma chave de operacao cobra uma vez so');
  perform xxv_test.ok(has_entitlement('teste_chat'), 'recurso comprado fica liberado');
  perform xxv_test.raises(format('select spend_coins(%L, %L)', v_prod2, 'chave-0002'),
    'gastar mais que o saldo e recusado');
  select balance into v_n from coin_wallets where user_id = b;
  perform xxv_test.ok(v_n = 70, 'saldo intacto apos gasto recusado');
  perform xxv_test.raises(format('select ledger_post(%L, %L, 1000, %L, %L)', b, 'purchase', 'hack-1', 'x'),
    'usuario comum nao chama a funcao do extrato');
  perform xxv_test.raises(format('select confirm_payment(%L, %L, 1000)', v_pay, 'x'),
    'usuario comum nao confirma pagamento');
  update coin_wallets set balance = 1000000 where user_id = b;

  perform xxv_test.as_service();
  select balance into v_n from coin_wallets where user_id = b;
  perform xxv_test.ok(v_n = 70, 'usuario nao altera o proprio saldo');
  perform xxv_test.raises(format('update coin_transactions set amount = amount where user_id = %L', b),
    'extrato nao pode ser alterado');
  perform xxv_test.raises(format('delete from coin_transactions where user_id = %L', b),
    'extrato nao pode ser apagado');

  perform reverse_payment(v_pay, 'refunded');
  select balance into v_n from coin_wallets where user_id = b;
  perform xxv_test.ok(v_n = 0, 'estorno retira o saldo restante');
  select shortfall_coins into v_n from payment_transactions where id = v_pay;
  perform xxv_test.ok(v_n = 30, 'estorno registra as moedas ja gastas');
  select count(*) into v_n from audit_wallets();
  perform xxv_test.ok(v_n = 0, 'auditoria: saldo bate com o extrato em todas as carteiras');

  ---------------------------------------------------------------- 7. chat
  perform xxv_test.as_service();
  update profiles set age_verified_until = now() + interval '1 hour' where id in (a, b);

  perform xxv_test.as_user(a);
  update profiles set allow_messages_from = 'nobody' where id = a;
  perform xxv_test.as_user(b);
  perform xxv_test.raises(format('select start_conversation(%L)', a),
    'destinatario com "ninguem" nao recebe conversa nova');
  perform xxv_test.as_user(a);
  update profiles set allow_messages_from = 'followers' where id = a;
  perform xxv_test.as_user(e);
  perform xxv_test.raises(format('select start_conversation(%L)', a),
    'chat exige idade verificada');

  perform xxv_test.as_user(b);
  select start_conversation(a) into v_conv;
  perform send_message(v_conv, 'Ola!');
  perform xxv_test.as_user(a);
  select unread_count into v_n from my_conversations where id = v_conv;
  perform xxv_test.ok(v_n = 1, 'conversa mostra 1 mensagem nao lida');
  select count(*) into v_n from notifications
   where user_id = a and type = 'message' and read_at is null;
  perform xxv_test.ok(v_n = 1, 'mensagem gera notificacao');
  perform mark_conversation_read(v_conv);
  select unread_count into v_n from my_conversations where id = v_conv;
  perform xxv_test.ok(v_n = 0, 'marcar como lida zera o contador');

  perform xxv_test.as_user(d);
  select count(*) into v_n from messages where conversation_id = v_conv;
  perform xxv_test.ok(v_n = 0, 'moderador nao le conversa sem denuncia');
  perform xxv_test.raises(format(
    'insert into reports (reporter_id, target_type, target_id, reason) values (%L, %L, %L, %L)',
    d, 'conversation', v_conv, 'outro'), 'so participante denuncia a conversa');
  perform xxv_test.as_user(b);
  insert into reports (reporter_id, target_type, target_id, reason)
  values (b, 'conversation', v_conv, 'outro');
  perform xxv_test.as_user(d);
  select count(*) into v_n from messages where conversation_id = v_conv;
  perform xxv_test.ok(v_n = 1, 'moderador le a conversa depois de denuncia aberta');

  perform xxv_test.as_user(a);
  insert into blocks (blocker_id, blocked_id) values (a, b);
  perform xxv_test.as_user(b);
  perform xxv_test.raises(format('select send_message(%L, %L)', v_conv, 'Ainda aqui'),
    'bloqueado nao envia mensagem');
  perform xxv_test.as_service();
  select count(*) into v_n from followers where follower_id = b and creator_id = a;
  perform xxv_test.ok(v_n = 0, 'bloqueio desfaz o vinculo de seguidor');

  ---------------------------------------------------------------- 8. administracao
  perform xxv_test.as_user(b);
  perform xxv_test.raises('select admin_dashboard()', 'usuario comum nao abre o painel');
  perform xxv_test.as_user(d);
  select admin_dashboard() ? 'revenue_cents_30d' into v_bool;
  perform xxv_test.ok(not v_bool, 'moderador nao ve o faturamento');
  perform xxv_test.raises('select admin_financial_summary(30)', 'moderador nao abre o financeiro');
  select count(*) into v_n from payment_transactions;
  perform xxv_test.ok(v_n = 0, 'moderador nao le pagamentos');
  perform admin_set_user_state(e, 'suspended', 'teste de moderacao');
  perform xxv_test.raises(format('select admin_set_user_state(%L, %L, %L)', e, 'blocked', 'x'),
    'moderador nao bloqueia conta');
  perform xxv_test.raises(format('select admin_set_user_state(%L, %L, %L)', c, 'suspended', 'x'),
    'moderador nao suspende administrador');

  perform xxv_test.as_user(c);
  select (admin_dashboard()->>'users_total')::int >= 5 into v_bool;
  perform xxv_test.ok(v_bool, 'administrador ve o resumo geral');
  select count(*) into v_n from payment_transactions;
  perform xxv_test.ok(v_n >= 1, 'administrador le pagamentos');
  select count(*) into v_n from admin_logs;
  perform xxv_test.ok(v_n >= 1, 'acoes administrativas ficam registradas');

  ---------------------------------------------------------------- 9. LGPD
  perform xxv_test.as_user(b);
  perform xxv_test.ok((export_my_data()->'perfil') is not null, 'usuario exporta os proprios dados');
  perform request_account_deletion();
  perform xxv_test.as_service();
  update deletion_requests set scheduled_for = now() - interval '1 day' where user_id = b;
  select count(*) into v_n from process_account_deletions() where deleted_user = b;
  perform xxv_test.ok(v_n = 1, 'rotina processa a exclusao vencida');
  select left(username, 9) = 'removido_' into v_bool from profiles where id = b;
  perform xxv_test.ok(v_bool, 'perfil excluido fica anonimizado');
  select body = '[comentario removido]' into v_bool from comments where id = v_comment;
  perform xxv_test.ok(v_bool, 'comentarios do excluido ficam sem texto');
  select count(*) into v_n from payment_transactions where user_id = b;
  perform xxv_test.ok(v_n = 1, 'compras sao mantidas apos a exclusao');

  ---------------------------------------------------------------- resultado
  perform xxv_test.as_service();
  select count(*), count(*) filter (where not passed),
         string_agg(name, '; ') filter (where not passed)
    into v_total, v_fails, v_list from xxv_test.results;
  if v_fails = 0 then
    raise exception 'TODOS OS % TESTES PASSARAM. (Esta mensagem aparece como erro de proposito: desfaz tudo e nada fica gravado.)', v_total;
  else
    raise exception '% DE % TESTES FALHARAM: %', v_fails, v_total, v_list;
  end if;
end $$;

rollback;
