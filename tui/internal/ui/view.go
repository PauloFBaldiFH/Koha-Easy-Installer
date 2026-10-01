package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

const (
	minW = 64
	minH = 22
	// Rows taken by everything but the management panel's body: brand 1,
	// status card 3, quick access 4, panel borders + hint 3, actions 3,
	// key help 1.
	fixedRows = 15
	sepW      = 3 // " │ " between sidebar and content
)

// dims returns the sidebar and content widths and the panel body height.
func (m *Model) dims() (sideW, contentW, bodyH int) {
	inner := m.w - 4
	sideW = min(44, max(28, inner*2/5))
	return sideW, inner - sideW - sepW, m.h - fixedRows
}

func (m *Model) View() string {
	if m.w == 0 {
		return ""
	}
	if m.w < minW || m.h < minH {
		return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center,
			sMuted.Render(fmt.Sprintf("Terminal too small: %d×%d (need %d×%d)", m.w, m.h, minW, minH)))
	}
	screen := lipgloss.JoinVertical(lipgloss.Left,
		m.viewBrand(),
		m.viewStatus(),
		m.viewQuick(),
		m.viewPanel(),
		m.viewFooter(),
		m.viewHelp(),
	)
	if m.dlg != nil {
		screen = m.overlay(screen, m.viewDialog())
	}
	return m.zones.Scan(screen)
}

func (m *Model) viewBrand() string {
	left := sBrand.Render("◆ koha") + sText.Bold(true).Render(".nexus")
	right := sMuted.Render("Koha Easy Installer · install & manage")
	gap := max(1, m.w-lipgloss.Width(left)-lipgloss.Width(right)-2)
	return " " + left + strings.Repeat(" ", gap) + right
}

func (m *Model) viewStatus() string {
	color, text := cDim, "Checking Koha…"
	switch m.status.State {
	case "ok":
		color, text = cOK, "All services are running"
	case "degraded":
		color, text = cWarn, "Some services need attention"
	case "stopped":
		color, text = cBad, "Koha is stopped"
	case "not_installed":
		color, text = cWarn, "Koha is not installed"
	case "unknown":
		if !m.checking {
			color, text = cBad, "Status unavailable"
			if m.status.Err != nil {
				text += " (" + m.status.Err.Error() + ")"
			}
		}
	}
	dot := lipgloss.NewStyle().Foreground(color).Render("●")
	if m.checking {
		dot = m.spin.View()
	}
	meta := "Last verification: never"
	if !m.status.CheckedAt.IsZero() {
		meta = "Last verification " + m.status.CheckedAt.Format("15:04:05")
	}
	if !m.status.LastBackup.IsZero() {
		meta += "  |  Last backup " + m.status.LastBackup.Format("2006-01-02 15:04")
	} else if m.status.State != "not_installed" && m.status.State != "unknown" {
		meta += "  |  Last backup: none yet"
	}
	meta += "  |  " + m.panel.Host.Label()
	st := btnNormal
	if m.hover == zRefresh {
		st = btnHover
	}
	btn := m.zones.Mark(zRefresh, button([]string{"↻ Refresh"}, 11, st))
	inner := m.w - 4
	left := dot + " " + sTitle.Render(text) + "   " + sMuted.Render(meta)
	left = ansi.Truncate(left, inner-lipgloss.Width(btn)-1, "…")
	line := left + strings.Repeat(" ", max(1, inner-lipgloss.Width(left)-lipgloss.Width(btn))) + btn
	return card("", line, m.w, color)
}

func (m *Model) viewQuick() string {
	inner := m.w - 4
	bw := (inner - 1) / 2
	labels := [][]string{
		{"Staff interface  [s]", strings.TrimSuffix(strings.TrimPrefix(m.panel.StaffURL, "http://"), "/")},
		{"Public catalog (OPAC)  [o]", strings.TrimSuffix(strings.TrimPrefix(m.panel.OpacURL, "http://"), "/")},
	}
	var b []string
	for i, l := range labels {
		id := []string{zStaff, zOpac}[i]
		st := btnNormal
		switch {
		case m.focus == rQuick && m.quick == i:
			st = btnFocus
		case m.hover == id:
			st = btnHover
		case i == 0:
			st = btnPrimary
		}
		w := bw
		if i == 1 {
			w = inner - bw - 1
		}
		b = append(b, m.zones.Mark(id, button(l, w, st)))
	}
	return card("Quick access", lipgloss.JoinHorizontal(lipgloss.Top, b[0], " ", b[1]), m.w, m.border(rQuick))
}

