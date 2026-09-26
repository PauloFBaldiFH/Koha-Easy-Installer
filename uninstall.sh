# 1. Interrompe e remove quaisquer instâncias ativas do Koha
koha-stop $(koha-list) 2>/dev/null || true
for inst in $(koha-list 2>/dev/null); do
    koha-remove "$inst" 2>/dev/null || true
done

# 2. Desbloqueia e repara o gerenciador de pacotes se algo foi interrompido
killall apt apt-get dpkg 2>/dev/null || true
dpkg --configure -a
apt install -f -y

# 3. Remove completamente os pacotes do Koha e dependências órfãs
apt purge -y koha-common
apt autoremove -y --purge

# 4. Remove arquivos de configuração, diretórios residuais e logs do instalador
rm -rf /etc/koha /var/lib/koha /var/log/koha
rm -rf /etc/koha-easy-install /var/log/koha-easy-installer
rm -f /root/credenciais_koha.txt /tmp/koha* /tmp/*.lock

# 5. Remove bancos de dados residuais do Koha no MariaDB
mysql -e "
SELECT CONCAT('DROP DATABASE IF EXISTS \`', schema_name, '\`;') 
FROM information_schema.schemata 
WHERE schema_name LIKE 'koha%' 
INTO OUTFILE '/tmp/drop_koha_dbs.sql';
" 2>/dev/null || true

if [ -f /tmp/drop_koha_dbs.sql ]; then
    mysql < /tmp/drop_koha_dbs.sql 2>/dev/null || true
    rm -f /tmp/drop_koha_dbs.sql
fi

# 6. Restaura as portas do Apache para o padrão (remove porta 8080/intranet)
a2dissite koha-* 2>/dev/null || true
systemctl restart apache2 2>/dev/null || true
