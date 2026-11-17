//go:build !unix

package chathost

import "os/exec"

// ownProcessGroup leaves the provider as it is where there are no process
// groups to put it in: the cancel of its context kills the provider alone.
func ownProcessGroup(*exec.Cmd) {}

// killProviderGroup kills the provider alone.
func killProviderGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return cmd.Process.Kill()
}
