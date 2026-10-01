// Package ui is the dashboard: header, quick access, the management panel
// (sidebar + content) and the actions footer, driven by mouse and keyboard.
package ui

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	zone "github.com/lrstanley/bubblezone"

	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/browser"
	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/koha"
	"github.com/PauloFBaldiFH/Koha-Easy-Installer/tui/internal/runner"
)

type region int

const (
	rQuick region = iota
	rSide
	rContent
	rFooter
	nRegions
)

const maxLogLines = 5000

// footer actions, in order.
const (
	actPanel = iota
	actRestart
	actTerminal
	actShutdown
)

type statusMsg koha.Status
type statusTickMsg struct{}

// dialog is a modal question (or a notice when no is empty).
type dialog struct {
	title, body string
	yes, no     string
	onYes       func(*Model) tea.Cmd
	focusNo     bool
}

type Model struct {
	panel koha.Panel
	demo  bool
	zones *zone.Manager
	menu  []koha.Item

	w, h    int
	focus   region
	sel     int // sidebar
	child   int // content button
	quick   int
	foot    int
	hover   string
	dlg     *dialog
	notice  string
	showLog bool

	status   koha.Status
	checking bool

	jobSeq   int
	job      *runner.Job
	jobTitle string
	running  bool
	jobErr   error
	jobTime  time.Duration
	percent  float64
	log      []string
	vp       viewport.Model
	spin     spinner.Model
	bar      progress.Model
}

func New(p koha.Panel, demo bool) *Model {
	sp := spinner.New(spinner.WithSpinner(spinner.MiniDot))
	sp.Style = sp.Style.Foreground(cAccent)
	return &Model{
		panel:  p,
		demo:   demo,
		zones:  zone.New(),
		menu:   koha.Menu(),
		focus:  rSide,
		status: koha.Status{State: "unknown"},
		vp:     viewport.New(0, 0),
		spin:   sp,
		bar:    progress.New(progress.WithSolidFill(string(cAccent)), progress.WithoutPercentage()),
	}
}

func (m *Model) Init() tea.Cmd { return m.checkStatus() }

func (m *Model) checkStatus() tea.Cmd {
	m.checking = true
	if m.demo {
		return func() tea.Msg {
			time.Sleep(400 * time.Millisecond)
			return statusMsg(koha.Status{State: "not_installed", CheckedAt: time.Now()})
		}
	}
	p := m.panel
	return func() tea.Msg { return statusMsg(p.Status(context.Background())) }
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.resizeLog()
		return m, nil

	case statusMsg:
		m.status, m.checking = koha.Status(msg), false
		return m, tea.Tick(time.Minute, func(time.Time) tea.Msg { return statusTickMsg{} })

	case statusTickMsg:
		if m.checking || m.running {
			return m, nil
		}
		return m, m.checkStatus()

	case spinner.TickMsg:
		if !m.running {
			return m, nil
		}
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case runner.LineMsg:
		if m.job == nil || msg.JobID != m.job.ID {
			return m, nil
		}
		m.appendLog(msg.Line)
		if msg.Percent >= 0 {
			m.percent = msg.Percent
		}
		return m, m.job.Next()

	case runner.DoneMsg:
		if msg.JobID != m.jobSeq {
			return m, nil
		}
		m.running, m.jobErr, m.jobTime = false, msg.Err, msg.Elapsed
		if m.job == nil { // interactive: the routine had the whole screen
			m.notice = m.doneText()
		}
		return m, m.checkStatus()

	case tea.MouseMsg:
		return m, m.mouse(msg)

	case tea.KeyMsg:
		return m, m.key(msg)
	}
	return m, nil
}

// ---- running things ------------------------------------------------------

// activate runs a leaf of the menu, asking first when it changes data.
func (m *Model) activate(it koha.Item) tea.Cmd {
	if len(it.Children) > 0 {
		return nil
	}
	run := func(m *Model) tea.Cmd { return m.start(it) }
	if it.Confirm {
		m.ask("Run "+it.Label+"?", "This routine can change data or restart part of Koha.", "Run", run)
		return nil
	}
	return run(m)
}

func (m *Model) start(it koha.Item) tea.Cmd {
	if m.running {
		m.notice = "Wait for " + m.jobTitle + " to finish first."
		return nil
	}
	if m.demo || it.Streamed() {
		return m.stream(it.Label, func(ctx context.Context) *exec.Cmd { return m.panel.StreamCmd(ctx, it.Args...) })
	}
	cmd, err := m.panel.RunCmd(it.Run)
	if err != nil {
		m.notice = err.Error()
		return nil
	}
	return m.interactive(it.Label, cmd)
}

