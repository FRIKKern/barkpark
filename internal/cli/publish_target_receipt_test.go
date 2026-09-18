package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE MEASUREMENT THIS FILE LOCKS (BP-ONB-18,
// onb-residue-onb18-target-mismatch-receipt).
//
// THE REPRODUCTION, run 2026-09-18 against two local fake servers built from the
// repo's own capabilities fixture, with bp built from origin/main@45a636068:
//
//	$ bp doc publish paper my-paper -q                  # saved context → :8731
//	rev: 2
//	exit=0
//	$ BARKPARK_SERVER=http://127.0.0.1:8732 \
//	  bp doc publish paper my-paper -q                  # → :8732
//	rev: 2
//	exit=0
//	# both servers logged their POST; the two receipts are byte-identical.
//
// The row's premise is TRUE on origin/main, not stale. `rev:` is the whole
// receipt and a rev is minted per transaction by the RECEIVING server, so it is
// not an identity and discriminates nothing. Nothing else in the receipt names
// a host.
//
// RED WITHOUT the emitter — the anchor is the ONE
// `emitPublishTarget(out, cmd, req.url, status)` line in run.go; delete it and
// the two discriminating tests below fail with the receipt that started this:
//
//	--- FAIL: TestPublishReceiptNamesTheServerItWroteTo/minimal
//	    the publish receipt never named the server it wrote to.
//	    stdout="rev: 2\n" stderr=""
//	--- FAIL: TestTwoServersProduceTwoDifferentReceipts
//	    the receipts for two DIFFERENT servers are indistinguishable
//
// The non-publish and non-2xx controls stay green either way — that is what
// makes them controls: they prove the line is scoped, not that it exists.

// fakePublishAPI answers a publish POST with a fixed, server-INDEPENDENT body,
// so the only thing that can distinguish two of these is what the CLI says
// about the target. The body is deliberately the SAME on both servers: a fake
// that stamped its own name into the rev would manufacture the discrimination
// the emitter is supposed to supply.
type fakePublishAPI struct {
	posts int
	path  string
	fail  bool
}

const publishReceiptBody = `{"transactionId":"tx-1","results":[{"id":"paper-abc","operation":"publish"}],"rev":"2"}`

func (f *fakePublishAPI) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		f.posts++
		f.path = r.URL.Path
		if f.fail {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"nope"}}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(publishReceiptBody))
	})
}

// docPublishCommand mirrors the real manifest entry
// (internal/manifest/testdata/capabilities-guerrilla-2026-09-04.json:
// id doc.publish, POST /v1/data/mutate/:dataset, writes true).
func docPublishCommand() manifest.Command {
	return manifest.Command{
		ID:            "doc.publish",
		Noun:          "doc",
		Verb:          "publish",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/v1/data/mutate/production"},
		Writes:        true,
		DefaultOutput: "minimal",
	}
}

func runPublishAgainst(t *testing.T, srvURL, shape string, cmd manifest.Command) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: shape, outputSet: true, yes: true}
	out.applyGlobals(g)
	code := runCommand(out, g, manifest.Context{Server: srvURL}, &manifest.Manifest{}, cmd, nil)
	return stdout.String(), stderr.String(), code
}

// TestPublishReceiptNamesTheServerItWroteTo is criterion c1: the receipt names
// the RESOLVED target, in every output shape, and names the one the bytes
// actually went to.
func TestPublishReceiptNamesTheServerItWroteTo(t *testing.T) {
	for _, shape := range []string{"minimal", "table", "json", "yaml"} {
		t.Run(shape, func(t *testing.T) {
			fake := &fakePublishAPI{}
			srv := httptest.NewServer(fake.handler())
			defer srv.Close()

			stdout, stderr, code := runPublishAgainst(t, srv.URL, shape, docPublishCommand())
			if code != exitOK {
				t.Fatalf("publish exit = %d, want 0; stdout=%q stderr=%q", code, stdout, stderr)
			}
			if fake.posts != 1 {
				t.Fatalf("the emitter changed the request count: posts=%d, want 1", fake.posts)
			}
			if !strings.Contains(stderr, "published to "+srv.URL) {
				t.Fatalf("the publish receipt never named the server it wrote to.\nstdout=%q stderr=%q",
					stdout, stderr)
			}
			// The dataset/scope half of the same mistake rides the same line.
			if !strings.Contains(stderr, fake.path) {
				t.Fatalf("the receipt named the host but not the route %q it wrote through.\nstderr=%q",
					fake.path, stderr)
			}
			// stdout is untouched: every pipeline reading the rev is unaffected.
			if strings.Contains(stdout, srv.URL) {
				t.Fatalf("the target line leaked onto stdout: %q", stdout)
			}
		})
	}
}

