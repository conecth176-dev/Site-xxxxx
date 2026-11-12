# XXV | Plataforma de Vídeos e Criadores (+18)

Site completo, interativo e pronto para publicação direta no **Netlify Drop** ou execução local no navegador.

---

## 🚀 Como subir no Netlify em 1 minuto (Sem terminal e Sem GitHub)

1. Acesse **[app.netlify.com/drop](https://app.netlify.com/drop)** no seu navegador.
2. Faça login na sua conta do Netlify (ou crie uma gratuita se não tiver).
3. **Arraste e solte esta pasta inteira** (`Site-xxxxx`) na área indicada pelo Netlify.
4. O Netlify fará o upload instantaneamente e gerará um link público ativo (ex: `https://xxv-plataforma-xxxx.netlify.app`).
5. Pronto! O site estará no ar com todas as telas e funcionalidades ativas.

---

## 🌟 O que está finalizado e funcionando

Todas as mensagens antigas de bloqueio (*"chega na Etapa 4"*, *"chega na Etapa 5"*) foram removidas e substituídas pelas telas completas e funcionais:

1. **Gate +18 (Verificação Obrigatória de Maioridade):**
   - Diálogo com aviso legal para maiores de 18 anos.
   - Botão para sair direto para o Google se menor.
   - Sessão segura registrada durante a navegação.

2. **Início (Home):**
   - Banner de destaque imersivo com chamadas para ação.
   - Filtros instantâneos por categoria (*Mulheres, Homens, Casais, Gays, Trans*).
   - Seção de vídeos em destaque.
   - Seção de vídeos +18 gratuitos com badge oficial.
   - Carrossel/grade de criadores populares com botão de seguir em tempo real.

3. **Explorar:**
   - Navegação por categorias completas.
   - Campo de busca em tempo real que filtra instantaneamente títulos e descrições.
   - Cards de vídeos com miniatura em alta qualidade, contagem de views, duração e avatar do criador.

4. **Player de Vídeo Completo:**
   - Reprodução de vídeo em tela cheia / modo imersivo com controles integrados.
   - Botão de **Curtir** com contador interativo sincronizado.
   - Botão de **Salvar nos Favoritos**.
   - Botão de **Gorjeta (XXV Coins)** para presentear criadores diretamente.
   - Botão de **Compartilhar** link.
   - Seção de **Comentários reais** (permite digitar e publicar comentários instantaneamente).
   - Lista lateral de vídeos recomendados (*A Seguir*).

5. **Área do Criador (Publicar Vídeo):**
   - Upload de arquivo de vídeo com zona de arrastar e soltar (drag & drop).
   - Definição de título, descrição, categoria e URL de capa/miniatura.
   - **Termo de Consentimento Legal e Verificação +18** (em conformidade com a Lei 15.211/2025 - ECA Digital).
   - Publicação instantânea que adiciona o vídeo ao catálogo do site.

6. **Mensagens / Chat:**
   - Interface completa de mensagens diretas com criadores de conteúdo.
   - Envio de mensagens em tempo real com respostas simuladas.
   - Opção de envio de gorjetas de moedas diretamente pelo chat.

7. **Carteira de Moedas (XXV Coins):**
   - Exibição do saldo atual de XXV Coins no cabeçalho e na barra lateral.
   - Catálogo de pacotes de moedas (100, 300, 750 e 2.000 Coins).
   - Modal com **Simulador de Pagamento PIX com QR Code**, aprovação instantânea e crédito imediato no saldo.
   - Extrato completo de movimentações (créditos, compras e gorjetas).

8. **Meu Perfil:**
   - Visualização do perfil com foto, capa personalizada, nome e handle (@).
   - Contador dinâmico de seguidores, seguindo e vídeos publicados.
   - Abas internas de navegação: *Meus Vídeos*, *Favoritos Salvos* e *Histórico de Visualização*.
   - Edição de perfil e logout.

9. **Autenticação (Login & Cadastro):**
   - Alternância entre Entrar e Cadastrar.
   - Escolha do tipo de perfil: *Espectador* ou *Criador (+18 Verificado)*.
   - Simulação de login com Google.
   - Atualização dinâmica da interface com a identidade do usuário.

10. **Painel Administrativo:**
    - Moderação de vídeos pendentes (aprovação e reprovação de publicações).
    - Gestão de status de criadores e conformidade legal.

---

## 🗄️ Integração com Supabase (Opcional)

Se você já criou o projeto no Supabase e rodou as migrações da pasta `supabase/migrations/`, o front-end já inclui o SDK oficial do Supabase (`@supabase/supabase-js`) pronto para sincronização com seu backend na nuvem.
