package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// stubBrowser replaces browserOpener with a recorder for the duration of the
// test, returning a pointer to the URL it was (last) asked to open ("" = never).
func stubBrowser(t *testing.T) *string {
	t.Helper()
	var opened string
	prev := browserOpener
	browserOpener = func(url string) error {
		opened = url
		return nil
	}
	t.Cleanup(func() { browserOpener = prev })
	return &opened
}

// TestOpenHashStability pins the legacy-stable hash for EVERY target form
// (charter decision 14) plus the error forms.
func TestOpenHashStability(t *testing.T) {
	ok := []struct {
		kind, id, want string
	}{
		{"fleet", "", "#fleet"},
		{"sites", "", "#sites"},
		{"activity", "", "#activity"},
		{"instance", "abc123", "#instance/abc123"},
		{"site", "s-9", "#site/s-9"},
	}
	for _, c := range ok {
		got, err := openHash(c.kind, c.id)
		if err != nil {
			t.Errorf("openHash(%q,%q) errored: %v", c.kind, c.id, err)
			continue
		}
		if got != c.want {
			t.Errorf("openHash(%q,%q) = %q, want %q", c.kind, c.id, got, c.want)
		}
	}
	bad := []struct{ kind, id string }{
		{"fleet", "x"},    // tab takes no id
		{"instance", ""},  // drill-down needs an id
		{"site", ""},      // drill-down needs an id
		{"settings", ""},  // never routable
		{"nonsense", "x"}, // unknown
	}
	for _, c := range bad {
		if _, err := openHash(c.kind, c.id); err == nil {
			t.Errorf("openHash(%q,%q) should have errored", c.kind, c.id)
		}
	}
}

func TestDashboardURL(t *testing.T) {
	cases := []struct{ base, hash, want string }{
		{"https://api.barkpark.cloud", "#fleet", "https://api.barkpark.cloud/#fleet"},
		{"https://api.barkpark.cloud/", "#sites", "https://api.barkpark.cloud/#sites"},
		{"http://localhost:4100", "#instance/x", "http://localhost:4100/#instance/x"},
	}
	for _, c := range cases {
		if got := dashboardURL(c.base, c.hash); got != c.want {
			t.Errorf("dashboardURL(%q,%q) = %q, want %q", c.base, c.hash, got, c.want)
		}
	}
}

func TestLooksLikeUUID(t *testing.T) {
	if !looksLikeUUID("11111111-2222-3333-4444-555555555555") {
		t.Error("canonical UUID should match")
	}
	for _, s := range []string{"", "my-box", "11111111222233334444555555555555", "zzzzzzzz-2222-3333-4444-555555555555"} {
		if looksLikeUUID(s) {
			t.Errorf("%q should NOT look like a UUID", s)
		}
	}
}

// TestRunCloudOpenPrintOnly: --print-only prints the URL and NEVER opens a
// browser, even a would-be tty. A UUID needs no network.
func TestRunCloudOpenPrintOnly(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	opened := stubBrowser(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.isTTY = true // pretend a terminal…
	w.output = "table"
	code := runCloudOpen(w, globals{}, []string{"instance", "11111111-2222-3333-4444-555555555555", "--print-only"})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stderr.String())
	}
	wantURL := "https://dash.test/#instance/11111111-2222-3333-4444-555555555555"
	if strings.TrimSpace(stdout.String()) != wantURL {
		t.Fatalf("printed %q, want %q", strings.TrimSpace(stdout.String()), wantURL)
	}
	if *opened != "" {
		t.Fatalf("--print-only must not open a browser; opened %q", *opened)
	}
}

// TestRunCloudOpenOpensOnTTY: on a tty (no --print-only) the URL is printed AND
// the browser is opened with the same URL.
func TestRunCloudOpenOpensOnTTY(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	opened := stubBrowser(t)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.isTTY = true
	w.output = "table"
	code := runCloudOpen(w, globals{}, []string{"fleet"})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stderr.String())
	}
	wantURL := "https://dash.test/#fleet"
	if strings.TrimSpace(stdout.String()) != wantURL {
		t.Fatalf("printed %q, want %q", strings.TrimSpace(stdout.String()), wantURL)
	}
	if *opened != wantURL {
		t.Fatalf("browser opened %q, want %q", *opened, wantURL)
	}
}

