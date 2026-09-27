#!/usr/bin/env bash
# ======================================================================
# KOHA EASY INSTALLER & MANAGER - DEEP CLEANUP & UNINSTALL
# Remove completamente instâncias, serviços, bancos, daemons e resíduos.
#
# Uso:  sudo ./uninstall.sh          (pede confirmação)
#       sudo ./uninstall.sh --yes    (sem perguntas, para automação)
# ======================================================================

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
[ "${EUID:-$(id -u)}" -ne 0 ] && { echo "Execute como root (sudo ./uninstall.sh)"; exit 1; }

ASSUME_YES="no"
case "${1:-}" in
    -y|--yes) ASSUME_YES="yes" ;;
    "") ;;
    *) echo "Uso: sudo $0 [--yes]"; exit 1 ;;
esac

if [ "$ASSUME_YES" != "yes" ]; then
    echo "======================================================================"
    echo " ATENÇÃO: esta operação APAGA DEFINITIVAMENTE o Koha deste servidor:"
    echo "  - todas as instâncias e bancos de dados koha_* (catálogo, leitores...)"
    echo "  - os backups locais em /var/backups/koha_sql e /var/backups/koha_marc"
    echo "  - configurações, credenciais, túnel Cloudflare e tarefas agendadas"
    echo ""
    echo " Se quiser guardar os dados, copie os backups para outro lugar ANTES."
    echo "======================================================================"
    printf 'Digite APAGAR para continuar (qualquer outra coisa cancela): '
    read -r answer < /dev/tty || answer=""
    if [ "$answer" != "APAGAR" ]; then
        echo "Cancelado. Nada foi alterado."
        exit 0
    fi
fi

# Espera o APT/dpkg terminar em vez de matá-lo (matar o dpkg no meio de uma
# instalação corrompe o banco de pacotes).
wait_for_apt() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 \
          || pgrep -x 'apt|apt-get|dpkg' >/dev/null 2>&1; do
        [ "$waited" -eq 0 ] && echo "    Aguardando outro processo do APT/dpkg terminar..."
        sleep 3
        waited=$((waited + 3))
        if [ "$waited" -ge 300 ]; then
            echo "    [AVISO] O APT continua ocupado após 5 minutos; seguindo mesmo assim."
            return 1
        fi
    done
    return 0
}

echo ">>> [1/8] Parando daemons, indexadores e serviços web..."
systemctl stop 'koha-*' 'koha-es-indexer@*' 'koha-zebra-daemon@*' cloudflared apache2 memcached 2>/dev/null || true
systemctl disable 'koha-es-indexer@*' 'koha-zebra-daemon@*' cloudflared 2>/dev/null || true
if command -v cloudflared >/dev/null 2>&1; then
    cloudflared service uninstall >/dev/null 2>&1 || true
fi

# Encerra apenas os processos do Koha que tenham sobrado
pkill -f 'zebrasrv|es_indexer_daemon|koha-worker|background_jobs_worker|starman.*koha' 2>/dev/null || true
sleep 2
pkill -9 -f 'zebrasrv|es_indexer_daemon|koha-worker|background_jobs_worker|starman.*koha' 2>/dev/null || true

echo ">>> [2/8] Removendo instâncias ativas do Koha..."
if command -v koha-list >/dev/null 2>&1; then
    for inst in $(koha-list 2>/dev/null); do
        koha-stop "$inst" 2>/dev/null || true
        koha-remove "$inst" 2>/dev/null || true
    done
fi

echo ">>> [3/8] Verificando o gerenciador de pacotes..."
wait_for_apt
DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>/dev/null || true

echo ">>> [4/8] Purgando pacotes do Koha, indexadores e dependências..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    koha-common koha-elasticsearch elasticsearch rabbitmq-server cloudflared 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge 2>/dev/null || true

