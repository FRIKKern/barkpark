package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-224f60146d9ff2a7: a non-mutation write ships its --file VERBATIM as
// application/json. A file that is not JSON (`bp doc mutate --file /etc/hosts`)
// went out anyway, and the only answer was the server's "invalid request body
// … check Content-Type: application/json" — naming neither the file nor the
// parse error, while `bp doc create --file` (the mutation path) refused the
// same file locally. The verbatim path now refuses it locally too, and valid
// JSON still ships byte-for-byte.
func verbatimFileCmd(id, path string) manifest.Command {
	noun, verb, _ := strings.Cut(id, ".")
	return manifest.Command{
		ID:     id,
		Noun:   noun,
		Verb:   verb,
		Writes: true,
		Flags:  []manifest.Flag{{Name: "file", Type: "file"}},
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: path},
	}
}

func TestVerbatimFileBodyRefusesNonJSONLocally(t *testing.T) {
	notJSON := writeTempJSON(t, "hosts", "# hosts\n127.0.0.1 localhost\n")
	for _, cmd := range []manifest.Command{
		verbatimFileCmd("doc.mutate", "/v1/data/mutate/:dataset"),
		verbatimFileCmd("schema.apply", "/v1/schemas/:dataset"),
	} {
		body, _, _, err := buildBody(cmd, map[string][]string{"file": {notJSON}}, map[string]string{})
		if err == nil {
			t.Fatalf("%s: a non-JSON --file shipped (%d bytes) instead of being refused locally", cmd.ID, len(body))
		}
		msg := err.Error()
		if !strings.Contains(msg, notJSON) || !strings.Contains(msg, "not valid JSON") {
			t.Errorf("%s: refusal must name the file and say it is not valid JSON; got %q", cmd.ID, msg)
		}
	}
}

func TestVerbatimFileBodyStillShipsValidJSONByteForByte(t *testing.T) {
	const raw = "{\n  \"mutations\": [ ]\n}\n"
	path := writeTempJSON(t, "m.json", raw)
	body, stream, ct, err := buildBody(
		verbatimFileCmd("doc.mutate", "/v1/data/mutate/:dataset"),
		map[string][]string{"file": {path}},
		map[string]string{},
	)
	if err != nil {
		t.Fatalf("valid JSON refused: %v", err)
	}
	if stream != nil || ct != "application/json" || string(body) != raw {
		t.Fatalf("body=%q ct=%q stream=%v; want the file byte-for-byte as application/json", body, ct, stream)
	}
}
