// Package platform tells where the TUI runs: which OS, inside WSL or not,
// over SSH or not, and whether a desktop is there to open a browser on.
package platform

import (
	"os"
	"runtime"
	"strings"
)

type Host struct {
	OS      string // runtime.GOOS
	WSL     bool   // Linux inside WSL (Windows opens the browser for it)
	SSH     bool   // a remote session: nothing can be opened on the user's screen
	Desktop bool   // a graphical session that can open the default browser
	// ServerIP is this machine's address as the SSH client reached it, so
	// the URLs printed over SSH work from the user's own browser.
	ServerIP string
}

func Detect() Host {
	h := Host{OS: runtime.GOOS}
	h.SSH = os.Getenv("SSH_CONNECTION") != "" || os.Getenv("SSH_CLIENT") != "" || os.Getenv("SSH_TTY") != ""
	// SSH_CONNECTION: client-ip client-port server-ip server-port
	if f := strings.Fields(os.Getenv("SSH_CONNECTION")); len(f) == 4 {
		h.ServerIP = f[2]
	}
	switch h.OS {
	case "windows", "darwin":
		h.Desktop = !h.SSH
	case "linux":
		h.WSL = isWSL()
		gui := os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != ""
		// X forwarding over SSH sets DISPLAY too; a browser opened that way
		// is slow and surprising, so SSH always counts as headless.
		h.Desktop = !h.SSH && (gui || h.WSL)
	}
	return h
}

// Label is the short mode shown in the header.
func (h Host) Label() string {
	switch {
	case h.SSH:
		return "SSH (headless)"
	case h.WSL:
		return "WSL"
	case h.Desktop:
		return "desktop"
	default:
		return "headless"
	}
}

func isWSL() bool {
	if os.Getenv("WSL_DISTRO_NAME") != "" {
		return true
	}
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	return err == nil && strings.Contains(strings.ToLower(string(b)), "microsoft")
}
