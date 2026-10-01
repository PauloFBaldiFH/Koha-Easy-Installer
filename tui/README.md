# koha.nexus (terminal dashboard)

A single-window replacement for the Koha window (`windows/KohaEasy.Window.ps1`),
built with [Bubble Tea](https://github.com/charmbracelet/bubbletea),
[Lip Gloss](https://github.com/charmbracelet/lipgloss) and
[Bubbles](https://github.com/charmbracelet/bubbles). The same binary runs in
Windows Terminal, a Linux desktop terminal and over SSH on a headless server.

```
go run . --demo          # try the layout anywhere; every routine is simulated
go build -o koha-nexus . # GOOS=windows for koha-nexus.exe
```

Flags: `--panel` (panel path inside Linux), `--distro` (WSL distro, Windows),
`--staff-url`, `--opac-url`.

## Layout

| Section | Mouse | Keyboard |
| --- | --- | --- |
| Header: status from `config.sh --status-json`, refreshed every minute | Refresh button | `r` |
| Quick access: staff interface, OPAC | click | `s`, `o`, or ←→ Enter |
| Sidebar: the panel's main menu | click, wheel | ↑↓, `1`–`0`, `-` |
| Content: the selected group's routines, or the log | click, wheel | ↑↓ Enter, Esc back, `l` log, `c` cancel |
| Actions: panel, restart, terminal, safe shutdown | click | `p`, `R`, `t`, `X` |

Tab / Shift+Tab move between sections; `q` quits.

## How routines run

Nothing opens another window.

* **Streamed** (`Item.Args`): non-interactive panel commands
  (`--rebuild-search-index`, `--export-diagnostics`). Output goes to the
  log viewer in the content area, with a spinner and a progress bar when
  the output carries a percentage.
* **Interactive** (`Item.Run`): the panel's own whiptail routines
  (`config.sh --run <action>`). The dashboard hands them this terminal and
  comes back when they end.

On Windows every command goes through `wsl.exe -d koha -u root`, as
`Get-KohaPanelLaunch` does. On Linux it runs as root, through `sudo` when
needed (streamed commands use `sudo -n`, so start the dashboard with sudo
or have a cached sudo ticket).

## Browser

On a desktop (Windows, Linux with `DISPLAY`/`WAYLAND_DISPLAY`, WSL) the
quick-access buttons open the default browser (`rundll32`, `xdg-open`,
`wslview`). Over SSH or on a headless server they show the address instead,
with `localhost` replaced by the server's IP and an `ssh -L` hint.

## Code

```
main.go                 flags, program setup (alt screen, mouse)
internal/platform       OS / WSL / SSH / desktop detection
internal/browser        open a URL or report headless
internal/koha           menu tree, panel commands, status JSON
internal/runner         streamed and interactive jobs
internal/ui             model, input (keys + mouse zones), view, styles
```
