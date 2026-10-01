#!/usr/bin/env bash
# Runs the Koha Easy Installer test battery (bats-core + a real MariaDB).
#
#   sudo KEI_TEST_SANDBOX=1 tests/run.sh [bats options] [tests/<file>.bats ...]
#
# DESTRUCTIVE: it replaces the koha_library database and installs test
# doubles for the koha-* tools and systemctl. Use a disposable container or
# VM only (see tests/README.md); it refuses to run next to a real Koha.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCKS="$REPO/tests/mocks"
LIBDIR=/usr/local/lib/kei-mock
KOHA_TOOLS=(koha-plack koha-zebra koha-indexer koha-es-indexer koha-worker koha-list
            koha-rebuild-zebra koha-upgrade-schema koha-shell koha-elasticsearch
            koha-create koha-remove koha-sip koha-z3950-responder koha-email-enable koha-mysql)
# Koha's command-line scripts used by the library tools (tests/mocks/koha-script).
KOHA_SCRIPTS=(stage_file.pl commit_file.pl import_patrons.pl cronjobs/update_patrons_category.pl
              cronjobs/delete_patrons.pl cronjobs/batch_anonymise.pl cronjobs/process_message_queue.pl
              maintenance/search_for_data_inconsistencies.pl admin/koha-preferences)

die() { echo "tests/run.sh: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[ "${KEI_TEST_SANDBOX:-}" = "1" ] || die "refusing to run without KEI_TEST_SANDBOX=1 (disposable machines only)."
if dpkg-query -W -f='${Status}' koha-common 2>/dev/null | grep -q 'ok installed'; then
    die "a real koha-common is installed here; the tests would destroy it."
fi
for c in bats mysql mysqldump mariadbd memcached whiptail gzip zip flock setsid yaz-marcdump xsltproc python3; do
    command -v "$c" >/dev/null 2>&1 || die "missing '$c' (apt-get install bats mariadb-server memcached whiptail zip yaz xsltproc python3 libmarc-record-perl)."
done
# The MARC tools, the messaging driver and marc_replace.pl run on Koha's own
# Perl stack (koha-common depends on these packages).
perl -MMARC::Record -MMARC::File::XML -MSMS::Send -MCGI -MModern::Perl -e 1 2>/dev/null \
    || die "missing Perl modules (apt-get install libmarc-record-perl libmarc-xml-perl libsms-send-perl libcgi-pm-perl libmodern-perl-perl)."

install_doubles() {
    mkdir -p "$LIBDIR" /usr/share/koha/bin /etc/koha/sites/library /run/kei-mock
    install -m 755 "$MOCKS/koha-mock" "$LIBDIR/koha-mock"
    local t
    for t in "${KOHA_TOOLS[@]}"; do
        if [ -e "/usr/sbin/$t" ] && [ ! -L "/usr/sbin/$t" ]; then die "/usr/sbin/$t is a real file; not overwriting."; fi
        ln -sfn "$LIBDIR/koha-mock" "/usr/sbin/$t"
    done
    install -m 644 "$MOCKS/koha-functions.sh" /usr/share/koha/bin/koha-functions.sh
    install -m 755 "$MOCKS/koha-script" "$LIBDIR/koha-script"
    # Koha's Perl modules used by marc_replace.pl, and the WhatsApp / Telegram API.
    rm -rf "$LIBDIR/perl5" && cp -r "$MOCKS/perl5" "$LIBDIR/perl5"
    install -m 755 "$MOCKS/http-mock" "$LIBDIR/http-mock"
    mkdir -p /usr/share/koha/bin/cronjobs /usr/share/koha/bin/maintenance /usr/share/koha/bin/admin
    for t in "${KOHA_SCRIPTS[@]}"; do
        if [ -e "/usr/share/koha/bin/$t" ] && [ ! -L "/usr/share/koha/bin/$t" ]; then die "/usr/share/koha/bin/$t is a real file; not overwriting."; fi
        ln -sfn "$LIBDIR/koha-script" "/usr/share/koha/bin/$t"
    done
    # First in the installer's PATH: the containers have no systemd.
    install -m 755 "$MOCKS/systemctl" /usr/local/sbin/systemctl
    install -m 755 "$MOCKS/curl" /usr/local/sbin/curl
    printf '#!/bin/sh\nexec /usr/local/sbin/systemctl "$2" "$1"\n' > /usr/local/sbin/service
    printf '#!/bin/sh\nshift 2 2>/dev/null; echo "$*" >> /run/kei-mock/syslog\n' > /usr/local/sbin/logger
    chmod 755 /usr/local/sbin/service /usr/local/sbin/logger
    # The panel asks for its language on first run.
    mkdir -p /etc/koha-easy-install
    printf 'KOHA_PANEL_LANG_FULL="en-GB"\nKOHA_PANEL_LANG="en"\n' > /etc/koha-easy-install/translation.conf
}

remove_doubles() {
    local t
    for t in "${KOHA_TOOLS[@]}"; do [ -L "/usr/sbin/$t" ] && rm -f "/usr/sbin/$t"; done
    for t in "${KOHA_SCRIPTS[@]}"; do [ -L "/usr/share/koha/bin/$t" ] && rm -f "/usr/share/koha/bin/$t"; done
    rm -f /usr/local/sbin/systemctl /usr/local/sbin/service /usr/local/sbin/logger /usr/local/sbin/curl
    rm -rf "$LIBDIR"
    if [ -f /run/kei-mock/daemons.pids ]; then
        xargs -r kill < /run/kei-mock/daemons.pids 2>/dev/null || true
    fi
}

# One run at a time: a second run would remove the doubles under the first.
exec 7>/run/kei-test-run.lock
flock -n 7 || die "another test run is in progress."

install_doubles
trap remove_doubles EXIT

if [ $# -eq 0 ]; then set -- "$REPO"/tests/*.bats; fi
bats "$@" 7>&-
