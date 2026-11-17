package chathost

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// The first-event bound (task-53bbabed87944b89): until the server takes a
// turn's first event, the provider must not get far. Runner.startListed applies
// it; these are its settings and the close that follows a cut.

// Bound on publishing a turn's first event, unless the Runner sets
// FirstEventTimeout. Long enough to outlast a short blip (with the default
// 1 s PollInterval: attempts at about 0, 1, 3 and 7 s), short enough that the
// provider is stopped before it gets far into a turn the server may never
// count as sent.
const defaultFirstEventTimeout = 10 * time.Second

// minFirstEventTimeout is the least BARKPARK_CHAT_HOST_FIRST_EVENT_TIMEOUT
// takes. Below about a second, one healthy but slow round trip to the server
// (a far server, a busy laptop) already outlasts the bound, so every turn
// would be stopped before it starts.
const minFirstEventTimeout = time.Second

func (r *Runner) firstEventTimeout() time.Duration {
	if r.FirstEventTimeout > 0 {
		return r.FirstEventTimeout
	}
	return defaultFirstEventTimeout
}

// FirstEventTimeoutFromEnv reads BARKPARK_CHAT_HOST_FIRST_EVENT_TIMEOUT (a Go
// duration of at least 1s) for Runner.FirstEventTimeout. Unset, it returns
// zero (the 10 s default) and logs nothing. Set, it logs one line to log (nil
// means os.Stderr) saying whether the value is used or ignored; an ignored
// value also gives zero.
func FirstEventTimeoutFromEnv(getenv func(string) string, log io.Writer) time.Duration {
	const name = "BARKPARK_CHAT_HOST_FIRST_EVENT_TIMEOUT"
	raw := strings.TrimSpace(getenv(name))
	if raw == "" {
		return 0
	}
	if log == nil {
		log = os.Stderr
	}
	timeout, err := time.ParseDuration(raw)
	if err != nil || timeout < minFirstEventTimeout {
		fmt.Fprintf(log, "barkpark-chat-host: %s=%q ignored: want a Go duration of at least %s; the first-event bound stays %s\n",
			name, raw, minFirstEventTimeout, defaultFirstEventTimeout)
		return 0
	}
	fmt.Fprintf(log, "barkpark-chat-host: the first-event bound is %s (%s)\n", timeout, name)
	return timeout
}

// cursorConflict reports whether the server refused an event because its
// cursor already holds a different one (ChatHosts.reconcile_event/4, answered
// 422 ":cursor_conflict").
func cursorConflict(err error) bool {
	var status *StatusError
	return errors.As(err, &status) && status.Code == http.StatusUnprocessableEntity && strings.Contains(status.Body, "cursor_conflict")
}

// closeAfterUnconfirmed runs when the close of a turn whose first event the
// bound cut met cursor_conflict at that event's cursor. Some event holds the
// cursor: the turn's own first event, taken after all, or the server's close
// (it withdrew the lease meanwhile). repost sends the first event again, same
// cursor, key and payload. The cursor is held, so it can only be answered as
// a duplicate (ours: the close goes after it, by close) or refused as a
// conflict (not ours: nothing more is sent, the server closed the lease
// itself). It returns the error the caller decides the lease's mark by: a
// transient one leaves the lease to the next poll, whose listing says.
func (r *Runner) closeAfterUnconfirmed(leaseID string, conflict error, repost, close func() error) error {
	if err := repost(); err != nil {
		if Transient(err) {
			return err
		}
		r.logf("lease %s: the turn's first event is not what the server holds; it closed the lease itself", leaseID)
		return conflict
	}
	r.logf("lease %s: the server holds the turn's first event after all; closing after it", leaseID)
	return close()
}
