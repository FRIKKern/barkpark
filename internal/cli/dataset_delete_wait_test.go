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
		if want := []string{"", "dataset_id=ds-1", "dataset_id=ds-1"}; strings.Join(h.queries, "|") != strings.Join(want, "|") {
			t.Errorf("the polls must name the dataset the 202 named: queries %q, want %q", h.queries, want)
		}
		if !strings.Contains(stderr, "still deleting") || strings.Contains(stdout, "deleting") {
			t.Errorf("the wait must be named on stderr and the receipt alone on stdout:\nstdout=%s\nstderr=%s", stdout, stderr)
		}
	})

	t.Run("a 202 that names no dataset is an error, never a poll of whatever holds the name", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)
		h.deletes = []int{http.StatusAccepted}
		h.accepted = `{"deleting":true,"dataset":"j10-20261029"}`

		code, stdout, stderr := h.runDestroy(globals{yes: true}, "dataset", "delete", "j10-20261029")

		if code == exitOK || len(h.queries) != 1 || !strings.Contains(stdout+stderr, "names no dataset_id") {
			t.Errorf("exit=%d queries=%q stdout=%s stderr=%s, want a failed command after one DELETE naming the missing dataset_id", code, h.queries, stdout, stderr)
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

func TestDatasetEmptyAsksAgainWithProgressUntilTheReceipt(t *testing.T) {
	const emptyPath = "POST /w/acme/p/site/v1/datasets/production/empty"
	datasetDeletePoll = 0
	t.Cleanup(func() { datasetDeletePoll = defaultDatasetDeletePoll })

	t.Run("202 with remaining, then the 200 receipt; the confirmation rides every poll", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)
		h.deletes = []int{http.StatusAccepted, http.StatusAccepted}
		h.accepted = `{"emptying":true,"dataset":"production","dataset_id":"ds-1","remaining":{"documents":59895,"media_files":1307}}`

		code, stdout, stderr := h.runDestroy(globals{yes: true}, "dataset", "empty", "production", "--confirm-production", "production")

		sent := 0
		for _, got := range h.seen {
			if got == emptyPath {
				sent++
			}
		}
		if code != exitOK || sent != 3 {
			t.Errorf("exit=%d posts=%d, want exit 0 after 3 POSTs; requests %v", code, sent, h.seen)
		}
		want := []string{
			"confirm-production=production",
			"confirm-production=production&dataset_id=ds-1",
			"confirm-production=production&dataset_id=ds-1",
		}
		if strings.Join(h.queries, "|") != strings.Join(want, "|") {
			t.Errorf("queries %q, want %q", h.queries, want)
		}
		if !strings.Contains(stderr, "still emptying") || !strings.Contains(stderr, "59895 documents and 1307 media files left") {
			t.Errorf("the wait and its progress must be named on stderr:\n%s", stderr)
		}
		if strings.Contains(stdout, "emptying") {
			t.Errorf("the receipt alone belongs on stdout:\n%s", stdout)
		}
	})

	t.Run("without --yes off a TTY nothing is sent", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)

		code, _, stderr := h.runDestroy(globals{}, "dataset", "empty", "production", "--confirm-production", "production")

		for _, got := range h.seen {
			if got == emptyPath {
				t.Fatalf("an unconfirmed empty sent its POST; requests %v", h.seen)
			}
		}
		if code == exitOK || !strings.Contains(stderr, "--yes") {
			t.Errorf("exit=%d, want a refusal naming --yes:\n%s", code, stderr)
		}
	})
}
