package chathost

import "fmt"

// An approval answer goes to the run that asked it, not the session's newest
// run (task-754fd6f9a890e75e). The host routes a control command by session
// to its one active run, and the server names an answer by approval id only.
// So an answer to an ask from run A, sent after run B took the session, went
// to B: Claude refused it as unknown, and that failure's close ended B's
// turn; Codex numbers its asks per process, so B's own ask with the same id
// was answered with A's decision.
//
// The server now names the asking lease in payload.asked_lease_id. An answer
// whose lease is not the active run's is not delivered. It is acknowledged as
// control_completed with a "refused" reason, not failed, because a failure
// closes the answer's lease with an error and that close ends the active
// run's turn. A server that sends no asked_lease_id is answered as before.

// refusedAnswer is the acknowledgement for an answer the active run did not
// ask, or nil when the answer is for this run (or names no lease).
func refusedAnswer(session *activeLocalSession, command map[string]any) map[string]any {
	payload, _ := command["payload"].(map[string]any)
	asked, _ := payload["asked_lease_id"].(string)
	if asked == "" || asked == session.leaseID {
		return nil
	}
	approvalID := fmt.Sprint(command["approval_id"])
	return map[string]any{
		"kind":        "control_completed",
		"operation":   "answer_approval",
		"approval_id": approvalID,
		"refused": fmt.Sprintf("approval %q was asked by run %s, which is no longer this session's active run, so the answer was not sent",
			approvalID, asked),
	}
}
