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
- **Safe restore** of `.sql` / `.sql.gz` backups, with a safety copy of the current database taken first, schema upgrade and reindexing.
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
| Operating system | Debian 11/12 or Ubuntu 22.04/24.04 (64-bit) |
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
