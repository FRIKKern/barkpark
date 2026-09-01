package cli

// hetzner_net_cmd_test.go drives the PR3 resources (volume, network, firewall,
// load-balancer, floating-ip, primary-ip, placement-group, certificate, dns)
// against the same httptest fake of api.hetzner.cloud that hetzner_cmd_test.go
// stands up: every test asserts the REAL wire request (method/path/body) and —
// on every mutating verb that returns an action — that the still-RUNNING
// action was POLLED to completion, so a fire-and-forget implementation fails.

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

// TestHetznerVolumeCreate asserts the POST /volumes body, the action+next
// -actions poll, and the structured receipt.
func TestHetznerVolumeCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"volume":{"id":9,"name":"data-1","size":10,"status":"creating","location":{"id":1,"name":"nbg1"},"linux_device":"/dev/disk/by-id/scsi-0HC_Volume_9"},
			"action":{"id":31,"command":"create_volume","status":"running","progress":0},
			"next_actions":[]
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "volume", "create", "--name", "data-1", "--size", "10", "--location", "nbg1", "--format", "ext4")
	if code != exitOK {
		t.Fatalf("volume create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/volumes")
	if !ok {
		t.Fatal("no POST /volumes was issued")
	}
	if req.Body["name"] != "data-1" || req.Body["size"] != float64(10) ||
		req.Body["location"] != "nbg1" || req.Body["format"] != "ext4" {
		t.Errorf("create body = %v, want name/size/location/format", req.Body)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("volume create never polled the running action — fire-and-forget")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("volume create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	vol, _ := payload["volume"].(map[string]any)
	if payload["ok"] != true || payload["action"] != "create" || vol["id"] != float64(9) {
		t.Errorf("receipt = %v, want ok=true action=create volume.id=9", payload)
	}
	if payload["linux_device"] != "/dev/disk/by-id/scsi-0HC_Volume_9" {
		t.Errorf("receipt linux_device = %v, want the created device path", payload["linux_device"])
	}
}

// TestHetznerVolumeAttach asserts the resolve→attach→POLL conversation: both
// the volume and server are looked up by name, the POST body carries the
// resolved server id (and automount), and the running action is polled.
func TestHetznerVolumeAttach(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "data-1" {
			t.Errorf("volume lookup name = %q, want data-1", got)
		}
		hzWriteJSON(w, 200, `{"volumes":[{"id":9,"name":"data-1","size":10,"status":"available"}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /volumes/9/actions/attach", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":32,"command":"attach_volume","status":"running","progress":0}}`)
	})
	// THE POST-READ (PDS wave 32). attach rides an ACTION endpoint that returns
	// `{action}` and nothing else, so the receipt is now built from this
	// single-resource GET on the RESOLVED id — never from the --server flag.
	f.mux.HandleFunc("GET /volumes/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volume":{"id":9,"name":"data-1","size":10,"status":"available","server":42}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":32,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "volume", "attach", "data-1", "--server", "web-1", "--automount")
	if code != exitOK {
		t.Fatalf("volume attach exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/volumes/9/actions/attach")
	if !ok {
		t.Fatal("no POST /volumes/9/actions/attach was issued")
	}
	if req.Body["server"] != float64(42) {
		t.Errorf("attach body server = %v, want the resolved id 42", req.Body["server"])
	}
	if req.Body["automount"] != true {
		t.Errorf("attach body automount = %v, want true", req.Body["automount"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("volume attach never polled the running action — fire-and-forget")
	}
	if f.count("GET", "/volumes/9") == 0 {
		t.Error("volume attach never re-read the volume — the receipt is an exit code with extra steps")
	}
	if !strings.Contains(stdout, "✓ attach — volume data-1 (id 9)") {
		t.Errorf("attach output = %q, want the ✓ receipt line", stdout)
	}
	if !strings.Contains(stdout, "confirmed_present: true") || !strings.Contains(stdout, "server_id: 42") {
		t.Errorf("attach output = %q, want the OBSERVED server id and confirmed_present", stdout)
	}
}

// TestHetznerVolumeAttachRefusesAnotherServer is the REFUSAL half: the API
// accepts the attach and the volume comes back on a DIFFERENT server. Before
// wave 32 that printed `✓ attach — volume data-1` with `server: web-1`, the
// string the operator typed.
func TestHetznerVolumeAttachRefusesAnotherServer(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volumes":[{"id":9,"name":"data-1","size":10,"status":"available"}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /volumes/9/actions/attach", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":32,"command":"attach_volume","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /volumes/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volume":{"id":9,"name":"data-1","size":10,"status":"available","server":99}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":32,"status":"success","progress":100}]}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "volume", "attach", "data-1", "--server", "web-1")
	if code == exitOK {
		t.Fatalf("attach exited 0 with the volume on server 99; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, "server id 99") || !strings.Contains(stderr, "post-condition is UNMET") {
		t.Errorf("stderr = %q, want the named field, what the server said, and the refusal", stderr)
	}
}

// TestHetznerVolumeAttachDetachBothDirections is the pair proof. The SAME
// fixture state — a volume reporting server 42 — must make attach agree and
// detach REFUSE, and the inverse state must flip both. A payment that wired the
// present-observer onto both arms passes every arm of the receipt census (no
// census arm reads a direction branch) and fails only here.
func TestHetznerVolumeAttachDetachBothDirections(t *testing.T) {
	volume := func(t *testing.T, body string) *fakeHzAPI {
		t.Helper()
		f := newFakeHzAPI(t)
		f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"volumes":[{"id":9,"name":"data-1","size":10,"status":"available"}]}`)
		})
		f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
		})
		f.mux.HandleFunc("POST /volumes/9/actions/attach", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"action":{"id":32,"command":"attach_volume","status":"running","progress":0}}`)
		})
		f.mux.HandleFunc("POST /volumes/9/actions/detach", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"action":{"id":32,"command":"detach_volume","status":"running","progress":0}}`)
		})
		f.mux.HandleFunc("GET /volumes/9", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, body)
		})
		f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"actions":[{"id":32,"status":"success","progress":100}]}`)
		})
		return f
	}
	const attached = `{"volume":{"id":9,"name":"data-1","size":10,"status":"available","server":42}}`
	const free = `{"volume":{"id":9,"name":"data-1","size":10,"status":"available"}}`

	for _, tc := range []struct {
		name    string
		body    string
		args    []string
		wantOK  bool
		wantErr string
	}{
		{"attach agrees when the volume reports the server", attached, []string{"attach", "data-1", "--server", "web-1"}, true, ""},
		{"detach REFUSES the same state", attached, []string{"detach", "data-1"}, false, "STILL attached to server id 42"},
		{"detach agrees when the volume reports none", free, []string{"detach", "data-1"}, true, ""},
		{"attach REFUSES the same state", free, []string{"attach", "data-1", "--server", "web-1"}, false, "no server at all"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			volume(t, tc.body)
			_, stderr, code := runHzCLI(t, "table", append([]string{"hetzner", "volume"}, tc.args...)...)
			if tc.wantOK && code != exitOK {
				t.Fatalf("exited %d, want 0; stderr: %s", code, stderr)
			}
			if !tc.wantOK {
				if code == exitOK {
					t.Fatalf("exited 0 on a state the verb did not produce")
				}
				if !strings.Contains(stderr, tc.wantErr) {
					t.Errorf("stderr = %q, want %q", stderr, tc.wantErr)
				}
			}
		})
	}
}

