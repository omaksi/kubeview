// Package clipboard copies text to the system clipboard without pulling in a
// dependency, and without assuming the terminal is local.
//
// A native helper (pbcopy, wl-copy, xclip) is tried first because it always
// works locally. When none exists — the usual case over SSH — it falls back to
// OSC 52, which asks the *terminal emulator* to set the clipboard, so the text
// lands on the machine the operator is actually sitting at.
package clipboard

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// Copy places s on the clipboard, reporting which mechanism succeeded.
func Copy(s string) (string, error) {
	if name, args, ok := nativeTool(); ok {
		cmd := exec.Command(name, args...)
		cmd.Stdin = strings.NewReader(s)
		if err := cmd.Run(); err == nil {
			return name, nil
		}
	}
	if err := osc52(s); err != nil {
		return "", fmt.Errorf("no clipboard mechanism available: %w", err)
	}
	return "OSC 52", nil
}

// nativeTool picks the first clipboard helper present on this machine.
func nativeTool() (string, []string, bool) {
	var candidates [][]string
	switch runtime.GOOS {
	case "darwin":
		candidates = [][]string{{"pbcopy"}}
	case "windows":
		candidates = [][]string{{"clip"}}
	default:
		candidates = [][]string{
			{"wl-copy"},
			{"xclip", "-selection", "clipboard"},
			{"xsel", "--clipboard", "--input"},
		}
	}
	for _, c := range candidates {
		if _, err := exec.LookPath(c[0]); err == nil {
			return c[0], c[1:], true
		}
	}
	return "", nil, false
}

// osc52 writes the clipboard escape sequence straight to the controlling
// terminal. It must not go to stdout: Bubble Tea owns that, and interleaving
// would corrupt the rendered frame.
//
// Inside tmux this needs `set -g set-clipboard on`, and inside screen it needs
// a DCS wrapper that is not implemented here.
func osc52(s string) error {
	tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer tty.Close()

	enc := base64.StdEncoding.EncodeToString([]byte(s))
	_, err = fmt.Fprintf(tty, "\x1b]52;c;%s\x07", enc)
	return err
}