// stream runs a task with its output in the content area's log viewer.
func (m *Model) stream(title string, build func(context.Context) *exec.Cmd) tea.Cmd {
	m.jobSeq++
	m.beginJob(title)
	var next tea.Cmd
	if m.demo {
		m.job, next = runner.Demo(m.jobSeq, title)
	} else {
		m.job, next = runner.Stream(m.jobSeq, title, build)
	}
	m.showLog, m.focus = true, rContent
	return tea.Batch(next, m.spin.Tick)
}

// interactive gives a routine the terminal; the dashboard comes back when
// it ends.
func (m *Model) interactive(title string, cmd *exec.Cmd) tea.Cmd {
	if m.demo {
		return m.stream(title, nil)
	}
	m.jobSeq++
	m.beginJob(title)
	m.job = nil
	return runner.Interactive(m.jobSeq, cmd)
}

func (m *Model) beginJob(title string) {
	m.jobTitle, m.running, m.jobErr, m.percent, m.notice = title, true, nil, -1, ""
	m.log = m.log[:0]
	m.vp.SetContent("")
}

func (m *Model) cancelJob() {
	if m.running && m.job != nil {
		m.job.Cancel()
	}
}

func (m *Model) doneText() string {
	if m.jobErr != nil {
		return fmt.Sprintf("✗ %s ended with an error: %v", m.jobTitle, m.jobErr)
	}
	return fmt.Sprintf("✓ %s finished in %s.", m.jobTitle, m.jobTime.Round(time.Second))
}

func (m *Model) appendLog(line string) {
	follow := m.vp.AtBottom()
	m.log = append(m.log, line)
	if len(m.log) > maxLogLines {
		m.log = m.log[len(m.log)-maxLogLines:]
	}
	m.vp.SetContent(strings.Join(m.log, "\n"))
	if follow {
		m.vp.GotoBottom()
	}
}

func (m *Model) footerAction(i int) tea.Cmd {
	switch i {
	case actPanel:
		cmd, _ := m.panel.RunCmd("")
		return m.interactive("Panel management", cmd)
	case actRestart:
		m.ask("Restart Koha?", "Koha's services restart; the catalogue is offline for a moment.", "Restart",
			func(m *Model) tea.Cmd { return m.start(koha.Item{Label: "Restart Koha", Run: "repair-services"}) })
	case actTerminal:
		return m.interactive("Terminal", m.panel.ShellCmd())
	case actShutdown:
		m.ask("Shut down safely?", "Koha stops cleanly and then this computer powers off.", "Shut down",
			func(m *Model) tea.Cmd { return m.interactive("Safe shutdown", m.panel.ShutdownCmd()) })
	}
	return nil
}

// openURL opens a web interface, or shows its address when there is no
// desktop to open it on (SSH, headless server).
func (m *Model) openURL(name, url string) tea.Cmd {
	if m.panel.Host.SSH && m.panel.Host.ServerIP != "" {
		url = strings.Replace(url, "localhost", m.panel.Host.ServerIP, 1)
	}
	err := browser.Open(m.panel.Host, url)
	if err == nil {
		m.notice = "Opened " + name + " in your browser."
		return nil
	}
	body := "Open this address in your browser:\n\n" + hyperlink(url)
	if m.panel.Host.SSH {
		body += "\n\nIf the port is closed, tunnel it from your computer:\n" +
			sMuted.Render("ssh -L 8080:localhost:8080 <user>@"+orHost(m.panel.Host.ServerIP))
	}
	m.dlg = &dialog{title: name, body: body, yes: "OK"}
	return nil
}

func orHost(ip string) string {
	if ip == "" {
		return "<server>"
	}
	return ip
}

func (m *Model) ask(title, body, yes string, onYes func(*Model) tea.Cmd) {
	m.dlg = &dialog{title: title, body: body, yes: yes, no: "Cancel", onYes: onYes, focusNo: true}
}

func (m *Model) closeDialog(accept bool) tea.Cmd {
	d := m.dlg
	m.dlg = nil
	if accept && d.onYes != nil {
		return d.onYes(m)
	}
	return nil
}

// ---- selection helpers ---------------------------------------------------

func (m *Model) current() koha.Item { return m.menu[m.sel] }

// buttons are the content area's activatable entries for the selection.
func (m *Model) buttons() []koha.Item {
	it := m.current()
	if len(it.Children) > 0 {
		return it.Children
	}
	return []koha.Item{it}
}

func (m *Model) selectItem(i int) {
	if i < 0 || i >= len(m.menu) {
		return
	}
	if i != m.sel {
		m.child = 0
	}
	m.sel = i
	if !m.running {
		m.showLog = false
	}
}

func (m *Model) resizeLog() {
	_, cw, bodyH := m.dims()
	m.vp.Width = max(10, cw)
	m.vp.Height = max(1, bodyH-3) // title, progress and buttons lines
}
