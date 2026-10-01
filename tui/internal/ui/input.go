package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// sidebarKeys jump straight to the sidebar entries, in order.
const sidebarKeys = "1234567890-"

func (m *Model) key(k tea.KeyMsg) tea.Cmd {
	s := k.String()
	if s == "ctrl+c" {
		m.cancelJob()
		return tea.Quit
	}
	if m.dlg != nil {
		return m.dialogKey(s)
	}

	// Global hotkeys.
	switch s {
	case "q":
		if m.running {
			m.ask("Quit?", m.jobTitle+" is still running and will be stopped.", "Quit",
				func(m *Model) tea.Cmd { m.cancelJob(); return tea.Quit })
			return nil
		}
		return tea.Quit
	case "tab":
		m.focus = (m.focus + 1) % nRegions
		return nil
	case "shift+tab":
		m.focus = (m.focus + nRegions - 1) % nRegions
		return nil
	case "s":
		return m.openURL("Staff interface", m.panel.StaffURL)
	case "o":
		return m.openURL("Public catalog (OPAC)", m.panel.OpacURL)
	case "p":
		return m.footerAction(actPanel)
	case "R":
		return m.footerAction(actRestart)
	case "t":
		return m.footerAction(actTerminal)
	case "X":
		return m.footerAction(actShutdown)
	case "r":
		if !m.checking {
			return m.checkStatus()
		}
		return nil
	case "l":
		if len(m.log) > 0 || m.running {
			m.showLog, m.focus = !m.showLog, rContent
		}
		return nil
	}
	if i := strings.Index(sidebarKeys, s); len(s) == 1 && i >= 0 && i < len(m.menu) {
		m.selectItem(i)
		m.focus = rSide
		return nil
	}

	switch m.focus {
	case rQuick:
		switch s {
		case "left", "h", "right":
			m.quick = 1 - m.quick
		case "down", "j":
			m.focus = rSide
		case "enter", " ":
			return m.quickAction(m.quick)
		}
	case rFooter:
		switch s {
		case "left", "h":
			m.foot = (m.foot + 3) % 4
		case "right":
			m.foot = (m.foot + 1) % 4
		case "up", "k":
			m.focus = rSide
		case "enter", " ":
			return m.footerAction(m.foot)
		}
	case rSide:
		switch s {
		case "up", "k":
			if m.sel == 0 {
				m.focus = rQuick
			} else {
				m.selectItem(m.sel - 1)
			}
		case "down", "j":
			if m.sel == len(m.menu)-1 {
				m.focus = rFooter
			} else {
				m.selectItem(m.sel + 1)
			}
		case "home", "g":
			m.selectItem(0)
		case "end", "G":
			m.selectItem(len(m.menu) - 1)
		case "right", "enter", " ":
			m.focus, m.showLog = rContent, false
		}
	case rContent:
		if m.showLog {
			return m.logKey(k)
		}
		n := len(m.buttons())
		switch s {
		case "up", "k":
			m.child = max(0, m.child-1)
		case "down", "j":
			m.child = min(n-1, m.child+1)
		case "left", "esc", "h":
			m.focus = rSide
		case "enter", " ":
			return m.activate(m.buttons()[m.child])
		}
	}
	return nil
}

func (m *Model) logKey(k tea.KeyMsg) tea.Cmd {
	switch k.String() {
	case "esc", "left", "b":
		m.showLog = false
		return nil
	case "c", "x":
		m.cancelJob()
		return nil
	}
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(k)
	return cmd
}

func (m *Model) dialogKey(s string) tea.Cmd {
	d := m.dlg
	switch s {
	case "left", "right", "tab", "shift+tab", "h", "l":
		if d.no != "" {
			d.focusNo = !d.focusNo
		}
	case "y":
		return m.closeDialog(true)
	case "n", "esc":
		return m.closeDialog(false)
	case "enter", " ":
		return m.closeDialog(!d.focusNo)
	}
	return nil
}

func (m *Model) quickAction(i int) tea.Cmd {
	if i == 0 {
		return m.openURL("Staff interface", m.panel.StaffURL)
	}
	return m.openURL("Public catalog (OPAC)", m.panel.OpacURL)
}

// ---- mouse ----------------------------------------------------------------

// Zone ids, marked in the view.
const (
	zStaff   = "quick:0"
	zOpac    = "quick:1"
	zRefresh = "hdr:refresh"
	zYes     = "dlg:yes"
	zNo      = "dlg:no"
	zBack    = "log:back"
	zCancel  = "log:cancel"
)

func zSide(i int) string    { return fmt.Sprintf("side:%d", i) }
func zContent(i int) string { return fmt.Sprintf("content:%d", i) }
func zFoot(i int) string    { return fmt.Sprintf("foot:%d", i) }

// hit returns the zone under the pointer, "" when none.
func (m *Model) hit(msg tea.MouseMsg) string {
	ids := []string{zYes, zNo}
	if m.dlg == nil {
		ids = []string{zStaff, zOpac, zRefresh, zBack, zCancel}
		for i := range m.menu {
			ids = append(ids, zSide(i))
		}
		for i := range m.buttons() {
			ids = append(ids, zContent(i))
		}
		for i := 0; i < 4; i++ {
			ids = append(ids, zFoot(i))
		}
	}
	for _, id := range ids {
		if m.zones.Get(id).InBounds(msg) {
			return id
		}
	}
	return ""
}

func (m *Model) mouse(msg tea.MouseMsg) tea.Cmd {
	id := m.hit(msg)
	switch {
	case msg.Action == tea.MouseActionMotion:
		m.hover = id
		return nil
	case msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown:
		return m.wheel(msg, id)
	case msg.Action != tea.MouseActionPress || msg.Button != tea.MouseButtonLeft:
		return nil
	}

	var n int
	switch {
	case id == zYes:
		return m.closeDialog(true)
	case id == zNo:
		return m.closeDialog(false)
	case id == zStaff, id == zOpac:
		m.focus, m.quick = rQuick, int(id[len(id)-1]-'0')
		return m.quickAction(m.quick)
	case id == zRefresh:
		if !m.checking {
			return m.checkStatus()
		}
	case id == zBack:
		m.showLog = false
	case id == zCancel:
		m.cancelJob()
	case scan(id, "side:%d", &n):
		m.selectItem(n)
		m.focus = rSide
	case scan(id, "content:%d", &n):
		m.focus, m.child = rContent, n
		return m.activate(m.buttons()[n])
	case scan(id, "foot:%d", &n):
		m.focus, m.foot = rFooter, n
		return m.footerAction(n)
	}
	return nil
}

func (m *Model) wheel(msg tea.MouseMsg, id string) tea.Cmd {
	up := msg.Button == tea.MouseButtonWheelUp
	switch {
	case strings.HasPrefix(id, "side:"):
		if up {
			m.selectItem(m.sel - 1)
		} else {
			m.selectItem(m.sel + 1)
		}
	case m.showLog:
		var cmd tea.Cmd
		m.vp, cmd = m.vp.Update(msg)
		return cmd
	case strings.HasPrefix(id, "content:"):
		if up {
			m.child = max(0, m.child-1)
		} else {
			m.child = min(len(m.buttons())-1, m.child+1)
		}
	}
	return nil
}

func scan(id, format string, n *int) bool {
	_, err := fmt.Sscanf(id, format, n)
	return err == nil
}
