package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// webhookLsCommand and schemaLsCommand mirror the manifest rows the server
// actually emits (api/lib/barkpark/plugins/capabilities.ex: webhook.ls, schema.ls). Both are `writes: false` with NO `paginated: true` — which
// is precisely why they sat outside the wave-28 fence.
func webhookLsCommand() manifest.Command {
	return manifest.Command{
		ID:            "webhook.ls",
		Noun:          "webhook",
		Verb:          "ls",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/v1/webhooks/:dataset"},
		DefaultOutput: "table",
	}
}

func schemaLsCommand() manifest.Command {
	return manifest.Command{
		ID:            "schema.ls",
		Noun:          "schema",
		Verb:          "ls",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/v1/schemas/:dataset"},
		DefaultOutput: "table",
	}
}

func serveOnce(t *testing.T, status int, contentType, body string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if contentType != "" {
			w.Header().Set("Content-Type", contentType)
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func runRead(t *testing.T, cmd manifest.Command, output, server string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: output, outputSet: true}
	out.applyGlobals(g)
	ctx := manifest.Context{Server: server, Dataset: "production"}
	code := runCommand(out, g, ctx, &manifest.Manifest{}, cmd, nil)
	return code, stdout.String(), stderr.String()
}

// TestNonPaginatedListReadsRefuseARowlessTwoHundred is the row's headline case.
// Every body here is served with HTTP 200 and PARSES — so screenUnpaginatedRead
// passes it by design (a read has honest empty answers) — but none carries a
// row array, and `webhook.ls` / `schema.ls` are commands that answer WITH rows.
// On origin/main all of them printed nothing and exited 0: indistinguishable
// from "this dataset has no webhooks".
func TestNonPaginatedListReadsRefuseARowlessTwoHundred(t *testing.T) {
	poisons := []struct{ name, body, ctype string }{
		{"empty object", `{}`, "application/json"},
		{"json null", `null`, "application/json"},
		{"count without rows", `{"count":0}`, "application/json"},
		{"rows key holding null", `{"webhooks":null,"count":0}`, "application/json"},
		{"result wrapping an empty object", `{"result":{}}`, "application/json"},
		{"unknown non-array envelope", `{"widgets":{"a":1}}`, "application/json"},
		{"plaintext gateway banner", `upstream connect error`, "text/plain"},
		{"bare scalar", `0`, "application/json"},
	}

	for _, cmd := range []manifest.Command{webhookLsCommand(), schemaLsCommand()} {
		for _, tc := range poisons {
			for _, output := range []string{"json", "table", "minimal", "yaml"} {
				t.Run(cmd.ID+"/"+tc.name+"/"+output, func(t *testing.T) {
					srv := serveOnce(t, http.StatusOK, tc.ctype, tc.body)
					code, stdout, stderr := runRead(t, cmd, output, srv)
					both := stdout + stderr
					if code == exitOK {
						t.Fatalf("`bp %s %s` -o %s exited 0 on %s; out=%q", cmd.Noun, cmd.Verb, output, tc.name, both)
					}
					if !strings.Contains(both, "unreadable_list_page") && !strings.Contains(both, "unreadable list page") {
						t.Fatalf("-o %s did not name the refusal: %q", output, both)
					}
					// -o json/yaml carry the machine envelope; assert the CODE
					// there, where a scripted caller reads it.
					if output == "json" {
						var env struct {
							OK    bool `json:"ok"`
							Error struct {
								Code string `json:"code"`
							} `json:"error"`
						}
						if err := json.Unmarshal([]byte(stdout), &env); err != nil {
							t.Fatalf("refusal not JSON: %v\n%s", err, stdout)
						}
						if env.OK || env.Error.Code != "unreadable_list_page" {
							t.Fatalf("want unreadable_list_page, got: %s", stdout)
						}
					}
				})
			}
		}
	}
}

// CONTROL A — a guard that reds an honest read is a regression, not a fix. The
// genuinely EMPTY list is the one that matters: it is byte-adjacent to the
// poison and it is the answer an operator's script is allowed to act on.
func TestHonestListReadsStillExitZero(t *testing.T) {
	honest := []struct {
		name string
		cmd  manifest.Command
		body string
	}{
		{"empty webhook list", webhookLsCommand(), `{"webhooks":[],"count":0}`},
		{"populated webhook list", webhookLsCommand(), `{"webhooks":[{"id":"wh-1","url":"https://x"}],"count":1}`},
		{"empty schema list", schemaLsCommand(), `{"schemas":[],"datasetSchemaHash":"abc"}`},
		{"populated schema list", schemaLsCommand(), `{"schemas":[{"name":"post"}],"datasetSchemaHash":"abc"}`},
	}
	for _, tc := range honest {
		for _, output := range []string{"json", "table", "minimal", "yaml"} {
			t.Run(tc.name+"/"+output, func(t *testing.T) {
				srv := serveOnce(t, http.StatusOK, "application/json", tc.body)
				code, stdout, stderr := runRead(t, tc.cmd, output, srv)
				if code != exitOK {
					t.Fatalf("honest read exited %d: stdout=%q stderr=%q", code, stdout, stderr)
				}
				if strings.Contains(stdout+stderr, "unreadable") {
					t.Fatalf("honest read was refused: %q", stdout+stderr)
				}
			})
		}
	}
}

// CONTROL B — the unit-level truth table for the widened predicate, including
// the shapes only a UNIT test can reach: an envelope key listEnvelopeKeys has
// never heard of (chat.list_sessions answers under `sessions`), and the BARE
// ARRAY search.synonyms leaves behind once unwrapResult strips its `result`.
// Both are honest and must pass; a write must still be skipped outright.
func TestRefuseUnreadableDefaultPagePredicate(t *testing.T) {
	listRead := func(id string) manifest.Command {
		return manifest.Command{ID: id, Noun: "x", Verb: "y", DefaultOutput: "table"}
	}
	cases := []struct {
		name    string
		cmd     manifest.Command
		body    string
		refused bool
	}{
		{"webhook.ls empty object", listRead("webhook.ls"), `{}`, true},
		{"webhook.ls honest empty", listRead("webhook.ls"), `{"webhooks":[]}`, false},
		{"chat.list_sessions unknown key, honest", listRead("chat.list_sessions"), `{"sessions":[{"id":"s1"}]}`, false},
		{"chat.list_sessions unknown key, empty", listRead("chat.list_sessions"), `{"sessions":[]}`, false},
		{"chat.list_sessions rowless", listRead("chat.list_sessions"), `{"count":0}`, true},
		{"search.synonyms bare array", listRead("search.synonyms"), `{"result":[]}`, false},
		{"search.synonyms rowless", listRead("search.synonyms"), `{"result":{}}`, true},
		{"graph.orphans honest", listRead("graph.orphans"), `{"orphans":[],"count":0}`, false},
		{"doc.related nested under result", listRead("doc.related"), `{"result":{"related":[],"count":0}}`, false},

		// The OBJECT reads are OUT, and this is the measurement that says why:
		// their happy-path body carries no array at all, so covering them here
		// would refuse a correct answer.
		{"doc.get single document", listRead("doc.get"), `{"result":{"_id":"post.p1","title":"hi"}}`, false},
		{"auth.me scalar map", listRead("auth.me"), `{"tier":"admin","workspace":"default"}`, false},
		{"data.counts empty projection", listRead("data.counts"), `{}`, false},

		// A write is skipped before any body test — screenWriteReceipt owns it.
		{"write receipt", manifest.Command{ID: "webhook.create", Writes: true}, `{}`, false},

		// A body screenUnpaginatedRead names better is handed back so one fault
		// gets one name (and, for the 2xx error envelope, the right remedy).
		{"html proxy page belongs to screenUnpaginatedRead", listRead("webhook.ls"), `<html><body>502</body></html>`, false},
		{"error envelope belongs to screenUnpaginatedRead", listRead("webhook.ls"), `{"ok":false,"error":{"code":"upstream_down"}}`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "json"
			_, refused := refuseUnreadableDefaultPage(out, tc.cmd, http.StatusOK, []byte(tc.body))
			if refused != tc.refused {
				t.Fatalf("refused = %v, want %v (body %s); out=%q%q", refused, tc.refused, tc.body, stdout.String(), stderr.String())
			}
		})
	}
}

