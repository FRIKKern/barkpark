package cli

import (
	"net/http"
	"strings"
	"testing"
)

func TestDatasetDeleteAsksAgainUntilTheReceipt(t *testing.T) {
	const deletePath = "DELETE /w/acme/p/site/v1/datasets/j10-20261029"
	datasetDeletePoll = 0
	t.Cleanup(func() { datasetDeletePoll = defaultDatasetDeletePoll })

	t.Run("202 twice, then the 200 receipt", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)
		h.deletes = []int{http.StatusAccepted, http.StatusAccepted}

		code, stdout, stderr := h.runDestroy(globals{yes: true}, "dataset", "delete", "j10-20261029")

		sent := 0
		for _, got := range h.seen {
			if got == deletePath {
				sent++
			}
		}
		if code != exitOK || sent != 3 {
			t.Errorf("exit=%d deletes=%d, want exit 0 after 3 DELETEs; requests %v", code, sent, h.seen)
		}
		if !strings.Contains(stderr, "still deleting") || strings.Contains(stdout, "deleting") {
			t.Errorf("the wait must be named on stderr and the receipt alone on stdout:\nstdout=%s\nstderr=%s", stdout, stderr)
		}
	})

	t.Run("an error after a 202 is the command's answer", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)
		h.deletes = []int{http.StatusAccepted, http.StatusServiceUnavailable}

		code, _, _ := h.runDestroy(globals{yes: true}, "dataset", "delete", "j10-20261029")

		if code == exitOK {
			t.Errorf("exit=0 on a 503 after a 202; requests %v", h.seen)
		}
	})
}