// TestHetznerVolumeResizeRefusesShortRead pins the resize post-condition: the
// API accepts the resize and the volume comes back at its OLD size.
func TestHetznerVolumeResizeRefusesShortRead(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volumes":[{"id":9,"name":"data-1","size":10,"status":"available"}]}`)
	})
	f.mux.HandleFunc("POST /volumes/9/actions/resize", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":36,"command":"resize_volume","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /volumes/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volume":{"id":9,"name":"data-1","size":10,"status":"available"}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":36,"status":"success","progress":100}]}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "volume", "resize", "data-1", "--size", "20")
	if code == exitOK {
		t.Fatalf("resize exited 0 with the volume still 10GB; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, `field "size_gb"`) {
		t.Errorf("stderr = %q, want the named post-condition field", stderr)
	}
	if f.count("GET", "/volumes/9") == 0 {
		t.Error("resize never re-read the volume")
	}
}

// TestHetznerVolumeChangeProtectionObserves pins that the receipt reports the
// protection the VOLUME carries, not the flag that asked for it.
func TestHetznerVolumeChangeProtectionObserves(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volumes":[{"id":9,"name":"data-1","size":10,"status":"available"}]}`)
	})
	f.mux.HandleFunc("POST /volumes/9/actions/change_protection", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":37,"command":"change_protection","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /volumes/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volume":{"id":9,"name":"data-1","size":10,"status":"available","protection":{"delete":false}}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":37,"status":"success","progress":100}]}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "volume", "change-protection", "data-1", "--enable")
	if code == exitOK {
		t.Fatalf("change-protection exited 0 while the volume reports delete=false; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, `field "delete_protection"`) {
		t.Errorf("stderr = %q, want the named post-condition field", stderr)
	}
}

// TestHetznerNetworkCreate asserts POST /networks carries name + ip_range and
// an invalid CIDR fails as usage before any request.
func TestHetznerNetworkCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /networks", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "network", "create", "--name", "backend", "--ip-range", "10.0.0.0/16")
	if code != exitOK {
		t.Fatalf("network create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/networks")
	if !ok {
		t.Fatal("no POST /networks was issued")
	}
	if req.Body["name"] != "backend" || req.Body["ip_range"] != "10.0.0.0/16" {
		t.Errorf("create body = %v, want name=backend ip_range=10.0.0.0/16", req.Body)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("network create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	netw, _ := payload["network"].(map[string]any)
	if payload["ok"] != true || netw["id"] != float64(5) {
		t.Errorf("receipt = %v, want ok=true network.id=5", payload)
	}

	// A malformed CIDR is a usage error caught client-side.
	before := len(f.requests())
	_, stderr2, code2 := runHzCLI(t, "table", "hetzner", "network", "create", "--name", "x", "--ip-range", "not-a-cidr")
	if code2 != exitUsage {
		t.Fatalf("bad --ip-range exited %d, want %d", code2, exitUsage)
	}
	if !strings.Contains(stderr2, "invalid --ip-range") {
		t.Errorf("stderr = %q, want the CIDR usage message", stderr2)
	}
	if len(f.requests()) != before {
		t.Error("a malformed --ip-range still issued an API request")
	}
}

// TestHetznerNetworkAddSubnet asserts the resolve→add_subnet→POLL path with
// the full subnet body.
func TestHetznerNetworkAddSubnet(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /networks", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "backend" {
			t.Errorf("network lookup name = %q, want backend", got)
		}
		hzWriteJSON(w, 200, `{"networks":[{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}]}`)
	})
	f.mux.HandleFunc("POST /networks/5/actions/add_subnet", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":33,"command":"add_subnet","status":"running","progress":0}}`)
	})
	// THE POST-READ (PDS wave 32) on the RESOLVED id.
	f.mux.HandleFunc("GET /networks/5", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16",
			"subnets":[{"type":"cloud","ip_range":"10.0.1.0/24","network_zone":"eu-central"}],
			"routes":[],"servers":[]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":33,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table",
		"hetzner", "network", "add-subnet", "backend",
		"--type", "cloud", "--network-zone", "eu-central", "--ip-range", "10.0.1.0/24")
	if code != exitOK {
		t.Fatalf("add-subnet exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/networks/5/actions/add_subnet")
	if !ok {
		t.Fatal("no POST /networks/5/actions/add_subnet was issued")
	}
	if req.Body["type"] != "cloud" || req.Body["network_zone"] != "eu-central" || req.Body["ip_range"] != "10.0.1.0/24" {
		t.Errorf("add_subnet body = %v, want type/network_zone/ip_range", req.Body)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("add-subnet never polled the running action — fire-and-forget")
	}
	if f.count("GET", "/networks/5") == 0 {
		t.Error("add-subnet never re-read the network — the receipt is an exit code with extra steps")
	}
	if !strings.Contains(stdout, "✓ add-subnet — network backend (id 5)") {
		t.Errorf("add-subnet output = %q, want the ✓ receipt line", stdout)
	}
	if !strings.Contains(stdout, "subnet_observed: true") {
		t.Errorf("add-subnet output = %q, want the OBSERVED subnet", stdout)
	}
}

// hzNetworkPairFake stands up the network fake both membership pairs share: the
// name lookup, both route actions, both subnet actions, and ONE post-read whose
// body the caller pins.
func hzNetworkPairFake(t *testing.T, body string) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /networks", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"networks":[{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}]}`)
	})
	for _, action := range []string{"add_route", "delete_route", "add_subnet", "delete_subnet"} {
		f.mux.HandleFunc("POST /networks/5/actions/"+action, func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"action":{"id":60,"command":"network","status":"running","progress":0}}`)
		})
	}
	f.mux.HandleFunc("GET /networks/5", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, body)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":60,"status":"success","progress":100}]}`)
	})
	return f
}

