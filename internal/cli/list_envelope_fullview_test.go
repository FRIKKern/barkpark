package cli

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp search query -o table` reads the FULL view (rows keyed `_id`); only
// `-o json` sends view=brief (rows keyed `id`). The drift check must stay quiet
// for either real shape and still fire when the rows carry neither.
func TestSearchQueryDriftAcceptsBothViews(t *testing.T) {
	cmd := manifest.Command{ID: "search.query", Noun: "search", Verb: "query"}
	for name, body := range map[string]string{
		"brief (-o json)": `{"documents":[{"id":"a","title":"x"}]}`,
		"full (-o table)": `{"documents":[{"_id":"a","title":"x"}]}`,
	} {
		if got := listEnvelopeDrift(cmd, 200, []byte(body)); got != "" {
			t.Errorf("%s: a real row shape was reported as drift: %s", name, got)
		}
	}
	if got := listEnvelopeDrift(cmd, 200, []byte(`{"documents":[{"title":"x"}]}`)); got == "" {
		t.Error("rows with neither id nor _id must still be reported as drift")
	}
}