func (m *Model) viewPanel() string {
	sideW, contentW, bodyH := m.dims()
	side := fit(m.viewSidebar(sideW, bodyH), sideW, bodyH)
	var content string
	if m.showLog {
		content = m.viewLog(contentW, bodyH)
	} else {
		content = m.viewContent(contentW, bodyH)
	}
	content = fit(content, contentW, bodyH)
	sep := sDim.Render(strings.TrimSuffix(strings.Repeat(" │ \n", bodyH), "\n"))
	body := lipgloss.JoinHorizontal(lipgloss.Top, side, sep, content)

	hint := "Click an option or use the arrows and Enter. Routines run right here, in this window."
	switch {
	case m.notice != "":
		hint = m.notice
	case m.running && !m.showLog:
		hint = m.spin.View() + " " + m.jobTitle + " is running. Press l to view its log."
	}
	return card("Management panel", body+"\n"+sMuted.Render(ansi.Truncate(hint, m.w-4, "…")), m.w, m.border(rSide, rContent))
}

func (m *Model) viewSidebar(w, h int) string {
	lines := make([]string, len(m.menu))
	for i, it := range m.menu {
		key := " "
		if i < len(sidebarKeys) {
			key = string(sidebarKeys[i])
		}
		chev := " "
		if len(it.Children) > 0 {
			chev = "›"
		}
		label := ansi.Truncate(it.Label, w-9, "…")
		pad := strings.Repeat(" ", max(0, w-9-ansi.StringWidth(label)))
		text := " " + it.Icon + "  " + label + pad + " " + chev + " " + key
		st := lipgloss.NewStyle().Foreground(cText).Width(w)
		switch {
		case i == m.sel && m.focus == rSide:
			st = st.Background(cFocus)
		case i == m.sel:
			st = st.Background(cSelect)
		case m.hover == zSide(i):
			st = st.Background(cHover)
		}
		bar := " "
		if i == m.sel {
			bar = lipgloss.NewStyle().Foreground(cAccent).Render("▌")
		}
		lines[i] = m.zones.Mark(zSide(i), bar+st.Width(w-1).Render(text))
	}
	return strings.Join(window(lines, m.sel, h), "\n")
}

func (m *Model) viewContent(w, h int) string {
	it := m.current()
	head := []string{sTitle.Render(it.Label), sMuted.Render(ansi.Truncate(it.Desc, w, "…")), ""}
	btns := m.buttons()
	gap := len(head)+2*len(btns)-1 <= h // room for a blank line between buttons
	var lines []string
	focusLine := 0
	for i, b := range btns {
		label := b.Label
		if len(it.Children) == 0 {
			label = "▶ Run: " + b.Label
		}
		if b.Streamed() {
			label += "  ≡"
		}
		if b.Confirm {
			label += "  (asks first)"
		}
		st := btnNormal
		switch {
		case m.focus == rContent && m.child == i:
			st = btnFocus
		case m.hover == zContent(i):
			st = btnHover
		}
		if i == m.child {
			focusLine = len(lines)
		}
		lines = append(lines, m.zones.Mark(zContent(i), row(label, w, st)))
		if gap && i < len(btns)-1 {
			lines = append(lines, "")
		}
	}
	return strings.Join(append(head, window(lines, focusLine, h-len(head))...), "\n")
}

func (m *Model) viewLog(w, h int) string {
	var title string
	switch {
	case m.running && m.job != nil:
		title = m.spin.View() + " " + sTitle.Render(m.jobTitle) + sMuted.Render("  running "+time.Since(m.job.Start).Round(time.Second).String())
	case m.jobErr != nil:
		title = lipgloss.NewStyle().Foreground(cBad).Render("✗ ") + sTitle.Render(m.jobTitle) + sMuted.Render("  failed: "+m.jobErr.Error())
	default:
		title = lipgloss.NewStyle().Foreground(cOK).Render("✓ ") + sTitle.Render(m.jobTitle) + sMuted.Render("  finished in "+m.jobTime.Round(time.Second).String())
	}
	bar := sDim.Render(strings.Repeat("─", w))
	if m.percent >= 0 {
		m.bar.Width = max(10, w-6)
		bar = m.bar.ViewAs(m.percent) + sMuted.Render(fmt.Sprintf(" %3.0f%%", m.percent*100))
	}
	m.vp.Width, m.vp.Height = w, max(1, h-3)
	back := btnNormal
	if m.hover == zBack {
		back = btnHover
	}
	btns := m.zones.Mark(zBack, button([]string{"◂ Back  esc"}, 13, back))
	if m.running {
		st := btnNormal
		if m.hover == zCancel {
			st = btnHover
		}
		btns += " " + m.zones.Mark(zCancel, button([]string{"■ Cancel  c"}, 13, st))
	}
	return strings.Join([]string{ansi.Truncate(title, w, "…"), ansi.Truncate(bar, w, ""), m.vp.View(), btns}, "\n")
}

