package ui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/koha"
	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/platform"
)

func newTestModel(t *testing.T) *Model {
	t.Helper()
	m := New(koha.NewPanel(platform.Host{OS: "linux"}), true)
	m.Update(tea.WindowSizeMsg{Width: 100, Height: 32})
	return m
}

// render draws a frame and waits for bubblezone to record its zones.
func render(t *testing.T, m *Model, id string) {
	t.Helper()
	for i := 0; i < 50; i++ {
		m.View()
		if !m.zones.Get(id).IsZero() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("zone %s never rendered", id)
}

func click(t *testing.T, m *Model, id string) tea.Cmd {
	t.Helper()
	render(t, m, id)
	z := m.zones.Get(id)
	return m.mouse(tea.MouseMsg{X: z.StartX, Y: z.StartY, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft})
}

func TestClickSidebarSelects(t *testing.T) {
	m := newTestModel(t)
	click(t, m, zSide(6))
	if m.sel != 6 || m.focus != rSide {
		t.Fatalf("sel=%d focus=%d, want 6 and sidebar", m.sel, m.focus)
	}
}

func TestClickFooterAsksBeforeRestart(t *testing.T) {
	m := newTestModel(t)
	click(t, m, zFoot(actRestart))
	if m.dlg == nil || m.dlg.title != "Restart Koha?" {
		t.Fatal("restart did not ask first")
	}
	click(t, m, zNo)
	if m.dlg != nil || m.running {
		t.Fatal("cancel should close the dialog without running")
	}
}

func TestClickContentRunsInLog(t *testing.T) {
	m := newTestModel(t)
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("7")}) // Diagnostic & maintenance
	if cmd := click(t, m, zContent(0)); cmd == nil {
		t.Fatal("no job started")
	}
	if !m.running || !m.showLog || m.jobTitle != "Detailed server & Koha status" {
		t.Fatalf("running=%v showLog=%v title=%q", m.running, m.showLog, m.jobTitle)
	}
}

func TestKeyboardWalksRegions(t *testing.T) {
	m := newTestModel(t)
	m.key(tea.KeyMsg{Type: tea.KeyUp}) // top of the sidebar -> quick access
	if m.focus != rQuick {
		t.Fatalf("focus=%d, want quick access", m.focus)
	}
	m.key(tea.KeyMsg{Type: tea.KeyDown})
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("-")}) // last item
	m.key(tea.KeyMsg{Type: tea.KeyDown})
	if m.focus != rFooter {
		t.Fatalf("focus=%d, want footer", m.focus)
	}
}

func TestHeadlessPrintsURL(t *testing.T) {
	m := newTestModel(t)
	m.panel.Host = platform.Host{OS: "linux", SSH: true, ServerIP: "10.0.0.5"}
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	if m.dlg == nil || !strings.Contains(m.dlg.body, "http://10.0.0.5:8080/") {
		t.Fatalf("dialog = %+v", m.dlg)
	}
}

func TestEveryLayoutFitsTheScreen(t *testing.T) {
	m := newTestModel(t)
	for _, size := range [][2]int{{64, 22}, {80, 24}, {120, 40}, {200, 60}} {
		m.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
		for i := range m.menu {
			m.selectItem(i)
			if got := strings.Count(m.View(), "\n") + 1; got != size[1] {
				t.Fatalf("%dx%d item %d: %d rows", size[0], size[1], i, got)
			}
		}
	}
}
