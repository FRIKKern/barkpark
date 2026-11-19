package chathost

import (
	"encoding/json"
	"strings"
)

// EnrollRefusedError is the server's 401 on POST /v1/chat-host/enroll: the
// code did not enroll this machine. Reason is the server's details.reason
// ("expired", "replaced", "revoked", "used"), empty when the server did not
// know the code or is older than the field. Message is the server's own
// sentence, which says what to do next.
type EnrollRefusedError struct {
	Reason  string
	Message string
}

func (e *EnrollRefusedError) Error() string {
	message := strings.TrimSpace(e.Message)
	if message == "" || message == "enrollment token is invalid or expired" {
		message = "the code is not valid or has expired. Check that you copied all of it, or ask the workspace owner for a new code."
	}
	return "the server refused this enrollment code: " + message
}

// enrollRefusal reads the error envelope of a 401 enroll answer. A body that
// is not the envelope still yields a refusal, with the generic sentence.
func enrollRefusal(body []byte) *EnrollRefusedError {
	var envelope struct {
		Error struct {
			Message string `json:"message"`
			Details struct {
				Reason string `json:"reason"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &envelope)
	return &EnrollRefusedError{Reason: envelope.Error.Details.Reason, Message: envelope.Error.Message}
}