func (m *Model) viewFooter() string {
	labels := []string{">_ Panel management", "↻ Restart Koha", ">_ Open terminal", "■ Safe shutdown"}
	inner := m.w - 4
	bw := (inner - (len(labels) - 1)) / len(labels)
	var b []string
	for i, l := range labels {
		st := btnNormal
		switch {
		case m.focus == rFooter && m.foot == i:
			st = btnFocus
		case m.hover == zFoot(i):
			st = btnHover
		}
		w := bw
		if i == len(labels)-1 {
			w = inner - (bw+1)*(len(labels)-1)
		}
		b = append(b, m.zones.Mark(zFoot(i), button([]string{l}, w, st)))
	}
	return card("Actions", strings.Join(b, " "), m.w, m.border(rFooter))
}

func (m *Model) viewHelp() string {
	keys := "tab focus · ↑↓←→ move · enter run · s staff · o opac · p panel · R restart · t terminal · X shutdown · r refresh · q quit"
	return " " + sDim.Render(ansi.Truncate(keys, m.w-2, "…"))
}

func (m *Model) viewDialog() string {
	d := m.dlg
	w := min(64, m.w-8)
	yesSt, noSt := btnFocus, btnNormal
	if d.focusNo {
		yesSt, noSt = btnNormal, btnFocus
	}
	if m.hover == zYes && yesSt != btnFocus {
		yesSt = btnHover
	}
	if m.hover == zNo && noSt != btnFocus {
		noSt = btnHover
	}
	btns := m.zones.Mark(zYes, button([]string{d.yes}, 12, yesSt))
	if d.no != "" {
		btns = m.zones.Mark(zNo, button([]string{d.no}, 12, noSt)) + "  " + btns
	}
	body := lipgloss.NewStyle().Width(w - 4).Render(sTitle.Render(d.title) + "\n\n" + sText.Render(d.body))
	inner := lipgloss.JoinVertical(lipgloss.Right, body, "", btns)
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cFocus).
		Padding(1, 2).Width(w).Render(inner)
}

// overlay centres box over a dimmed copy of screen.
func (m *Model) overlay(screen, box string) string {
	bg := strings.Split(ansi.Strip(screen), "\n")
	fg := strings.Split(box, "\n")
	bw := lipgloss.Width(box)
	x, y := max(0, (m.w-bw)/2), max(0, (len(bg)-len(fg))/2)
	for i := range bg {
		line := bg[i]
		if i < y || i >= y+len(fg) {
			bg[i] = sDim.Render(line)
			continue
		}
		left := ansi.Truncate(line, x, "")
		left += strings.Repeat(" ", x-ansi.StringWidth(left))
		right := ansi.TruncateLeft(line, x+bw, "")
		bg[i] = sDim.Render(left) + fg[i-y] + sDim.Render(right)
	}
	return strings.Join(bg, "\n")
}

// border colours a section by whether it has the keyboard.
func (m *Model) border(rs ...region) lipgloss.Color {
	for _, r := range rs {
		if m.focus == r && m.dlg == nil {
			return cFocus
		}
	}
	return cBorder
}

// window cuts lines to h, scrolled so line focus stays visible.
func window(lines []string, focus, h int) []string {
	if h <= 0 {
		return nil
	}
	if len(lines) <= h {
		return lines
	}
	off := min(max(0, focus-h+1), len(lines)-h)
	return lines[off : off+h]
}

// hyperlink makes url clickable in terminals that support OSC 8.
func hyperlink(url string) string {
	return ansi.SetHyperlink(url) + sURL.Render(url) + ansi.ResetHyperlink()
}
