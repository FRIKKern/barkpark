package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ticketInboxFixture is a GET /v1/tickets/inbox 2xx body shaped EXACTLY like
// TicketsController.inbox emits: {ok, tickets:[…]} where each row is the
// inbox_row map — Thread.to_map minus :messages/:key_id, plus the derived
// waiting_age_seconds (nil on a non-open row) and the seen boolean. Wire keys
// are strings because Phoenix's json/2 stringifies the atom keys. Two rows
// exercise the two turn states the operator triages: an OPEN row (their move,
// waiting age set, an attachment, not yet seen) and an ANSWERED row (the
// submitter's move, no waiting age, seen).
const ticketInboxFixture = `{"ok":true,"tickets":[` +
	`{"id":"tk-1","subject":"ONIX export 500s","status":"open","key_name":"Gyldendal — Kari",` +
	`"message_count":2,"has_attachments":true,"submitter_seen_at":null,` +
	`"waiting_since":"2026-07-03T09:00:00Z","updated_at":"2026-07-03T09:05:00Z",` +
	`"waiting_age_seconds":7200,"seen":false},` +
	`{"id":"tk-2","subject":"Password reset","status":"answered","key_name":"Aschehoug — Ola",` +
	`"message_count":3,"has_attachments":false,"submitter_seen_at":"2026-07-03T10:00:00Z",` +
	`"waiting_since":"2026-07-02T08:00:00Z","updated_at":"2026-07-03T09:30:00Z",` +
	`"waiting_age_seconds":null,"seen":true}]}`

// TestTicketInboxRendersTriageColumns pins the operator-triage rendering: the
// inbox rows columnize (they do NOT collapse into a single crammed key/value
// cell — the regression when "tickets" is absent from listEnvelopeKeys), and
// every at-a-glance field the operator triages from the terminal surfaces as its
// own column: who (key_name), whose move (status), the digestible waiting age,
// the message count, the attachment marker, and the seen signal (charter
// Decision 3). The actual row VALUES render too — nothing is silently dropped.
func TestTicketInboxRendersTriageColumns(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderSuccess(w, manifest.Command{DefaultOutput: "table"}, []byte(ticketInboxFixture))
	got := stdout.String()

	// Regression guard: the whole row array must never be stringified into one
	// cell (renderKV's `tickets  [{"id":…}]` — valid output, zero information).
	if strings.Contains(got, `[{"`) || strings.Contains(got, "tickets  ") {
		t.Fatalf("inbox rows were crammed into a KV cell, not a table:\n%s", got)
	}

	header := strings.SplitN(got, "\n", 2)[0]
	cols := map[string]bool{}
	for _, c := range strings.Fields(header) {
		cols[c] = true
	}
	for _, col := range []string{"subject", "key_name", "status", "message_count", "has_attachments", "seen", "waiting_age_seconds"} {
		if !cols[col] {
			t.Errorf("inbox header is missing the %q triage column:\n%s", col, header)
		}
	}

	// The triage read is id → subject → status, so subject must LEAD (pickColumns
	// promotes it as an identity column), not drown mid-table in the alphabetical
	// block after has_attachments/key_name/message_count.
	if si, hi := strings.Index(header, "subject"), strings.Index(header, "has_attachments"); si == -1 || hi == -1 || si > hi {
		t.Errorf("subject must lead the inbox header (before the alphabetical block):\n%s", header)
	}

	for _, v := range []string{"ONIX export 500s", "Gyldendal — Kari", "Aschehoug — Ola"} {
		if !strings.Contains(got, v) {
			t.Errorf("inbox table dropped the value %q:\n%s", v, got)
		}
	}
}

// TestTicketInboxMinimalListsIds pins that `-o minimal` over the same envelope
// surfaces one id line per ticket (the same treatment every list noun gets once
// its envelope key is known) — not a bare "ok".
func TestTicketInboxMinimalListsIds(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderMinimal(w, []byte(ticketInboxFixture))
	got := stdout.String()
	for _, want := range []string{"id: tk-1", "id: tk-2"} {
		if !strings.Contains(got, want) {
			t.Errorf("minimal inbox missing %q:\n%s", want, got)
		}
	}
	if strings.TrimSpace(got) == "ok" {
		t.Errorf("minimal inbox printed a bare \"ok\" — the tickets envelope was not recognised:\n%s", got)
	}
}