// TestRunCloudOpenPipedNeverOpens: piped (non-tty) prints the URL but never
// launches a browser — the scriptable contract.
func TestRunCloudOpenPipedNeverOpens(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	opened := stubBrowser(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // runCloudCapture leaves table when jsonOut=false and buffer→pipe
		return runCloudOpen(out, globals{}, []string{"activity"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if strings.TrimSpace(stdout) != "https://dash.test/#activity" {
		t.Fatalf("printed %q", strings.TrimSpace(stdout))
	}
	if *opened != "" {
		t.Fatalf("piped output must not open a browser; opened %q", *opened)
	}
}

// TestRunCloudOpenResolvesName resolves an instance NAME to its id via the fleet
// list endpoint and builds the id-based hash.
func TestRunCloudOpenResolvesName(t *testing.T) {
	withTempConfigHome(t)
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = io.WriteString(w, `{"barkparks":[{"id":"bp-77","name":"acme","slug":"acme"}]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)
	opened := stubBrowser(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"instance", "acme"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	if gotPath != "/v1/barkparks" {
		t.Fatalf("resolve hit %q, want /v1/barkparks", gotPath)
	}
	wantURL := srv.URL + "/#instance/bp-77"
	if strings.TrimSpace(stdout) != wantURL {
		t.Fatalf("printed %q, want %q", strings.TrimSpace(stdout), wantURL)
	}
	if *opened != "" {
		t.Fatalf("piped: must not open; opened %q", *opened)
	}
}

// TestRunCloudOpenUnknownName: a name that resolves to nothing is not_found.
func TestRunCloudOpenUnknownName(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)
	stubBrowser(t)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // human path: the message lands on stderr
		return runCloudOpen(out, globals{}, []string{"instance", "ghost"})
	})
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !bytes.Contains([]byte(stderr), []byte("no Barkpark matches")) {
		t.Fatalf("stderr = %s", stderr)
	}
}

// TestRunCloudOpenJSON emits the {ok,target,url,opened} envelope.
func TestRunCloudOpenJSON(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	stubBrowser(t)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runCloudOpen(out, globals{}, []string{"sites"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	for _, want := range []string{`"ok": true`, `"target": "sites"`, `"url": "https://dash.test/#sites"`, `"opened": false`} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("json missing %q:\n%s", want, stdout)
		}
	}
}

// TestRunCloudOpenInstanceMissingID: a drill-down with no id is a usage error
// (no generic resolve failure), and never touches the network or a browser.
func TestRunCloudOpenInstanceMissingID(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	opened := stubBrowser(t)

	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runCloudOpen(out, globals{}, []string{"instance"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if *opened != "" {
		t.Fatalf("must not open a browser; opened %q", *opened)
	}
}

// TestRunCloudDispatch proves `bp cloud status` / `bp cloud open` route through
// the cloud command tree, and an unknown subcommand is a usage error.
func TestRunCloudDispatch(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	stubBrowser(t)

	// open routes (fleet needs no network).
	if _, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloud(out, globals{}, []string{"open", "fleet"})
	}); code != exitOK {
		t.Fatalf("`bp cloud open fleet` exit = %d", code)
	}
	// unknown subcommand is usage.
	if _, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runCloud(out, globals{}, []string{"bogus"})
	}); code != exitUsage {
		t.Fatalf("`bp cloud bogus` exit = %d, want %d", code, exitUsage)
	}
}

// TestRunCloudOpenBadTarget: an unknown target is a usage error.
func TestRunCloudOpenBadTarget(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	stubBrowser(t)

	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runCloudOpen(out, globals{}, []string{"widgets"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
}
