package cli

import (
	"bytes"
	"strings"
	"testing"
)

func minimalOf(t *testing.T, payload string) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderMinimal(w, []byte(payload))
	if stderr.Len() != 0 {
		t.Fatalf("renderMinimal wrote to stderr: %q", stderr.String())
	}
	return strings.TrimSpace(stdout.String())
}

// The class, measured against the server's real bodies. renderMinimal harvests
// ids and a rev and prints "ok" when it finds neither, so the field that reports
// the OUTCOME was invisible to it. Three of these printed a DIFFERENT identifier
// in its place, which reads as confirmation of something that did not occur.
func TestWriteReceiptsCarryTheirOutcome(t *testing.T) {
	cases := []struct {
		verb    string
		payload string
		before  string   // what the receipt used to say, verbatim
		want    []string // every fragment the new receipt must carry
		absent  string   // a fragment it must not carry
	}{
		{
			verb:    "share rm (nothing matched)",
			payload: `{"removed":0,"scope":"default/default/production"}`,
			before:  "id: default/default/production",
			want:    []string{"removed: 0", "default/default/production"},
		},
		{
			verb:    "share rm (two revoked)",
			payload: `{"removed":2,"scope":"default/default/production"}`,
			before:  "id: default/default/production",
			want:    []string{"removed: 2", "default/default/production"},
		},
		{
			verb:    "media delete",
			payload: `{"deleted":"asset-42","filename":"cover.png","dataset":"production"}`,
			before:  "ok",
			want:    []string{"deleted: asset-42"},
		},
		{
			// The old receipt printed the webhook's NAME under an "id:" label.
			// `bp webhook delete` takes an id, not a name.
			verb:    "webhook delete",
			payload: `{"deleted":"wh-1","name":"my-hook","dataset":"production"}`,
			before:  "id: my-hook",
			want:    []string{"deleted: wh-1"},
			absent:  "id: my-hook",
		},
		{
			// The old receipt printed the schema row's uuid. `bp schema delete`
			// takes a NAME.
			verb:    "schema delete",
			payload: `{"deleted":"Post","id":"7f0c-uuid","dataset":"production"}`,
			before:  "id: 7f0c-uuid",
			want:    []string{"deleted: Post"},
		},
		{
			// The rev is still worth keeping on a doc delete, so it prints below.
			verb:    "doc delete",
			payload: `{"deleted":"post-1","type":"post","rev":"r1"}`,
			before:  "rev: r1",
			want:    []string{"deleted: post-1", "rev: r1"},
		},
		{
			// A removed seat carries principal_id/identity and no "id" at all,
			// which is why collectIDs found nothing and this printed a bare "ok".
			verb:    "workspace member-rm",
			payload: `{"removed":{"principal_id":"u-1","identity":"a@b.no","role":"member"}}`,
			before:  "ok",
			want:    []string{"removed: u-1"},
		},
		{
			// The verb you reach for when a credential has leaked. It answered
			// "ok" and never echoed what the server returned.
			verb:    "token revoke",
			payload: `{"revoked":{"id":"ac8ff595","label":"lead-verify","revoked_at":"2026-08-24T10:00:00Z"}}`,
			before:  "ok",
			want:    []string{"revoked: ac8ff595"},
		},
		{
			// HTTP 200 by design — the controller returns the delivery VERDICT in
			// the body. The command exists to tell you whether an endpoint works.
			verb:    "webhook test-send (delivery failed)",
			payload: `{"delivery":{"id":"d1","status":"failed","attempts":1,"last_error_text":"connection refused"}}`,
			before:  "ok",
			want:    []string{"failed", "connection refused"},
		},
	}

	for _, c := range cases {
		t.Run(c.verb, func(t *testing.T) {
			got := minimalOf(t, c.payload)
			if got == c.before {
				t.Fatalf("receipt is unchanged at %q — the outcome is still dropped", got)
			}
			for _, want := range c.want {
				if !strings.Contains(got, want) {
					t.Errorf("receipt %q is missing %q", got, want)
				}
			}
			if c.absent != "" && strings.Contains(got, c.absent) {
				t.Errorf("receipt %q still carries %q", got, c.absent)
			}
		})
	}
}

