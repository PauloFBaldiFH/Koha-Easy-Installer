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

**Koha-Easy-Installer** is a production-grade Bash utility designed to eliminate the complexity of deploying, maintaining, and recovering Koha instances. It abstracts the orchestration of database configuration, Apache vhost routing, background indexers, security layers, and locale provisioning through an interactive, multi-language Terminal User Interface (TUI).

---

## ⚡ Quick Start

Execute the one-line installer directly in your terminal. Root privileges are required to provision system packages, Apache modules, and database daemons.

```bash
curl -fsSL [https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer](https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/refs/heads/main/installer) | sudo bash