// TestTicketKeyLsRendersColumns pins the admin leg of the mint flow:
// `bp ticket-key ls` gets {keys:[…]} from GET /v1/plugins/tickets/keys (each row
// the key_json map — id/name/dataset/status/…). With "keys" in listEnvelopeKeys
// the named credentials columnize; without it the table is one crammed
// `keys  [{"id":…}]` cell — the ticket-key twin of the inbox regression.
func TestTicketKeyLsRendersColumns(t *testing.T) {
	const keysFixture = `{"keys":[` +
		`{"id":"k-1","name":"Gyldendal — Kari","dataset":"production","status":"active",` +
		`"paused_at":null,"revoked_at":null,"expires_at":null,` +
		`"last_used_at":"2026-07-03T09:00:00Z","created_at":"2026-07-01T08:00:00Z"},` +
		`{"id":"k-2","name":"Aschehoug — Ola","dataset":"production","status":"paused",` +
		`"paused_at":"2026-07-02T12:00:00Z","revoked_at":null,"expires_at":null,` +
		`"last_used_at":null,"created_at":"2026-07-01T09:00:00Z"}]}`

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderSuccess(w, manifest.Command{DefaultOutput: "table"}, []byte(keysFixture))
	got := stdout.String()

	if strings.Contains(got, `[{"`) || strings.Contains(got, "keys  ") {
		t.Fatalf("ticket-key ls rows were crammed into a KV cell, not a table:\n%s", got)
	}
	header := strings.SplitN(got, "\n", 2)[0]
	for _, col := range []string{"id", "name", "status", "last_used_at"} {
		if !strings.Contains(header, col) {
			t.Errorf("ticket-key ls header is missing the %q column:\n%s", col, header)
		}
	}
	for _, v := range []string{"Gyldendal — Kari", "paused"} {
		if !strings.Contains(got, v) {
			t.Errorf("ticket-key ls table dropped %q:\n%s", v, got)
		}
	}
}

// TestTicketShowUnwrapsThreadEnvelope pins the operator's NEXT move after the
// inbox: `bp ticket show <id>` (default_output table) gets {ok, ticket:{…}}
// from GET /v1/tickets/inbox/:id — a single-object envelope. With "ticket" in
// singleObjectEnvelopeKeys the thread's fields render as key/value lines; without
// it renderKV crams the whole thread into ONE `ticket  {…json…}` cell truncated
// at 60 runes — the show-verb twin of the inbox regression. (The login-ticket
// endpoint's {"ticket":"<opaque string>"} is a string value, which the
// map-guarded unwrap never touches.)
func TestTicketShowUnwrapsThreadEnvelope(t *testing.T) {
	const showFixture = `{"ok":true,"ticket":` +
		`{"id":"tk-1","subject":"ONIX export 500s","status":"open","key_name":"Gyldendal — Kari",` +
		`"messages":[{"author_kind":"submitter","author_name":"Gyldendal — Kari","body":"The export 500s on…"}],` +
		`"message_count":1,"has_attachments":false,"submitter_seen_at":null,` +
		`"waiting_since":"2026-07-03T09:00:00Z","updated_at":"2026-07-03T09:05:00Z"}}`

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderSuccess(w, manifest.Command{DefaultOutput: "table"}, []byte(showFixture))
	got := stdout.String()

	if strings.Contains(got, `ticket  {`) {
		t.Fatalf("ticket.show crammed the thread into one KV cell, not unwrapped fields:\n%s", got)
	}
	for _, v := range []string{"subject", "ONIX export 500s", "status", "open", "Gyldendal — Kari"} {
		if !strings.Contains(got, v) {
			t.Errorf("ticket.show detail dropped %q:\n%s", v, got)
		}
	}
}

// TestTicketInboxTableIsColorless pins that the operator's ticket surfaces emit
// ZERO ANSI even on a color-enabled tty: the ticket statuses (open/answered/
// closed) map to NO status role, and the quickstart card is printed raw. This is
// the "already colorless" leg of the NO_COLOR guarantee — the ticket table never
// colorizes in the first place, so there is nothing to degrade.
func TestTicketInboxTableIsColorless(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.color = true // pretend a color-capable tty
	renderSuccess(w, manifest.Command{DefaultOutput: "table"}, []byte(ticketInboxFixture))
	if got := stdout.String(); strings.Contains(got, "\x1b") {
		t.Fatalf("ticket inbox table emitted ANSI on a color tty; want colorless:\n%q", got)
	}
}

