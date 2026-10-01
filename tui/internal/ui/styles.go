package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Dark palette taken from the WinForms window.
var (
	cText    = lipgloss.Color("#E6E8EB")
	cMuted   = lipgloss.Color("#8B9099")
	cDim     = lipgloss.Color("#5C616B")
	cBorder  = lipgloss.Color("#30343C")
	cFocus   = lipgloss.Color("#4C6EF5")
	cButton  = lipgloss.Color("#2A2D35")
	cHover   = lipgloss.Color("#383C46")
	cSelect  = lipgloss.Color("#2B2F38")
	cAccent  = lipgloss.Color("#2563EB")
	cBrand   = lipgloss.Color("#7AC143")
	cOK      = lipgloss.Color("#22C55E")
	cWarn    = lipgloss.Color("#F59E0B")
	cBad     = lipgloss.Color("#EF4444")
	cCaption = lipgloss.Color("#A3A8B1")
)

var (
	sText    = lipgloss.NewStyle().Foreground(cText)
	sMuted   = lipgloss.NewStyle().Foreground(cMuted)
	sDim     = lipgloss.NewStyle().Foreground(cDim)
	sTitle   = lipgloss.NewStyle().Foreground(cText).Bold(true)
	sBrand   = lipgloss.NewStyle().Foreground(cBrand).Bold(true)
	sCaption = lipgloss.NewStyle().Foreground(cCaption)
	sURL     = lipgloss.NewStyle().Foreground(lipgloss.Color("#7DA2FF")).Underline(true)
)

// btnState picks a button's colours.
type btnState int

const (
	btnNormal btnState = iota
	btnHover
	btnFocus
	btnPrimary
)

// button renders lines (1 or 2) centred in a block w cells wide.
func button(lines []string, w int, st btnState) string {
	bg, fg := cButton, cText
	switch st {
	case btnHover:
		bg = cHover
	case btnFocus:
		bg = cFocus
	case btnPrimary:
		bg = cAccent
	}
	s := lipgloss.NewStyle().Background(bg).Foreground(fg).Width(w).Align(lipgloss.Center)
	for i, l := range lines {
		lines[i] = ansi.Truncate(l, w-2, "…")
	}
	return s.Render(strings.Join(lines, "\n"))
}

// row renders a full-width, left-aligned clickable line.
func row(text string, w int, st btnState) string {
	bg := cButton
	switch st {
	case btnHover:
		bg = cHover
	case btnFocus:
		bg = cFocus
	}
	return lipgloss.NewStyle().Background(bg).Foreground(cText).Width(w).Padding(0, 1).
		Render(ansi.Truncate(text, w-2, "…"))
}

// card draws body in a rounded box w cells wide (border included) with
// title set into the top edge, as the window's section captions are.
func card(title, body string, w int, border lipgloss.Color) string {
	b := lipgloss.RoundedBorder()
	bs := lipgloss.NewStyle().Foreground(border)
	box := lipgloss.NewStyle().Border(b).BorderTop(false).BorderForeground(border).
		Width(w-2).Padding(0, 1).Render(body)
	if title == "" {
		return bs.Render(b.TopLeft+strings.Repeat(b.Top, w-2)+b.TopRight) + "\n" + box
	}
	t := " " + sCaption.Bold(true).Render(strings.ToUpper(title)) + " "
	fill := w - 3 - lipgloss.Width(t)
	if fill < 0 {
		fill = 0
	}
	top := bs.Render(b.TopLeft+b.Top) + t + bs.Render(strings.Repeat(b.Top, fill)+b.TopRight)
	return top + "\n" + box
}

// fit forces s to exactly w×h cells (cuts or pads), so the layout's fixed
// heights hold whatever the content.
func fit(s string, w, h int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > h {
		lines = lines[:h]
	}
	for len(lines) < h {
		lines = append(lines, "")
	}
	for i, l := range lines {
		l = ansi.Truncate(l, w, "")
		lines[i] = l + strings.Repeat(" ", max(0, w-ansi.StringWidth(l)))
	}
	return strings.Join(lines, "\n")
}