// CONTROL C — the paginated arm is UNCHANGED. Its strict key test is what
// TestPaginatedCommandsUseKnownEnvelopeKeys certifies, and the wider shape test
// must not leak into it: `{"widgets":[…]}` is an unknown envelope and stays a
// wave-27 poison.
func TestPaginatedArmKeepsTheStrictKeyTest(t *testing.T) {
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	if _, refused := refuseUnreadableDefaultPage(out, paginatedReadCommand(50), http.StatusOK, []byte(`{"widgets":[{"a":1}]}`)); !refused {
		t.Fatalf("a paginated read stopped refusing an unknown envelope key — the shape test leaked into the strict arm")
	}
}

// objectReadCommands is the OTHER half of the classification: every
// non-paginated core read that is NOT covered by the widened fence, with the
// reason it cannot be. This is the re-derivation criterion 2 asks for, kept
// executable instead of pasted once into a task row.
//
// The shared reason is structural, not a shrug: extractListRows returns the ""
// sentinel for these bodies on their HAPPY path, so a list fence here would
// refuse correct answers. They are NOT unguarded — screenUnpaginatedRead
// (run.go) still refuses an empty body, an HTML proxy page, a `result` filled
// with non-JSON, and an error envelope on a 2xx for every one of them. What
// stays uncovered for an object read is `{}` / `null` / an unknown-key object,
// which for THESE verbs can be an honest projection.
var objectReadCommands = map[string]string{
	"access.show":                  "single grant object (access_controller.ex)",
	"auth.me":                      "flat identity map, no row array (auth_controller.ex)",
	"chat.get_attachment":          "single attachment object — id, media_type, byte_size, base64 data; never a row array (chat_attachment_controller.ex)",
	"chat.get_session":             "single session object (chat_controller.ex)",
	"cycle.show":                   "wave projection object; several values are arrays, none is 'the rows' (cycle_fleet_controller.ex)",
	"data.counts":                  "`counts` is a type=>count MAP, not an array — `{}` is an honest fresh dataset (query_controller.ex)",
	"doc.get":                      "single document; envelopeRows refuses list treatment for a payload carrying _id (query_controller.ex)",
	"doc.revision":                 "one revision object (history_controller.ex)",
	"media.collection":             "single collection object (v1/media_collections_controller.ex)",
	"media.get":                    "single asset object (v1/media_controller.ex)",
	"media.relations":              "arrays nested under result.outbound/result.inbound, neither guaranteed present (v1/media_controller.ex)",
	"media.search-insights":        "aggregate counters object (v1/media_controller.ex)",
	"media.search-settings":        "settings object (v1/media_controller.ex)",
	"media.search-synonym-preview": "preview object (v1/media_controller.ex)",
	"media.share-view":             "share projection; hits nested under result (v1/media_collections_controller.ex)",
	"media.suggest":                "result.recent/popular/nohits, none guaranteed present (v1/media_controller.ex)",
	"schema.get":                   "one schema object (schema_controller.ex)",
	"search.insights":              "aggregate counters object (search_controller.ex)",
	"search.settings":              "settings object (search_controller.ex)",
	"search.suggestions":           "result.recent/popular/nohits, none guaranteed present (search_controller.ex)",
	"search.synonym-preview":       "preview object (search_controller.ex)",
	"secret.get":                   "one secret object (secret_controller.ex)",
	"secret.scoped-get":            "one secret object, scoped twin (secret_controller.ex)",
	"webhook.get":                  "single subscription object (webhook_controller.ex)",
}