// TestHetznerNetworkRouteBothDirections is THE instrument for the shared
// dispatcher. runHetznerNetworkRoute emits ONE receipt site for TWO (kind,
// action) keys, and NO arm of the receipt census reads the direction branch: a
// payment that confirmed "route present" on both add-route AND delete-route is
// fully green there, exact pins included. Only a fake driven in both directions
// against the same state can catch it, so both arms are pinned here.
func TestHetznerNetworkRouteBothDirections(t *testing.T) {
	const withRoute = `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],
		"routes":[{"destination":"10.100.0.0/16","gateway":"10.0.0.1"}],"servers":[]}}`
	const withoutRoute = `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}}`
	route := []string{"--destination", "10.100.0.0/16", "--gateway", "10.0.0.1"}

	for _, tc := range []struct {
		name    string
		body    string
		verb    string
		wantOK  bool
		wantErr string
	}{
		{"add-route agrees when the route is there", withRoute, "add-route", true, ""},
		{"delete-route REFUSES the same state", withRoute, "delete-route", false, "is STILL present"},
		{"delete-route agrees when the route is gone", withoutRoute, "delete-route", true, ""},
		{"add-route REFUSES the same state", withoutRoute, "add-route", false, `field "routes"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := hzNetworkPairFake(t, tc.body)
			stdout, stderr, code := runHzCLI(t, "table",
				append([]string{"hetzner", "network", tc.verb, "backend"}, route...)...)
			if f.count("GET", "/networks/5") == 0 {
				t.Fatal("the dispatcher never re-read the network")
			}
			if tc.wantOK {
				if code != exitOK {
					t.Fatalf("%s exited %d, want 0; stderr: %s", tc.verb, code, stderr)
				}
				if !strings.Contains(stdout, "confirmed_present: true") {
					t.Errorf("%s output = %q, want confirmed_present", tc.verb, stdout)
				}
				return
			}
			if code == exitOK {
				t.Fatalf("%s exited 0 on a state it did not produce; stdout: %s", tc.verb, stdout)
			}
			if !strings.Contains(stderr, tc.wantErr) {
				t.Errorf("stderr = %q, want %q", stderr, tc.wantErr)
			}
		})
	}
}

// TestHetznerNetworkSubnetBothDirections is the same proof for the OTHER
// network membership pair. These two verbs are separate call sites, so the
// census can see them apart — but nothing in the census says which observer
// each one wired up, and a swap reads green there too.
func TestHetznerNetworkSubnetBothDirections(t *testing.T) {
	const withSubnet = `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16",
		"subnets":[{"type":"cloud","ip_range":"10.0.1.0/24","network_zone":"eu-central"}],"routes":[],"servers":[]}}`
	const withoutSubnet = `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}}`

	for _, tc := range []struct {
		name    string
		body    string
		args    []string
		wantOK  bool
		wantErr string
	}{
		{"add-subnet agrees", withSubnet,
			[]string{"add-subnet", "backend", "--type", "cloud", "--network-zone", "eu-central", "--ip-range", "10.0.1.0/24"}, true, ""},
		{"delete-subnet REFUSES the same state", withSubnet,
			[]string{"delete-subnet", "backend", "--ip-range", "10.0.1.0/24"}, false, "is STILL present"},
		{"delete-subnet agrees when it is gone", withoutSubnet,
			[]string{"delete-subnet", "backend", "--ip-range", "10.0.1.0/24"}, true, ""},
		{"add-subnet REFUSES the same state", withoutSubnet,
			[]string{"add-subnet", "backend", "--type", "cloud", "--network-zone", "eu-central", "--ip-range", "10.0.1.0/24"}, false, `field "subnets"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			hzNetworkPairFake(t, tc.body)
			_, stderr, code := runHzCLI(t, "table", append([]string{"hetzner", "network"}, tc.args...)...)
			if tc.wantOK {
				if code != exitOK {
					t.Fatalf("exited %d, want 0; stderr: %s", code, stderr)
				}
				return
			}
			if code == exitOK {
				t.Fatal("exited 0 on a state the verb did not produce")
			}
			if !strings.Contains(stderr, tc.wantErr) {
				t.Errorf("stderr = %q, want %q", stderr, tc.wantErr)
			}
		})
	}
}

// TestHetznerNetworkCreateAdvisoryUsesTheNormalisedRange pins the one advisory
// trap wave 32 named: hzCIDR is bare net.ParseCIDR and MASKS HOST BITS, so
// enrolling the RAW --ip-range flag would fire `you asked for 10.0.0.5/16, the
// server reports 10.0.0.0/16` on a create that did EXACTLY what was asked. The
// asked side is the POST-normalisation token, so a non-canonical CIDR is silent.
func TestHetznerNetworkCreateAdvisoryUsesTheNormalisedRange(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /networks", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"network":{"id":5,"name":"backend","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "network", "create", "--name", "backend", "--ip-range", "10.0.0.5/16")
	if code != exitOK {
		t.Fatalf("network create exited %d, stderr: %s", code, stderr)
	}
	if strings.Contains(stdout, "divergence") {
		t.Errorf("a CORRECT create fired an advisory: %q — the asked side must be the post-hzCIDR token", stdout)
	}
	if !strings.Contains(stdout, "ip_range: 10.0.0.0/16") {
		t.Errorf("output = %q, want the OBSERVED ip_range", stdout)
	}
}

// TestHetznerNetworkCreateAdvisoryFiresOnRealDivergence is the other half: the
// advisory must still be able to fire, or the pair above is decorative. The API
// answers with a DIFFERENT range than the (normalised) one asked for.
func TestHetznerNetworkCreateAdvisoryFiresOnRealDivergence(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /networks", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"network":{"id":5,"name":"backend","ip_range":"10.9.0.0/16","subnets":[],"routes":[],"servers":[]}}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "network", "create", "--name", "backend", "--ip-range", "10.0.0.0/16")
	if code != exitOK {
		t.Fatalf("an advisory must never change the exit code; exited %d, stderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "you asked for 10.0.0.0/16, the server reports 10.9.0.0/16") {
		t.Errorf("output = %q, want the divergence line", stdout)
	}
}

// TestHetznerNetworkCreateRefusesAnIDLessResponse pins the EMPTY-ID COLLAPSE.
// hcloud-go's generated NetworkFromSchema takes a schema VALUE and returns a
// freshly-allocated pointer, so the naive `obj == nil` refusal is UNREACHABLE:
// without the collapse this exits 0 with confirmed_present:true and empty
// observed fields, which is worse than the argv echo it replaced.
func TestHetznerNetworkCreateRefusesAnIDLessResponse(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /networks", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "network", "create", "--name", "backend", "--ip-range", "10.0.0.0/16")
	if code == exitOK {
		t.Fatalf("a create response carrying no network exited 0; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, "NOT READABLE") {
		t.Errorf("stderr = %q, want the not-readable refusal", stderr)
	}
}

// TestHetznerFirewallApplyToServer asserts the resolve→apply_to_resources→POLL
// path: the firewall and server resolve by name and the body carries the
// typed server resource.
func TestHetznerFirewallApplyToServer(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /firewalls", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-fw" {
			t.Errorf("firewall lookup name = %q, want web-fw", got)
		}
		hzWriteJSON(w, 200, `{"firewalls":[{"id":3,"name":"web-fw","rules":[],"applied_to":[]}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /firewalls/3/actions/apply_to_resources", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"actions":[{"id":34,"command":"apply_firewall","status":"running","progress":0}]}`)
	})
	// THE POST-READ (PDS wave 32) on the RESOLVED id.
	f.mux.HandleFunc("GET /firewalls/3", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewall":{"id":3,"name":"web-fw","rules":[],
			"applied_to":[{"type":"server","server":{"id":42}}]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":34,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "apply-to-resource", "web-fw", "--server", "web-1")
	if code != exitOK {
		t.Fatalf("apply-to-resource exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/firewalls/3/actions/apply_to_resources")
	if !ok {
		t.Fatal("no POST /firewalls/3/actions/apply_to_resources was issued")
	}
	applyTo, _ := req.Body["apply_to"].([]any)
	if len(applyTo) != 1 {
		t.Fatalf("apply_to = %v, want exactly one resource", req.Body["apply_to"])
	}
	res, _ := applyTo[0].(map[string]any)
	srv, _ := res["server"].(map[string]any)
	if res["type"] != "server" || srv["id"] != float64(42) {
		t.Errorf("apply_to[0] = %v, want type=server server.id=42", res)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("apply-to-resource never polled the running action — fire-and-forget")
	}
	if f.count("GET", "/firewalls/3") == 0 {
		t.Error("apply-to-resource never re-read the firewall")
	}
	if !strings.Contains(stdout, "✓ apply-to-resource — firewall web-fw (id 3)") {
		t.Errorf("apply output = %q, want the ✓ receipt line", stdout)
	}
	if !strings.Contains(stdout, "attachment_observed: true") {
		t.Errorf("apply output = %q, want the OBSERVED attachment", stdout)
	}
}

// hzFirewallPairFake is the shared executor's fake: both directions, one
// post-read body the caller pins.
func hzFirewallPairFake(t *testing.T, body string) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewalls":[{"id":3,"name":"web-fw","rules":[],"applied_to":[]}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	for _, action := range []string{"apply_to_resources", "remove_from_resources"} {
		f.mux.HandleFunc("POST /firewalls/3/actions/"+action, func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"actions":[{"id":61,"command":"firewall","status":"running","progress":0}]}`)
		})
	}
	f.mux.HandleFunc("GET /firewalls/3", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, body)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":61,"status":"success","progress":100}]}`)
	})
	return f
}

