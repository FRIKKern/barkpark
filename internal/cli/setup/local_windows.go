//go:build windows

package setup

import (
	"os/exec"
	"syscall"
)

// backgroundCommand puts the child in a new process group so it does not receive
// the Ctrl+C / Ctrl+Break that bp's console group gets, letting it outlive bp's
// exit. Windows has no session concept; CREATE_NEW_PROCESS_GROUP is the analog
// of Setsid for detaching a long-running background server.
func backgroundCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
	return cmd
}
