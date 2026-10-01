// Command koha-nexus is the Koha Easy Installer dashboard for the
// terminal: one window, mouse and keyboard, on Windows Terminal, a Linux
// desktop or a headless server over SSH.
package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/koha"
	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/platform"
	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/ui"
)

func main() {
	p := koha.NewPanel(platform.Detect())
	demo := flag.Bool("demo", false, "simulate every routine (try the layout without Koha)")
	flag.StringVar(&p.Path, "panel", p.Path, "the Koha panel inside Linux")
	flag.StringVar(&p.Distro, "distro", p.Distro, "the WSL distro (Windows only)")
	flag.StringVar(&p.StaffURL, "staff-url", p.StaffURL, "staff interface address")
	flag.StringVar(&p.OpacURL, "opac-url", p.OpacURL, "public catalog address")
	flag.Parse()

	prog := tea.NewProgram(ui.New(p, *demo), tea.WithAltScreen(), tea.WithMouseAllMotion())
	if _, err := prog.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "koha-nexus:", err)
		os.Exit(1)
	}
}