// TestHetznerFirewallResourceBothDirections is the second shared dispatcher's
// pair proof — the same blind spot as the route pair, on the other executor.
func TestHetznerFirewallResourceBothDirections(t *testing.T) {
	const applied = `{"firewall":{"id":3,"name":"web-fw","rules":[],"applied_to":[{"type":"server","server":{"id":42}}]}}`
	const clean = `{"firewall":{"id":3,"name":"web-fw","rules":[],"applied_to":[]}}`

	for _, tc := range []struct {
		name    string
		body    string
		verb    string
		wantOK  bool
		wantErr string
	}{
		{"apply agrees when the server is attached", applied, "apply-to-resource", true, ""},
		{"remove REFUSES the same state", applied, "remove-from-resource", false, "is STILL attached"},
		{"remove agrees when it is detached", clean, "remove-from-resource", true, ""},
		{"apply REFUSES the same state", clean, "apply-to-resource", false, `field "applied_to"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			hzFirewallPairFake(t, tc.body)
			_, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", tc.verb, "web-fw", "--server", "web-1")
			if tc.wantOK {
				if code != exitOK {
					t.Fatalf("%s exited %d, want 0; stderr: %s", tc.verb, code, stderr)
				}
				return
			}
			if code == exitOK {
				t.Fatalf("%s exited 0 on a state it did not produce", tc.verb)
			}
			if !strings.Contains(stderr, tc.wantErr) {
				t.Errorf("stderr = %q, want %q", stderr, tc.wantErr)
			}
		})
	}
}

// TestHetznerFirewallResourceUnionIsSwitchedOnType pins PDS-D399 trap (b) on
// this surface: `applied_to` is a oneOf union hcloud-go flattens into ONE
// struct, so reading .Server on a LABEL-SELECTOR attachment yields a zero value
// rather than an error. A predicate that skipped the Type switch would confirm
// a --server apply against a label-selector attachment (server id 0 == 0).
func TestHetznerFirewallResourceUnionIsSwitchedOnType(t *testing.T) {
	hzFirewallPairFake(t, `{"firewall":{"id":3,"name":"web-fw","rules":[],
		"applied_to":[{"type":"label_selector","label_selector":{"selector":"env=prod"}}]}}`)

	_, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "apply-to-resource", "web-fw", "--server", "web-1")
	if code == exitOK {
		t.Fatal("a label-selector attachment confirmed a --server apply — the union switch is missing")
	}
	if !strings.Contains(stderr, "label_selector") {
		t.Errorf("stderr = %q, want the refusal to report what IS attached", stderr)
	}
}

// TestHetznerFirewallCreateAdvisoryCountsRules pins the create pair: the
// receipt reports an OBSERVED rule_count (the old `rules` key was a pure argv
// echo of len(rules)), the COUNT grade is stated, and a divergence is ADVISORY —
// the API accepted the create, so the exit code must not move.
func TestHetznerFirewallCreateAdvisoryCountsRules(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"firewall":{"id":3,"name":"web-fw","rules":[],"applied_to":[]},"actions":[]}`)
	})
	rulesPath := filepath.Join(t.TempDir(), "rules.json")
	if err := writeTempFile(rulesPath, `[{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0"]}]`); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "create", "--name", "web-fw", "--rules-file", rulesPath)
	if code != exitOK {
		t.Fatalf("an advisory must never change the exit code; exited %d, stderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "rule_count — you asked for 1, the server reports 0") {
		t.Errorf("output = %q, want the rule_count divergence", stdout)
	}
	if !strings.Contains(stdout, "COUNT — equal counts do not mean equal rules") {
		t.Errorf("output = %q, want the COUNT grade stated in the receipt", stdout)
	}
}

