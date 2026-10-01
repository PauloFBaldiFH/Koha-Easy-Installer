// Package browser opens the Koha web interfaces: in the default browser on
// a desktop, or not at all on a headless/SSH session (the caller prints the
// URL instead).
package browser

import (
	"errors"
	"os/exec"

	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/platform"
)

// ErrHeadless means there is no screen to open a browser on.
var ErrHeadless = errors.New("no desktop session")

// Open starts the default browser on url without waiting for it. Its
// output is discarded so it never draws over the TUI.
func Open(h platform.Host, url string) error {
	if !h.Desktop {
		return ErrHeadless
	}
	cmd := command(h, url)
	if cmd == nil {
		return ErrHeadless
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait() //nolint:errcheck // reap the launcher; its result is not ours
	return nil
}

func command(h platform.Host, url string) *exec.Cmd {
	switch h.OS {
	case "windows":
		// Not "cmd /c start": it splits URLs on "&".
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		return exec.Command("open", url)
	case "linux":
		if h.WSL {
			if p, err := exec.LookPath("wslview"); err == nil {
				return exec.Command(p, url)
			}
			return exec.Command("explorer.exe", url)
		}
		if p, err := exec.LookPath("xdg-open"); err == nil {
			return exec.Command(p, url)
		}
	}
	return nil
}
