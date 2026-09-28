<p align="right">
  <a href="README.md">🇺🇸 English</a> &nbsp;|&nbsp; 🇧🇷 Português
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
- **Diagnóstico**: verificação completa com relatório detalhado, status do servidor, logs do Apache em tempo real e manutenção profunda do banco.
- **Segurança**: Fail2ban, firewall UFW (com opção de restringir a porta 8080 do Staff) e troca da senha do banco de dados.
- **Configurações do Koha**: perfis de dimensionamento, avisos por e-mail (agenda do próprio Koha, ativada com `koha-email-enable`), criação de superbibliotecário, SIP2 e Z39.50, relógio e fuso horário.
- **Ferramentas da biblioteca**: importação MARC guiada com opção de desfazer, pacote de relatórios SQL essenciais, importação de leitores por CSV e virada do ano letivo (troca de categorias), verificação da qualidade do catálogo e rotinas de privacidade (LGPD). Toda alteração mostra antes uma prévia com a simulação do próprio Koha e é protegida por um backup verificado (veja [Ferramentas da biblioteca](#ferramentas-da-biblioteca)).
- **Idiomas**: instala os pacotes de idioma do Koha e traduz o próprio painel (22 idiomas).
- **Autoatualização** pelo GitHub com verificação SHA-256.

## Requisitos

| Item | Mínimo |
|------|--------|
| Sistema operacional | Debian 11/12/13 ou Ubuntu 22.04/24.04, 64 bits (amd64 ou arm64, ex.: Oracle Ampere, AWS Graviton, Raspberry Pi 4/5) |
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
| 10 | Ferramentas da biblioteca | Importação MARC e desfazer, relatórios SQL, importação de leitores, virada do ano letivo, qualidade do catálogo, privacidade (LGPD) |
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

Se a instalação parar, o painel mostra a etapa que falhou. A saída completa do gerenciador de pacotes fica em `/var/log/koha-easy-install/apt.log`.

## Desinstalação

O `uninstall.sh` **apaga definitivamente** o Koha, seus bancos de dados, os backups locais e as configurações, e pede confirmação antes:

```bash
sudo bash uninstall.sh          # pede para digitar APAGAR
sudo bash uninstall.sh --yes    # sem perguntas (automação)
```

Copie seus backups para outro lugar antes de executá-lo.

## Testes (para quem contribui)

A pasta `tests/` tem uma bateria [bats-core](https://github.com/bats-core/bats-core) que executa o painel contra um MariaDB real: backups corrompidos, truncados e vazios, MariaDB parado ou recusando o login, disco cheio ou sem permissão de escrita, CTRL+C / queda do SSH no meio da restauração, travas compartilhadas com os backups noturnos, indexação depois de trocar o motor de busca e de restaurar, versões do Debian/Ubuntu em amd64/arm64, as ferramentas da biblioteca (simulação antes de qualquer alteração, trava, backup verificado, aspas do `koha-shell`) e a atualização dos agendamentos.

```bash
sudo apt-get install bats mariadb-server memcached whiptail
sudo KEI_TEST_SANDBOX=1 tests/run.sh
```

**Somente em um contêiner ou VM descartável:** os testes substituem o banco `koha_library` e instalam dublês de teste para as ferramentas `koha-*` e o `systemctl`. O `tests/run.sh` se recusa a rodar ao lado de um Koha real.

## Traduções (para quem contribui)

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
