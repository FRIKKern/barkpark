package chat

import "github.com/FRIKKern/barkpark/internal/apiclient"

// settledAskStatus is the ask's status when err is an answer the server
// refused because the ask was no longer pending (apiclient.AskSettledError).
func settledAskStatus(err error) (string, bool) {
	settled, ok := apiclient.AsAskSettled(err)
	if !ok {
		return "", false
	}
	return settled.Status, true
}

// askSettledNotice says, in plain words, what happened to an ask the answer
// came too late for. Nothing was sent in either case.
func askSettledNotice(status string) string {
	switch status {
	case "canceled":
		return "this ask was canceled before your answer reached it, so your answer was not sent"
	case "":
		// The /answer 404 does not say what happened to the question.
		return "this question is no longer waiting for an answer, so your answer was not sent"
	default:
		return "this ask was already answered (" + status + "), so your answer was not sent"
	}
}