echo ">>> [5/8] Limpando bancos de dados e usuários no MariaDB..."
if mysql -e "SELECT 1;" >/dev/null 2>&1; then
    # Apaga todos os bancos que comecem com koha
    dbs=$(mysql -Nse "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'koha%';" 2>/dev/null)
    for db in $dbs; do
        mysql -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || true
    done

    # Remove usuários criados para o Koha (em qualquer host)
    mysql -Nse "SELECT CONCAT(QUOTE(User), '@', QUOTE(Host)) FROM mysql.user WHERE User LIKE 'koha%';" 2>/dev/null \
        | while read -r account; do
            [ -n "$account" ] && mysql -e "DROP USER IF EXISTS ${account};" 2>/dev/null || true
        done
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
fi

echo ">>> [6/8] Restaurando configurações do Apache e portas padrão..."
if [ -d /etc/apache2 ]; then
    for site in /etc/apache2/sites-enabled/*; do
        [ -e "$site" ] || continue
        if grep -qs 'koha' "$site"; then
            a2dissite "$(basename "$site")" >/dev/null 2>&1 || rm -f "$site"
        fi
    done
    rm -f /etc/apache2/sites-available/library.conf /etc/apache2/sites-enabled/library.conf 2>/dev/null || true

    # Remove a escuta extra na porta 8080 inserida no ports.conf
    sed -i '/^[[:space:]]*Listen[[:space:]]\+8080[[:space:]]*$/d' /etc/apache2/ports.conf 2>/dev/null || true

    # Restaura o site default se foi removido
    a2ensite 000-default >/dev/null 2>&1 || true
fi

echo ">>> [7/8] Removendo cronjobs, scripts e unidades do Systemd..."
rm -f /etc/cron.d/koha_* /etc/cron.d/koha-common
rm -f /root/backup_sql.sh /root/backup_marc.sh /usr/local/bin/koha-es-watchdog.sh
rm -f /usr/local/bin/config.sh /usr/local/bin/config.sh.bak-*
rm -f /etc/systemd/system/koha-es-indexer@.service
rm -f /etc/apt/sources.list.d/koha.list /etc/apt/sources.list.d/elastic*.list /etc/apt/sources.list.d/cloudflared.list
rm -f /usr/share/keyrings/koha-keyring.gpg /usr/share/keyrings/elasticsearch-keyring.gpg /etc/apt/keyrings/cloudflare-main.gpg
rm -f /etc/fail2ban/jail.d/koha-easy-install.local
rm -f /etc/mysql/mariadb.conf.d/99-koha-tuning.cnf
systemctl daemon-reload 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

echo ">>> [8/8] Deletando diretórios residuais, credenciais, caches e travas..."
rm -rf /etc/koha /var/lib/koha /var/log/koha /var/run/koha /var/lock/koha /usr/share/koha
rm -rf /etc/koha-easy-install /var/log/koha-easy-install /run/koha-easy-install
rm -rf /var/backups/koha_sql /var/backups/koha_marc
rm -rf /etc/elasticsearch /etc/rabbitmq /etc/cloudflared
rm -rf /root/.cloudflared /home/*/.cloudflared

# Limpa travas e temporários criados pelo painel
rm -f /var/run/koha_panel.lock /var/run/koha_backup.pid /var/run/koha_es_watchdog.pid \
      /var/lock/koha_backup.lock /var/lock/koha_es_rebuild.lock
rm -f /root/credenciais_koha.txt /tmp/koha_* /tmp/koha-foreach /tmp/drop_koha_dbs.sql
rm -f /usr/local/bin/koha-foreach 2>/dev/null || true

# Restaura a tela de login padrão (o painel substitui /etc/issue e /etc/motd)
if [ -r /etc/os-release ]; then
    pretty_name=$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")
    printf '%s \\n \\l\n\n' "$pretty_name" > /etc/issue
    printf '%s\n' "$pretty_name" > /etc/issue.net
    : > /etc/motd
fi

# Reinicia Apache limpo
systemctl restart apache2 2>/dev/null || true
apt-get update >/dev/null 2>&1 || true

echo "----------------------------------------------------------------------"
echo "O ambiente foi totalmente limpo e redefinido para o estado padrão."
echo "Portas 80 e 8080 liberadas. Pronto para uma nova instalação limpa!"
echo "----------------------------------------------------------------------"
