//go:build unix

package chathost

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// ownProcessGroup starts the provider as the leader of a process group of its
// own, and makes the cancel of its context kill that whole group. A tool or
// shell command the provider starts joins the group, so it is ended with the
// turn instead of running on after the turn was reported ended
// (task-00d0c5e8ff5dc5d1). A child that leaves the group itself (setsid,
// setpgid) is not reached.
func ownProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killProviderGroup(cmd) }
}

// killProviderGroup kills every process left in the provider's group, the
// provider too while it lives, as cmd.Process.Kill did for the provider
// alone. A group with no one left in it is os.ErrProcessDone.
func killProviderGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}
