# Test battery

Runs the panel's own functions against a **real MariaDB and Memcached**, with
test doubles only for what a container cannot have (the `koha-*` tools,
Koha's command-line scripts, `systemctl`, the Elasticsearch API) and for the
dialogs.

```bash
sudo apt-get install bats mariadb-server memcached whiptail \
                     yaz xsltproc libmarc-record-perl         # shellcheck is optional
sudo KEI_TEST_SANDBOX=1 tests/run.sh                           # everything
sudo KEI_TEST_SANDBOX=1 tests/run.sh tests/restore.bats        # one file
sudo KEI_TEST_SANDBOX=1 tests/run.sh -f 'R08' tests/restore.bats
```

**Disposable containers or VMs only.** The tests drop and recreate the
`koha_library` database and install the doubles in `/usr/sbin` and
`/usr/local/sbin`. `run.sh` refuses to run without `KEI_TEST_SANDBOX=1`, next
to a real `koha-common`, or while another run is in progress.

| File | What it covers |
|------|----------------|
| `restore.bats` | Empty, corrupt, truncated and non-Koha backups; MariaDB down, login refused, missing privileges; full or unwritable backup disk; not enough space; import, schema upgrade and MariaDB failing mid-restore (rollback); engine kept after restore; Koha DB user over socket and TCP |
| `signals_locks.bats` | CTRL+C, SIGHUP (lost SSH) and SIGTERM during the import; CTRL+C during the trial import; locks shared with the nightly backups; daemons never keeping the panel's locks |
| `indexing.bats` | Zebra watchdog (starts/unsticks `koha-indexer`, honours maintenance markers), health check, Elasticsearch watchdog following `SearchEngine`, indexing after restores (successful or rolled back) and engine switches, `koha-conf.xml` edits |
| `backup.bats` | Nightly SQL backup (DB down, full disk, size check), manual backup, "test latest backup" never touching production |
| `platform_services.bats` | Debian 11/12/13 and Ubuntu 22.04/24.04 on amd64/arm64, APT sources pinned to `dpkg --print-architecture`, boot order and readiness wait, ShellCheck, UTF-8, translations |
| `library_tools.bats` | Library tools: MARC import/undo, SQL reports pack, patron import, school-year turnover, data-quality check, anonymisation and patron deletion. Dry run before any change, lock, verified `PRE-*` backup before Koha writes, input checks, `koha-shell` quoting |
| `brazil.bats` | Brazil tools: CPF check digits, Easter and movable holidays, Biblivre/SophiA/Pergamum/custom MARC migration (Latin-1 to UTF-8, items moved to 952, existing 952 kept), `yaz` missing, legacy patron spreadsheets (Windows-1252, CPF as card number and attribute, `mawk`), CPF audit, Pimaco templates, cataloguing card through `xsltproc`, holidays in `special_holidays` and `library_single_closures`, nothing applied without being chosen |
| `schedules_ui.bats` | Nightly cleanup with `--confirm`, e-mail handed to `koha-email-enable` (and the upgrade of old schedules), dialog geometry, dark theme never exported, status markers, main menu |

`lib/panel.sh FUNCTION [ARGS]` loads the installer as a library (it opens no
menu when sourced), applies `lib/overrides.sh` and calls one function in its
own process, so the signal tests can interrupt it like a terminal would.
To document a regression, point `KEI_INSTALLER` at another copy of the
installer: `sudo KEI_TEST_SANDBOX=1 KEI_INSTALLER=/path/to/installer tests/run.sh`.
To run the panel under another Bash release (Debian 11 / Ubuntu 22.04 ship
5.1), set `KEI_BASH=/path/to/bash`.