// TestTwoServersProduceTwoDifferentReceipts is the DISCRIMINATION control, and
// it is the task's whole subject: two servers answering byte-identical bodies
// must produce receipts a reader can tell apart. It also pins the trap itself —
// the two STDOUTs are identical, which is why stderr has to carry the fact.
func TestTwoServersProduceTwoDifferentReceipts(t *testing.T) {
	fakeA, fakeB := &fakePublishAPI{}, &fakePublishAPI{}
	srvA := httptest.NewServer(fakeA.handler())
	defer srvA.Close()
	srvB := httptest.NewServer(fakeB.handler())
	defer srvB.Close()

	outA, errA, codeA := runPublishAgainst(t, srvA.URL, "minimal", docPublishCommand())
	outB, errB, codeB := runPublishAgainst(t, srvB.URL, "minimal", docPublishCommand())
	if codeA != exitOK || codeB != exitOK {
		t.Fatalf("exits = %d/%d, want 0/0", codeA, codeB)
	}
	// THE TRAP, asserted rather than described: stdout cannot tell them apart.
	if outA != outB {
		t.Fatalf("precondition broken — the two stdouts already differ (%q vs %q), "+
			"so this test would pass without the emitter", outA, outB)
	}
	if errA == errB {
		t.Fatalf("the receipts for two DIFFERENT servers are indistinguishable: %q", errA)
	}
	if !strings.Contains(errA, srvA.URL) || strings.Contains(errA, srvB.URL) {
		t.Fatalf("the receipt for server A names the wrong host.\nA=%q (want %s, not %s)",
			errA, srvA.URL, srvB.URL)
	}
	if !strings.Contains(errB, srvB.URL) || strings.Contains(errB, srvA.URL) {
		t.Fatalf("the receipt for server B names the wrong host.\nB=%q (want %s, not %s)",
			errB, srvB.URL, srvA.URL)
	}
}

// TestPublishTargetIsSilentOnNonPublishAndOnFailure is the SCOPE control: a
// line that printed on every command, or on a refusal, would pass the two tests
// above while making the receipt noisier and less trustworthy, not more.
func TestPublishTargetIsSilentOnNonPublishAndOnFailure(t *testing.T) {
	t.Run("non-publish write", func(t *testing.T) {
		fake := &fakePublishAPI{}
		srv := httptest.NewServer(fake.handler())
		defer srv.Close()
		_, stderr, _ := runPublishAgainst(t, srv.URL, "minimal", mutateCommand())
		if strings.Contains(stderr, "published to") {
			t.Fatalf("the publish-target line fired on `doc mutate`: %q", stderr)
		}
	})
	t.Run("refused publish", func(t *testing.T) {
		fake := &fakePublishAPI{fail: true}
		srv := httptest.NewServer(fake.handler())
		defer srv.Close()
		_, stderr, code := runPublishAgainst(t, srv.URL, "minimal", docPublishCommand())
		if code == exitOK {
			t.Fatalf("precondition broken — the 403 arm exited 0, so this control measures nothing")
		}
		if strings.Contains(stderr, "published to") {
			t.Fatalf("a REFUSED publish claimed it published somewhere: %q", stderr)
		}
	})
}

// TestPublishTargetLineIsDerivedNotGuessed pins the unit-level bound: an
// unparseable or relative request URL yields NO line rather than a guess.
func TestPublishTargetLineIsDerivedNotGuessed(t *testing.T) {
	cmd := docPublishCommand()
	for _, bad := range []string{"", "   ", "/v1/data/mutate/production", "::not a url"} {
		if line := publishTargetLine(cmd, bad, http.StatusOK); line != "" {
			t.Fatalf("publishTargetLine(%q) guessed a target: %q", bad, line)
		}
	}
	got := publishTargetLine(cmd, "https://guerrilla.barkpark.cloud/v1/data/mutate/production", http.StatusOK)
	want := "published to https://guerrilla.barkpark.cloud (POST /v1/data/mutate/production)"
	if got != want {
		t.Fatalf("publishTargetLine = %q, want %q", got, want)
	}
}
