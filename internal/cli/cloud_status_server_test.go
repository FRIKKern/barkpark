package cli

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// cloud_status_server_test.go — `bp cloud status` says whether a launch took a
// warm server or creates a new one (task-9de1dbcf13951044). The fleet body is the
// control plane's own spelling: barkpark_json/6 emits `provision_console` as a
// list of {"line","at"} entries, and the line is the provisioner's step framing
// "create: progress — <caption>". The captions are written out literally so the
// test compiles against the code before the fix and fails there.
const statusServerFleet = `{"barkparks":[
	{"id":"a","name":"cold-box","host":"","provision_status":"claimed",
	 "provision_console":[
	   {"line":"provisioning cold-box.barkpark.cloud (nbg1 / cx23)…","at":"2026-11-19T20:00:00Z"},
	   {"line":"create: progress — No warm server: warm pool is off on the worker (WARM_POOL_SIZE=0) — creating a new server","at":"2026-11-19T20:00:01Z"},
	   {"line":"create: started","at":"2026-11-19T20:00:02Z"}]},
	{"id":"b","name":"warm-box","host":"","provision_status":"claimed",
	 "provision_console":[
	   {"line":"create: progress — Warm server warm-52d0bbcf claimed","at":"2026-11-19T20:00:01Z"}]},
	{"id":"c","name":"failed-box","host":"","provision_status":"failed","provision_error":"migrate failed",
	 "provision_console":[
	   {"line":"create: progress — Warm server warm-1 claimed","at":"2026-11-19T20:00:01Z"},
	   {"line":"create: progress — No warm server: warm server warm-1 failed to assign: boom — creating a new server","at":"2026-11-19T20:00:09Z"}]},
	{"id":"d","name":"quiet-box","host":"","provision_status":"claimed","provision_console":[]}
]}`

func TestCloudStatusSaysWarmOrNewServer(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, statusServerFleet)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	line := func(name string) string {
		for _, l := range strings.Split(stdout, "\n") {
			if strings.Contains(l, " "+name+" ") {
				return l
			}
		}
		t.Fatalf("no row for %s:\n%s", name, stdout)
		return ""
	}
	if l := line("cold-box"); !strings.Contains(l, "server: new — warm pool is off on the worker (WARM_POOL_SIZE=0)") {
		t.Errorf("cold-box row does not say why it creates a new server:\n%s", l)
	}
	if l := line("warm-box"); !strings.Contains(l, "server: warm (warm-52d0bbcf)") {
		t.Errorf("warm-box row does not name its warm server:\n%s", l)
	}
	// The later line wins: the warm server failed to assign, so a new one is made.
	if l := line("failed-box"); !strings.Contains(l, "migrate failed") ||
		!strings.Contains(l, "server: new — warm server warm-1 failed to assign: boom") {
		t.Errorf("failed-box row should carry its error and the failed-assign line:\n%s", l)
	}
	if l := line("quiet-box"); strings.Contains(l, "server:") {
		t.Errorf("a row without the line must show nothing new:\n%s", l)
	}
}
