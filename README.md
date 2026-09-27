<p align="right">
  🇺🇸 English &nbsp;|&nbsp; <a href="README.pt-BR.md">🇧🇷 Português</a>
</p>

# Koha Easy Installer & Manager

A single Bash script that installs, tunes and maintains the **[Koha](https://koha-community.org/) Integrated Library System** on Debian/Ubuntu, through a friendly menu-driven control panel (whiptail) available in **22 languages**.

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
- **Koha settings**: server sizing profiles, e-mail/overdue notices, super librarian creation, SIP2 and Z39.50, clock and timezone.
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
| 10 | General tools | htop/nethogs, terminal browser, file manager |
| 11 | Schedules & cron tasks | View, explain, regenerate or edit automated tasks |
| 12 | Koha languages | Koha language packs and panel language |
| 13 | Update center | System/Koha updates and panel self-update |
| 14 | About | Project information and support |
| 15 | Reboot server | |
| 16 | Exit | |

## Automated tasks

Installed in `/etc/cron.d/koha_tasks`:

| When | Task |
|------|------|
| Daily 23:00 | Compressed SQL backup (verified, optional cloud upload) |
| Sundays 03:00 | MARC21 export of bibliographic and authority records |
| Daily 01:30 | Session and database cleanup |
| Daily 05:00 | Plack restart (keeps memory low) |
| Daily 08:00 / 08:05 | Overdue notices and e-mail queue |
| Every 2 min | Zebra indexing watchdog: keeps Koha's indexer daemon (`koha-indexer`) running and restarts it if records wait more than 10 min |
| Every 5 min (Elasticsearch only) | Elasticsearch indexer watchdog |

## Important files

| Path | Content |
|------|---------|
| `/root/koha_credentials.txt` | First-access credentials |
| `/etc/koha/sites/library/koha-conf.xml` | Koha instance configuration |
| `/var/backups/koha_sql`, `/var/backups/koha_marc` | Local backups |
| `/etc/koha-easy-install/` | Panel settings (language, backup) |
| `/var/log/koha-easy-install/` | Panel, APT and validation logs |

If the installation stops, the panel shows the failed step. The full package manager output is in `/var/log/koha-easy-install/apt.log`.

## Uninstall

`uninstall.sh` **permanently deletes** Koha, its databases, local backups and settings, and asks for confirmation first:

```bash
sudo bash uninstall.sh          # asks you to type APAGAR to confirm
sudo bash uninstall.sh --yes    # no questions (automation)
```

Copy your backups somewhere else before running it.

## Tests (for contributors)

`tests/` has a [bats-core](https://github.com/bats-core/bats-core) battery that runs the panel against a real MariaDB: corrupt, truncated and empty backups, MariaDB down or refusing the login, full or unwritable disks, CTRL+C / lost SSH connection in the middle of a restore, locks shared with the nightly backups, indexing after engine switches and restores, Debian/Ubuntu releases on amd64/arm64.

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

## Support the project

- Pix (Brazil): `076.650.449.21`
- Bitcoin (BTC): `bc1qw0kvacdkzul0panuppxcv90y08ah443m2z89tx`
- ⭐ Star the repository and share it with other libraries.

---

Created with dedication by **Paulo F. Baldi FH** — Library Assistant, Castro Alves Public Library, Palotina, Paraná, Brazil.