var coreCmdOpen = regexp.MustCompile(`^\s*core_cmd\($`)
var quotedString = regexp.MustCompile(`"([^"]*)"`)

// TestEveryNonPaginatedCoreReadIsClassified re-derives the population from the
// manifest SOURCE — api/lib/barkpark/plugins/capabilities.ex, defp
// core_commands — instead of trusting either map. A read that is in neither
// table fails here, so the next `<noun> ls` to land cannot quietly inherit the
// hole this row closed, and a stale entry in either table fails too.
func TestEveryNonPaginatedCoreReadIsClassified(t *testing.T) {
	path := filepath.Join("..", "..", "api", "lib", "barkpark", "plugins", "capabilities.ex")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("API source not present (%v) — guard runs in the monorepo checkout", err)
	}
	lines := strings.Split(string(src), "\n")

	start := -1
	for i, l := range lines {
		if strings.TrimSpace(l) == "defp core_commands do" {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("%s: `defp core_commands do` not found — the guard scanned nothing", path)
	}
	end := -1
	for i := start + 1; i < len(lines); i++ {
		if lines[i] == "  end" {
			end = i
			break
		}
	}
	if end < 0 {
		t.Fatalf("%s: core_commands has no terminating `  end`", path)
	}

	nonPaginatedReads := map[string]bool{}
	for i := start; i < end; i++ {
		if !coreCmdOpen.MatchString(lines[i]) {
			continue
		}
		depth := 0
		var block []string
		for j := i; j < end; j++ {
			block = append(block, lines[j])
			depth += strings.Count(lines[j], "(") - strings.Count(lines[j], ")")
			if j > i && depth <= 0 {
				break
			}
		}
		body := strings.Join(block, "\n")
		m := quotedString.FindStringSubmatch(body)
		if m == nil {
			t.Errorf("%s:%d: core_cmd( with no quoted id", path, i+1)
			continue
		}
		if strings.Contains(body, "writes: true") || strings.Contains(body, "paginated: true") {
			continue
		}
		nonPaginatedReads[m[1]] = true
	}

	if len(nonPaginatedReads) < 20 {
		t.Fatalf("only %d non-paginated core reads found — the parser stopped matching the source, so this guard is vacuous", len(nonPaginatedReads))
	}

	for id := range nonPaginatedReads {
		_, list := listReadCommands[id]
		_, object := objectReadCommands[id]
		switch {
		case list && object:
			t.Errorf("%q is in BOTH listReadCommands and objectReadCommands — one command, one classification", id)
		case !list && !object:
			t.Errorf("non-paginated read %q is unclassified: read its controller action and put it in listReadCommands (list_reads.go) if the 200 body carries a row array, or in objectReadCommands with the reason it cannot be fenced. Leaving it out means `bp %s` renders a rowless HTTP 200 as an empty result at exit 0.",
				id, strings.ReplaceAll(id, ".", " "))
		}
	}
	for id := range listReadCommands {
		if !nonPaginatedReads[id] {
			t.Errorf("listReadCommands records %q, which is no longer a non-paginated core read in the API source (renamed, removed, or now `paginated: true`) — drop or move the stale row so the fence keeps measuring reality", id)
		}
	}
	for id := range objectReadCommands {
		if !nonPaginatedReads[id] {
			t.Errorf("objectReadCommands records %q, which is no longer a non-paginated core read in the API source — drop the stale exclusion", id)
		}
	}
}
