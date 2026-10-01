#!/usr/bin/env bats
# Library tools 14: Koha's own plugin system turned on or off in
# koha-conf.xml (enable_plugins, pluginsdir, plugins_restricted and the
# plugin repositories), Koha restarted, and the plugins copied into the
# folder by hand registered with Koha's own script.

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_tools_catalog
    CONF=/etc/koha/sites/library/koha-conf.xml
    PDIR=/var/lib/koha/library/plugins
    DEVEL=/usr/share/koha/bin/devel/install_plugins.pl
    rm -rf "$PDIR" "$DEVEL" /etc/koha/sites/library/koha-conf.xml.bak-*
    mysql -e "DELETE FROM systempreferences WHERE variable = 'UseKohaPlugins';" "$DB"
}

teardown() { rm -rf "$DEVEL" "$PDIR"; kei_kill_daemons; }

conf()        { xmllint --xpath "string(/yazgfs/config/$1[1])" "$CONF" 2>/dev/null; }
conf_count()  { xmllint --xpath "count(/yazgfs/config/$1)" "$CONF" 2>/dev/null; }
extra()       { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/extra.sh"; export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"; }
pre_backups() { find /var/backups/koha_sql -maxdepth 1 -name "PRE-${1:-}*" 2>/dev/null | wc -l; }

