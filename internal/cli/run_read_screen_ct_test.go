package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// REMAINDER A of the CLI honesty wave (task-d5640a667988b1d1).
//
// A load balancer answering HTTP 200 with the plaintext banner
// `upstream connect error` used to be rendered as THE ANSWER at exit 0, in all
// four output shapes, because the read screen refused an HTML document but not
// arbitrary non-JSON — and it could not refuse arbitrary non-JSON, because
// onixedit.export streams honest ONIX 3.0 XML through the same dispatch.
//
// The discriminator is the response Content-Type, which sendManifestRequest
// now carries: a server that DECLARES application/json and sends bytes that
// are not JSON is contradicting itself. A server that declares XML and sends
// XML is not.
func TestScreenUnpaginatedReadUsesTheContentType(t *testing.T) {
	cmd := nonPaginatedReadCommand()
	gateway := []byte("upstream connect error")

	t.Run("declared JSON that is not JSON is refused", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		code, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, gateway, "application/json; charset=utf-8")
		if !handled || code != exitGeneric {
			t.Fatalf("handled=%v code=%d, want true/%d — the gateway banner passed as an answer", handled, code, exitGeneric)
		}
		if !strings.Contains(stderr.String(), "transport lie") {
			t.Errorf("refusal does not name the fault: %q", stderr.String())
		}
		if stdout.Len() != 0 {
			t.Errorf("a refused read still wrote to stdout: %q", stdout.String())
		}
	})

	t.Run("onixedit.export ONIX XML still passes", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		onix := []byte(`<?xml version="1.0"?><ONIXMessage release="3.0"><Product/></ONIXMessage>`)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, onix, "application/xml"); handled {
			t.Fatalf("an honest ONIX export was refused: %q", stderr.String())
		}
	})

	t.Run("a +json suffix type counts as JSON", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, gateway, "application/problem+json"); !handled {
			t.Errorf("a +json media type escaped the screen")
		}
	})

	t.Run("an UNDECLARED plaintext body still passes", func(t *testing.T) {
		// Deliberate. Without a declared type this function cannot tell a
		// gateway banner from an honest plaintext payload, and inventing a
		// rule the manifest does not state would red the honest one. The
		// screen widens only as far as the evidence reaches.
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, gateway, ""); handled {
			t.Errorf("an undeclared plaintext body was refused — the screen over-reached")
		}
	})

	t.Run("declared JSON that IS JSON passes", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, []byte(`{"id":"p1"}`), "application/json"); handled {
			t.Errorf("an honest JSON answer was refused: %q", stderr.String())
		}
	})

	t.Run("a malformed Content-Type is not a refusal", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, gateway, "application/json;;;charset"); handled {
			t.Errorf("an unparseable Content-Type was treated as a declaration")
		}
	})

	t.Run("a WRITE is still outside this screen", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		w := nonPaginatedReadCommand()
		w.Writes = true
		if _, handled := screenUnpaginatedRead(out, w, http.StatusOK, gateway, "application/json"); handled {
			t.Errorf("the read screen swallowed a write — screenWriteReceipt owns that path")
		}
	})
}

// END TO END through the real dispatch, because the unit test above proves the
// SCREEN and not the WIRING: if sendManifestRequest dropped the header again,
// every subtest above would still pass. This one serves the exact measured
// payload — HTTP 200, Content-Type application/json, the 22-byte plaintext
// banner a load balancer emits — and asserts the CLI refuses it in all four
// output shapes instead of printing it as the answer at exit 0.
func TestRunCommandRefusesAPlaintextGatewayTwoHundred(t *testing.T) {
	const banner = "upstream connect error"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(banner))
	}))
	defer srv.Close()

	for _, output := range []string{"table", "json", "yaml", "minimal"} {
		t.Run(output, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			g := globals{output: output, outputSet: true}
			out.applyGlobals(g)

			code := runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
				nonPaginatedReadCommand(), nil)

			// The refusal CHANNEL differs by output shape and that is by
			// design: -o table/minimal write the human refusal to stderr,
			// while -o json/yaml render a machine {"ok":false,...} envelope
			// on stdout so a scripted caller can parse it. Assert on the
			// union, not on one channel, or this test pins a rendering
			// decision it does not own.
			both := stdout.String() + stderr.String()

			if code == 0 {
				t.Fatalf("-o %s exited 0 on a gateway banner; out=%q", output, both)
			}
			if !strings.Contains(both, "unreadable_read") && !strings.Contains(both, "unreadable read") {
				t.Errorf("-o %s did not name the refusal: %q", output, both)
			}
			if !strings.Contains(both, "transport lie") {
				t.Errorf("-o %s did not name WHY: %q", output, both)
			}
			// The banner may appear ONLY inside the capped preview the
			// refusal quotes — never as the rendered answer. A rendered
			// answer would carry no refusal code at all, which the checks
			// above already exclude; what this pins is that the preview
			// stays bounded rather than spilling the whole body.
			if len(both) > 4096 {
				t.Errorf("-o %s refusal is unbounded (%d bytes) — the preview cap slipped", output, len(both))
			}
		})
	}
}

// The control arm: the SAME dispatch, an honest ONIX export, must still reach
// the caller. A screen that refuses the gateway by refusing everything non-JSON
// would pass the test above and break the product.
func TestRunCommandStillDeliversAnHonestXMLExport(t *testing.T) {
	const onix = `<?xml version="1.0"?><ONIXMessage release="3.0"><Product/></ONIXMessage>`

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(onix))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true}
	out.applyGlobals(g)

	code := runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
		nonPaginatedReadCommand(), nil)

	if strings.Contains(stderr.String(), "unreadable read") {
		t.Fatalf("an honest ONIX export was refused (exit %d): %q", code, stderr.String())
	}
}
