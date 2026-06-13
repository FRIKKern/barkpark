//go:build !windows

package setup

import (
	"os/exec"
	"syscall"
)

// backgroundCommand detaches the child into its own session (Setsid) so it
// outlives bp's exit and never holds the controlling terminal.
func backgroundCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd
}
