<p align="right">
  🇺🇸 English &nbsp;|&nbsp; <a href="README.pt-BR.md">🇧🇷 Português</a>
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
- **Diagnostics**: full health check with a detailed report, server status, real-time Apache log viewer and deep database maintenance.
- **Security**: Fail2ban, UFW firewall (with option to restrict the staff port 8080) and database password rotation.
- **Koha settings**: server sizing profiles, e-mail notices (Koha's own schedule, enabled with `koha-email-enable`), super librarian creation, SIP2 and Z39.50, clock and timezone.
- **Library tools**: guided MARC import with undo, essential SQL reports pack, patron import from CSV and school-year category turnover, catalog data-quality check, and privacy (LGPD) housekeeping. Every change is previewed first with Koha's own dry run and protected by a verified backup (see [Library tools](#library-tools)).
- **Languages**: installs Koha language packs and translates the panel itself (22 languages).
- **Self-update** from GitHub with SHA-256 verification.

## Requirements

| Item | Minimum |
|------|---------|
| Operating system | Debian 11/12/13 or Ubuntu 22.04/24.04, 64-bit (amd64 or arm64, e.g. Oracle Ampere, AWS Graviton, Raspberry Pi 4/5) |
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
| 10 | Library tools | MARC import/undo, SQL reports pack, patron import, school-year turnover, data-quality check, privacy (LGPD) |
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

If the installation stops, the panel shows the failed step. The full package manager output is in `/var/log/koha-easy-install/apt.log`.

## Uninstall

`uninstall.sh` **permanently deletes** Koha, its databases, local backups and settings, and asks for confirmation first:

```bash
sudo bash uninstall.sh          # asks you to type APAGAR to confirm
sudo bash uninstall.sh --yes    # no questions (automation)
```

Copy your backups somewhere else before running it.

## Tests (for contributors)

`tests/` has a [bats-core](https://github.com/bats-core/bats-core) battery that runs the panel against a real MariaDB: corrupt, truncated and empty backups, MariaDB down or refusing the login, full or unwritable disks, CTRL+C / lost SSH connection in the middle of a restore, locks shared with the nightly backups, indexing after engine switches and restores, Debian/Ubuntu releases on amd64/arm64, the library tools (dry run before any change, lock, verified backup, `koha-shell` quoting) and the schedule upgrade.

```bash
sudo apt-get install bats mariadb-server memcached whiptail
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
