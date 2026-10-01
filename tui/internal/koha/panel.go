package koha

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"time"

	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/platform"
)

// Panel reaches the installed panel: directly on Linux, through WSL on
// Windows (the same call as Get-KohaPanelLaunch in KohaEasy.Core.psm1).
type Panel struct {
	Host     platform.Host
	Path     string // the panel inside Linux
	Distro   string // the WSL distro, Windows only
	WinRoot  string // the Windows tools' folder (KohaEasy.ps1), Windows only
	StaffURL string
	OpacURL  string
}

func NewPanel(h platform.Host) Panel {
	p := Panel{
		Host:     h,
		Path:     "/usr/local/bin/config.sh",
		Distro:   "koha",
		WinRoot:  `C:\KohaEasy`,
		StaffURL: "http://localhost:8080/",
		OpacURL:  "http://localhost/",
	}
	if h.OS == "windows" {
		p.Path = "/usr/local/bin/koha-panel"
	}
	if v := os.Getenv("KOHAEASY_ROOT"); v != "" {
		p.WinRoot = v
	}
	return p
}

var actionRe = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// ErrBadAction refuses anything but a plain action name.
var ErrBadAction = errors.New("invalid panel action")

// RunCmd is the panel straight on one routine (interactive). An empty
// action opens the panel's main menu.
func (p Panel) RunCmd(action string) (*exec.Cmd, error) {
	if action == "" {
		return p.command(nil, true), nil
	}
	if !actionRe.MatchString(action) {
		return nil, ErrBadAction
	}
	return p.command(nil, true, "--run", action), nil
}

// StreamCmd is a non-interactive panel command for the log viewer.
func (p Panel) StreamCmd(ctx context.Context, args ...string) *exec.Cmd {
	return p.command(ctx, false, args...)
}

// ShellCmd is a shell on the Koha server, in this terminal.
func (p Panel) ShellCmd() *exec.Cmd {
	if p.Host.OS == "windows" {
		return exec.Command("wsl.exe", "-d", p.Distro, "--cd", "~")
	}
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/sh"
	}
	return exec.Command(sh)
}

// ShutdownCmd stops Koha cleanly and powers the machine off.
func (p Panel) ShutdownCmd() *exec.Cmd {
	if p.Host.OS == "windows" {
		return exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
			"-File", filepath.Join(p.WinRoot, "KohaEasy.ps1"), "SafeShutdown")
	}
	return p.root(nil, true, "systemctl", "poweroff")
}

// command builds "<panel> args..." as root. With interactive false, sudo
// must not prompt (there is no terminal to prompt on).
func (p Panel) command(ctx context.Context, interactive bool, args ...string) *exec.Cmd {
	if p.Host.OS == "windows" {
		a := []string{"-d", p.Distro, "-u", "root", "--cd", "/root", "--", "env", "KEI_PLAIN_GLYPHS=0", p.Path}
		return mk(ctx, "wsl.exe", append(a, args...)...)
	}
	return p.root(ctx, interactive, p.Path, args...)
}

func (p Panel) root(ctx context.Context, interactive bool, name string, args ...string) *exec.Cmd {
	if os.Geteuid() == 0 {
		return mk(ctx, name, args...)
	}
	a := []string{name}
	if !interactive {
		a = []string{"-n", name}
	}
	return mk(ctx, "sudo", append(a, args...)...)
}

func mk(ctx context.Context, name string, args ...string) *exec.Cmd {
	if ctx == nil {
		return exec.Command(name, args...)
	}
	return exec.CommandContext(ctx, name, args...)
}

// Status is the panel's own view of Koha (config.sh --status-json).
type Status struct {
	State      string // ok | degraded | stopped | not_installed | unknown
	Version    string
	LastBackup time.Time
	CheckedAt  time.Time
	Err        error
}

func (p Panel) Status(ctx context.Context) Status {
	st := Status{State: "unknown", CheckedAt: time.Now()}
	if p.Host.OS != "windows" {
		// No panel copy yet: nothing was installed, and no sudo is needed
		// to say so.
		if _, err := os.Stat(p.Path); errors.Is(err, os.ErrNotExist) {
			st.State = "not_installed"
			return st
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := p.StreamCmd(ctx, "--status-json").Output()
	if err != nil {
		st.Err = err
		if p.Host.OS == "windows" {
			// The distro or the panel inside it is missing.
			st.State = "not_installed"
		}
		return st
	}
	var js struct {
		State        string `json:"state"`
		PanelVersion string `json:"panel_version"`
		Backup       struct {
			LastEpoch int64 `json:"last_epoch"`
		} `json:"backup"`
	}
	if err := json.Unmarshal(out, &js); err != nil {
		st.Err = err
		return st
	}
	st.State, st.Version = js.State, js.PanelVersion
	if js.Backup.LastEpoch > 0 {
		st.LastBackup = time.Unix(js.Backup.LastEpoch, 0)
	}
	return st
}
