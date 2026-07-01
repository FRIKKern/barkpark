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
	if !strings.Contains(stdout, "✓ attach — volume data-1 (id 9)") {
		t.Errorf("attach output = %q, want the ✓ receipt line", stdout)
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
	if !strings.Contains(stdout, "✓ add-subnet — network backend (id 5)") {
		t.Errorf("add-subnet output = %q, want the ✓ receipt line", stdout)
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
	if !strings.Contains(stdout, "✓ apply-to-resource — firewall web-fw (id 3)") {
		t.Errorf("apply output = %q, want the ✓ receipt line", stdout)
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
