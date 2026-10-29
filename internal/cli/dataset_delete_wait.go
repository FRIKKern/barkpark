package cli

import (
	"net/http"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// dataset_delete_wait.go: a dataset delete outlives its request
// (task-10608b4831a0e9b8). The server answers 202 {deleting: true} after a few
// seconds and keeps the delete running; the same DELETE asks again and answers
// the receipt, an error, or 202 once more. `bp dataset delete` repeats it until
// the answer is not 202, so the command still ends on the receipt.

const defaultDatasetDeletePoll = 2 * time.Second

var datasetDeletePoll = defaultDatasetDeletePoll

func awaitDatasetDelete(out *writer, cmd manifest.Command, req *manifestRequest, status int, body []byte, ct string, err error) (int, []byte, string, error) {
	if cmd.ID != "dataset.delete" {
		return status, body, ct, err
	}
	waited := false
	for err == nil && status == http.StatusAccepted {
		if !waited {
			out.errf("bp: the server is still deleting the dataset; asking again every %s", datasetDeletePoll)
			waited = true
		}
		time.Sleep(datasetDeletePoll)
		status, body, ct, err = sendManifestRequest(req)
	}
	if waited && err == nil && status == http.StatusNotFound {
		out.errf("bp: the dataset is gone, and another DELETE already read its receipt")
	}
	return status, body, ct, err
}
