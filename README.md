<p align="right">
  🇺🇸 English &nbsp;|&nbsp; <a href="README.pt-BR.md">🇧🇷 Português</a>
</p>

<p align="center">
  <img src="docs/images/koha-logo-green.png" alt="Koha logo" width="320">
</p>

# Koha Easy Installer & Manager

A single Bash script that installs, tunes and maintains the **[Koha](https://koha-community.org/) Integrated Library System** on Debian/Ubuntu, through a friendly menu-driven control panel (whiptail, dark theme) available in **22 languages**.

It was born from real-life experience facing technical barriers in collection management, and is designed for libraries without budget for expensive commercial systems or dedicated technical support.

---

## Features

- **One-step installation** of Koha, MariaDB, Apache, Memcached and Plack, with pre-validation of the server (OS, disk, network, busy ports), 4 GB SWAP, NTP and timezone selection.
- **Backup center**: daily compressed SQL backups, weekly MARC21 export, manual backup with download instructions, restore test in a temporary database and cloud copies to Google Drive (rclone).
- **Safe restore** of `.sql` / `.sql.gz` backups: the file is checked (gzip test, complete mysqldump, Koha tables) and imported into a temporary database first; the current catalog is only replaced after a verified safety copy exists, is put back automatically if anything fails, and a restore cannot be left half-done by CTRL+C or a lost SSH connection.
- **Search engine**: switch between Zebra and Elasticsearch 7, indexer watchdog and repair/rebuild tools.
- **Publishing to the internet**: Cloudflare Tunnel (no open ports), free SSL certificate (Certbot) and a Google Search Console assistant.
- **QR code sign-in**: when Cloudflare or Google Drive asks you to authorize the server, the panel lets you choose how to open the page. Cloudflare offers a QR code to scan with your phone, the browser of this computer (the Windows browser under WSL) or a link to copy. Google Drive offers the browser or the link: Google only returns to the computer running rclone, so a phone cannot finish that login, and on a server with no screen the panel explains the SSH tunnel. The Google token is never shown on screen.
- **Diagnostics**: full health check with a detailed report, server status, real-time Apache log viewer and deep database maintenance.
- **Security**: Fail2ban, UFW firewall (with option to restrict the staff port 8080) and database password rotation.
- **Koha settings**: server sizing profiles, e-mail notices (Koha's own schedule, enabled with `koha-email-enable`), super librarian creation, SIP2 and Z39.50, clock and timezone.
- **Library tools**: guided MARC import with undo, essential SQL reports pack, patron import from CSV and school-year category turnover, catalog data-quality check, and privacy (LGPD) housekeeping. Every change is previewed first with Koha's own dry run and protected by a verified backup (see [Library tools](#library-tools)).
- **Brazil: localization & migration** (opt-in, never applied by the installation or by a schedule): MARC migration from Biblivre, SophiA and Pergamum (UTF-8 conversion, items moved to Koha's 952), collection spreadsheets (Biblioteca Fácil), legacy patron spreadsheets with CPF check, CPF audit (modulo 11), Pimaco label templates, the Brazilian cataloguing card (ficha catalográfica) and Brazilian holidays in the Koha calendar (see [Brazil: localization & migration](#brazil-localization--migration)).
- **Messaging: WhatsApp and Telegram** (opt-in): Koha's own notices (checkout, check-in, overdue, due, hold) delivered through a self-hosted WhatsApp gateway (Evolution API or similar) or a Telegram bot, with the patrons' numbers completed and corrected on the way (see [Messaging](#messaging-whatsapp-and-telegram)).
- **Cataloguing aids**: author notation with the PHA or Cutter-Sanborn table loaded by the library, Dewey (CDD) lookup, and a staff-interface page that replaces a record by its biblionumber without touching its items (see [Cataloguing aids](#cataloguing-aids-pha-cutter-sanborn-cdd) and [Replace a MARC record](#replace-a-marc-record-staff-interface)).
- **Windows 10/11 (WSL 2)**: Koha on a single Windows PC, with Start/Stop shortcuts that use the official Koha icon, a status icon, Windows notifications, one-click diagnostics and a disk watchdog (see [Windows (WSL 2)](#windows-wsl-2)).
- **Languages**: installs Koha language packs and translates the panel itself (22 languages).
- **Self-update** from GitHub with SHA-256 verification.

## Requirements

| Item | Minimum |
|------|---------|
| Operating system | Debian 11/12/13 or Ubuntu 22.04/24.04, 64-bit (amd64 or arm64, e.g. Oracle Ampere, AWS Graviton, Raspberry Pi 4/5), or Windows 10/11 through WSL 2 (see [Windows](#windows-wsl-2)) |
| RAM | 2 GB (4 GB+ recommended; Elasticsearch needs ~1.5 GB more) |
| Free disk | 5 GB (10 GB+ recommended) |
| Access | `root` or a user with `sudo` |
| Network | Internet access to `debian.koha-community.org` |
| Ports | 80 (OPAC) and 8080 (staff interface) free |

## Installation

```bash
wget https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer
sudo bash installer
```

Or clone the repository (this keeps the translation files next to the script and works offline):

```bash
git clone https://github.com/PauloFBaldiFH/Koha-Easy-Installer.git
cd Koha-Easy-Installer
sudo bash installer
```

On the first run you choose the panel language. Then pick **1 – Install Koha server** and follow the wizard (10 to 30 minutes).

After the installation the panel is available anywhere as:

```bash
sudo config.sh
```

### After installing

1. Open the staff interface at `http://SERVER-IP:8080`.
2. Log in with the database user and password shown at the end of the installation (also saved in `/root/koha_credentials.txt`) and complete Koha's **Web Installer**.
3. Back in the panel, create your own super librarian (**9 – Koha settings > Create super librarian**).
4. The public catalog (OPAC) is at `http://SERVER-IP:80`.

## Windows (WSL 2)

Koha can also run on a single Windows 10 or 11 PC. This suits small single-desk libraries, staff training and evaluations. Libraries with several desks should keep a dedicated Linux server.

Koha runs inside a Debian system in **WSL 2** (the Windows Subsystem for Linux), managed by the same panel. Small **PowerShell** tools let the librarian control it from Windows without opening a terminal.

### What works on Windows

- **WSL mode in the panel**: WSL 2 is detected automatically. WSL 1 is refused, with an explanation.
  - The host tasks are left to Windows: no swapfile, NTP, UFW, Fail2ban or avahi. The timezone follows Windows.
  - "Reboot server" becomes **Restart Koha services**.
  - systemd must be enabled in WSL.
  - The Windows side talks to the panel through `/etc/koha-easy-install/windows.conf`. It is read with a whitelist of keys and never executed.
- **Networking**: on Windows 11, WSL's mirrored networking lets other PCs on the network reach Koha. On Windows 10 (NAT), use the panel's built-in **Cloudflare Tunnel** to publish it.
- **Koha icon and shortcuts**: a *Koha* folder in the Start menu, with the staff interface and catalog links also on the desktop, all with the official `koha.ico`. It holds:
  - Staff interface, Public catalog, Control panel and Backups folder
  - **Start**, **Stop** and **Restart**
  - Status, Export diagnostics and Status icon
- **Start and stop**: Koha can start automatically when you sign in to Windows, or only when you click *Koha - Start*. Change this at any time from the tray menu. After **Stop**, Koha stays off until you start it again, and nothing starts it behind your back.
- **Status icon (notification area)**: the Koha icon with a coloured dot (green running, yellow starting, red not responding, grey stopped). The menu opens the staff interface and catalog, starts, stops and restarts Koha, and exports diagnostics.
- **Windows notifications**:
  - Koha stops responding, stops unexpectedly or recovers
  - the nightly backup succeeds (can be switched off), fails, or has not run for 36 hours
  - disk space runs low
- **Diagnostics in one click**: a `.zip` on the desktop with WSL, Windows, Apache, MariaDB, Koha and panel logs and the system status, ready to send to whoever supports your library. Passwords, tokens and keys are removed, and no configuration file is included.
- **Disk watchdog**: warns when the drive that holds Koha's virtual disk (`ext4.vhdx`) has less than 10 GB free, and critically below 5 GB. When the virtual disk holds a lot of unused space, **Compact** gives it back to Windows (needs administrator rights).
- **Languages**: the Windows tools use the panel's 22 languages.

### Installing on Windows today

> **Coming soon:** a one-click installer (`Install Koha.cmd`, a ZIP with a PowerShell bootstrapper). It will check virtualization, install WSL 2, create the Debian system, install Koha and set up the shortcuts, all in the librarian's language. It will come with a guide for the Windows SmartScreen warning, because the scripts are not signed. Until then, the steps below are for people comfortable with PowerShell.

1. In PowerShell as administrator: `wsl --install --no-distribution`, then restart Windows.
2. Create a Debian system named `KohaEasy` (the Windows tools look for that name). For example, install Debian from the Microsoft Store, then `wsl --export Debian debian.tar` and `wsl --import KohaEasy C:\KohaEasy\wsl debian.tar`.
3. Inside it (`wsl -d KohaEasy -u root`), enable systemd by adding `[boot]` and `systemd=true` to `/etc/wsl.conf`. Then run `wsl --terminate KohaEasy` in PowerShell and open it again.
4. Install Koha as on Linux ([Installation](#installation)).
5. Copy the `windows\` folder and `lang\` to `C:\KohaEasy\bin`, then run, as your normal user:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\KohaEasy\bin\KohaEasy.ps1 RegisterTasks -Mode logon
   ```

   This creates the start tasks, the Start menu and desktop shortcuts, and the status icon at sign-in. Use `-Mode manual` to start Koha only when you click *Koha - Start*.

Real-Windows behaviour (notifications, the tray, Task Scheduler and disk compaction) is still being checked on physical machines, so please report anything odd.

## Main menu

| # | Option | What it does |
|---|--------|--------------|
| 1 | Install Koha server | Complete installation and tuning |
| 2 | View first-access credentials | Addresses, user and password |
| 3 | Restore database | Imports a `.sql` / `.sql.gz` backup |
| 4 | Backup center | Manual backup, cloud backup, integrity test |
| 5 | Search engine & indexing | Zebra ⇄ Elasticsearch, repair indexes |
| 6 | Publish system to internet | Cloudflare Tunnel, SSL, Google Search Console |
| 7 | Diagnostics & maintenance | Status, health check, logs, optimization |
| 8 | Security center | Fail2ban, firewall, password rotation |
| 9 | Koha settings & parameters | Sizing, e-mail, super librarian, SIP2/Z39.50, clock |
| 10 | Library tools | MARC import/undo, SQL reports pack, patron import, school-year turnover, data-quality check, privacy (LGPD), Brazil: localization & migration, WhatsApp / Telegram messaging, cataloguing aids, replace a MARC record |
| 11 | General tools | htop/nethogs, terminal browser, file manager |
| 12 | Schedules & cron tasks | View, explain, regenerate or edit automated tasks |
| 13 | Koha languages | Koha language packs and panel language |
| 14 | Update center | System/Koha updates and panel self-update |
| 15 | About | Project information and support |
| 16 | Reboot server | |
| 17 | Exit | |

The dialogs use a dark theme, a fixed width and adapt to small terminals. For newt's default colours in a monochrome terminal, start the panel with `NO_COLOR=1`.

## Library tools

Day-to-day tasks for the library staff, run with Koha's own command-line tools as the instance user (`koha-shell library -c ...`). Anything that changes data follows the same steps: the backup/restore lock (no nightly backup or restore can run in the middle), a **preview** (Koha's own dry run), an explicit confirmation, a **verified `PRE-*` backup** in `/var/backups/koha_sql`, and only then the real run. The tools never stop Koha's services, and the `PRE-*` backup undoes any change (**Restore database**).

| Tool | Koha scripts | Preview | Backup |
|------|--------------|---------|--------|
| Import MARC records (ISO 2709 / MARCXML), keeping or replacing matching records | `stage_file.pl`, `commit_file.pl` | Staging report (nothing enters the catalog) | `PRE-IMPORT` |
| Undo a MARC import | `commit_file.pl --revert` | Records and items of the batch | `PRE-UNDO-IMPORT` |
| Essential SQL reports pack: 8 read-only reports (most borrowed, overdue with contacts, never borrowed, new acquisitions, expiring accounts, loans per month, items without barcode/call number, lost items), tagged so that updating or removing the pack never touches other reports | — (`saved_sql`) | Each query is checked against this Koha version | `PRE-REPORTS` |
| Import patrons from CSV (template in `/root/koha_patrons_template.csv`; UTF-8, commas) | `import_patrons.pl` | Native dry run: new, updated, skipped, invalid | `PRE-PATRONS` |
| School-year turnover: move patrons between categories (all, over the age limit, or registered before a date) | `update_patrons_category.pl` | Native dry run with the list of patrons | `PRE-PATRONS` |
| Catalog data-quality check (read-only) | `search_for_data_inconsistencies.pl` | — | — |
| Privacy (LGPD): anonymise old loan and hold history | `batch_anonymise.pl` | Counts computed like Koha does | `PRE-PRIVACY` |
| Privacy (LGPD): delete expired patrons who borrowed nothing since (typed confirmation) | `delete_patrons.pl` | Native dry run | `PRE-PRIVACY` |

Every run is logged in `/var/log/koha-easy-install/tools/` (readable by root only: the logs may contain patron names), also viewable from the menu.

### Brazil: localization & migration

**Library tools > Brazil: localization & migration**. Nothing here is applied during the installation or by a schedule: each option acts only when you choose it, follows the same steps as the other tools (lock, preview, confirmation, verified `PRE-*` backup) and can be undone.

| Tool | How it works | Preview | Backup |
|------|--------------|---------|--------|
| Migrate MARC from Biblivre, SophiA, Pergamum or another system (field map typed by hand) | Characters converted to UTF-8 with `yaz-marcdump` (from Latin-1 or MARC-8; the `yaz` package is offered when missing); the item field (Biblivre 949, Pergamum 852, SophiA 990 or your own map) is moved to Koha's 952 (barcode, call number, copy, notes, library, item type) with Koha's own MARC::Record; then the normal MARC import (`stage_file.pl` / `commit_file.pl`, undo with `--revert`) | Counts and a sample of the converted items, then Koha's staging report | `PRE-IMPORT` |
| Import patrons from a legacy spreadsheet | Finds the columns by their Portuguese or English names (Nome, Matrícula, CPF, E-mail, Nascimento...), Windows-1252 or UTF-8, `;` or `,`; checks the CPF (modulo 11, repeated digits, duplicates), uses it as card number when there is none and keeps it in a patron attribute with code `CPF` when that type exists; then `import_patrons.pl` | Rejected lines with the reason, then Koha's dry run | `PRE-PATRONS` |
| Migrate a collection spreadsheet (Biblioteca Fácil and other programs that export the collection to Excel / CSV) | Columns found by their usual names (Tombo, Título, Autor, Editora, Ano, ISBN, CDD, Cutter, Assunto, Exemplar, Tipo, Data de aquisição, Valor...), Windows-1252 or UTF-8; rows with the same title, author, edition, year and ISBN become one MARC 21 record (built with MARC::Record) with one item in 952 per row (tombo as barcode, CDD + Cutter as call number, item type by code or description); repeated barcodes are dropped; then the normal MARC import (undo with `--revert`) | Columns used and ignored, counts and a sample of the records, then Koha's staging report | `PRE-IMPORT` |
| Check patron CPFs (read-only) | Card number, username, sort1/sort2 or the `CPF` attribute: valid, invalid, shared by two patrons | — | — |
| Pimaco label templates | Sheets 6180, 6181, 6287 (Letter) and A4256, A4251 (A4) plus 3 layouts (spine, barcode, title and barcode) in Koha's label creator; updates or removes only its own templates | Summary before the change | `PRE-LABELS` |
| Cataloguing card (ficha catalográfica) | Stylesheets that wrap Koha's default detail view (OPAC and staff interface, one per installed language) and add the card below the record, with a print button; set in `OPACXSLTDetailsDisplay` / `XSLTDetailsDisplay`. The previous values are kept and **Hide the card** puts them back; the files are rewritten each time the panel starts, so they follow Koha updates | Old and new values | `PRE-FICHA` |
| Brazilian holidays in the calendar | National holidays of a year, Carnival (Monday and Tuesday), Good Friday and Corpus Christi (Easter by the Meeus/Jones/Butcher algorithm) and an optional municipal holiday, for one library or all; days already in the calendar are skipped and **Remove** takes out only the days added by the panel | Dates with the weekday | `PRE-CALENDAR` |

- The label sizes are the Avery equivalents of each Pimaco sheet: do a test print on plain paper first and adjust the template in Koha if your printer shifts the page.
- The card follows the AACR2 layout used by Brazilian libraries (call number column, hanging indent, numbered subjects, roman-numbered added entries).
- The Biblivre, SophiA and Pergamum presets follow their usual export layout. The preview shows the result before anything is written; **Other layout** accepts any item field.
- Carnival and Corpus Christi are *ponto facultativo*, not national holidays: remove them in Tools > Calendar if the library opens. Consciência Negra (20/11) is added from 2024 on.
- The Biblioteca Fácil preset reads a spreadsheet export; it was written from the usual column names, not from a real export of that program. The preview lists the columns it used and the ones it ignored before anything is written.

### Messaging: WhatsApp and Telegram

**Library tools > Messaging: WhatsApp and Telegram**. Koha already writes the notices (checkout, check-in, overdue, due, hold) and hands those of the SMS type to the SMS::Send driver named in the `SMSSendDriver` preference. The panel installs such a driver (`SMS::Send::KohaEasy::Gateway`): each notice goes to Telegram when the patron linked the library's bot, otherwise to WhatsApp. Nothing changes in Koha until **Send Koha notices** is turned on, and turning it off puts the previous `SMSSendDriver` back (verified `PRE-MESSAGING` backup both ways).

| Option | What it does |
|--------|--------------|
| WhatsApp gateway | A gateway of the library's own: Evolution API v2 (`POST /message/sendText/<instance>`, `apikey` header) or another one that accepts `{"number", "to", "text"}` with a Bearer token |
| Telegram bot | The token from @BotFather is checked with Telegram (`getMe`). Patrons open the bot, tap Start and share their own contact; a job every two minutes links the chat to the number (`/stop` undoes it) |
| Country and area code | Numbers are completed and corrected before sending: country code (Brazil by default, or any other), area code (DDD) for numbers without one, trunk and carrier prefixes removed, and the 9th digit of Brazilian mobiles added |
| Send a test message | Through the same SMS::Send path Koha uses, as the instance user |
| What Koha needs | Checks `SMSSendDriver`, the SMS versions of the notices, overdue rules with SMS and patrons with SMS numbers and preferences; offers to create short SMS versions of the notices that have none (`PRE-NOTICES`) |
| Check the patrons' phone numbers | Read-only report with the same rules; the corrected numbers are written only on confirmation (`PRE-PHONES`) |

The settings (with the tokens) are in `/etc/koha/sites/library/kei-messaging.conf`, readable by root and Koha only. When the notices are on, the SMS queue is also sent every two minutes (`/etc/cron.d/koha_messaging`).

### Cataloguing aids: PHA, Cutter-Sanborn, CDD

**Library tools > Cataloguing aids**, read-only for the catalogue.

- **Author notation**: the entry right before the name in the table, the initial of the surname, the number and the initial of the title (the initial article never counts, and a title starting with "l" gets a capital L); prefixes read as one word (La Fonte, O'Donnel) and M' / Mc as Mac; institutions by the first word and anonymous works by the first word of the title, as in the PHA explanation. From a catalogue record it reads 100 / 110 / 111, 245 (with its nonfiling indicator) and 082, and lists the call numbers that already use the same number in that class, with the free numbers right before and after it.
- **The tables are not distributed with the panel**: the PHA table (Heloísa de Almeida Prado, T. A. Queiroz) and the Cutter-Sanborn tables are copyrighted. Each library loads its own copy as a text file (one entry and its number per line; the PHA rows can be typed as printed, entry - number - entry). The file is checked before it is kept: entries per letter, numbers out of order (typing mistakes) and repeated entries.
- **CDD**: the ten main classes are built in; the library can load its own schedule (number and caption per line) to search by number or by word, and every lookup also shows how the catalogue already uses the number.

### Replace a MARC record (staff interface)

**Library tools > Replace a MARC record** installs `marc_replace.pl` in Koha's staff interface (`/cgi-bin/koha/tools/marc_replace.pl`, and optionally in the Edit menu of each record). It replaces a record, found by its biblionumber, with an `.mrc` or `.xml` file or pasted text (Biblioteca Nacional `245 10 |a`, MarcEdit or yaz-marcdump lines):

- login with the `edit_catalogue` permission and a CSRF token (Koha 24.05+ `cud-` operations);
- a preview first; then, in one transaction, the current record is locked and compared with the preview (nothing is replaced if it changed), saved as MARCXML in `/var/lib/koha/library/kei-marc-replace/` (downloadable from the page, and accepted back to undo) and replaced with Koha's `ModBiblio`;
- item fields in the file are always left out: the items are never touched;
- MARC-8 / Latin-1 files are converted by Koha's own `MarcToUTF8Record`.

The page is checked with Koha's Perl modules before it is installed; removing it keeps the saved versions.

#### AI cataloguing (photos of the book)

Two more tabs of the same page catalogue a book from photos of its cover, title page and verso of the title page (with the CIP block):

- **AI settings** (staff allowed to change the system preferences only): the vision model, either a cloud API with a token (OpenAI, Anthropic or any OpenAI-compatible service) or a model on the library's own network (Ollama `http://localhost:11434` or LM Studio `http://localhost:1234/v1` with a vision model such as `qwen2.5vl`, `llama3.2-vision` or `gemma3`). The settings are kept in `kei-marc-replace/vision.conf`, readable by the Koha instance user only; the token is never shown again, and a token is refused over plain `http` to a server outside the local network. **Test the connection** lists the models of the server. No token ships with the panel.
- **AI cataloguing**: the photos go to the model, which answers with the bibliographic data as JSON (checked against a fixed schema: nothing invented, placeholders dropped). The national rules are then applied by `KohaEasy::Cataloguing::Rules`: AACR2 and ISBD punctuation (245 `:` `/`, 260 with `[S.l.]` / `[s.n.]`, 300), names inverted as Brazilian cataloguers do (`Assis, Machado de`, `Andrade Filho, José de`), 245 non-filing characters, ISBN check digits (wrong ones go to 020 `$z`), the CDD printed in the CIP block (otherwise the model's suggestion, flagged for checking) in 082 and 090, and the **author notation of the library's own PHA or Cutter-Sanborn table**, computed by a Perl port of the panel's algorithm, so the page and **Cataloguing aids** give the same notation.
- The librarian corrects the draft next to the photos, and a **mandatory preview** follows. Only then is the record added with Koha's `AddBiblio`, in one transaction under a database lock, after the ISBN is checked against the catalogue again (a record with the same ISBN needs an explicit tick), with a copy of the record and of the model's answer saved in `kei-marc-replace/vision/`. A form sent twice adds nothing. With a biblionumber, the draft goes to the replacement above instead (with its lock and saved version).

The two modules are installed with the page in `/usr/local/lib/site_perl/KohaEasy/Cataloguing/` and removed with it (the settings stay with the saved versions).

## Automated tasks

Installed in `/etc/cron.d/koha_tasks`:

| When | Task |
|------|------|
| Daily 23:00 | Compressed SQL backup (verified, optional cloud upload) |
| Sundays 03:00 | MARC21 export of bibliographic and authority records |
| Daily 01:30 | Session and Zebra queue cleanup (`cleanup_database.pl --confirm`) |
| Daily 05:00 | Plack restart (keeps memory low) |
| Every 2 min | Zebra indexing watchdog: keeps Koha's indexer daemon (`koha-indexer`) running and restarts it if records wait more than 10 min |
| Every 5 min (Elasticsearch only) | Elasticsearch indexer watchdog |

E-mail notices are left to Koha's own schedule (`koha-common`): overdue and advance notices once a day and the message queue every 15 minutes, for the instance enabled with `koha-email-enable` (done at installation and in **Koha settings > Configure email**). Schedules written by older versions of the panel are upgraded automatically: the 01:30 cleanup gets `--confirm` (without it, it only reported what it would delete) and the old 08:00/08:05 e-mail jobs, which duplicated Koha's, are removed once e-mail is enabled.

## Important files

| Path | Content |
|------|---------|
| `/root/koha_credentials.txt` | First-access credentials |
| `/etc/koha/sites/library/koha-conf.xml` | Koha instance configuration |
| `/var/backups/koha_sql`, `/var/backups/koha_marc` | Local backups |
| `/etc/koha-easy-install/` | Panel settings (language, backup) |
| `/var/log/koha-easy-install/` | Panel, APT and validation logs (`tools/`: library tools, root only) |
| `/root/koha_patrons_template.csv` | Empty CSV template for the patron import |
| `/var/lib/koha/library/kei-xslt/` | Cataloguing card stylesheets (only while the card is enabled) |
| `/etc/koha/sites/library/kei-messaging.conf` | WhatsApp / Telegram settings and tokens (root and Koha only) |
| `/usr/local/lib/site_perl/SMS/Send/KohaEasy/Gateway.pm` | The messaging driver of Koha (with `KohaEasy/Messaging.pm`) |
| `/etc/koha-easy-install/tables/` | Author tables and CDD schedule loaded by the library |
| `/var/lib/koha/library/kei-marc-replace/` | Records as they were before each replacement |
| `/etc/koha-easy-install/windows.conf` | Windows only: what the Windows tools tell the panel (network mode, automatic start...) |
| `C:\KohaEasy\` | Windows only: `bin\` (scripts and `koha.ico`), `logs\`, `Backups\`, `state.json` |

If the installation stops, the panel shows the failed step. The full package manager output is in `/var/log/koha-easy-install/apt.log`.

## Uninstall

`uninstall.sh` **permanently deletes** Koha, its databases, local backups and settings, and asks for confirmation first:

```bash
sudo bash uninstall.sh          # asks you to type APAGAR to confirm
sudo bash uninstall.sh --yes    # no questions (automation)
```

Copy your backups somewhere else before running it.

## Tests (for contributors)

`tests/` has a [bats-core](https://github.com/bats-core/bats-core) battery that runs the panel against a real MariaDB: corrupt, truncated and empty backups, MariaDB down or refusing the login, full or unwritable disks, CTRL+C / lost SSH connection in the middle of a restore, locks shared with the nightly backups, indexing after engine switches and restores, Debian/Ubuntu releases on amd64/arm64, the library tools (dry run before any change, lock, verified backup, `koha-shell` quoting), the Brazil tools (Latin-1 MARC migration to 952, CPF check digits, movable holidays, label templates, cataloguing card, collection spreadsheets), the messaging driver (against a WhatsApp / Telegram test double), the author notation and CDD lookup, `marc_replace.pl` (run as a CGI), the schedule upgrade, the WSL mode, the QR code / browser / link sign-in, and the Windows tools (their PowerShell tests run with [Pester 5](https://pester.dev) when `pwsh` is installed).

```bash
sudo apt-get install bats mariadb-server memcached whiptail yaz xsltproc python3 \
     libmarc-record-perl libmarc-xml-perl libsms-send-perl libcgi-pm-perl libmodern-perl-perl
sudo KEI_TEST_SANDBOX=1 tests/run.sh
```

**Only on a disposable container or VM:** the tests replace the `koha_library` database and install test doubles for the `koha-*` tools and `systemctl`. `tests/run.sh` refuses to run next to a real Koha.

## Translations (for contributors)

The panel texts are in English inside `installer`; each language has a dictionary in `lang/<code>.cache` (`base64(English)|base64(translation)`). The panel itself is pure Bash; the Python scripts below are optional contributor tools.

- Wrap every user-visible text in `$(t "...")`. Variables must be escaped so the English text reaches `t()` unchanged: `$(t "Backup saved in \${file}")`.
- Check coverage and repair dictionaries: `python3 i18n_common.py` / `python3 i18n_common.py --fix`
- Translate only what is missing: `python3 gen_all_langs.py` (offline, Argos Translate) or `python3 gen_lang.py` (online).
- Translations that lose a variable or `%s` are rejected automatically and English is shown instead.

After changing `PANEL_VERSION`, run `python3 i18n_common.py --fix` (each dictionary is stamped with the panel version, and outdated dictionaries are only used as a last resort).

After changing `installer`, regenerate the checksum used by the self-update:

```bash
sha256sum installer > installer.sha256
```

## License

Koha Easy Installer & Manager is free software under the [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later), the same license as Koha itself. You can use, study, share and modify it; if you distribute modified versions, they must stay under the GPL with their source code available. It comes with **no warranty**.

## Support the project

- Pix (Brazil): `076.650.449.21`
- Bitcoin (BTC): `bc1qw0kvacdkzul0panuppxcv90y08ah443m2z89tx`
- ⭐ Star the repository and share it with other libraries.

---

Created with dedication by **Paulo F. Baldi FH** — Library Assistant, Castro Alves Public Library, Palotina, Paraná, Brazil.

<sub>The Koha name and logo belong to the Koha community (koha-community.org); this installer is an independent project.</sub>
