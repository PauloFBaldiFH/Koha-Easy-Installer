#!/usr/bin/env bash
# ======================================================================
# KOHA EASY INSTALLER & MANAGER - DEEP CLEANUP & UNINSTALL
# Remove completamente instâncias, serviços, bancos, daemons e resíduos.
# ======================================================================

set -o pipefail
[ "${EUID:-$(id -u)}" -ne 0 ] && { echo "Execute como root (sudo ./uninstall.sh)"; exit 1; }

echo ">>> [1/8] Parando daemons, indexadores e serviços web..."
# Interrompe serviços e daemons do Koha / Watchdog / Indexers
systemctl stop 'koha-*' 'koha-es-indexer@*' 'koha-zebra-daemon@*' cloudflared apache2 memcached 2>/dev/null || true
systemctl disable 'koha-es-indexer@*' 'koha-zebra-daemon@*' cloudflared 2>/dev/null || true

# Derruba processos remanescentes nas portas e em background
fuser -k 80/tcp 8080/tcp 61613/tcp 2>/dev/null || true
pkill -9 -f 'zebrasrv|es_indexer_daemon|koha-worker|background_jobs_worker' 2>/dev/null || true

echo ">>> [2/8] Removendo instâncias ativas do Koha..."
if command -v koha-list >/dev/null 2>&1; then
    for inst in $(koha-list 2>/dev/null); do
        koha-stop "$inst" 2>/dev/null || true
        koha-remove "$inst" 2>/dev/null || true
    done
fi

echo ">>> [3/8] Desbloqueando e reparando o gerenciador de pacotes..."
killall -9 apt apt-get dpkg unattended-upgrade 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
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

    # Remove usuários criados para o Koha
    users=$(mysql -Nse "SELECT User FROM mysql.user WHERE User LIKE 'koha%';" 2>/dev/null)
    for u in $users; do
        mysql -e "DROP USER IF EXISTS '$u'@'localhost'; DROP USER IF EXISTS '$u'@'%';" 2>/dev/null || true
    done
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
fi

echo ">>> [6/8] Restaurando configurações do Apache e portas padrão..."
if [ -d /etc/apache2 ]; then
    # Desativa sites do Koha
    a2dissite library library.conf koha-* 2>/dev/null || true
    rm -f /etc/apache2/sites-available/library.conf /etc/apache2/sites-enabled/library.conf 2>/dev/null || true
    
    # Remove a escuta extra na porta 8080 inserida no ports.conf
    sed -i '/^[[:space:]]*Listen[[:space:]]\+8080/d' /etc/apache2/ports.conf 2>/dev/null || true
    
    # Restaura o site default se foi removido
    a2ensite 000-default.conf 2>/dev/null || true
fi

echo ">>> [7/8] Removendo cronjobs, scripts e unidades do Systemd..."
rm -f /etc/cron.d/koha_* /etc/cron.d/koha-common /etc/cron.d/koha_tasks /etc/cron.d/koha_zebra_queue /etc/cron.d/koha_es_watchdog
rm -f /root/backup_sql.sh /root/backup_marc.sh /usr/local/bin/koha-es-watchdog.sh
rm -f /etc/systemd/system/koha-es-indexer@.service
rm -f /etc/apt/sources.list.d/koha.list /etc/apt/sources.list.d/elastic*.list /etc/apt/sources.list.d/cloudflared.list
rm -f /usr/share/keyrings/koha-keyring.gpg /usr/share/keyrings/elasticsearch-keyring.gpg
systemctl daemon-reload 2>/dev/null || true

echo ">>> [8/8] Deletando diretórios residuais, credenciais, caches e travas..."
rm -rf /etc/koha /var/lib/koha /var/log/koha /var/run/koha /var/lock/koha
rm -rf /etc/koha-easy-install /var/log/koha-easy-install /run/koha-easy-install
rm -rf /var/backups/koha_sql /var/backups/koha_marc
rm -rf /etc/elasticsearch /etc/rabbitmq /etc/cloudflared
rm -rf /root/.cloudflared /home/*/.cloudflared

# Limpa travas de sessão
rm -f /var/run/koha_panel.lock /var/run/koha_backup.pid /var/run/koha_es_watchdog.pid /var/lock/koha_backup.lock /var/lock/koha_es_rebuild.lock
rm -f /root/credenciais_koha.txt /tmp/koha* /tmp/*.lock /tmp/drop_koha_dbs.sql

# Reinicia Apache limpo
systemctl restart apache2 2>/dev/null || true

echo "----------------------------------------------------------------------"
echo "O ambiente foi totalmente limpo e redefinido para o estado padrão."
echo "Portas 80 e 8080 liberadas. Pronto para uma nova instalação limpa!"
echo "----------------------------------------------------------------------"
