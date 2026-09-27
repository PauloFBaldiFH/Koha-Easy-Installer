<p align="right">
  <a href="README.md">🇺🇸 English</a> &nbsp;|&nbsp; 🇧🇷 Português
</p>

# Koha Easy Installer & Manager

Um único script Bash que instala, ajusta e mantém o **[Koha](https://koha-community.org/), sistema integrado de gestão de bibliotecas**, no Debian/Ubuntu, por meio de um painel de controle com menus (whiptail) disponível em **22 idiomas**.

Nasceu da experiência real com as barreiras técnicas da gestão de acervos e foi pensado para bibliotecas sem orçamento para sistemas comerciais caros ou suporte técnico dedicado.

---

## Recursos

- **Instalação em um passo** do Koha, MariaDB, Apache, Memcached e Plack, com pré-validação do servidor (sistema, disco, rede, portas ocupadas), SWAP de 4 GB, NTP e escolha do fuso horário.
- **Central de backup**: backup SQL compactado diário, exportação MARC21 semanal, backup manual com instruções de download, teste de restauração em banco temporário e cópia na nuvem para o Google Drive (rclone).
- **Restauração segura** de backups `.sql` / `.sql.gz`, com cópia de segurança do banco atual antes, atualização do esquema e reindexação.
- **Motor de busca**: troca entre Zebra e Elasticsearch 7, vigia (watchdog) do indexador e ferramentas de reparo/reconstrução.
- **Publicação na internet**: Túnel Cloudflare (sem abrir portas), certificado SSL gratuito (Certbot) e assistente do Google Search Console.
- **Diagnóstico**: verificação completa com relatório detalhado, status do servidor, logs do Apache em tempo real e manutenção profunda do banco.
- **Segurança**: Fail2ban, firewall UFW (com opção de restringir a porta 8080 do Staff) e troca da senha do banco de dados.
- **Configurações do Koha**: perfis de dimensionamento, e-mail/avisos de atraso, criação de superbibliotecário, SIP2 e Z39.50, relógio e fuso horário.
- **Idiomas**: instala os pacotes de idioma do Koha e traduz o próprio painel (22 idiomas).
- **Autoatualização** pelo GitHub com verificação SHA-256.

## Requisitos

| Item | Mínimo |
|------|--------|
| Sistema operacional | Debian 11/12 ou Ubuntu 22.04/24.04 (64 bits) |
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
2. Entre com o usuário e a senha do banco de dados mostrados no fim da instalação (também salvos em `/root/credenciais_koha.txt`) e conclua o **Web Installer** do Koha.
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
| 10 | Ferramentas gerais | htop/nethogs, navegador de terminal, gerenciador de arquivos |
| 11 | Agendamentos e tarefas (cron) | Ver, entender, regenerar ou editar as tarefas automáticas |
| 12 | Idiomas do Koha e do painel | Pacotes de idioma do Koha e idioma do painel |
| 13 | Central de atualizações | Atualizações do sistema/Koha e do painel |
| 14 | Sobre | Informações do projeto e apoio |
| 15 | Reiniciar servidor | |
| 16 | Sair | |

## Tarefas automáticas

Instaladas em `/etc/cron.d/koha_tasks`:

| Quando | Tarefa |
|--------|--------|
| Diariamente 23:00 | Backup SQL compactado (verificado, envio opcional para a nuvem) |
| Domingos 03:00 | Exportação MARC21 dos registros bibliográficos e de autoridade |
| Diariamente 01:30 | Limpeza de sessões e do banco |
| Diariamente 05:00 | Reinício do Plack (mantém a memória baixa) |
| Diariamente 08:00 / 08:05 | Avisos de atraso e fila de e-mails |
| A cada 2 min | Indexação incremental do Zebra |

## Arquivos importantes

| Caminho | Conteúdo |
|---------|----------|
| `/root/credenciais_koha.txt` | Credenciais de primeiro acesso |
| `/etc/koha/sites/library/koha-conf.xml` | Configuração da instância do Koha |
| `/var/backups/koha_sql`, `/var/backups/koha_marc` | Backups locais |
| `/etc/koha-easy-install/` | Configurações do painel (idioma, backup) |
| `/var/log/koha-easy-install/` | Logs do painel, do APT e das validações |

Se a instalação parar, o painel mostra a etapa que falhou. A saída completa do gerenciador de pacotes fica em `/var/log/koha-easy-install/apt.log`.

## Desinstalação

O `uninstall.sh` **apaga definitivamente** o Koha, seus bancos de dados, os backups locais e as configurações, e pede confirmação antes:

```bash
sudo bash uninstall.sh          # pede para digitar APAGAR
sudo bash uninstall.sh --yes    # sem perguntas (automação)
```

Copie seus backups para outro lugar antes de executá-lo.

## Traduções (para quem contribui)

Os textos do painel ficam em inglês dentro do `installer`; cada idioma tem um dicionário em `lang/<código>.cache` (`base64(inglês)|base64(tradução)`).

- Envolva todo texto visível em `$(t "...")`. As variáveis devem ser escapadas para que o texto em inglês chegue intacto ao `t()`: `$(t "Backup saved in \${file}")`.
- Verificar a cobertura e reparar os dicionários: `python3 i18n_common.py` / `python3 i18n_common.py --fix`
- Traduzir só o que falta: `python3 gen_all_langs.py` (offline, Argos Translate) ou `python3 gen_lang.py` (online).
- Traduções que perdem uma variável ou `%s` são rejeitadas automaticamente e o texto em inglês é exibido.

Depois de mudar o `PANEL_VERSION`, rode `python3 i18n_common.py --fix` (cada dicionário leva a versão do painel, e dicionários desatualizados só são usados em último caso).

Depois de alterar o `installer`, gere de novo o checksum usado pela autoatualização:

```bash
sha256sum installer > installer.sha256
```

## Apoie o projeto

- Pix: `076.650.449.21`
- Bitcoin (BTC): `bc1qw0kvacdkzul0panuppxcv90y08ah443m2z89tx`
- ⭐ Dê uma estrela ao repositório e compartilhe com outras bibliotecas.

---

Criado com dedicação por **Paulo F. Baldi FH** — Auxiliar de Biblioteca, Biblioteca Pública Castro Alves, Palotina, Paraná, Brasil.