// TestHetznerFirewallCreateReceiptCountsTheServersRules is the rule_count's own
// pin, and it is deliberately SEPARATE from the advisory test above.
//
// WHY A SECOND TEST. The advisory line is the ONE receipt value authorised to
// print argv (PDS-D432), and the test above asserts only that line. An
// implementation that reported `rule_count: 1` — the ARGV echo — while ALSO
// printing a correct "you asked for 1, the server reports 0" advisory would
// pass it. The field an operator reads to learn their network posture would
// still be the number they typed.
//
// So this drives a create whose SERVER-SIDE count (2) differs from the
// requested count (1) in the OTHER direction: no zero value, no empty slice,
// and no len() of the request can produce 2, so a green here cannot come from
// a coincidence.
func TestHetznerFirewallCreateReceiptCountsTheServersRules(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"firewall":{"id":3,"name":"web-fw","applied_to":[],"rules":[
			{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0"]},
			{"direction":"in","protocol":"tcp","port":"80","source_ips":["::/0"]}
		]},"actions":[]}`)
	})
	rulesPath := filepath.Join(t.TempDir(), "rules.json")
	if err := writeTempFile(rulesPath, `[{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]}]`); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "firewall", "create", "--name", "web-fw", "--rules-file", rulesPath)
	if code != exitOK {
		t.Fatalf("create exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON (%v): %s", err, stdout)
	}
	got, ok := payload["rule_count"].(float64)
	if !ok {
		t.Fatalf("receipt = %v, want a rule_count", payload)
	}
	if got == 1 {
		t.Errorf("rule_count = 1 — the receipt echoed the REQUESTED count; the server reported 2 rules")
	}
	if got != 2 {
		t.Errorf("rule_count = %v, want 2 — the count the create RESPONSE carries", got)
	}
	if src := payload["rule_source"]; src != "the create response" {
		t.Errorf("rule_source = %v, want the receipt to name the create response", src)
	}
}

// TestHetznerFirewallCreateRefusesAnIDLessResponse pins the EMPTY-ID COLLAPSE at
// the firewall create site, the same one the network create carries.
//
// hcloud-go's generated FirewallFromSchema takes a schema VALUE and returns
// `&hcloudFirewall` on EVERY path, so `result.Firewall == nil` cannot be true
// once Create returned no error — the hand-rolled nil guard that used to sit
// here was dead code that read as protection. What CAN arrive is a 2xx whose
// body carries no firewall object, and that is the case the dead guard left
// unhandled: the zero value confirms a firewall at id 0 with an empty name and
// rule_count 0, which is a confident receipt for a security posture nobody has.
func TestHetznerFirewallCreateRefusesAnIDLessResponse(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "create", "--name", "web-fw")
	if code == exitOK {
		t.Fatalf("a create response carrying no firewall exited 0; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, "NOT READABLE") {
		t.Errorf("stderr = %q, want the not-readable refusal", stderr)
	}
}

// TestHetznerFirewallSetRules asserts the --rules-file read: the parsed rules
// ride in the set_rules body and the returned actions are polled.
func TestHetznerFirewallSetRules(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewalls":[{"id":3,"name":"web-fw","rules":[],"applied_to":[]}]}`)
	})
	f.mux.HandleFunc("POST /firewalls/3/actions/set_rules", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"actions":[{"id":35,"command":"set_firewall_rules","status":"running","progress":0}]}`)
	})
	// THE POST-READ, EXPLICITLY REGISTERED (PDS-D401). Omitting it does NOT
	// prove the confirming read: ServeMux's default 404 is text/plain, which
	// hcloud-go cannot decode as an API error, so it becomes a TRANSPORT error
	// and lands in the "not confirmed" arm at exit 0 — green for the wrong
	// reason.
	f.mux.HandleFunc("GET /firewalls/3", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewall":{"id":3,"name":"web-fw","applied_to":[],
			"rules":[{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]}]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":35,"status":"success","progress":100}]}`)
	})

	rulesPath := filepath.Join(t.TempDir(), "rules.json")
	if err := writeTempFile(rulesPath, `[{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"],"description":"http"}]`); err != nil {
		t.Fatal(err)
	}

	_, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "set-rules", "web-fw", "--rules-file", rulesPath)
	if code != exitOK {
		t.Fatalf("set-rules exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/firewalls/3/actions/set_rules")
	if !ok {
		t.Fatal("no POST /firewalls/3/actions/set_rules was issued")
	}
	rules, _ := req.Body["rules"].([]any)
	if len(rules) != 1 {
		t.Fatalf("rules = %v, want exactly one rule", req.Body["rules"])
	}
	rule, _ := rules[0].(map[string]any)
	if rule["direction"] != "in" || rule["protocol"] != "tcp" || rule["port"] != "80" {
		t.Errorf("rule = %v, want direction=in protocol=tcp port=80", rule)
	}
	srcs, _ := rule["source_ips"].([]any)
	if len(srcs) != 2 || srcs[0] != "0.0.0.0/0" {
		t.Errorf("rule source_ips = %v, want both CIDRs from the file", rule["source_ips"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("set-rules never polled the running action — fire-and-forget")
	}
	if f.count("GET", "/firewalls/3") == 0 {
		t.Error("set-rules never re-read the firewall")
	}
}

// TestHetznerFirewallSetRulesRefusesACountMismatch is set-rules' refusal half.
// set-rules REPLACES the whole set, so a firewall that reports a different
// number of rules afterwards did not take what was sent. The grade is still
// COUNT — equal counts do not mean equal rules — and the receipt says so.
func TestHetznerFirewallSetRulesRefusesACountMismatch(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /firewalls", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewalls":[{"id":3,"name":"web-fw","rules":[],"applied_to":[]}]}`)
	})
	f.mux.HandleFunc("POST /firewalls/3/actions/set_rules", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"actions":[{"id":35,"command":"set_firewall_rules","status":"running","progress":0}]}`)
	})
	f.mux.HandleFunc("GET /firewalls/3", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"firewall":{"id":3,"name":"web-fw","rules":[],"applied_to":[]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":35,"status":"success","progress":100}]}`)
	})

	rulesPath := filepath.Join(t.TempDir(), "rules.json")
	if err := writeTempFile(rulesPath, `[{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0"]}]`); err != nil {
		t.Fatal(err)
	}

	_, stderr, code := runHzCLI(t, "table", "hetzner", "firewall", "set-rules", "web-fw", "--rules-file", rulesPath)
	if code == exitOK {
		t.Fatalf("set-rules exited 0 with the firewall reporting no rules; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, `field "rule_count"`) {
		t.Errorf("stderr = %q, want the named post-condition field", stderr)
	}
}