// The sharpest instance, pinned on its own: `share rm` is a revocation verb, and
// it printed a byte-identical receipt for "two shares revoked" and "nothing was
// revoked", both at exit 0.
func TestShareRemoveDistinguishesZeroFromSome(t *testing.T) {
	none := minimalOf(t, `{"removed":0,"scope":"default/default/production"}`)
	some := minimalOf(t, `{"removed":2,"scope":"default/default/production"}`)
	if none == some {
		t.Fatalf("a no-op revoke and a real one print the SAME receipt: %q", none)
	}
}

// A failing verdict that carries an HTTP status code names it — "the endpoint
// answered 500" and "the endpoint was unreachable" are different problems with
// different fixes.
func TestFailedVerdictNamesTheStatusCode(t *testing.T) {
	got := minimalOf(t, `{"delivery":{"status":"failed","last_status_code":500,"last_error_text":"boom"}}`)
	if !strings.Contains(got, "500") {
		t.Errorf("receipt %q does not name the status code", got)
	}
}

// A SUCCEEDING nested verdict is left alone: it is already consistent with what
// the caller was told, and hijacking that receipt would trade information for
// noise. This pins the asymmetry as deliberate.
func TestSucceedingVerdictIsLeftAlone(t *testing.T) {
	if got := minimalOf(t, `{"delivery":{"id":"d1","status":"delivered","attempts":1}}`); got != "ok" {
		t.Errorf("a successful verdict changed the receipt to %q", got)
	}
}

// A DOCUMENT is not a receipt. Envelope.render (api) flattens a document's
// content fields to the top level, so `bp doc get <type> <id> -q` can hand the
// renderer a payload whose own author-controlled field is called `removed` — a
// numeric one would otherwise be printed as this write's outcome, replacing the
// id the -q receipt exists to give.
func TestADocumentsOwnFieldIsNeverReadAsAnOutcome(t *testing.T) {
	got := minimalOf(t, `{"_id":"post-1","_type":"post","title":"Hello","updated":7,"removed":3}`)
	if !strings.Contains(got, "post-1") {
		t.Errorf("the document receipt lost its id: %q", got)
	}
	if strings.Contains(got, "updated: 7") || strings.Contains(got, "removed: 3") {
		t.Errorf("a document's content field was read as a write outcome: %q", got)
	}
}

// An outcome object with nothing that identifies it falls through to the old
// receipt rather than being replaced by a worse one.
func TestUnidentifiableOutcomeObjectFallsThrough(t *testing.T) {
	if got := minimalOf(t, `{"removed":{"role":"member","count":1}}`); got != "ok" {
		t.Errorf("an unidentifiable outcome object produced %q, want the unchanged %q", got, "ok")
	}
}

// Everything without an outcome field keeps the receipt it had.
func TestReceiptsWithoutAnOutcomeAreUnchanged(t *testing.T) {
	cases := map[string]string{
		`{"_id":"post-1","_rev":"abc"}`:         "post-1",
		`{"ok":true,"doc":{"doc_id":"task-9"}}`: "task-9",
		`{"workspace":{"slug":"acme"}}`:         "acme",
		`{"ok":false,"reason":"no_ready"}`:      "no_ready",
	}
	for payload, want := range cases {
		if got := minimalOf(t, payload); !strings.Contains(got, want) {
			t.Errorf("renderMinimal(%s) = %q, want it to carry %q", payload, got, want)
		}
	}
	if got := minimalOf(t, `{"status":"queued"}`); got != "ok" {
		t.Errorf("a payload with no id, rev or outcome should still be %q, got %q", "ok", got)
	}
}