# The plugin part of Debian's koha-conf.xml: settings with trailing comments
# and the example repositories commented out inside <plugin_repos>.
debian_conf() {
    python3 - "$CONF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(" <memcached_servers>", """ <pluginsdir>/var/lib/koha/library/plugins</pluginsdir> <!-- This entry can be repeated to use multiple directories -->
 <enable_plugins>0</enable_plugins>
 <plugins_restricted>0</plugins_restricted> <!-- <enable_plugins>1</enable_plugins> in a comment is not a setting -->
 <plugin_repos>
    <!--
    <repo>
        <name>ByWater Solutions</name>
        <org_name>bywatersolutions</org_name>
        <service>github</service>
    </repo>
    -->
 </plugin_repos>
 <memcached_servers>""", 1)
open(p, "w").write(s)
PY
}

@test "K01 menu: Library tools 14 opens the plugins menu, which shows the current state" {
    assert 'grep -q "^            14) function_koha_plugins ;;$" "$KEI_REPO/installer"' "entry 14 of Library tools"
    inputs CANCEL
    panel function_koha_plugins
    assert '[ "$status" -eq 0 ] && dialogs | grep -q "MENU \[⌁  Koha plugins (turn on or off)\] => CANCEL"' "$(dialogs)"
}

@test "K02 on: enable_plugins set, the missing pluginsdir added and created for the instance user, Koha restarted, old file kept" {
    mysql -e "INSERT INTO systempreferences (variable, value) VALUES ('UseKohaPlugins', '0');" "$DB"
    local before; before=$(md5sum < "$CONF")
    answer yes
    panel lt_plugins_on
    assert '[ "$(conf enable_plugins)" = "1" ] && [ "$(conf pluginsdir)" = "$PDIR" ] && [ "$(conf plugins_restricted)" = "0" ]' "$(cat "$CONF")"
    assert '[ -d "$PDIR" ] && xmllint --noout "$CONF"' "folder and well-formed file"
    assert '[ "$(md5sum < /etc/koha/sites/library/koha-conf.xml.bak-*)" = "$before" ]' "the previous file is kept"
    assert 'grep -q "^koha-plack --restart library" "$KEI_S/calls.log" && grep -q "^koha-worker --restart library" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(mysql -N -B -e "SELECT value FROM systempreferences WHERE variable = '"'"'UseKohaPlugins'"'"';" "$DB")" = "1" ]' "UseKohaPlugins on older Koha"
    assert 'dialogs | grep -q "OK ✔ Koha plugins are on"' "$(dialogs | tail -2)"
    # A second run changes nothing.
    rm -f "$KEI_S/calls.log"
    panel lt_plugins_on
    assert 'dialogs | grep -q "already on" && ! grep -q koha-plack "$KEI_S/calls.log" 2>/dev/null' "$(dialogs | tail -1)"
}

@test "K03 off: only enable_plugins changes; the plugins, their folder and the other settings are kept" {
    debian_conf
    answer yes
    panel lt_plugins_on
    mkdir -p "$PDIR/Koha/Plugin/Test" && echo 1 > "$PDIR/Koha/Plugin/Test.pm"
    answer yes
    panel lt_plugins_off
    assert '[ "$(conf enable_plugins)" = "0" ] && [ "$(conf pluginsdir)" = "$PDIR" ] && [ "$(conf_count pluginsdir)" = "1" ] && [ "$(conf_count enable_plugins)" = "1" ]' "$(cat "$CONF")"
    assert '[ -f "$PDIR/Koha/Plugin/Test.pm" ] && dialogs | grep -q "OK ✔ Koha plugins are off"' "$(dialogs | tail -2)"
    # Answering no changes nothing.
    answer yes
    panel lt_plugins_on
    local before; before=$(md5sum < "$CONF")
    answer no
    panel lt_plugins_off
    assert '[ "$(md5sum < "$CONF")" = "$before" ]' "no means no"
}

@test "K04 source: restricted adds the example repositories inside Debian's <plugin_repos>; open keeps them" {
    debian_conf
    inputs restricted
    answer yes
    panel lt_plugins_source
    assert '[ "$(conf plugins_restricted)" = "1" ] && [ "$(conf_count plugin_repos)" = "1" ] && [ "$(conf_count plugin_repos/repo)" = "3" ]' "$(cat "$CONF")"
    assert '[ "$(xmllint --xpath "string(/yazgfs/config/plugin_repos/repo[3]/org_name)" "$CONF")" = "ptfs-europe" ] && [ "$(conf enable_plugins)" = "0" ]' "$(cat "$CONF")"
    inputs open
    panel lt_plugins_source
    assert '[ "$(conf plugins_restricted)" = "0" ] && [ "$(conf_count plugin_repos/repo)" = "3" ]' "$(cat "$CONF")"
    # Restricted again: the repositories are not added twice.
    inputs restricted
    panel lt_plugins_source
    assert '[ "$(conf_count plugin_repos/repo)" = "3" ] && [ "$(conf_count plugin_repos)" = "1" ]' "$(cat "$CONF")"
}

@test "K05 a koha-conf.xml that would not be well-formed or read back is never used" {
    local before; before=$(md5sum < "$CONF")
    extra 'plugins_conf_edit() { local f; f=$(mktemp "${KOHA_CONF}.XXXXXX"); echo "<yazgfs><config>" > "$f"; printf "%s" "$f"; }'
    answer yes
    panel lt_plugins_on
    assert '[ "$(md5sum < "$CONF")" = "$before" ] && dialogs | grep -q "koha-conf.xml could not be changed"' "$(dialogs | tail -2)"
    extra 'plugins_conf_edit() { local f; f=$(mktemp "${KOHA_CONF}.XXXXXX"); cp "$KOHA_CONF" "$f"; printf "%s" "$f"; }'
    answer yes
    panel lt_plugins_on
    assert '[ "$(md5sum < "$CONF")" = "$before" ] && ! grep -q "koha-plack --restart" "$KEI_S/calls.log" 2>/dev/null' "$(calls)"
    assert '[ -z "$(find /etc/koha/sites/library -name "koha-conf.xml.??????")" ]' "no temporary file left"
}

@test "K06 register: refused while off; with plugins on, Koha's script runs as the instance user after a verified backup" {
    mkdir -p "$(dirname "$DEVEL")"
    printf '#!/usr/bin/perl\nprint "Installed Koha::Plugin::Test version 1.0\\n";\n' > "$DEVEL"
    panel lt_plugins_register
    assert 'dialogs | grep -q "Turn Koha plugins on first" && [ "$(pre_backups PLUGINS)" = "0" ]' "$(dialogs | tail -1)"
    answer yes
    panel lt_plugins_on
    answer yes
    panel lt_plugins_register
    assert '[ "$(pre_backups PLUGINS)" = "1" ] && grep -q "koha-shell library -c \"/usr/bin/perl\" \".*install_plugins.pl\"" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "Installed Koha::Plugin::Test" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last" 2>&1)"
}