// TestHetznerLBCreate asserts the POST /load_balancers body (type by name,
// location, algorithm) and the create-action wait.
func TestHetznerLBCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /load_balancers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"load_balancer":{"id":7,"name":"web-lb","load_balancer_type":{"id":1,"name":"lb11"},"location":{"id":1,"name":"nbg1"},"public_net":{"enabled":true,"ipv4":{"ip":"192.0.2.7"},"ipv6":{}},"algorithm":{"type":"round_robin"},"services":[],"targets":[]},
			"action":{"id":36,"command":"create_load_balancer","status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":36,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "load-balancer", "create", "--name", "web-lb", "--type", "lb11", "--location", "nbg1", "--algorithm", "round_robin")
	if code != exitOK {
		t.Fatalf("lb create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/load_balancers")
	if !ok {
		t.Fatal("no POST /load_balancers was issued")
	}
	if req.Body["name"] != "web-lb" || req.Body["load_balancer_type"] != "lb11" || req.Body["location"] != "nbg1" {
		t.Errorf("create body = %v, want name/load_balancer_type/location", req.Body)
	}
	alg, _ := req.Body["algorithm"].(map[string]any)
	if alg["type"] != "round_robin" {
		t.Errorf("create body algorithm = %v, want round_robin", req.Body["algorithm"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("lb create never polled the running action — fire-and-forget")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("lb create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["ipv4"] != "192.0.2.7" {
		t.Errorf("receipt ipv4 = %v, want 192.0.2.7", payload["ipv4"])
	}
}

// TestHetznerLBAddTarget asserts the resolve→add_target→POLL path with the
// typed server target in the body.
func TestHetznerLBAddTarget(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /load_balancers", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-lb" {
			t.Errorf("lb lookup name = %q, want web-lb", got)
		}
		hzWriteJSON(w, 200, `{"load_balancers":[{"id":7,"name":"web-lb","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},"algorithm":{"type":"round_robin"},"services":[],"targets":[]}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /load_balancers/7/actions/add_target", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":37,"command":"add_target","status":"running","progress":0}}`)
	})
	// THE POST-READ (pds-w29-pay-lb): add-target now confirms on the RESOLVED
	// id, so the single-resource GET must exist or the verb lands in the
	// honest "not confirmed" arm. Note the LIST above still says `targets: []`
	// — that stale collection body is exactly the trap a by-name post-read
	// would fall into, and hetzner_lb_cmd_test.go pins it.
	f.mux.HandleFunc("GET /load_balancers/7", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"load_balancer":{"id":7,"name":"web-lb","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},"algorithm":{"type":"round_robin"},"services":[],"targets":[{"type":"server","server":{"id":42},"use_private_ip":true}]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":37,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "load-balancer", "add-target", "web-lb", "--server", "web-1", "--use-private-ip")
	if code != exitOK {
		t.Fatalf("add-target exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/load_balancers/7/actions/add_target")
	if !ok {
		t.Fatal("no POST /load_balancers/7/actions/add_target was issued")
	}
	srv, _ := req.Body["server"].(map[string]any)
	if req.Body["type"] != "server" || srv["id"] != float64(42) {
		t.Errorf("add_target body = %v, want type=server server.id=42", req.Body)
	}
	if req.Body["use_private_ip"] != true {
		t.Errorf("add_target body use_private_ip = %v, want true", req.Body["use_private_ip"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("add-target never polled the running action — fire-and-forget")
	}
	if !strings.Contains(stdout, "✓ add-target — load-balancer web-lb (id 7)") {
		t.Errorf("add-target output = %q, want the ✓ receipt line", stdout)
	}
}

// TestHetznerLBTypes asserts the read-only lb-types discovery view.
func TestHetznerLBTypes(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /load_balancer_types", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"load_balancer_types":[{"id":1,"name":"lb11","description":"LB11","max_connections":10000,"max_services":5,"max_targets":25}]}`)
	})
	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "lb-types")
	if code != exitOK {
		t.Fatalf("lb-types exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("GET", "/load_balancer_types"); !ok {
		t.Fatal("no GET /load_balancer_types was issued")
	}
	if !strings.Contains(stdout, "lb11") || !strings.Contains(stdout, "10000") {
		t.Errorf("lb-types output = %q, want the lb11 row", stdout)
	}
}

// TestHetznerFloatingIPAssign asserts the resolve→assign→POLL path: the
// floating IP resolves by name, the body carries the resolved server id, and
// the running action is polled.
func TestHetznerFloatingIPAssign(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /floating_ips", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-vip" {
			t.Errorf("floating-ip lookup name = %q, want web-vip", got)
		}
		hzWriteJSON(w, 200, `{"floating_ips":[{"id":11,"name":"web-vip","ip":"192.0.2.99","type":"ipv4","dns_ptr":[]}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-2","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /floating_ips/11/actions/assign", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":38,"command":"assign_floating_ip","status":"running","progress":0}}`)
	})
	// THE POST-READ (pds-w29-pay-lb): assign now confirms the assignment on the
	// resolved floating-ip id. The nested server ref carries an ID and no name.
	f.mux.HandleFunc("GET /floating_ips/11", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"floating_ip":{"id":11,"name":"web-vip","ip":"192.0.2.99","type":"ipv4","dns_ptr":[],"server":42}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":38,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "floating-ip", "assign", "web-vip", "--server", "web-2")
	if code != exitOK {
		t.Fatalf("floating-ip assign exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/floating_ips/11/actions/assign")
	if !ok {
		t.Fatal("no POST /floating_ips/11/actions/assign was issued")
	}
	if req.Body["server"] != float64(42) {
		t.Errorf("assign body server = %v, want the resolved id 42", req.Body["server"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("floating-ip assign never polled the running action — fire-and-forget")
	}
	if !strings.Contains(stdout, "✓ assign — floating-ip web-vip (id 11)") {
		t.Errorf("assign output = %q, want the ✓ receipt line", stdout)
	}
}

// TestHetznerFloatingIPCreate asserts the POST /floating_ips body and the
// structured receipt carrying the allocated address.
func TestHetznerFloatingIPCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /floating_ips", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"floating_ip":{"id":11,"name":"web-vip","ip":"192.0.2.99","type":"ipv4","home_location":{"id":1,"name":"nbg1"},"dns_ptr":[]}}`)
	})
	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "floating-ip", "create", "--type", "ipv4", "--home-location", "nbg1", "--name", "web-vip")
	if code != exitOK {
		t.Fatalf("floating-ip create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/floating_ips")
	if !ok {
		t.Fatal("no POST /floating_ips was issued")
	}
	if req.Body["type"] != "ipv4" || req.Body["home_location"] != "nbg1" || req.Body["name"] != "web-vip" {
		t.Errorf("create body = %v, want type/home_location/name", req.Body)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("floating-ip create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["ip"] != "192.0.2.99" {
		t.Errorf("receipt ip = %v, want 192.0.2.99", payload["ip"])
	}
}

// TestHetznerPrimaryIPCreate asserts the POST /primary_ips body — including
// the fixed assignee_type=server the API requires.
func TestHetznerPrimaryIPCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /primary_ips", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"primary_ip":{"id":19,"name":"web-ip","ip":"192.0.2.50","type":"ipv4","assignee_type":"server","dns_ptr":[]}}`)
	})
	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "primary-ip", "create", "--type", "ipv4", "--datacenter", "nbg1-dc3", "--name", "web-ip")
	if code != exitOK {
		t.Fatalf("primary-ip create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/primary_ips")
	if !ok {
		t.Fatal("no POST /primary_ips was issued")
	}
	if req.Body["type"] != "ipv4" || req.Body["datacenter"] != "nbg1-dc3" || req.Body["name"] != "web-ip" {
		t.Errorf("create body = %v, want type/datacenter/name", req.Body)
	}
	if req.Body["assignee_type"] != "server" {
		t.Errorf("create body assignee_type = %v, want server", req.Body["assignee_type"])
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("primary-ip create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["ip"] != "192.0.2.50" {
		t.Errorf("receipt ip = %v, want 192.0.2.50", payload["ip"])
	}
}

// TestHetznerPlacementGroupCreate asserts the POST /placement_groups body and
// that a non-spread type is rejected client-side.
func TestHetznerPlacementGroupCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /placement_groups", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"placement_group":{"id":17,"name":"web-spread","type":"spread","servers":[]}}`)
	})
	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "placement-group", "create", "--name", "web-spread", "--type", "spread")
	if code != exitOK {
		t.Fatalf("placement-group create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/placement_groups")
	if !ok {
		t.Fatal("no POST /placement_groups was issued")
	}
	if req.Body["name"] != "web-spread" || req.Body["type"] != "spread" {
		t.Errorf("create body = %v, want name=web-spread type=spread", req.Body)
	}
	if !strings.Contains(stdout, "✓ create — placement-group web-spread (id 17)") {
		t.Errorf("create output = %q, want the ✓ receipt line", stdout)
	}

	_, stderr2, code2 := runHzCLI(t, "table", "hetzner", "placement-group", "create", "--name", "x", "--type", "cluster")
	if code2 != exitUsage || !strings.Contains(stderr2, "invalid --type") {
		t.Errorf("non-spread type exited %d (%q), want a client-side usage error", code2, stderr2)
	}
}