// TestNoColorEnvDisablesColor pins the NO_COLOR convention (https://no-color.org):
// the env var, when set, forces color off through the same seam --no-color and
// the non-tty default use — so any painted table (cloud/hetzner status, or a
// future colorized ticket state) degrades to plain text. This is the "when
// NO_COLOR is set" leg of the guarantee.
func TestNoColorEnvDisablesColor(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.color = true // pretend a color tty…
	w.applyGlobals(globals{output: "table", outputSet: true})
	if w.color {
		t.Fatal("NO_COLOR in the environment must force color off")
	}
	if got := w.paintCell("live", "live"); got != "live" {
		t.Errorf("with NO_COLOR set, paintCell must be a no-op; got %q", got)
	}
}

// TestTicketsManifestDispatch proves the tickets verbs fall out of the
// capabilities manifest with ZERO bespoke Go command code: parsed from the
// full-manifest fixture, each ticket / ticket-key command looks up in the tree,
// binds its :id path param, and dispatches to the right method + URL. This is
// the whole point of the manifest-first slice — no Go changes beyond the
// fixture drive the new noun.
func TestTicketsManifestDispatch(t *testing.T) {
	m, tree := loadTreeFrom(t, fullManifest)
	ctx := manifest.Context{Server: "http://localhost:4000"}

	cases := []struct {
		noun, verb string
		method     string
		path       string // flat template (pre-fill)
		args       map[string]string
		wantURL    string
	}{
		{"ticket", "inbox", "GET", "/v1/tickets/inbox", nil,
			"http://localhost:4000/v1/tickets/inbox"},
		{"ticket", "ls", "GET", "/v1/tickets", nil,
			"http://localhost:4000/v1/tickets"},
		{"ticket", "show", "GET", "/v1/tickets/inbox/:id", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/inbox/tk-7"},
		{"ticket", "file", "POST", "/v1/tickets", nil,
			"http://localhost:4000/v1/tickets"},
		{"ticket", "reply", "POST", "/v1/tickets/:id/messages", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/messages"},
		{"ticket", "answer", "POST", "/v1/tickets/:id/answer", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/answer"},
		{"ticket", "close", "POST", "/v1/tickets/:id/close", map[string]string{"id": "tk-7"},
			"http://localhost:4000/v1/tickets/tk-7/close"},
		{"ticket-key", "mint", "POST", "/v1/plugins/tickets/keys", nil,
			"http://localhost:4000/v1/plugins/tickets/keys"},
		{"ticket-key", "ls", "GET", "/v1/plugins/tickets/keys", nil,
			"http://localhost:4000/v1/plugins/tickets/keys"},
		{"ticket-key", "rotate", "POST", "/v1/plugins/tickets/keys/:id/rotate", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1/rotate"},
		{"ticket-key", "pause", "POST", "/v1/plugins/tickets/keys/:id/pause", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1/pause"},
		{"ticket-key", "unpause", "POST", "/v1/plugins/tickets/keys/:id/unpause", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1/unpause"},
		{"ticket-key", "revoke", "DELETE", "/v1/plugins/tickets/keys/:id", map[string]string{"id": "k-1"},
			"http://localhost:4000/v1/plugins/tickets/keys/k-1"},
	}

	for _, tc := range cases {
		cmd, ok := tree.Lookup(tc.noun, tc.verb)
		if !ok {
			t.Errorf("%s %s missing from full-manifest fixture", tc.noun, tc.verb)
			continue
		}
		if cmd.HTTP.Method != tc.method || cmd.HTTP.PathTemplate != tc.path {
			t.Errorf("%s %s http = %s %s, want %s %s",
				tc.noun, tc.verb, cmd.HTTP.Method, cmd.HTTP.PathTemplate, tc.method, tc.path)
		}
		gotURL, err := m.BuildURL(*cmd, ctx, tc.args)
		if err != nil {
			t.Errorf("BuildURL %s %s: %v", tc.noun, tc.verb, err)
			continue
		}
		if gotURL != tc.wantURL {
			t.Errorf("%s %s url = %q, want %q", tc.noun, tc.verb, gotURL, tc.wantURL)
		}
	}
}

// TestTicketsPathParamNotInBody asserts the :id path placeholder is consumed by
// the URL and never leaks into a write body — bp ticket reply <id> <body> must
// send {"body":…}, not {"id":…,"body":…}. Same invariant the task claim/close
// tests pin, applied to the ticket noun.
func TestTicketsPathParamNotInBody(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	reply, ok := tree.Lookup("ticket", "reply")
	if !ok {
		t.Fatal("ticket reply missing from full-manifest fixture")
	}

	// bp ticket reply tk-7 "please advise"
	args, err := bindArgs(*reply, []string{"tk-7", "please advise"})
	if err != nil {
		t.Fatalf("bindArgs ticket reply: %v", err)
	}
	body, _, ct, err := buildBody(*reply, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody ticket reply: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("reply content-type = %q, want application/json", ct)
	}
	var obj map[string]any
	if json.Unmarshal(body, &obj) != nil {
		t.Fatalf("reply body not valid JSON: %s", body)
	}
	if obj["body"] != "please advise" {
		t.Errorf("reply body.body = %v, want \"please advise\"; body = %s", obj["body"], body)
	}
	if _, leaked := obj["id"]; leaked {
		t.Errorf("path arg id must not appear in reply body: %s", body)
	}
}

// TestTicketFileBody asserts the 2-minute first-ticket path: bp ticket file
// <subject> <body> seeds BOTH body args (neither is a path placeholder).
func TestTicketFileBody(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	file, ok := tree.Lookup("ticket", "file")
	if !ok {
		t.Fatal("ticket file missing from full-manifest fixture")
	}
	args, err := bindArgs(*file, []string{"Broken export", "The ONIX file 500s."})
	if err != nil {
		t.Fatalf("bindArgs ticket file: %v", err)
	}
	body, _, _, err := buildBody(*file, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody ticket file: %v", err)
	}
	var obj map[string]any
	if json.Unmarshal(body, &obj) != nil {
		t.Fatalf("file body not valid JSON: %s", body)
	}
	if obj["subject"] != "Broken export" || obj["body"] != "The ONIX file 500s." {
		t.Errorf("file body = %s, want subject+body", body)
	}
}

// TestTicketAnswerCloseFlag asserts the --close bool flag on ticket answer rides
// as a query param (?close=true) the way applyQuery sends set bool flags — the
// manifest carries it, no Go command code declares it.
func TestTicketAnswerCloseFlag(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	answer, ok := tree.Lookup("ticket", "answer")
	if !ok {
		t.Fatal("ticket answer missing from full-manifest fixture")
	}
	if _, ok := splitFlagLookup(*answer, "close"); !ok {
		t.Fatal("ticket answer must declare the --close flag in the manifest fixture")
	}
	got := applyQuery("http://localhost:4000/v1/tickets/tk-7/answer",
		globals{}, *answer, map[string][]string{"close": {"true"}}, map[string]string{"id": "tk-7"})
	if got != "http://localhost:4000/v1/tickets/tk-7/answer?close=true" {
		t.Errorf("answer --close query = %q, want ...?close=true", got)
	}
}

// TestTicketKeyMintDefaultsToTable pins that mint (and rotate) default to the
// `table` output so the quickstart handoff card renders as the primary human
// output — NOT `minimal`, which would hide the raw key the operator forwards.
func TestTicketKeyMintDefaultsToTable(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	for _, verb := range []string{"mint", "rotate"} {
		cmd, ok := tree.Lookup("ticket-key", verb)
		if !ok {
			t.Fatalf("ticket-key %s missing from full-manifest fixture", verb)
		}
		if cmd.DefaultOutput != "table" {
			t.Errorf("ticket-key %s default_output = %q, want table", verb, cmd.DefaultOutput)
		}
	}
}

// TestQuickstartCardRendersVerbatim proves the small renderer touch: a 2xx
// response carrying a string "quickstart" field prints that block verbatim as
// the primary human output under the `table` default (the mint handoff card),
// and NOT under `minimal` (the terse agent receipt keeps the key id line).
func TestQuickstartCardRendersVerbatim(t *testing.T) {
	card := "bptk_live_abc123\n\ncurl -H 'Authorization: Bearer bptk_live_abc123' http://localhost:4000/v1/tickets"
	resp := []byte(`{"result":{"id":"k-1","quickstart":` + mustJSONString(card) + `}}`)

	// table default: the card is printed verbatim.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	cmd := manifest.Command{DefaultOutput: "table"}
	renderSuccess(w, cmd, resp)
	if got := stdout.String(); got != card+"\n" {
		t.Errorf("table render = %q, want the verbatim card %q", got, card+"\n")
	}

	// minimal: the card is NOT the output — the terse receipt surfaces the id.
	var mStdout, mStderr bytes.Buffer
	wm := newWriter(&mStdout, &mStderr)
	wm.output = "minimal"
	renderSuccess(wm, cmd, resp)
	if got := mStdout.String(); got == card+"\n" {
		t.Errorf("minimal render leaked the full card: %q", got)
	}
	if !bytes.Contains(mStdout.Bytes(), []byte("k-1")) {
		t.Errorf("minimal render should surface the key id; got %q", mStdout.String())
	}
}

// mustJSONString encodes s as a JSON string literal (with surrounding quotes) so
// it can be spliced into a hand-built response body.
func mustJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
