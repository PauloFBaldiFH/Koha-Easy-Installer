// Package runner runs one long task at a time inside the TUI. A streamed
// job's output arrives as messages for the log viewer; an interactive job
// gets the whole terminal (the panel's whiptail screens) and hands it back
// when it ends. Neither opens another window.
package runner

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// LineMsg is one line of a streamed job's output. Percent is >= 0 when the
// line carried a progress figure ("42%").
type LineMsg struct {
	JobID   int
	Line    string
	Percent float64
}

// DoneMsg ends a job, streamed or interactive.
type DoneMsg struct {
	JobID   int
	Err     error
	Elapsed time.Duration
}

type Job struct {
	ID     int
	Title  string
	Start  time.Time
	events chan tea.Msg
	cancel context.CancelFunc
}

// Next waits for the job's next message. Call it again after every
// LineMsg; stop after DoneMsg.
func (j *Job) Next() tea.Cmd {
	return func() tea.Msg { return <-j.events }
}

// Cancel stops a streamed job; its DoneMsg still arrives.
func (j *Job) Cancel() { j.cancel() }

// Stream starts build(ctx) with stdin closed and stdout+stderr merged.
// Without a terminal on stdin, anything that would prompt fails fast
// instead of hanging the log.
func Stream(id int, title string, build func(context.Context) *exec.Cmd) (*Job, tea.Cmd) {
	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{ID: id, Title: title, Start: time.Now(), events: make(chan tea.Msg, 256), cancel: cancel}
	cmd := build(ctx)
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr, cmd.Stdin = pw, pw, nil
	if err := cmd.Start(); err != nil {
		cancel()
		go func() { j.events <- DoneMsg{JobID: id, Err: err} }()
		return j, j.Next()
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		j.scan(pr)
	}()
	go func() {
		err := cmd.Wait()
		pw.Close()
		wg.Wait()
		cancel()
		j.events <- DoneMsg{JobID: id, Err: err, Elapsed: time.Since(j.Start)}
	}()
	return j, j.Next()
}

// Demo streams made-up output, so the layout can be tried anywhere.
func Demo(id int, title string) (*Job, tea.Cmd) {
	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{ID: id, Title: title, Start: time.Now(), events: make(chan tea.Msg, 256), cancel: cancel}
	go func() {
		defer cancel()
		steps := []string{"Checking services", "Reading configuration", "Working on " + title, "Writing results", "Cleaning up"}
		for i := 0; i <= 20; i++ {
			select {
			case <-ctx.Done():
				j.events <- DoneMsg{JobID: id, Err: ctx.Err(), Elapsed: time.Since(j.Start)}
				return
			case <-time.After(150 * time.Millisecond):
			}
			line := fmt.Sprintf("[demo] %s... %d%%", steps[i*len(steps)/21], i*5)
			j.events <- LineMsg{JobID: id, Line: line, Percent: float64(i*5) / 100}
		}
		j.events <- DoneMsg{JobID: id, Elapsed: time.Since(j.Start)}
	}()
	return j, j.Next()
}

// Interactive suspends the TUI and gives cmd the terminal.
func Interactive(id int, cmd *exec.Cmd) tea.Cmd {
	start := time.Now()
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return DoneMsg{JobID: id, Err: err, Elapsed: time.Since(start)}
	})
}

var percentRe = regexp.MustCompile(`(\d{1,3}(?:\.\d+)?)\s?%`)

func (j *Job) scan(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	sc.Split(splitLines)
	for sc.Scan() {
		line := ansi.Strip(sc.Text())
		msg := LineMsg{JobID: j.ID, Line: line, Percent: -1}
		if m := percentRe.FindAllStringSubmatch(line, -1); m != nil {
			if p, err := strconv.ParseFloat(m[len(m)-1][1], 64); err == nil && p <= 100 {
				msg.Percent = p / 100
			}
		}
		j.events <- msg
	}
	io.Copy(io.Discard, r) //nolint:errcheck // drain after an over-long line
}

// splitLines splits on \n and on a bare \r, so progress bars that redraw
// one line still show up as they move.
func splitLines(data []byte, atEOF bool) (int, []byte, error) {
	if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
		adv := i + 1
		if data[i] == '\r' && adv == len(data) && !atEOF {
			return 0, nil, nil // maybe "\r\n" split across reads
		}
		if data[i] == '\r' && adv < len(data) && data[adv] == '\n' {
			adv++
		}
		return adv, bytes.TrimRight(data[:i], "\r"), nil
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}
