<p align="right">
  <a href="README.md">🇺🇸 English</a> &nbsp;|&nbsp; 🇧🇷 Português
</p>

<p align="center">
  <img src="docs/images/koha-logo-green.png" alt="Logotipo do Koha" width="320">
</p>

# Koha Easy Installer & Manager

Um único script Bash que instala, ajusta e mantém o **[Koha](https://koha-community.org/), sistema integrado de gestão de bibliotecas**, no Debian/Ubuntu, por meio de um painel de controle com menus (whiptail, tema escuro) disponível em **22 idiomas**.

Nasceu da experiência real com as barreiras técnicas da gestão de acervos e foi pensado para bibliotecas sem orçamento para sistemas comerciais caros ou suporte técnico dedicado.

---

## Recursos

- **Instalação em um passo** do Koha, MariaDB, Apache, Memcached e Plack, com pré-validação do servidor (sistema, disco, rede, portas ocupadas), SWAP de 4 GB, NTP e escolha do fuso horário.
- **Central de backup**: backup SQL compactado diário, exportação MARC21 semanal, backup manual com instruções de download, teste de restauração em banco temporário e cópia na nuvem para o Google Drive (rclone).
- **Restauração segura** de backups `.sql` / `.sql.gz`: o arquivo é verificado (teste do gzip, mysqldump completo, tabelas do Koha) e importado antes em um banco temporário; o catálogo atual só é substituído depois de existir uma cópia de segurança verificada, volta automaticamente se algo falhar, e a restauração não fica pela metade por causa de um CTRL+C ou de uma queda da conexão SSH.
- **Motor de busca**: troca entre Zebra e Elasticsearch 7, vigia (watchdog) do indexador e ferramentas de reparo/reconstrução.
- **Publicação na internet**: Túnel Cloudflare (sem abrir portas), certificado SSL gratuito (Certbot) e assistente do Google Search Console.
- **Endereço gratuito (em teste)**: um endereço público para o catálogo sem comprar domínio nem abrir conta no Cloudflare. A biblioteca envia um pedido curto pelo painel e, quando o serviço de endereços aprova, o servidor se conecta sozinho. O link pode ser compartilhado como QR code na tela, imagem de QR code para imprimir ou link. O acesso remoto da equipe acrescenta uma senha verificada no Cloudflare antes do login do próprio Koha. O serviço de endereços ainda está em teste e não está aberto às bibliotecas.
- **Autorização por QR code**: quando o Cloudflare ou o Google Drive pedem para autorizar o servidor, o painel deixa você escolher como abrir a página. O Cloudflare oferece um QR code para ler com o celular, o navegador deste computador (o navegador do Windows no WSL) ou um link para copiar. O Google Drive oferece o navegador ou o link: o Google só volta ao computador que executa o rclone, então o celular não conclui esse login, e em um servidor sem tela o painel explica o túnel SSH. O token do Google nunca aparece na tela.
- **Diagnóstico**: verificação completa com relatório detalhado, status do servidor, logs do Apache em tempo real e manutenção profunda do banco.
- **Segurança**: Fail2ban, firewall UFW (com opção de restringir a porta 8080 do Staff) e troca da senha do banco de dados.
- **Configurações do Koha**: perfis de dimensionamento, avisos por e-mail (agenda do próprio Koha, ativada com `koha-email-enable`), criação de superbibliotecário, SIP2 e Z39.50, relógio e fuso horário.
- **Ferramentas da biblioteca**: importação MARC guiada com opção de desfazer, pacote de relatórios SQL essenciais, importação de leitores por CSV e virada do ano letivo (troca de categorias), verificação da qualidade do catálogo e rotinas de privacidade (LGPD). Toda alteração mostra antes uma prévia com a simulação do próprio Koha e é protegida por um backup verificado (veja [Ferramentas da biblioteca](#ferramentas-da-biblioteca)).
- **Brasil: localização e migração** (opcional, nunca aplicado pela instalação nem por agendamento): migração MARC do Biblivre, SophiA e Pergamum (conversão para UTF-8, exemplares levados para o 952 do Koha), planilhas do acervo (Biblioteca Fácil), planilhas de leitores do sistema antigo com verificação do CPF, auditoria de CPF (módulo 11), modelos de etiquetas Pimaco, ficha catalográfica e feriados brasileiros no calendário do Koha (veja [Brasil: localização e migração](#brasil-localização-e-migração)).
- **Mensagens: WhatsApp e Telegram** (opcional): os próprios avisos do Koha (empréstimo, devolução, atraso, vencimento, reserva) entregues por um gateway de WhatsApp próprio (Evolution API ou similar) ou por um bot do Telegram, com os números dos leitores completados e corrigidos no caminho (veja [Mensagens](#mensagens-whatsapp-e-telegram)).
- **Auxílio à catalogação**: notação de autor com a tabela PHA ou Cutter-Sanborn carregada pela biblioteca, consulta à CDD e uma página da interface da equipe que substitui um registro pelo biblionumber sem mexer nos exemplares (veja [Auxílio à catalogação](#auxílio-à-catalogação-pha-cutter-sanborn-cdd) e [Substituir um registro MARC](#substituir-um-registro-marc-interface-da-equipe)).
- **Windows 10/11 (WSL 2)**: o Koha em um único computador com Windows, com atalhos Iniciar/Parar que usam o ícone oficial do Koha, ícone de status, notificações do Windows, diagnóstico com um clique e vigia do disco (veja [Windows (WSL 2)](#windows-wsl-2)).
- **Idiomas**: instala os pacotes de idioma do Koha e traduz o próprio painel (22 idiomas).
- **Autoatualização** pelo GitHub com verificação SHA-256.

## Requisitos

| Item | Mínimo |
|------|--------|
| Sistema operacional | Debian 11/12/13 ou Ubuntu 22.04/24.04, 64 bits (amd64 ou arm64, ex.: Oracle Ampere, AWS Graviton, Raspberry Pi 4/5), ou Windows 10/11 pelo WSL 2 (veja [Windows](#windows-wsl-2)) |
| RAM | 2 GB (recomendado 4 GB ou mais; o Elasticsearch precisa de ~1,5 GB a mais) |
| Disco livre | 5 GB (recomendado 10 GB ou mais) |
| Acesso | `root` ou usuário com `sudo` |
| Rede | Acesso à internet para `debian.koha-community.org` |
| Portas | 80 (OPAC) e 8080 (interface do Staff) livres |

## Instalação

```bash
wget https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer
sudo bash installer
```

Ou clone o repositório (assim os arquivos de tradução ficam ao lado do script e funcionam sem internet):

```bash
git clone https://github.com/PauloFBaldiFH/Koha-Easy-Installer.git
cd Koha-Easy-Installer
sudo bash installer
```

Na primeira execução você escolhe o idioma do painel. Depois selecione **1 – Instalar servidor Koha** e siga o assistente (10 a 30 minutos).

Após a instalação, o painel fica disponível em qualquer lugar com:

```bash
sudo config.sh
```

### Depois de instalar

1. Abra a interface do Staff em `http://IP-DO-SERVIDOR:8080`.
2. Entre com o usuário e a senha do banco de dados mostrados no fim da instalação (também salvos em `/root/koha_credentials.txt`) e conclua o **Web Installer** do Koha.
3. De volta ao painel, crie seu próprio superbibliotecário (**9 – Configurações do Koha > Criar superbibliotecário**).
4. O catálogo público (OPAC) fica em `http://IP-DO-SERVIDOR:80`.

## Windows (WSL 2)

O Koha também pode rodar em um único computador com Windows 10 ou 11. É o caso de bibliotecas pequenas com um só balcão, de treinamentos da equipe e de avaliações. Bibliotecas com vários balcões devem continuar com um servidor Linux dedicado.

O Koha roda dentro de um sistema Debian no **WSL 2** (Subsistema do Windows para Linux), administrado pelo mesmo painel. Pequenas ferramentas em **PowerShell** permitem controlá-lo pelo Windows, sem abrir um terminal.

### O que já funciona no Windows

- **Modo WSL no painel**: o WSL 2 é detectado automaticamente. O WSL 1 é recusado, com explicação.
  - As tarefas do computador ficam com o Windows: sem swapfile, NTP, UFW, Fail2ban ou avahi. O fuso horário segue o do Windows.
  - "Reiniciar servidor" vira **Reiniciar os serviços do Koha**.
  - O systemd precisa estar ativado no WSL.
  - O lado Windows conversa com o painel pelo arquivo `/etc/koha-easy-install/windows.conf`. Ele é lido com uma lista fechada de chaves e nunca é executado.
- **Rede**: no Windows 11, a rede espelhada (mirrored) do WSL deixa os outros computadores da rede acessarem o Koha. No Windows 10 (NAT), use o **Túnel Cloudflare** do painel para publicá-lo.
- **Ícone e atalhos do Koha**: uma pasta *Koha* no menu Iniciar, com os links da interface da equipe e do catálogo também na área de trabalho, todos com o ícone oficial `koha.ico`. Ela traz:
  - Interface da equipe, Catálogo público, Painel de controle e Pasta de backups
  - **Iniciar**, **Parar** e **Reiniciar**
  - Status, Exportar diagnóstico e Ícone de status
- **Iniciar e parar**: o Koha pode iniciar sozinho quando você entra no Windows ou só quando você clica em *Koha - Iniciar*. Isso pode ser trocado a qualquer momento pelo menu do ícone. Depois de **Parar**, o Koha fica desligado até você iniciá-lo de novo, e nada o liga sem você saber.
- **Ícone de status (área de notificação)**: o ícone do Koha com um ponto colorido (verde funcionando, amarelo iniciando, vermelho sem resposta, cinza parado). O menu abre a interface da equipe e o catálogo, inicia, para e reinicia o Koha e exporta o diagnóstico.
- **Notificações do Windows**:
  - o Koha para de responder, para sem aviso ou volta a funcionar
  - o backup noturno é concluído (dá para desligar esse aviso), falha ou não roda há 36 horas
  - o espaço em disco fica baixo
- **Diagnóstico com um clique**: um `.zip` na área de trabalho com os logs do WSL, do Windows, do Apache, do MariaDB, do Koha e do painel, além do status do sistema, pronto para enviar a quem dá suporte à biblioteca. Senhas, tokens e chaves são removidos, e nenhum arquivo de configuração entra.
- **Vigia do disco**: avisa quando a unidade que guarda o disco virtual do Koha (`ext4.vhdx`) tem menos de 10 GB livres, e em nível crítico abaixo de 5 GB. Quando o disco virtual tem muito espaço sem uso, **Compactar** devolve esse espaço ao Windows (pede permissão de administrador).
- **Idiomas**: as ferramentas do Windows usam os 22 idiomas do painel.

### Como instalar no Windows

**Opção 1, um comando.** Abra o **PowerShell** (menu Iniciar, digite *PowerShell*; não precisa ser como administrador) e cole:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1 | iex
```

**Opção 2, dois cliques.** Baixe o ZIP do repositório (**Code > Download ZIP**), extraia e dê dois cliques em **`Install Koha.cmd`**. Se o Windows mostrar "O Windows protegeu o computador", clique em **Mais informações > Executar assim mesmo**: o script não é assinado, e você pode lê-lo antes de executar.

O instalador faz todo o resto e mostra cada etapa em linguagem simples:

1. Verifica o computador: Windows 10 versão 2004 ou mais recente, ou Windows 11; 64 bits; pelo menos 4 GB de memória (8 GB recomendados); pelo menos 10 GB livres no C:; virtualização ativada na BIOS.
2. Instala o WSL 2. O Windows pede permissão uma vez. Se o Windows precisar reiniciar, o instalador continua sozinho quando você entrar de novo.
3. Baixa o Debian da lista oficial do WSL da Microsoft, confere o SHA-256 e o importa como `KohaEasy` em `C:\KohaEasy\wsl`.
4. Ativa o systemd. No Windows 11 22H2 ou mais recente, também acrescenta a rede espelhada (mirrored) ao seu `.wslconfig`, mantendo as suas configurações e uma cópia de segurança.
5. Abre o painel de controle do Koha. Escolha o idioma, depois **1 – Instalar servidor Koha**, e saia do painel com **Sair** quando terminar.
6. Pergunta se o Koha deve iniciar quando você entrar no Windows. Depois cria os atalhos e o ícone de status, inicia o Koha e abre a interface da equipe.

Pode rodar de novo sem medo: ele continua da última etapa concluída. O usuário e a senha de primeiro acesso ficam no painel de controle, opção 2. Tudo fica em `C:\KohaEasy`, e o log do instalador em `C:\KohaEasy\logs`.

O comportamento em um Windows real (o instalador, notificações, ícone de status, Agendador de Tarefas e compactação do disco) ainda está sendo conferido em computadores físicos, então avise se algo parecer estranho.

## Menu principal

| # | Opção | O que faz |
|---|-------|-----------|
| 1 | Instalar servidor Koha | Instalação e ajuste completos |
| 2 | Ver credenciais de primeiro acesso | Endereços, usuário e senha |
| 3 | Restaurar banco de dados | Importa um backup `.sql` / `.sql.gz` |
| 4 | Central de backup | Backup manual, backup na nuvem, teste de integridade |
| 5 | Motor de busca e indexação | Zebra ⇄ Elasticsearch, reparo de índices |
| 6 | Publicar o sistema na internet | Túnel Cloudflare, SSL, Google Search Console |
| 7 | Diagnóstico e manutenção | Status, verificação, logs, otimização |
| 8 | Central de segurança | Fail2ban, firewall, troca de senha |
| 9 | Configurações e parâmetros do Koha | Dimensionamento, e-mail, superbibliotecário, SIP2/Z39.50, relógio |
| 10 | Ferramentas da biblioteca | Importação MARC e desfazer, relatórios SQL, importação de leitores, virada do ano letivo, qualidade do catálogo, privacidade (LGPD), Brasil: localização e migração, mensagens por WhatsApp / Telegram, auxílio à catalogação, substituir um registro MARC |
| 11 | Ferramentas gerais | htop/nethogs, navegador de terminal, gerenciador de arquivos |
| 12 | Agendamentos e tarefas (cron) | Ver, entender, regenerar ou editar as tarefas automáticas |
| 13 | Idiomas do Koha e do painel | Pacotes de idioma do Koha e idioma do painel |
| 14 | Central de atualizações | Atualizações do sistema/Koha e do painel |
| 15 | Sobre | Informações do projeto e apoio |
| 16 | Reiniciar servidor | |
| 17 | Sair | |

As janelas usam um tema escuro, largura fixa e se adaptam a terminais pequenos. Para as cores padrão do newt em um terminal monocromático, abra o painel com `NO_COLOR=1`.

## Ferramentas da biblioteca

Tarefas do dia a dia da equipe da biblioteca, feitas com as próprias ferramentas de linha de comando do Koha, como o usuário da instância (`koha-shell library -c ...`). Tudo o que altera dados segue os mesmos passos: a trava de backup/restauração (nenhum backup noturno ou restauração roda no meio), uma **prévia** (a simulação do próprio Koha), uma confirmação explícita, um **backup `PRE-*` verificado** em `/var/backups/koha_sql` e só então a execução real. As ferramentas nunca param os serviços do Koha, e o backup `PRE-*` desfaz qualquer alteração (**Restaurar banco de dados**).

| Ferramenta | Scripts do Koha | Prévia | Backup |
|------------|-----------------|--------|--------|
| Importar registros MARC (ISO 2709 / MARCXML), mantendo ou substituindo os registros já existentes | `stage_file.pl`, `commit_file.pl` | Relatório da preparação (nada entra no catálogo) | `PRE-IMPORT` |
| Desfazer uma importação MARC | `commit_file.pl --revert` | Registros e exemplares do lote | `PRE-UNDO-IMPORT` |
| Pacote de relatórios SQL essenciais: 8 relatórios somente leitura (mais emprestados, atrasos com contato, nunca emprestados, aquisições recentes, cadastros a vencer, empréstimos por mês, exemplares sem código de barras/número de chamada, perdidos), marcados para que atualizar ou remover o pacote nunca mexa em outros relatórios | — (`saved_sql`) | Cada consulta é testada nesta versão do Koha | `PRE-REPORTS` |
| Importar leitores de um CSV (modelo em `/root/koha_patrons_template.csv`; UTF-8, vírgulas) | `import_patrons.pl` | Simulação nativa: novos, atualizados, ignorados, inválidos | `PRE-PATRONS` |
| Virada do ano letivo: mover leitores entre categorias (todos, acima da idade da categoria ou cadastrados antes de uma data) | `update_patrons_category.pl` | Simulação nativa com a lista de leitores | `PRE-PATRONS` |
| Verificação da qualidade do catálogo (somente leitura) | `search_for_data_inconsistencies.pl` | — | — |
| Privacidade (LGPD): anonimizar o histórico antigo de empréstimos e reservas | `batch_anonymise.pl` | Contagens calculadas como o Koha faz | `PRE-PRIVACY` |
| Privacidade (LGPD): excluir leitores expirados que não pegaram nada desde então (confirmação digitada) | `delete_patrons.pl` | Simulação nativa | `PRE-PRIVACY` |

Cada execução fica registrada em `/var/log/koha-easy-install/tools/` (só o root lê: os logs podem ter nomes de leitores), que também podem ser vistos pelo menu.

### Brasil: localização e migração

**Ferramentas da biblioteca > Brasil: localização e migração**. Nada aqui é aplicado durante a instalação nem por agendamento: cada opção só age quando você a escolhe, segue os mesmos passos das outras ferramentas (trava, prévia, confirmação, backup `PRE-*` verificado) e pode ser desfeita.

| Ferramenta | Como funciona | Prévia | Backup |
|------------|---------------|--------|--------|
| Migrar MARC do Biblivre, SophiA, Pergamum ou de outro sistema (mapa de campos digitado) | Os caracteres são convertidos para UTF-8 com o `yaz-marcdump` (de Latin-1 ou MARC-8; o pacote `yaz` é oferecido se faltar); o campo de exemplar (Biblivre 949, Pergamum 852, SophiA 990 ou o seu próprio mapa) vai para o 952 do Koha (código de barras, número de chamada, exemplar, notas, biblioteca, tipo de material) com o MARC::Record do próprio Koha; depois vem a importação MARC normal (`stage_file.pl` / `commit_file.pl`, desfazer com `--revert`) | Contagens e uma amostra dos exemplares convertidos, depois o relatório de preparação do Koha | `PRE-IMPORT` |
| Importar leitores de uma planilha do sistema antigo | Encontra as colunas pelo nome em português ou inglês (Nome, Matrícula, CPF, E-mail, Nascimento...), Windows-1252 ou UTF-8, `;` ou `,`; verifica o CPF (módulo 11, dígitos repetidos, duplicados), usa o CPF como número do cartão quando não há um e o guarda em um atributo de leitor com código `CPF` quando esse tipo existe; depois roda o `import_patrons.pl` | Linhas rejeitadas com o motivo, depois a simulação do Koha | `PRE-PATRONS` |
| Migrar uma planilha do acervo (Biblioteca Fácil e outros programas que exportam o acervo para Excel / CSV) | Colunas encontradas pelos nomes usuais (Tombo, Título, Autor, Editora, Ano, ISBN, CDD, Cutter, Assunto, Exemplar, Tipo, Data de aquisição, Valor...), Windows-1252 ou UTF-8; linhas com o mesmo título, autor, edição, ano e ISBN viram um registro MARC 21 (montado com o MARC::Record) com um exemplar no 952 por linha (tombo como código de barras, CDD + Cutter como número de chamada, tipo de material pelo código ou pela descrição); códigos de barras repetidos são descartados; depois vem a importação MARC normal (desfazer com `--revert`) | Colunas usadas e ignoradas, contagens e uma amostra dos registros, depois o relatório de preparação do Koha | `PRE-IMPORT` |
| Verificar CPFs dos leitores (somente leitura) | Número do cartão, usuário, sort1/sort2 ou o atributo `CPF`: válidos, inválidos, compartilhados por dois leitores | — | — |
| Modelos de etiquetas Pimaco | Folhas 6180, 6181, 6287 (Carta) e A4256, A4251 (A4) mais 3 leiautes (lombada, código de barras, título e código de barras) no criador de etiquetas do Koha; atualiza ou remove só os próprios modelos | Resumo antes da alteração | `PRE-LABELS` |
| Ficha catalográfica | Folhas de estilo que envolvem a visualização de detalhes padrão do Koha (OPAC e interface da equipe, uma por idioma instalado) e acrescentam a ficha abaixo do registro, com botão de impressão; configuradas em `OPACXSLTDetailsDisplay` / `XSLTDetailsDisplay`. Os valores anteriores são guardados e **Ocultar a ficha** os devolve; os arquivos são regravados sempre que o painel abre, acompanhando as atualizações do Koha | Valores antigos e novos | `PRE-FICHA` |
| Feriados brasileiros no calendário | Feriados nacionais de um ano, Carnaval (segunda e terça), Sexta-feira Santa e Corpus Christi (Páscoa pelo algoritmo de Meeus/Jones/Butcher) e um feriado municipal opcional, para uma biblioteca ou todas; os dias que já estão no calendário são ignorados e **Remover** tira só os dias adicionados pelo painel | Datas com o dia da semana | `PRE-CALENDAR` |

- As medidas das etiquetas são as equivalentes Avery de cada folha Pimaco: faça um teste de impressão em papel comum e ajuste o modelo no Koha se a impressora deslocar a página.
- A ficha segue o leiaute AACR2 usado nas bibliotecas brasileiras (coluna do número de chamada, recuo francês, assuntos numerados, entradas secundárias em algarismos romanos).
- As predefinições do Biblivre, SophiA e Pergamum seguem o leiaute de exportação mais comum desses sistemas. A prévia mostra o resultado antes de qualquer gravação; **Outro formato** aceita qualquer campo de exemplar.
- Carnaval e Corpus Christi são ponto facultativo, não feriados nacionais: remova-os em Ferramentas > Calendário se a biblioteca abrir. O Dia da Consciência Negra (20/11) entra a partir de 2024.
- A predefinição do Biblioteca Fácil lê uma planilha exportada; ela foi escrita a partir dos nomes de coluna usuais, não de uma exportação real desse programa. A prévia lista as colunas usadas e as ignoradas antes de qualquer gravação.

### Mensagens: WhatsApp e Telegram

**Ferramentas da biblioteca > Mensagens: WhatsApp e Telegram**. O Koha já escreve os avisos (empréstimo, devolução, atraso, vencimento, reserva) e entrega os do tipo SMS ao driver SMS::Send indicado na preferência `SMSSendDriver`. O painel instala um driver assim (`SMS::Send::KohaEasy::Gateway`): cada aviso vai pelo Telegram quando o leitor vinculou o bot da biblioteca, senão pelo WhatsApp. Nada muda no Koha até **Enviar os avisos do Koha** ser ligado, e desligar devolve o `SMSSendDriver` anterior (backup `PRE-MESSAGING` verificado nos dois sentidos).

| Opção | O que faz |
|-------|-----------|
| Gateway de WhatsApp | Um gateway próprio da biblioteca: Evolution API v2 (`POST /message/sendText/<instância>`, cabeçalho `apikey`) ou outro que aceite `{"number", "to", "text"}` com token Bearer |
| Bot do Telegram | O token do @BotFather é verificado com o Telegram (`getMe`). Os leitores abrem o bot, tocam em Iniciar e compartilham o próprio contato; uma tarefa a cada dois minutos vincula a conversa ao número (`/stop` desfaz) |
| Código do país e DDD | Os números são completados e corrigidos antes do envio: código do país (Brasil por padrão, ou qualquer outro), DDD para números sem ele, prefixos de operadora e o 0 retirados, e o 9º dígito dos celulares brasileiros acrescentado |
| Enviar uma mensagem de teste | Pelo mesmo caminho SMS::Send que o Koha usa, como o usuário da instância |
| O que o Koha precisa | Verifica o `SMSSendDriver`, as versões SMS dos avisos, as regras de atraso com SMS e os leitores com número e preferências de SMS; oferece criar versões SMS curtas dos avisos que não têm (`PRE-NOTICES`) |
| Verificar os telefones dos leitores | Relatório somente de leitura com as mesmas regras; os números corrigidos só são gravados após confirmação (`PRE-PHONES`) |

As configurações (com os tokens) ficam em `/etc/koha/sites/library/kei-messaging.conf`, legível só pelo root e pelo Koha. Com os avisos ligados, a fila de SMS também é enviada a cada dois minutos (`/etc/cron.d/koha_messaging`).

### Auxílio à catalogação: PHA, Cutter-Sanborn, CDD

**Ferramentas da biblioteca > Auxílio à catalogação**, somente leitura para o catálogo.

- **Notação de autor**: a entrada imediatamente anterior ao nome na tabela, a inicial do sobrenome, o número e a inicial do título (o artigo inicial nunca conta, e título começando com "l" leva L maiúsculo); prefixos lidos como uma só palavra (La Fonte, O'Donnel) e M' / Mc como Mac; instituições pela primeira palavra e obras anônimas pela primeira palavra do título, como na explicação da tabela PHA. A partir de um registro do catálogo, lê o 100 / 110 / 111, o 245 (com o indicador de caracteres a desprezar) e o 082, e lista os números de chamada que já usam o mesmo número naquela classe, com os números livres imediatamente antes e depois.
- **As tabelas não são distribuídas com o painel**: a Tabela PHA (Heloísa de Almeida Prado, T. A. Queiroz) e as tabelas Cutter-Sanborn têm direitos autorais. Cada biblioteca carrega o próprio exemplar como arquivo de texto (uma entrada e o número por linha; as linhas da PHA podem ser digitadas como estão impressas, entrada - número - entrada). O arquivo é conferido antes de ser guardado: entradas por letra, números fora de ordem (erros de digitação) e entradas repetidas.
- **CDD**: as dez classes principais vêm embutidas; a biblioteca pode carregar a própria tabela (número e descrição por linha) para pesquisar por número ou por palavra, e toda consulta mostra também como o catálogo já usa o número.

### Substituir um registro MARC (interface da equipe)

**Ferramentas da biblioteca > Substituir um registro MARC** instala o `marc_replace.pl` na interface da equipe do Koha (`/cgi-bin/koha/tools/marc_replace.pl`, e se quiser no menu Editar de cada registro). Ele substitui um registro, encontrado pelo biblionumber, por um arquivo `.mrc` ou `.xml` ou por texto colado (linhas da Biblioteca Nacional `245 10 |a`, do MarcEdit ou do yaz-marcdump):

- login com a permissão `edit_catalogue` e token CSRF (operações `cud-` do Koha 24.05+);
- primeiro uma prévia; depois, numa única transação, o registro atual é travado e comparado com a prévia (nada é substituído se ele mudou), guardado em MARCXML em `/var/lib/koha/library/kei-marc-replace/` (pode ser baixado pela página e reenviado para desfazer) e substituído com o `ModBiblio` do Koha;
- os campos de exemplar do arquivo são sempre deixados de fora: os exemplares nunca são tocados;
- arquivos em MARC-8 / Latin-1 são convertidos pelo `MarcToUTF8Record` do próprio Koha.

A página é verificada com os módulos Perl do Koha antes de ser instalada; removê-la mantém as versões guardadas.

#### Catalogação com IA (fotos do livro)

Mais duas abas da mesma página catalogam um livro a partir de fotos da capa, da folha de rosto e do verso da folha de rosto (com a ficha catalográfica):

- **Configuração da IA** (só para quem pode alterar as preferências do sistema): o modelo de visão, seja uma API na nuvem com token (OpenAI, Anthropic ou qualquer serviço compatível com a OpenAI), seja um modelo na própria rede da biblioteca (Ollama `http://localhost:11434` ou LM Studio `http://localhost:1234/v1` com um modelo de visão como `qwen2.5vl`, `llama3.2-vision` ou `gemma3`). A configuração fica em `kei-marc-replace/vision.conf`, legível só pelo usuário da instância do Koha; o token nunca volta a ser exibido e é recusado em `http` simples para um servidor fora da rede local. **Testar a conexão** lista os modelos do servidor. Nenhum token vem com o painel.
- **Catalogação com IA**: as fotos vão para o modelo, que responde com os dados bibliográficos em JSON (conferidos contra um esquema fixo: nada inventado, marcadores vazios descartados). Em seguida as regras nacionais são aplicadas por `KohaEasy::Cataloguing::Rules`: pontuação AACR2 e ISBD (245 `:` `/`, 260 com `[S.l.]` / `[s.n.]`, 300), nomes invertidos como na catalogação brasileira (`Assis, Machado de`, `Andrade Filho, José de`), caracteres a desconsiderar do 245, dígito verificador do ISBN (os errados vão para o 020 `$z`), a CDD impressa na ficha catalográfica (senão a sugestão do modelo, marcada para conferência) no 082 e 090, e a **notação de autor da tabela PHA ou Cutter-Sanborn da própria biblioteca**, calculada por uma versão em Perl do algoritmo do painel, de modo que a página e o **Auxílio à catalogação** dão a mesma notação.
- O bibliotecário corrige o rascunho ao lado das fotos e segue uma **prévia obrigatória**. Só então o registro é incluído com o `AddBiblio` do Koha, numa única transação sob uma trava do banco, depois de conferir de novo o ISBN no catálogo (um registro com o mesmo ISBN exige marcar uma caixa), com uma cópia do registro e da resposta do modelo guardada em `kei-marc-replace/vision/`. Um formulário enviado duas vezes não inclui nada. Com um biblionumber, o rascunho vai para a substituição acima (com a trava e a versão guardada dela).

Os dois módulos são instalados com a página em `/usr/local/lib/site_perl/KohaEasy/Cataloguing/` e removidos com ela (a configuração fica junto das versões guardadas).

## Tarefas automáticas

Instaladas em `/etc/cron.d/koha_tasks`:

| Quando | Tarefa |
|--------|--------|
| Diariamente 23:00 | Backup SQL compactado (verificado, envio opcional para a nuvem) |
| Domingos 03:00 | Exportação MARC21 dos registros bibliográficos e de autoridade |
| Diariamente 01:30 | Limpeza de sessões e da fila do Zebra (`cleanup_database.pl --confirm`) |
| Diariamente 05:00 | Reinício do Plack (mantém a memória baixa) |
| A cada 2 min | Vigia da indexação do Zebra: mantém o daemon indexador do Koha (`koha-indexer`) no ar e o reinicia se registros esperarem mais de 10 min |
| A cada 5 min (só Elasticsearch) | Vigia do indexador do Elasticsearch |

Os avisos por e-mail ficam com a agenda do próprio Koha (`koha-common`): avisos de atraso e de vencimento uma vez por dia e a fila de mensagens a cada 15 minutos, para a instância ativada com `koha-email-enable` (feito na instalação e em **Configurações do Koha > Configurar e-mail**). Agendamentos gravados por versões antigas do painel são atualizados sozinhos: a limpeza das 01:30 ganha o `--confirm` (sem ele, só informava o que apagaria) e as antigas tarefas de e-mail das 08:00/08:05, que duplicavam as do Koha, são removidas assim que o e-mail é ativado.

## Arquivos importantes

| Caminho | Conteúdo |
|---------|----------|
| `/root/koha_credentials.txt` | Credenciais de primeiro acesso |
| `/etc/koha/sites/library/koha-conf.xml` | Configuração da instância do Koha |
| `/var/backups/koha_sql`, `/var/backups/koha_marc` | Backups locais |
| `/etc/koha-easy-install/` | Configurações do painel (idioma, backup) |
| `/var/log/koha-easy-install/` | Logs do painel, do APT e das validações (`tools/`: ferramentas da biblioteca, só root) |
| `/root/koha_patrons_template.csv` | Modelo CSV vazio para a importação de leitores |
| `/var/lib/koha/library/kei-xslt/` | Folhas de estilo da ficha catalográfica (só enquanto a ficha estiver ativada) |
| `/etc/koha/sites/library/kei-messaging.conf` | Configurações e tokens de WhatsApp / Telegram (só root e Koha) |
| `/usr/local/lib/site_perl/SMS/Send/KohaEasy/Gateway.pm` | O driver de mensagens do Koha (com `KohaEasy/Messaging.pm`) |
| `/etc/koha-easy-install/tables/` | Tabelas de autor e tabela da CDD carregadas pela biblioteca |
| `/var/lib/koha/library/kei-marc-replace/` | Registros como estavam antes de cada substituição |
| `/etc/koha-easy-install/windows.conf` | Só no Windows: o que as ferramentas do Windows informam ao painel (modo de rede, início automático...) |
| `C:\KohaEasy\` | Só no Windows: `bin\` (scripts e `koha.ico`), `logs\`, `Backups\`, `state.json` |

Se a instalação parar, o painel mostra a etapa que falhou. A saída completa do gerenciador de pacotes fica em `/var/log/koha-easy-install/apt.log`.

## Desinstalação

O `uninstall.sh` **apaga definitivamente** o Koha, seus bancos de dados, os backups locais e as configurações, e pede confirmação antes:

```bash
sudo bash uninstall.sh          # pede para digitar APAGAR
sudo bash uninstall.sh --yes    # sem perguntas (automação)
```

Copie seus backups para outro lugar antes de executá-lo.

## Testes

A pasta `tests/` tem uma bateria [bats-core](https://github.com/bats-core/bats-core) que executa o painel contra um MariaDB real: backups corrompidos, truncados e vazios, MariaDB parado ou recusando o login, disco cheio ou sem permissão de escrita, CTRL+C / queda do SSH no meio da restauração, travas compartilhadas com os backups noturnos, indexação depois de trocar o motor de busca e de restaurar, versões do Debian/Ubuntu em amd64/arm64, as ferramentas da biblioteca (simulação antes de qualquer alteração, trava, backup verificado, aspas do `koha-shell`), as ferramentas do Brasil (migração MARC em Latin-1 para o 952, dígitos verificadores do CPF, feriados móveis, modelos de etiquetas, ficha catalográfica, planilhas do acervo), o driver de mensagens (contra um dublê de WhatsApp / Telegram), a notação de autor e a consulta à CDD, o `marc_replace.pl` (executado como CGI), a atualização dos agendamentos, o modo WSL, a autorização por QR code / navegador / link e as ferramentas do Windows (os testes em PowerShell rodam com o [Pester 5](https://pester.dev) quando o `pwsh` está instalado).

```bash
sudo apt-get install bats mariadb-server memcached whiptail yaz xsltproc python3 \
     libmarc-record-perl libmarc-xml-perl libsms-send-perl libcgi-pm-perl libmodern-perl-perl
sudo KEI_TEST_SANDBOX=1 tests/run.sh
```

**Somente em um contêiner ou VM descartável:** os testes substituem o banco `koha_library` e instalam dublês de teste para as ferramentas `koha-*` e o `systemctl`. O `tests/run.sh` se recusa a rodar ao lado de um Koha real.

## Traduções

Os textos do painel ficam em inglês dentro do `installer`; cada idioma tem um dicionário em `lang/<código>.cache` (`base64(inglês)|base64(tradução)`). O painel em si é Bash puro; os scripts Python abaixo são ferramentas opcionais para quem contribui.

- Envolva todo texto visível em `$(t "...")`. As variáveis devem ser escapadas para que o texto em inglês chegue intacto ao `t()`: `$(t "Backup saved in \${file}")`.
- Verificar a cobertura e reparar os dicionários: `python3 i18n_common.py` / `python3 i18n_common.py --fix`
- Traduzir só o que falta: `python3 gen_all_langs.py` (offline, Argos Translate) ou `python3 gen_lang.py` (online).
- Traduções que perdem uma variável ou `%s` são rejeitadas automaticamente e o texto em inglês é exibido.

Depois de mudar o `PANEL_VERSION`, rode `python3 i18n_common.py --fix` (cada dicionário leva a versão do painel, e dicionários desatualizados só são usados em último caso).

Depois de alterar o `installer`, gere de novo o checksum usado pela autoatualização:

```bash
sha256sum installer > installer.sha256
```

## Licença

O Koha Easy Installer & Manager é software livre sob a [Licença Pública Geral GNU v3.0 ou posterior](LICENSE) (GPL-3.0-or-later), a mesma licença do Koha. Você pode usar, estudar, compartilhar e modificar; se distribuir versões modificadas, elas devem continuar sob a GPL e com o código-fonte disponível. É fornecido **sem garantia**.

## Apoie o projeto

- Pix: `076.650.449.21`
- Bitcoin (BTC): `bc1qw0kvacdkzul0panuppxcv90y08ah443m2z89tx`
- ⭐ Dê uma estrela ao repositório e compartilhe com outras bibliotecas.

---

Criado com dedicação por **Paulo F. Baldi FH** — Auxiliar de Biblioteca, Biblioteca Pública Castro Alves, Palotina, Paraná, Brasil.

<sub>O nome e o logotipo do Koha pertencem à comunidade Koha (koha-community.org); este instalador é um projeto independente.</sub>
