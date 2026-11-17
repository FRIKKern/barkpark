package apiclient

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// AskSettledError is an approval answer the server refused because the ask is
// no longer pending: 409 `conflict` with `details.approval_status` (#26895,
// task-035d3495dae536cf). Nothing reached the agent. Status is what the ask is
// now ("canceled" is the one the server sends today). A caller should reload
// the session rather than retry: the ask is settled, and a resend changes
// nothing (task-6d6dc151c1dab808).
type AskSettledError struct {
	Status  string
	Message string
}

func (e *AskSettledError) Error() string { return e.Message }

// askSettled reads a refused approval answer. It is non-nil only for a 409
// whose envelope names the ask's status; any other refusal stays the plain
// humanAPIError it always was.
func askSettled(status int, body []byte) *AskSettledError {
	if status != http.StatusConflict {
		return nil
	}
	env, ok := apierr.Parse(body)
	if !ok || len(env.Details) == 0 {
		return nil
	}
	var d struct {
		ApprovalStatus string `json:"approval_status"`
	}
	if json.Unmarshal(env.Details, &d) != nil || d.ApprovalStatus == "" {
		return nil
	}
	return &AskSettledError{Status: d.ApprovalStatus, Message: env.Summary()}
}

// AsAskSettled reports whether err is a refused answer to a settled ask.
func AsAskSettled(err error) (*AskSettledError, bool) {
	var settled *AskSettledError
	if errors.As(err, &settled) {
		return settled, true
	}
	return nil, false
}
