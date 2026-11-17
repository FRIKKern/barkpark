//go:build !unix

package chathost

import "errors"

// signalZero has no kill(pid, 0) here. The tests that call it run a provider
// through sh, so they do not run off unix; one that did would fail on this
// error rather than pass.
func signalZero(int) error { return errors.ErrUnsupported }