// TestHetznerCertificateCreateManaged asserts the POST /certificates body
// (type managed + domain_names) and that the ISSUANCE action is waited on.
func TestHetznerCertificateCreateManaged(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /certificates", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"certificate":{"id":13,"name":"web-tls","type":"managed","domain_names":["example.com","www.example.com"]},
			"action":{"id":39,"command":"issue_certificate","status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":39,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "certificate", "create-managed", "--name", "web-tls", "--domain", "example.com,www.example.com")
	if code != exitOK {
		t.Fatalf("create-managed exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/certificates")
	if !ok {
		t.Fatal("no POST /certificates was issued")
	}
	if req.Body["name"] != "web-tls" || req.Body["type"] != "managed" {
		t.Errorf("create body = %v, want name=web-tls type=managed", req.Body)
	}
	domains, _ := req.Body["domain_names"].([]any)
	if len(domains) != 2 || domains[0] != "example.com" || domains[1] != "www.example.com" {
		t.Errorf("create body domain_names = %v, want the comma-split pair", req.Body["domain_names"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("create-managed never polled the issuance action — fire-and-forget")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("create-managed -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	cert, _ := payload["certificate"].(map[string]any)
	if payload["ok"] != true || cert["id"] != float64(13) {
		t.Errorf("receipt = %v, want ok=true certificate.id=13", payload)
	}
}

// TestHetznerDNSZoneCreate asserts the POST /zones body and the create-action
// wait, with the assigned nameservers surfaced in the receipt.
func TestHetznerDNSZoneCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"zone":{"id":1,"name":"example.com","mode":"primary","ttl":3600,"status":"ok","record_count":0,"authoritative_nameservers":{"assigned":["hydrogen.ns.hetzner.com."],"delegated":[],"delegation_last_check":null,"delegation_status":"unknown"}},
			"action":{"id":40,"command":"create_zone","status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":40,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "dns", "zone", "create", "--name", "example.com")
	if code != exitOK {
		t.Fatalf("dns zone create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/zones")
	if !ok {
		t.Fatal("no POST /zones was issued")
	}
	if req.Body["name"] != "example.com" || req.Body["mode"] != "primary" {
		t.Errorf("create body = %v, want name=example.com mode=primary", req.Body)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("dns zone create never polled the running action — fire-and-forget")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("dns zone create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	ns, _ := payload["nameservers"].([]any)
	if len(ns) != 1 || ns[0] != "hydrogen.ns.hetzner.com." {
		t.Errorf("receipt nameservers = %v, want the assigned set", payload["nameservers"])
	}
}

// TestHetznerDNSRecordCreate asserts the rrset create: the zone is addressed
// by name in the path, the body carries name/type/ttl/records, and the action
// is polled.
func TestHetznerDNSRecordCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones/example.com/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"records":[{"value":"192.0.2.10"}]},
			"action":{"id":41,"command":"create_rrset","status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":41,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table",
		"hetzner", "dns", "record", "create",
		"--zone", "example.com", "--type", "a", "--name", "www", "--value", "192.0.2.10", "--ttl", "300")
	if code != exitOK {
		t.Fatalf("dns record create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/zones/example.com/rrsets")
	if !ok {
		t.Fatal("no POST /zones/example.com/rrsets was issued")
	}
	if req.Body["name"] != "www" || req.Body["type"] != "A" || req.Body["ttl"] != float64(300) {
		t.Errorf("create body = %v, want name=www type=A (uppercased) ttl=300", req.Body)
	}
	records, _ := req.Body["records"].([]any)
	if len(records) != 1 {
		t.Fatalf("records = %v, want exactly one", req.Body["records"])
	}
	rec, _ := records[0].(map[string]any)
	if rec["value"] != "192.0.2.10" {
		t.Errorf("records[0] = %v, want value=192.0.2.10", rec)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("dns record create never polled the running action — fire-and-forget")
	}
	if !strings.Contains(stdout, "✓ create — record www") {
		t.Errorf("record create output = %q, want the ✓ receipt line", stdout)
	}
}

// TestHetznerDNSRecordDeleteApex asserts the apex mapping: --name @ deletes
// the rrset addressed as @/<type>, waiting the returned action.
func TestHetznerDNSRecordDeleteApex(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("DELETE /zones/example.com/rrsets/@/A", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"action":{"id":42,"command":"delete_rrset","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":42,"status":"success","progress":100}]}`)
	})

	_, stderr, code := runHzCLI(t, "table",
		"hetzner", "dns", "record", "delete", "--zone", "example.com", "--type", "A", "--name", "@")
	if code != exitOK {
		t.Fatalf("dns record delete exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("DELETE", "/zones/example.com/rrsets/@/A"); !ok {
		t.Fatalf("no DELETE /zones/example.com/rrsets/@/A was issued; requests: %v", f.requests())
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("dns record delete never polled the running action — fire-and-forget")
	}
}

// TestHetznerVolumeCreateLocationServerExclusive asserts the one-of guard:
// both or neither of --location/--server is a usage error, no request issued.
func TestHetznerVolumeCreateLocationServerExclusive(t *testing.T) {
	f := newFakeHzAPI(t)
	_, stderr, code := runHzCLI(t, "table",
		"hetzner", "volume", "create", "--name", "v", "--size", "10", "--location", "nbg1", "--server", "web-1")
	if code != exitUsage {
		t.Fatalf("both location+server exited %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr, "exactly one of --location or --server") {
		t.Errorf("stderr = %q, want the one-of message", stderr)
	}
	if len(f.requests()) != 0 {
		t.Errorf("a usage error still issued API requests: %v", f.requests())
	}
}

// TestHetznerDNSRecordGet asserts the single-rrset read: the zone is addressed
// by name, the rrset by name/type in the path, and the row is emitted.
func TestHetznerDNSRecordGet(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /zones/example.com/rrsets/www/A", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"records":[{"value":"192.0.2.10"}]}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "dns", "record", "get", "--zone", "example.com", "--type", "a", "--name", "www")
	if code != exitOK {
		t.Fatalf("dns record get exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("GET", "/zones/example.com/rrsets/www/A"); !ok {
		t.Fatalf("no GET /zones/example.com/rrsets/www/A was issued; requests: %v", f.requests())
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("dns record get -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	rec, _ := payload["record"].(map[string]any)
	if rec["name"] != "www" || rec["type"] != "A" {
		t.Errorf("record = %v, want name=www type=A", payload["record"])
	}
	vals, _ := rec["values"].([]any)
	if len(vals) != 1 || vals[0] != "192.0.2.10" {
		t.Errorf("record values = %v, want [192.0.2.10]", rec["values"])
	}
}

// TestHetznerDNSRecordGetNotFound asserts a missing rrset (the SDK returns
// nil,nil on 404) maps to the not-found exit, not a generic error.
func TestHetznerDNSRecordGetNotFound(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /zones/example.com/rrsets/nope/A", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 404, `{"error":{"code":"not_found","message":"rrset not found"}}`)
	})

	_, _, code := runHzCLI(t, "table",
		"hetzner", "dns", "record", "get", "--zone", "example.com", "--type", "A", "--name", "nope")
	if code != exitNotFound {
		t.Fatalf("missing record get exited %d, want exitNotFound (%d)", code, exitNotFound)
	}
}

// TestHetznerDNSZoneUpdateTTL asserts zone update resolves the zone, fires the
// change_ttl action and POLLS it to completion (fire-and-forget fails).
func TestHetznerDNSZoneUpdateTTL(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /zones/example.com", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"zone":{"id":1,"name":"example.com","mode":"primary","ttl":3600,"status":"ok","record_count":0}}`)
	})
	// The resolved zone carries id 1, so the action path addresses it by ID.
	f.mux.HandleFunc("POST /zones/1/actions/change_ttl", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":50,"command":"change_zone_ttl","status":"running","progress":0}}`)
	})
	// THE POST-READ (PDS wave 32): change_ttl returns `{action}` and nothing
	// else, so the settled TTL comes from this GET on the RESOLVED id.
	f.mux.HandleFunc("GET /zones/1", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"zone":{"id":1,"name":"example.com","mode":"primary","ttl":600,"status":"ok","record_count":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":50,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "dns", "zone", "update", "example.com", "--ttl", "600")
	if code != exitOK {
		t.Fatalf("dns zone update exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/zones/1/actions/change_ttl")
	if !ok {
		t.Fatalf("no change_ttl action was issued; requests: %v", f.requests())
	}
	if req.Body["ttl"] != float64(600) {
		t.Errorf("change_ttl body = %v, want ttl=600", req.Body)
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("dns zone update never polled the running action — fire-and-forget")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("dns zone update -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["ok"] != true || payload["action"] != "update" || payload["ttl"] != float64(600) {
		t.Errorf("receipt = %v, want ok/update/ttl=600", payload)
	}
	if payload["confirmed_present"] != true {
		t.Errorf("receipt = %v, want confirmed_present — the ttl must come from the re-read", payload)
	}
	if f.count("GET", "/zones/1") == 0 {
		t.Error("dns zone update never re-read the zone")
	}
}

// TestHetznerDNSZoneUpdateRefusesAStaleTTL is the refusal half: the API accepts
// change_ttl and the zone comes back with the OLD value. Before wave 32 this
// printed `ttl: 600` because 600 is what the operator typed.
func TestHetznerDNSZoneUpdateRefusesAStaleTTL(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /zones/example.com", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"zone":{"id":1,"name":"example.com","mode":"primary","ttl":3600,"status":"ok","record_count":0}}`)
	})
	f.mux.HandleFunc("POST /zones/1/actions/change_ttl", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":50,"command":"change_zone_ttl","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /zones/1", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"zone":{"id":1,"name":"example.com","mode":"primary","ttl":3600,"status":"ok","record_count":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":50,"status":"success","progress":100}]}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "zone", "update", "example.com", "--ttl", "600")
	if code == exitOK {
		t.Fatalf("zone update exited 0 with the zone still at 3600; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, `field "ttl"`) {
		t.Errorf("stderr = %q, want the named post-condition field", stderr)
	}
}

// TestHetznerDNSZoneCreateAdvisoryUsesTheRawMode pins zone/create's advisory
// pair: the RAW --mode token, because the resolved mode would be degenerately
// always-equal and hzResDivergence skips an EMPTY asked (so an unset --mode is
// simply not compared).
func TestHetznerDNSZoneCreateAdvisoryUsesTheRawMode(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"zone":{"id":1,"name":"example.com","mode":"secondary","ttl":3600,"status":"ok","record_count":0},
			"action":{"id":51,"command":"create_zone","status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":51,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "zone", "create", "--name", "example.com", "--mode", "primary")
	if code != exitOK {
		t.Fatalf("an advisory must never change the exit code; exited %d, stderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "mode — you asked for primary, the server reports secondary") {
		t.Errorf("output = %q, want the mode divergence", stdout)
	}
	if !strings.Contains(stdout, "mode: secondary") {
		t.Errorf("output = %q, want the OBSERVED mode, not the flag", stdout)
	}
}

// TestHetznerDNSRecordCreateRefusesAnRRSetLessResponse pins the EMPTY-ID
// COLLAPSE on record/create — the measured trap. hcloud-go's generated
// ZoneRRSetFromSchema takes a schema VALUE and returns a freshly-allocated
// pointer assigned unconditionally, so `result.RRSet == nil` is UNREACHABLE:
// without the collapse, a 201 whose body OMITS the rrset key exits 0 with
// confirmed_present:true and EMPTY observed fields.
func TestHetznerDNSRecordCreateRefusesAnRRSetLessResponse(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones/example.com/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":41,"command":"create_rrset","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":41,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "record", "create",
		"--zone", "example.com", "--type", "A", "--name", "www", "--value", "192.0.2.10")
	if code == exitOK {
		t.Fatalf("a create response carrying no rrset exited 0; stdout: %s", stdout)
	}
	if !strings.Contains(stderr, "NOT READABLE") {
		t.Errorf("stderr = %q, want the not-readable refusal", stderr)
	}
}

// TestHetznerDNSRecordUpdateObservesTheRRSet pins that `record` IS payable
// (GetRRSetByNameAndType exists and 404-swallows into the hzResGoneRead shape),
// independently of the harvest slice's refusal to HARVEST the kind: the receipt
// reports the values the rrset NOW holds, order-insensitively.
func TestHetznerDNSRecordUpdateObservesTheRRSet(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones/example.com/rrsets/www/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":43,"command":"set_rrset_records","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /zones/example.com/rrsets/www/A", func(w http.ResponseWriter, r *http.Request) {
		// The API is free to REORDER an rrset's records, so the comparison is
		// order-insensitive: this body returns them back-to-front on purpose.
		hzWriteJSON(w, 200, `{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,
			"records":[{"value":"192.0.2.11"},{"value":"192.0.2.10"}]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":43,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "record", "update",
		"--zone", "example.com", "--type", "A", "--name", "www", "--value", "192.0.2.10", "--value", "192.0.2.11")
	if code != exitOK {
		t.Fatalf("record update exited %d, stderr: %s", code, stderr)
	}
	if f.count("GET", "/zones/example.com/rrsets/www/A") == 0 {
		t.Fatalf("record update never re-read the rrset; requests: %v", f.requests())
	}
	if !strings.Contains(stdout, "confirmed_present: true") {
		t.Errorf("output = %q, want confirmed_present", stdout)
	}
}

// TestHetznerDNSRecordUpdateRefusesAStaleRRSet is the refusal half: the API
// accepts set_records and the rrset still reports the OLD value.
func TestHetznerDNSRecordUpdateRefusesAStaleRRSet(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /zones/example.com/rrsets/www/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":43,"command":"set_rrset_records","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /zones/example.com/rrsets/www/A", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"records":[{"value":"198.51.100.7"}]}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":43,"status":"success","progress":100}]}`)
	})
	_ = f

	_, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "record", "update",
		"--zone", "example.com", "--type", "A", "--name", "www", "--value", "192.0.2.10")
	if code == exitOK {
		t.Fatalf("record update exited 0 with the rrset still on the old value; stderr: %s", stderr)
	}
	if !strings.Contains(stderr, `field "values"`) {
		t.Errorf("stderr = %q, want the named post-condition field", stderr)
	}
}

// TestHetznerDNSZoneUpdateNothing asserts the empty-update guard: no --ttl and
// no --label is a usage error before any request.
func TestHetznerDNSZoneUpdateNothing(t *testing.T) {
	f := newFakeHzAPI(t)
	_, stderr, code := runHzCLI(t, "table", "hetzner", "dns", "zone", "update", "example.com")
	if code != exitUsage {
		t.Fatalf("empty zone update exited %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr, "nothing to update") {
		t.Errorf("stderr = %q, want the nothing-to-update message", stderr)
	}
	if len(f.requests()) != 0 {
		t.Errorf("a usage error still issued API requests: %v", f.requests())
	}
}
