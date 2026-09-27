<div align="right">
  <strong><a href="#-versão-em-português">🇧🇷 Português</a></strong>
</div>

<div align="center">

# Koha-Easy-Installer

**Automated deployment and lifecycle management toolkit for Koha Integrated Library System (ILS).**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-orange.svg)](#system-requirements)
[![Release](https://img.shields.io/badge/Release-v0.9.3--beta-green.svg)](https://github.com/PauloFBaldiFH/Koha-Easy-Installer/releases)
[![ShellCheck](https://img.shields.io/badge/Shell-Bash%204.0%2B-blue)](https://www.gnu.org/software/bash/)

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#system-requirements">Requirements</a> •
  <a href="#architecture--features">Architecture</a> •
  <a href="#maintenance--security">Maintenance</a>
</p>

</div>

---

## Overview

**Koha-Easy-Installer** is a production-grade Bash utility designed to simplify the deployment, maintenance, configuration, and recovery of **Koha Integrated Library System (ILS)** environments.

It provides an interactive, multi-language Terminal User Interface (TUI) that centralizes system administration tasks, including database configuration, Apache routing, indexing services, security hardening, backups, maintenance, and locale provisioning.

---

## ⚡ Quick Start

The installer can be downloaded and executed directly from the terminal.

**Root privileges are required** because the installer provisions system packages, configures Apache and database services, and performs system-level operations.

### One-line installation

Copy and paste the following command directly into your terminal:

```bash
curl -fsSL "https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer" | sudo bash
```

The command downloads the latest version of the installer from the official GitHub repository and immediately starts the interactive setup.

> **⚠️ Security note:** Piping a remotely downloaded script directly into `sudo bash` executes the current contents of the referenced GitHub file with root privileges. If you prefer to inspect the script first, download it separately:

```bash
curl -fsSL "https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer" -o installer
```

Then review it and execute it with:

```bash
sudo bash installer
```

### Repository

**GitHub:**
https://github.com/PauloFBaldiFH/Koha-Easy-Installer

---

## 🇧🇷 Versão em Português

O **Koha-Easy-Installer** é uma ferramenta Bash desenvolvida para simplificar a instalação, configuração, manutenção e recuperação do **Koha Integrated Library System (ILS)**.

A ferramenta oferece uma interface interativa de terminal (TUI) e centraliza tarefas administrativas como configuração do banco de dados, Apache, indexação, backups, segurança, manutenção e suporte a múltiplos idiomas.

### ⚡ Início rápido

Para instalar diretamente pelo terminal, execute:

```bash
curl -fsSL "https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer" | sudo bash
```

Ou, para baixar primeiro e revisar o arquivo antes da execução:

```bash
curl -fsSL "https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer" -o installer
```

Depois:

```bash
sudo bash installer
```

---

## System Requirements

* **Debian** or **Ubuntu**
* **Bash 4.0+**
* Root or `sudo` privileges
* Internet connection
* Minimum system resources appropriate for the Koha installation and expected workload

---

## Architecture & Features

The installer is designed as a centralized management layer for Koha environments, providing tools for:

* Koha installation and configuration
* Database management
* Apache configuration
* Search and indexing services
* Backup and restoration
* System diagnostics
* Security configuration
* Maintenance and updates
* Localization and language support
* Service management
* Interactive terminal administration

---

## Maintenance & Security

The project is intended for administrators who need a repeatable and centralized way to deploy and maintain Koha installations.

Before running any remotely downloaded script with administrative privileges, users are encouraged to inspect the source code and verify the repository and release being used.

---

## License

This project is distributed under the **GNU General Public License v3.0**.

See [LICENSE](LICENSE) for the complete license text.
