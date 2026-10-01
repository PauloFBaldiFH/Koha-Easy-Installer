package runner

import (
	"bufio"
	"strings"
	"testing"
)

func TestSplitLinesHandlesCR(t *testing.T) {
	sc := bufio.NewScanner(strings.NewReader("a\r\nb\rc\nd"))
	sc.Split(splitLines)
	var got []string
	for sc.Scan() {
		got = append(got, sc.Text())
	}
	if strings.Join(got, ",") != "a,b,c,d" {
		t.Fatalf("got %q", got)
	}
}
