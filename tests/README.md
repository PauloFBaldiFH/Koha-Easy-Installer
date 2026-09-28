# Test battery

Runs the panel's own functions against a **real MariaDB and Memcached**, with
test doubles only for what a container cannot have (the `koha-*` tools,
Koha's command-line scripts, `systemctl`, the Elasticsearch API) and for the
dialogs.

```bash
sudo apt-get install bats mariadb-server memcached whiptail yaz xsltproc python3 \
     libmarc-record-perl libmarc-xml-perl libsms-send-perl \
     libcgi-pm-perl libmodern-perl-perl                        # shellcheck is optional
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
| `modules.bats` | Library tools 11-13 and collection spreadsheets: phone sanitizer (country and area code, 9th digit, DDD), the SMS::Send driver run by the real SMS::Send against `mocks/http-mock` (Evolution API, Telegram `getMe` / `getUpdates` / `sendMessage`, own-contact linking), `SMSSendDriver` saved and restored, SMS notices created only where missing, phone corrections; author tables (rows of the book, order checks) and notation rules, collisions in the catalogue, CDD lookup; Biblioteca Fácil spreadsheet to MARC 21 with items in 952; `marc_replace.pl` as a CGI with the Koha doubles of `mocks/perl5` (permission, CSRF, preview, locked transaction, saved versions, item fields left out, formats, escaping) and its installation with the IntranetUserJS link; the AI cataloguing tabs against a vision model on `mocks/http-mock` (OpenAI-compatible and Ollama): rules applied (PHA notation identical to the panel's, CDD of the CIP, AACR2 punctuation, ISBN check digits), text of the model escaped, mandatory preview, `AddBiblio` under a lock in one transaction with the ISBN checked again and a copy saved, a form sent twice, settings only with `manage_sysprefs` and the token never shown |
| `auth_links.bats` | Authorization links for Cloudflare Tunnel and rclone (Google Drive): the link caught from the tool's output and refused if unusual, the methods offered (QR code only where the answer can come from another device, the browser of this computer on a Linux desktop or under WSL, the link always), switching method while waiting, CTRL+C stopping the tool, the Google token captured without being shown and its file removed |
| `wsl_mode.bats` | Windows (WSL) mode: WSL 1 / WSL 2 / Linux detection, the `windows.conf` handshake (whitelisted keys, never executed, unsafe files refused), `host_can`, and the host tasks left to Windows: no swapfile, NTP, UFW, Fail2ban or avahi, timezone following Windows, "Restart Koha services" instead of a reboot, systemd required as PID 1 |
| `windows_tools.bats` | Commands the Windows tools call: `--status-json` (overall state, services, staff page, nightly backup result) and `--export-diagnostics` (private folder, passwords and tokens redacted, no configuration files), both running next to an open panel; the handshake written by PowerShell read by the panel's parser; the Pester tests of `tests/windows` (Start/Stop, automatic start, tray notifications, disk watchdog, diagnostics .zip, Windows PowerShell 5.1 syntax) when `pwsh` and Pester 5 are installed |
| `schedules_ui.bats` | Nightly cleanup with `--confirm`, e-mail handed to `koha-email-enable` (and the upgrade of old schedules), dialog geometry, dark theme never exported, status markers, main menu |

`lib/cgi-run SCRIPT GET|POST [name=value | name=@FILE]` runs a CGI script like the web server would (multipart uploads included).
`lib/panel.sh FUNCTION [ARGS]` loads the installer as a library (it opens no
menu when sourced), applies `lib/overrides.sh` and calls one function in its
own process, so the signal tests can interrupt it like a terminal would.
To document a regression, point `KEI_INSTALLER` at another copy of the
installer: `sudo KEI_TEST_SANDBOX=1 KEI_INSTALLER=/path/to/installer tests/run.sh`.
To run the panel under another Bash release (Debian 11 / Ubuntu 22.04 ship
5.1), set `KEI_BASH=/path/to/bash`.
