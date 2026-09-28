# Shared helpers for the bats test battery (see tests/README.md).
# shellcheck shell=bash
KEI_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEI_S=/run/kei-mock
PANEL="$KEI_REPO/tests/lib/panel.sh"
# Shell used for the panel and the generated scripts: KEI_BASH=/path/to/bash
# runs the battery with another Bash release (e.g. 5.1 of Debian 11 / Ubuntu 22.04).
KEI_SH="${KEI_BASH:-bash}"
DB=koha_library
FIX="${BATS_FILE_TMPDIR:-/tmp}/fixtures"

# ---------------------------------------------------------------------
# Synthetic Koha catalog: the core tables the panel checks, the zebraqueue
# and background_jobs queues, and fillers up to 60 tables (a real Koha has
# ~300). Random text keeps the dumps from compressing to nothing.
# ---------------------------------------------------------------------
kei_schema_sql() {
    cat <<'SQL'
CREATE TABLE branches (branchcode varchar(10) NOT NULL PRIMARY KEY, branchname longtext NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE categories (categorycode varchar(10) NOT NULL PRIMARY KEY, description longtext, category_type varchar(1) NOT NULL DEFAULT 'A') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE borrowers (borrowernumber int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, cardnumber varchar(32) UNIQUE, surname longtext, firstname mediumtext, branchcode varchar(10) NOT NULL, categorycode varchar(10) NOT NULL, userid varchar(75) UNIQUE, password varchar(60), flags bigint(11)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE biblio (biblionumber int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, title longtext, author longtext, datecreated date NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE biblio_metadata (id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, biblionumber int(11) NOT NULL, format varchar(16) NOT NULL, `schema` varchar(16) NOT NULL, metadata longtext NOT NULL, CONSTRAINT bm_fk FOREIGN KEY (biblionumber) REFERENCES biblio (biblionumber) ON DELETE CASCADE) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE items (itemnumber int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, biblionumber int(11) NOT NULL, barcode varchar(20) UNIQUE, homebranch varchar(10), CONSTRAINT it_fk FOREIGN KEY (biblionumber) REFERENCES biblio (biblionumber) ON DELETE CASCADE) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE systempreferences (variable varchar(50) NOT NULL PRIMARY KEY, value mediumtext, options longtext, explanation mediumtext, type varchar(20)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE zebraqueue (id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, biblio_auth_number bigint(20) unsigned NOT NULL DEFAULT 0, operation char(20) NOT NULL DEFAULT '', server char(20) NOT NULL DEFAULT '', done int(11) NOT NULL DEFAULT 0, time timestamp NOT NULL DEFAULT current_timestamp()) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE background_jobs (id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, status varchar(32), type varchar(64), queue varchar(191) NOT NULL DEFAULT 'default', enqueued_on datetime, data longtext) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE sessions (id varchar(32) NOT NULL PRIMARY KEY, a_session longblob NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL
    local i
    for i in $(seq -w 1 50); do
        printf 'CREATE TABLE kei_filler_%s (id int(11) NOT NULL PRIMARY KEY, note varchar(100)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n' "$i"
    done
}

# kei_data_sql LABEL NBIB ENGINE: catalog content; every title starts with LABEL.
kei_data_sql() {
    local label="$1" n="${2:-200}" engine="${3:-Zebra}"
    cat <<SQL
INSERT INTO branches VALUES ('CPL','Castro Alves');
INSERT INTO categories VALUES ('S','Staff','S'),('PT','Patron','A');
INSERT INTO systempreferences (variable,value,type) VALUES ('Version','24.0500000','Free'),('SearchEngine','${engine}','Choice'),('marker','${label}','Free');
INSERT INTO borrowers (cardnumber,surname,firstname,branchcode,categorycode,userid) VALUES ('C1','${label}','Ana','CPL','PT','ana');
SQL
    awk -v n="$n" -v label="$label" 'BEGIN {
        srand(42 + length(label));
        for (i = 1; i <= n; i++) {
            s = ""; for (j = 0; j < 40; j++) s = s sprintf("%c", 97 + int(rand() * 26));
            printf "INSERT INTO biblio VALUES (%d,\"%s title %d %s\",\"author %d\",\"2024-01-01\");\n", i, label, i, s, i;
            printf "INSERT INTO biblio_metadata (biblionumber,format,`schema`,metadata) VALUES (%d,\"marcxml\",\"MARC21\",\"<record>%s %s</record>\");\n", i, label, s s s;
            printf "INSERT INTO items (biblionumber,barcode,homebranch) VALUES (%d,\"%s-%d\",\"CPL\");\n", i, substr(label, 1, 3), i;
        }
        for (i = 1; i <= 300; i++) {
            s = ""; for (j = 0; j < 30; j++) s = s sprintf("%c", 65 + int(rand() * 26));
            printf "INSERT INTO systempreferences (variable,value,type) VALUES (\"pref%d\",\"%s\",\"Free\");\n", i, s;
        }
    }'
}

# kei_make_catalog DB LABEL [NBIB] [ENGINE]
kei_make_catalog() {
    local db="$1"
    mysql -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    { echo "SET FOREIGN_KEY_CHECKS=0;"; kei_schema_sql; kei_data_sql "$2" "${3:-200}" "${4:-Zebra}"; } | mysql "$db"
}

# The live catalog: "OLD" data, as found on the server before a restore.
kei_reset_live_catalog() { kei_make_catalog "$DB" "${1:-OLD}" "${2:-200}" "${3:-Zebra}"; }

# kei_dump DB FILE [extra mysqldump options]: .sql or .sql.gz by extension.
kei_dump() {
    local db="$1" out="$2"; shift 2
    if [[ "$out" == *.gz ]]; then
        mysqldump --single-transaction --routines --triggers "$@" "$db" | gzip > "$out"
    else
        mysqldump --single-transaction --routines --triggers "$@" "$db" > "$out"
    fi
}

# A valid backup of a "NEW" catalog, in both formats (cached per test file).
kei_backup_fixtures() {
    mkdir -p "$FIX"
    [ -s "$FIX/new.sql.gz" ] && return 0
    kei_make_catalog kei_src NEW 300
    kei_dump kei_src "$FIX/new.sql.gz"
    kei_dump kei_src "$FIX/new.sql"
    mysql -e "DROP DATABASE IF EXISTS kei_src;"
}

# Label of the live catalog ("OLD", "NEW"...), or "" when it is gone.
live_marker()  { mysql -Nse "SELECT value FROM ${DB}.systempreferences WHERE variable='marker';" 2>/dev/null; }
live_biblios() { mysql -Nse "SELECT COUNT(*) FROM ${DB}.biblio;" 2>/dev/null; }
live_engine()  { mysql -Nse "SELECT value FROM ${DB}.systempreferences WHERE variable='SearchEngine';" 2>/dev/null; }

# ---------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------
# Starts a background service without any of the test runner's descriptors:
# bats waits until every copy of its pipes is closed, so a server that kept
# one would hang the run.
kei_detached() {
    (
        for fd in /proc/self/fd/*; do
            fd="${fd##*/}"
            [ "$fd" -gt 2 ] 2>/dev/null && eval "exec $fd>&-" 2>/dev/null
        done
        exec setsid "$@" </dev/null >>/tmp/kei-services.log 2>&1
    ) &
}

kei_mariadb_up() { mysqladmin ping >/dev/null 2>&1; }
kei_start_mariadb() {   # [extra mariadbd options, e.g. --skip-name-resolve]
    kei_mariadb_up && return 0
    mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
    kei_detached mariadbd --user=mysql --socket=/run/mysqld/mysqld.sock \
        --pid-file=/run/mysqld/mysqld.pid "$@"
    local i
    for i in $(seq 1 60); do kei_mariadb_up && return 0; sleep 0.5; done
    return 1
}
kei_stop_mariadb() {
    mysqladmin shutdown >/dev/null 2>&1
    local i
    for i in $(seq 1 60); do kei_mariadb_up || return 0; sleep 0.5; done
    return 1
}
# memcached needs a moment to exit on SIGTERM: wait for real state changes.
kei_memcached_up() { (exec 3<>/dev/tcp/127.0.0.1/11211) 2>/dev/null; }
kei_stop_memcached() {
    pkill -x memcached || true
    local i
    for i in $(seq 1 40); do pgrep -x memcached >/dev/null || return 0; sleep 0.25; done
    return 1
}
kei_start_memcached() {
    kei_memcached_up && return 0
    kei_stop_memcached
    kei_detached memcached -u memcache -l 127.0.0.1 -p 11211 -m 16
    local i
    for i in $(seq 1 40); do kei_memcached_up && return 0; sleep 0.25; done
    return 1
}

# Kills the fake daemons started by the koha-* test doubles.
kei_kill_daemons() {
    local p
    [ -f "$KEI_S/daemons.pids" ] || return 0
    while read -r p; do [ -n "$p" ] && { kill "$p" 2>/dev/null || true; }; done < "$KEI_S/daemons.pids"
    rm -f "$KEI_S/daemons.pids"
}

# Fresh state for every test: logs, mock services, locks, backups, cron.
kei_reset_env() {
    kei_kill_daemons
    rm -rf "$KEI_S/calls.log" "$KEI_S/dialogs.log" "$KEI_S/answers" "$KEI_S/syslog" \
           "$KEI_S/run" "$KEI_S/svc" "$KEI_S/svc-fail" "$KEI_S/fail" "$KEI_S/pkgs" \
           "$KEI_S/inputs" "$KEI_S/textbox.last" "$KEI_S"/batch-*.biblios
    rm -rf /var/log/koha-easy-install/tools /var/lib/koha/library/email.enabled /root/koha_patrons_template.csv
    mkdir -p "$KEI_S/run" "$KEI_S/svc" "$KEI_S/svc-fail" "$KEI_S/fail" "$KEI_S/pkgs"
    touch "$KEI_S/svc/mariadb" "$KEI_S/svc/memcached" "$KEI_S/svc/apache2" "$KEI_S/svc/cron"
    touch "$KEI_S/run/zebra" "$KEI_S/run/indexer" "$KEI_S/run/plack" "$KEI_S/run/worker"
    rm -f /root/.my.cnf
    rm -rf /var/backups/koha_sql /var/backups/koha_marc /run/koha-easy-install
    rm -f /etc/cron.d/koha_* /var/lock/koha_backup.lock /var/run/koha_backup.pid
    rm -f /usr/local/bin/koha-zebra-watchdog.sh /usr/local/bin/koha-es-watchdog.sh /usr/local/bin/koha-wait-services.sh
    rm -f /etc/systemd/system/koha-common.service.d/koha-easy-install.conf /etc/systemd/system/apache2.service.d/koha-easy-install.conf
    cp -f "$KEI_REPO/tests/mocks/koha-conf.xml" /etc/koha/sites/library/koha-conf.xml
    printf 'USE_INDEXER_DAEMON="yes"\n' > /etc/default/koha-common
    kei_start_mariadb
    kei_start_memcached
    mysql -e "DROP DATABASE IF EXISTS koha_restore_check; DROP DATABASE IF EXISTS koha_teste_restauracao;" 2>/dev/null || true
}

# Runs one installer function through the driver (bats "run" semantics).
panel() { run "$KEI_SH" "$PANEL" "$@"; }

dialogs() { cat "$KEI_S/dialogs.log" 2>/dev/null; }
calls()   { cat "$KEI_S/calls.log" 2>/dev/null; }
answer()  { printf '%s\n' "$@" >> "$KEI_S/answers"; }
inputs()  { printf '%s\n' "$@" >> "$KEI_S/inputs"; }

# Fails the test with context when a condition is false.
assert() {
    if ! eval "$1"; then
        printf 'ASSERTION FAILED: %s\n' "${2:-$1}" >&2
        printf -- '--- output ---\n%s\n--- dialogs ---\n%s\n' "${output:-}" "$(dialogs | tail -n 15)" >&2
        return 1
    fi
}

# The catalog was not modified: still the OLD data, Koha still serving.
assert_catalog_untouched() {
    assert '[ "$(live_marker)" = "OLD" ]' "live catalog must still be the OLD one (got '$(live_marker)')"
    assert '[ "$(live_biblios)" = "200" ]' "OLD catalog must keep its 200 records (got '$(live_biblios)')"
    assert '! grep -q "koha-plack --stop" "$KEI_S/calls.log" 2>/dev/null' "Koha services must not have been stopped"
}

# ---------------------------------------------------------------------
# Library tools: the tables and columns they read or write (same names and
# types as Koha's kohastructure.sql), added to the live catalog.
#   patrons: C1 Ana (PT), 3 students (ST: two adults, one child), 2 expired
#   patrons without loans, 1 expired with a loan, 1 expired staff member,
#   1 patron who keeps his history (privacy 0)
#   history: 3 old loans + 2 old holds anonymisable, 1 recent loan
# ---------------------------------------------------------------------
kei_tools_catalog() {
    mysql "$DB" <<'SQL'
ALTER TABLE borrowers ADD COLUMN email mediumtext, ADD COLUMN phone mediumtext, ADD COLUMN dateofbirth date,
  ADD COLUMN dateenrolled date, ADD COLUMN dateexpiry date, ADD COLUMN privacy int(11) NOT NULL DEFAULT 1;
ALTER TABLE items ADD COLUMN itemcallnumber varchar(255), ADD COLUMN dateaccessioned date, ADD COLUMN issues smallint(6),
  ADD COLUMN itemlost tinyint(1) NOT NULL DEFAULT 0, ADD COLUMN itemlost_on datetime;
ALTER TABLE items MODIFY homebranch varchar(10) NULL;
CREATE TABLE import_batches (import_batch_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, matcher_id int(11), num_records int(11) NOT NULL DEFAULT 0,
  num_items int(11) NOT NULL DEFAULT 0, upload_timestamp timestamp NOT NULL DEFAULT current_timestamp(),
  import_status enum('staging','staged','importing','imported','reverting','reverted','cleaned') NOT NULL DEFAULT 'staging',
  batch_type enum('batch','z3950','webservice') NOT NULL DEFAULT 'batch', record_type enum('biblio','auth','holdings') NOT NULL DEFAULT 'biblio',
  file_name varchar(100), comments longtext);
CREATE TABLE import_records (import_record_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, import_batch_id int(11) NOT NULL,
  status enum('error','staged','imported','reverted','items_reverted','ignored') NOT NULL DEFAULT 'staged');
CREATE TABLE import_items (import_items_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, import_record_id int(11) NOT NULL,
  itemnumber int(11), status enum('error','staged','imported','reverted','ignored') NOT NULL DEFAULT 'staged');
CREATE TABLE marc_matchers (matcher_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, code varchar(10) NOT NULL DEFAULT '',
  description varchar(255) NOT NULL DEFAULT '', record_type varchar(10) NOT NULL DEFAULT 'biblio', threshold int(11) NOT NULL DEFAULT 0);
CREATE TABLE saved_sql (id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, borrowernumber int(11), date_created datetime, last_modified datetime,
  savedsql mediumtext, last_run datetime, report_name varchar(255) NOT NULL DEFAULT '', type varchar(255), notes mediumtext,
  cache_expiry int(11) NOT NULL DEFAULT 300, public tinyint(1) NOT NULL DEFAULT 0, report_area varchar(6), report_group varchar(80),
  report_subgroup varchar(80), mana_id int(11)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE issues (issue_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, borrowernumber int(11), itemnumber int(11),
  date_due datetime, branchcode varchar(10), issuedate datetime);
CREATE TABLE old_issues (issue_id int(11) NOT NULL PRIMARY KEY, borrowernumber int(11), itemnumber int(11), date_due datetime,
  branchcode varchar(10), returndate datetime, issuedate datetime);
CREATE TABLE old_reserves (reserve_id int(11) NOT NULL PRIMARY KEY, borrowernumber int(11), biblionumber int(11),
  timestamp timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp());
CREATE TABLE statistics (datetime datetime, branch varchar(10), type varchar(16), itemnumber int(11), borrowernumber int(11));
CREATE TABLE authorised_values (id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, category varchar(32) NOT NULL DEFAULT '',
  authorised_value varchar(80) NOT NULL DEFAULT '', lib varchar(200));

INSERT INTO marc_matchers (code, description) VALUES ('ISBN', 'ISBN');
INSERT INTO authorised_values (category, authorised_value, lib) VALUES ('LOST', '1', 'Lost');
INSERT INTO branches VALUES ('MPL', 'Midway');
INSERT INTO categories VALUES ('ST', 'Student', 'C'), ('FM', 'Former student', 'A');
UPDATE borrowers SET dateexpiry = '2099-01-01', dateenrolled = '2020-01-01' WHERE cardnumber = 'C1';
INSERT INTO borrowers (cardnumber, surname, firstname, branchcode, categorycode, flags, dateofbirth, dateenrolled, dateexpiry, privacy) VALUES
  ('S1', 'Souza', 'Bia', 'CPL', 'ST', 0, '2000-03-01', '2019-02-01', '2099-01-01', 1),
  ('S2', 'Lima', 'Caio', 'CPL', 'ST', 0, '2001-05-01', '2024-02-01', '2099-01-01', 1),
  ('S3', 'Rocha', 'Duda', 'MPL', 'ST', 0, '2016-07-01', '2024-02-01', '2099-01-01', 1),
  ('E1', 'Old', 'Eva', 'CPL', 'PT', 0, NULL, '2010-01-01', '2019-01-01', 1),
  ('E2', 'Old', 'Fabio', 'CPL', 'PT', 0, NULL, '2010-01-01', '2019-06-01', 1),
  ('E3', 'Old', 'Gil', 'CPL', 'PT', 0, NULL, '2010-01-01', '2019-06-01', 1),
  ('E4', 'Staff', 'Hugo', 'CPL', 'S', 1, NULL, '2010-01-01', '2019-06-01', 1),
  ('K1', 'Keep', 'Iris', 'CPL', 'PT', 0, NULL, '2010-01-01', '2099-01-01', 0);
UPDATE items SET itemcallnumber = CONCAT('000.', itemnumber), dateaccessioned = '2020-01-01', issues = 0;
UPDATE items SET itemlost = 1, itemlost_on = NOW() WHERE itemnumber = 1;
INSERT INTO issues (borrowernumber, itemnumber, date_due, branchcode, issuedate)
  SELECT borrowernumber, 2, DATE_SUB(NOW(), INTERVAL 3 DAY), 'CPL', DATE_SUB(NOW(), INTERVAL 20 DAY) FROM borrowers WHERE cardnumber = 'E3';
INSERT INTO old_issues (issue_id, borrowernumber, itemnumber, returndate, issuedate)
  SELECT 1, borrowernumber, 3, '2019-03-01', '2019-02-01' FROM borrowers WHERE cardnumber = 'C1' UNION ALL
  SELECT 2, borrowernumber, 4, '2019-03-01', '2019-02-01' FROM borrowers WHERE cardnumber = 'S1' UNION ALL
  SELECT 3, borrowernumber, 5, '2019-03-01', '2019-02-01' FROM borrowers WHERE cardnumber = 'E1' UNION ALL
  SELECT 4, borrowernumber, 6, '2019-03-01', '2019-02-01' FROM borrowers WHERE cardnumber = 'K1' UNION ALL
  SELECT 5, borrowernumber, 7, NOW(), DATE_SUB(NOW(), INTERVAL 5 DAY) FROM borrowers WHERE cardnumber = 'C1';
INSERT INTO old_reserves (reserve_id, borrowernumber, biblionumber, timestamp)
  SELECT 1, borrowernumber, 1, '2020-03-01' FROM borrowers WHERE cardnumber = 'C1' UNION ALL
  SELECT 2, borrowernumber, 2, '2020-03-01' FROM borrowers WHERE cardnumber = 'S2';
INSERT INTO statistics (datetime, branch, type, itemnumber, borrowernumber) VALUES
  (NOW(), 'CPL', 'issue', 3, 1), (NOW(), 'CPL', 'issue', 3, 1), (NOW(), 'MPL', 'return', 3, 1);
INSERT INTO saved_sql (borrowernumber, date_created, savedsql, report_name, type, notes)
  VALUES (NULL, NOW(), 'SELECT 1', 'My own report', '1', 'written by the library');
SQL
}
tools_sql() { mysql -Nse "$1" "$DB"; }
