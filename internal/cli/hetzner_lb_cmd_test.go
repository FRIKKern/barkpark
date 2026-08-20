package cli

// hetzner_lb_cmd_test.go proves the MUTATION post-condition apparatus on the
// load-balancer family: load-balancer, floating-ip, primary-ip,
// placement-group and certificate.
//
// WHY THIS FILE EXISTS AT ALL (PDS-D414)
// --------------------------------------
// Every LB-family test shipped so far lives in hetzner_net_cmd_test.go, and
// none of them reaches a receipt's post-condition: nine of this family's
// sixteen receipt sites had NO test touching them, and the two that did asserted
// the ✓ LINE, not what the ✓ was built from. So over half of paying this slice
// was writing the test before the site could be observed at all.
//
// THE THREE FIXTURE RULES, EACH OF WHICH IS A MEASURED TRAP
// ---------------------------------------------------------
//	1. A STATEFUL SINGLE-RESOURCE GET PER KIND. There were ZERO single-resource
//	   GET fixtures for load_balancers/floating_ips/primary_ips/placement_groups/
//	   certificates. A post-read spelled Get(idOrName) therefore lands on the
//	   registered LIST and is handed a STALE 200 that no red announces
//	   (PDS-D401). Every case here registers /<kind>/{id} explicitly, and the
//	   body it serves REFLECTS whether the mutation actually applied.
//	2. A LYING VARIANT PER CLASS. The same fixture with `lying: true` ACCEPTS
//	   the action, returns a successful action, and never applies it. That is
//	   the arm that decides whether any of this is worth shipping: the verb must
//	   refuse at a non-zero exit and NAME the field that disagreed.
//	3. AN EXPLICIT PRODUCTION-SHAPED JSON 404 PER KIND. http.ServeMux's default
//	   404 is text/plain; hcloud-go cannot decode it as an API error, so an
//	   UNREGISTERED path yields a TRANSPORT error and lands in the "not
//	   confirmed" arm — while PRODUCTION's JSON 404 lands in the REFUSAL arm.
//	   A test that just omits the fixture proves the wrong arm and reads green.
//	   TestHetznerLBUnregisteredPathIsTheWrongArm pins the difference.
//
// AND THE ONE THAT WOULD HAVE MADE THE WHOLE SLICE VACUOUS: resolveHzLB →
// hzResolve → LoadBalancer.Get goes straight to the NAME-FILTERED LIST for a
// non-numeric token. A post-read spelled that way reads a stale collection body.
// TestHetznerLBPostReadBindsOnTheResolvedIDNotTheName is the NEGATIVE PIN.

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// hzMutState is a fixture's memory of whether the mutation it accepted was
// actually APPLIED. `lying` is the whole point: a lying fake answers the action
// with a success and then keeps serving the pre-mutation body forever.
type hzMutState struct {
	mu      sync.Mutex
	applied bool
	lying   bool
}

func (s *hzMutState) accept() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.lying {
		s.applied = true
	}
}

func (s *hzMutState) settled() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.applied
}

// hzMutResource is hzServerStates generalised past its hard-wired `{"server":…}`
// envelope and past its blind script: the body served depends on whether the
// mutation POST fired, not on how many times the resource has been read. That
// matters because a verb reads its resource TWICE (resolve, then confirm) and a
// script would flip on the count even when nothing was applied.
func hzMutResource(f *fakeHzAPI, path, envelope, before, after string, st *hzMutState) {
	f.mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
		body := before
		if st.settled() {
			body = after
		}
		hzWriteJSON(w, 200, `{"`+envelope+`":`+body+`}`)
	})
}

// hzMutAction registers an action POST that ACCEPTS the mutation (and applies it
// unless the fixture is lying) and answers the poll.
func hzMutAction(f *fakeHzAPI, path string, actionID string, st *hzMutState) {
	f.mux.HandleFunc("POST "+path, func(w http.ResponseWriter, r *http.Request) {
		st.accept()
		hzWriteJSON(w, 201, `{"action":{"id":`+actionID+`,"command":"mutate","status":"running","progress":0}}`)
	})
}

// The five kinds' bodies, parameterised only where a case needs a difference.
// Written out rather than templated so a reader can see the union arms.
const (
	hzLBEmpty = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},"services":[],"targets":[]}`
	hzLBSvc443 = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},` +
		`"services":[{"protocol":"https","listen_port":443,"destination_port":8443,"proxyprotocol":false}],"targets":[]}`
	hzLBSvcBoth = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},` +
		`"services":[{"protocol":"http","listen_port":80,"destination_port":8080,"proxyprotocol":false},` +
		`{"protocol":"https","listen_port":443,"destination_port":8443,"proxyprotocol":false}],"targets":[]}`
	hzLBSvc80 = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},` +
		`"services":[{"protocol":"http","listen_port":80,"destination_port":8080,"proxyprotocol":false}],"targets":[]}`
	// A SERVER target: note the nested ref carries an id and NO name (trap (a)).
	hzLBServerTargetBody = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},"services":[],` +
		`"targets":[{"type":"server","server":{"id":42},"use_private_ip":false,"health_status":[]}]}`
	// A LABEL-SELECTOR target: the union arm whose `.Server` is nil, which a
	// predicate that did not switch on Type would read as a zero value and
	// confirm anyway (trap (b)).
	hzLBSelectorTargetBody = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},"services":[],` +
		`"targets":[{"type":"label_selector","label_selector":{"selector":"role=web"},"health_status":[]}]}`
	hzLBLeastConn = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"least_connections"},"services":[],"targets":[]}`
	hzLBType21 = `{"id":7,"name":"lb-7","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},` +
		`"load_balancer_type":{"id":2,"name":"lb21"},"algorithm":{"type":"round_robin"},"services":[],"targets":[]}`

	hzFIPFree     = `{"id":11,"name":"vip-11","type":"ipv4","ip":"192.0.2.99","dns_ptr":[],"server":null}`
	hzFIPAssigned = `{"id":11,"name":"vip-11","type":"ipv4","ip":"192.0.2.99","dns_ptr":[],"server":42}`

	hzPIPFree     = `{"id":9,"name":"pip-9","type":"ipv4","ip":"192.0.2.50","dns_ptr":[],"assignee_id":null,"assignee_type":"server"}`
	hzPIPAssigned = `{"id":9,"name":"pip-9","type":"ipv4","ip":"192.0.2.50","dns_ptr":[],"assignee_id":42,"assignee_type":"server"}`
)

// hzServerLookup registers the server the target/assign verbs resolve.
func hzServerLookup(f *fakeHzAPI) {
	f.mux.HandleFunc("GET /servers/42", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}}`)
	})
}

// hzLBVerbCase is one mutating verb's whole conversation, in the shipped
// hzFlagVerbCase shape: the argv, the single-resource path that carries BOTH
// the resolve and the confirming read, the body before and after the mutation,
// what the honest receipt must carry, what it must NOT carry (the request echo
// that used to ride it), and the sentence the LYING fake must produce.
type hzLBVerbCase struct {
	name     string
	kind     string
	args     []string
	getPath  string
	envelope string
	postPath string
	actionID string
	before   string
	after    string
	setup    func(*fakeHzAPI)
	want     []string
	unwanted []string
	unmet    string
}

// hzLBVerbCases is the TEN mutating (non-create) receipts in this family. Every
// argv uses a NUMERIC token so the resolve addresses the single-resource path
// too — the by-NAME spelling has its own dedicated pin below.
func hzLBVerbCases() []hzLBVerbCase {
	return []hzLBVerbCase{
		{
			name: "lb-add-service", kind: "load-balancer",
			args:    []string{"load-balancer", "add-service", "7", "--protocol", "https", "--listen-port", "443"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/add_service", actionID: "101",
			before: hzLBEmpty, after: hzLBSvc443,
			want: []string{"confirmed_present: true", "protocol: https", "listen_port: 443", "destination_port: 8443", "services: 1"},
			// A request echo would have printed the DESTINATION port it was
			// never given — 8443 is a fact only the server knows.
			unwanted: []string{"destination_port: 443"},
			unmet:    "not a service on listen port 443",
		},
		{
			name: "lb-delete-service", kind: "load-balancer",
			args:    []string{"load-balancer", "delete-service", "7", "--listen-port", "443"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/delete_service", actionID: "102",
			before: hzLBSvcBoth, after: hzLBSvc80,
			want: []string{"confirmed_present: true", "listen_port_absent: 443", "services: 1", "services_listen_ports: [80]"},
			// The old receipt printed `listen_port: 443` — the argument, with
			// nothing behind it.
			unwanted: []string{"listen_port: 443"},
			unmet:    "listen port 443 is STILL served",
		},
		{
			name: "lb-add-target-server", kind: "load-balancer",
			args:    []string{"load-balancer", "add-target", "7", "--server", "42"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/add_target", actionID: "103",
			before: hzLBEmpty, after: hzLBServerTargetBody,
			setup: hzServerLookup,
			// `server: web-1` is the NAME (the target ref has none); the
			// predicate bound on the resolved id 42.
			want:  []string{"confirmed_present: true", "target_observed: true", "target_type: server", "targets: 1", "server: web-1"},
			unmet: "not a server target for server id 42",
		},
		{
			name: "lb-remove-target-label-selector", kind: "load-balancer",
			args:    []string{"load-balancer", "remove-target", "7", "--label-selector", "role=web"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/remove_target", actionID: "104",
			before: hzLBSelectorTargetBody, after: hzLBEmpty,
			want:  []string{"confirmed_present: true", "target_absent: true", "targets: 0", "label_selector: role=web"},
			unmet: `label-selector target for "role=web" is STILL attached`,
		},
		{
			name: "lb-change-algorithm", kind: "load-balancer",
			args:    []string{"load-balancer", "change-algorithm", "7", "--algorithm", "least_connections"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/change_algorithm", actionID: "105",
			before: hzLBEmpty, after: hzLBLeastConn,
			want:  []string{"confirmed_present: true", "algorithm: least_connections"},
			unmet: `reports algorithm "round_robin", not "least_connections"`,
		},
		{
			// THE WORST CASE IN THE SET: the flag is an id-or-name reference and
			// the old receipt printed the raw string. `--type 2` now yields the
			// RESOLVED name the server reports.
			name: "lb-change-type", kind: "load-balancer",
			args:    []string{"load-balancer", "change-type", "7", "--type", "2"},
			getPath: "/load_balancers/7", envelope: "load_balancer",
			postPath: "/load_balancers/7/actions/change_type", actionID: "106",
			before: hzLBEmpty, after: hzLBType21,
			want:     []string{"confirmed_present: true", "load_balancer_type: lb21", "load_balancer_type_id: 2"},
			unwanted: []string{"type: 2"},
			unmet:    `reports load_balancer_type "lb11" (id 1), not "2"`,
		},
		{
			name: "floating-ip-assign", kind: "floating-ip",
			args:    []string{"floating-ip", "assign", "11", "--server", "42"},
			getPath: "/floating_ips/11", envelope: "floating_ip",
			postPath: "/floating_ips/11/actions/assign", actionID: "107",
			before: hzFIPFree, after: hzFIPAssigned,
			setup: hzServerLookup,
			want:  []string{"confirmed_present: true", "assigned: true", "server_id: 42", "server: web-1"},
			unmet: "no server at all, not server id 42",
		},
		{
			name: "floating-ip-unassign", kind: "floating-ip",
			args:    []string{"floating-ip", "unassign", "11"},
			getPath: "/floating_ips/11", envelope: "floating_ip",
			postPath: "/floating_ips/11/actions/unassign", actionID: "108",
			before: hzFIPAssigned, after: hzFIPFree,
			want:  []string{"confirmed_present: true", "assigned: false"},
			unmet: "STILL assigned to server id 42",
		},
		{
			name: "primary-ip-assign", kind: "primary-ip",
			args:    []string{"primary-ip", "assign", "9", "--server", "42"},
			getPath: "/primary_ips/9", envelope: "primary_ip",
			postPath: "/primary_ips/9/actions/assign", actionID: "109",
			before: hzPIPFree, after: hzPIPAssigned,
			setup: hzServerLookup,
			want:  []string{"confirmed_present: true", "assigned: true", "assignee_id: 42", "assignee_type: server", "server: web-1"},
			unmet: "not server id 42",
		},
		{
			name: "primary-ip-unassign", kind: "primary-ip",
			args:    []string{"primary-ip", "unassign", "9"},
			getPath: "/primary_ips/9", envelope: "primary_ip",
			postPath: "/primary_ips/9/actions/unassign", actionID: "110",
			before: hzPIPAssigned, after: hzPIPFree,
			want:  []string{"confirmed_present: true", "assigned: false"},
			unmet: "STILL assigned to",
		},
	}
}

// hzLBWire stands a case's fixtures up. `lying` produces the variant that
// accepts the action and never applies it.
func hzLBWire(t *testing.T, tc hzLBVerbCase, lying bool) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	st := &hzMutState{lying: lying}
	hzMutResource(f, tc.getPath, tc.envelope, tc.before, tc.after, st)
	hzMutAction(f, tc.postPath, tc.actionID, st)
	hzActionsAllSucceed(f)
	if tc.setup != nil {
		tc.setup(f)
	}
	return f
}

// TestHetznerLBFamilyMutationsReportWhatTheServerNowSays is the HONEST
// direction on all ten mutating receipts: the mutation really applied, so the
// receipt carries what the RE-READ resource says — including facts nobody typed
// — and the request echoes it used to print are gone.
func TestHetznerLBFamilyMutationsReportWhatTheServerNowSays(t *testing.T) {
	for _, tc := range hzLBVerbCases() {
		t.Run(tc.name, func(t *testing.T) {
			f := hzLBWire(t, tc, false)

			stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner"}, tc.args...)...)
			if code != exitOK {
				t.Fatalf("%s exited %d, stderr: %s\nstdout: %s", tc.name, code, stderr, stdout)
			}
			// THE CONFIRMING READ MUST HAVE HAPPENED. Once to resolve, once to
			// confirm — a receipt that carries confirmed_present without a
			// second read is asserting, not observing.
			if n := f.count("GET", tc.getPath); n < 2 {
				t.Errorf("%s: GET %s happened %d time(s), want >= 2 (resolve + confirm) — the post-read never fired",
					tc.name, tc.getPath, n)
			}
			for _, want := range tc.want {
				if !strings.Contains(stdout, want) {
					t.Errorf("%s receipt = %q, want %q read off the post-mutation resource", tc.name, stdout, want)
				}
			}
			for _, never := range tc.unwanted {
				if strings.Contains(stdout, never) {
					t.Errorf("%s receipt = %q, still carries the request echo %q", tc.name, stdout, never)
				}
			}
		})
	}
}

// TestHetznerLBFamilyMutationsRefuseALyingFake is the arm that decides whether
// this slice is worth anything: the API accepts the action, reports it
// succeeded, and never applies it. Every verb must REFUSE at a non-zero exit
// and NAME the field that disagreed — a ✓ here is a receipt telling an operator
// a load balancer is serving traffic it is not.
func TestHetznerLBFamilyMutationsRefuseALyingFake(t *testing.T) {
	for _, tc := range hzLBVerbCases() {
		t.Run(tc.name, func(t *testing.T) {
			f := hzLBWire(t, tc, true)

			stdout, stderr, code := runHzCLI(t, "json", append([]string{"hetzner"}, tc.args...)...)
			if code == exitOK {
				t.Fatalf("%s exited 0 against a fake that ACCEPTED the action and never applied it — "+
					"the receipt claimed a state change that did not happen\nstdout: %s", tc.name, stdout)
			}
			var payload map[string]any
			if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
				t.Fatalf("%s refusal is not JSON: %v\n%s\nstderr: %s", tc.name, err, stdout, stderr)
			}
			if payload["ok"] != false {
				t.Errorf("%s refusal ok = %v, want false", tc.name, payload["ok"])
			}
			errObj, _ := payload["error"].(map[string]any)
			msg, _ := errObj["message"].(string)
			if !strings.Contains(msg, tc.unmet) {
				t.Errorf("%s refusal message = %q, want it to name the disagreement (%q)", tc.name, msg, tc.unmet)
			}
			if !strings.Contains(msg, "UNMET") {
				t.Errorf("%s refusal message = %q, want the post-condition named UNMET", tc.name, msg)
			}
			_ = f
		})
	}
}

// TestHetznerLBFamilyMutationsRefuseAVanishedResource is the INVERTED NIL
// BRANCH (PDS-D415), and the single highest-flip-risk judgment in this slice:
// the same (nil, nil) that EARNS a destroy's ✓ must REFUSE a mutation's.
//
// The fixture serves the resource for the resolve and then a PRODUCTION-SHAPED
// JSON 404 — which is the arm the SDK converts to a clean miss. The three kinds
// driven here are the three with a mutating verb at all; placement-group and
// certificate have only create + delete, and a create observes the response
// object rather than re-reading (their JSON-404 fixtures are registered anyway,
// so the paths exist the day one of them grows a mutation).
func TestHetznerLBFamilyMutationsRefuseAVanishedResource(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		getPath  string
		envelope string
		body     string
		postPath string
		kind     string
	}{
		{"load-balancer", []string{"load-balancer", "change-algorithm", "7", "--algorithm", "least_connections"},
			"/load_balancers/7", "load_balancer", hzLBEmpty, "/load_balancers/7/actions/change_algorithm", "load_balancer"},
		{"floating-ip", []string{"floating-ip", "unassign", "11"},
			"/floating_ips/11", "floating_ip", hzFIPAssigned, "/floating_ips/11/actions/unassign", "floating_ip"},
		{"primary-ip", []string{"primary-ip", "unassign", "9"},
			"/primary_ips/9", "primary_ip", hzPIPAssigned, "/primary_ips/9/actions/unassign", "primary_ip"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeHzAPI(t)
			var mu sync.Mutex
			resolved := false
			f.mux.HandleFunc("GET "+tc.getPath, func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				first := !resolved
				resolved = true
				mu.Unlock()
				if first {
					hzWriteJSON(w, 200, `{"`+tc.envelope+`":`+tc.body+`}`)
					return
				}
				// PRODUCTION'S 404: a JSON error body, which hcloud-go decodes
				// into ErrorCodeNotFound and GetByID turns into (nil, resp, nil).
				hzJSON404(w, tc.kind)
			})
			f.mux.HandleFunc("POST "+tc.postPath, func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 201, `{"action":{"id":200,"command":"mutate","status":"running","progress":0}}`)
			})
			hzActionsAllSucceed(f)

			stdout, stderr, code := runHzCLI(t, "json", append([]string{"hetzner"}, tc.args...)...)
			if code == exitOK {
				t.Fatalf("%s exited 0 after mutating a resource the API now 404s. THIS IS THE POLARITY FLIP: "+
					"for a DESTROY that 404 is the proof, for a MUTATION it means the verb reported changing "+
					"something that is not there\nstdout: %s\nstderr: %s", tc.name, stdout, stderr)
			}
			var payload map[string]any
			if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
				t.Fatalf("%s refusal is not JSON: %v\n%s", tc.name, err, stdout)
			}
			if payload[hzKeyConfirmedGone] != nil {
				t.Errorf("%s receipt carries %s = %v — the destroy vocabulary must never appear on a mutation",
					tc.name, hzKeyConfirmedGone, payload[hzKeyConfirmedGone])
			}
			errObj, _ := payload["error"].(map[string]any)
			msg, _ := errObj["message"].(string)
			if !strings.Contains(msg, "NOT READABLE") || !strings.Contains(msg, "UNMET") {
				t.Errorf("%s refusal message = %q, want it to say the resource is NOT READABLE and the "+
					"post-condition is UNMET", tc.name, msg)
			}
		})
	}
}

// TestHetznerLBUnregisteredPathIsTheWrongArm is the ANTI-VACUITY CONTROL for
// PDS-D401 on the mutation half, and it is what makes every JSON-404 fixture
// above load-bearing.
//
// It asserts the trap EXISTS: with the confirming read left unregistered, the
// mux answers text/plain, hcloud-go cannot decode it, and the SDK returns a
// TRANSPORT error — so the verb lands in the "not confirmed" arm at EXIT 0,
// which is NOT the refusal production's JSON 404 produces. A lazily-written
// proof would be measuring the opposite arm while printing green.
func TestHetznerLBUnregisteredPathIsTheWrongArm(t *testing.T) {
	f := newFakeHzAPI(t)
	var mu sync.Mutex
	resolved := false
	f.mux.HandleFunc("GET /load_balancers/7", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		first := !resolved
		resolved = true
		mu.Unlock()
		if first {
			hzWriteJSON(w, 200, `{"load_balancer":`+hzLBEmpty+`}`)
			return
		}
		http.NotFound(w, r) // the bare mux default: text/plain, no JSON body
	})
	f.mux.HandleFunc("POST /load_balancers/7/actions/change_algorithm", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":210,"command":"change_algorithm","status":"running","progress":0}}`)
	})
	hzActionsAllSucceed(f)

	stdout, _, code := runHzCLI(t, "json", "hetzner", "load-balancer", "change-algorithm", "7",
		"--algorithm", "least_connections")
	if code != exitOK {
		t.Fatalf("a TRANSPORT-error confirmation must land in the not-confirmed arm at exit 0, got %d: %s", code, stdout)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload["complete"] != false || payload[hzKeyConfirmedPresent] != false {
		t.Errorf("receipt = %v, want complete=false and %s=false — an unconfirmed mutation must not read as a ✓",
			payload, hzKeyConfirmedPresent)
	}
	note, _ := payload["note"].(string)
	if !strings.Contains(note, hzNotConfirmedPhras) {
		t.Errorf("note = %q, want it to say %q", note, hzNotConfirmedPhras)
	}
}

// TestHetznerLBPostReadBindsOnTheResolvedIDNotTheName is THE NEGATIVE PIN
// (PDS-D416): the test that would go GREEN — and then be worthless — if a
// builder re-resolved by NAME instead of by the id the verb already holds.
//
// resolveHzLB → hzResolve → LoadBalancer.Get sends a non-numeric token straight
// to the NAME-FILTERED LIST. This fixture makes that list STALE on purpose: it
// keeps saying `targets: []` after the target was added, exactly like the
// fixture that shipped in hetzner_net_cmd_test.go. A by-name post-read would
// therefore read `targets: []` and REFUSE a correct add-target — and it fails
// on the measured baseline too, where the naive by-name read reported
// `targets seen: 0` in all four fixture variants including a stateful lying
// fake, so no fixture can rescue that spelling.
//
// Two assertions, and the second is the structural one: the receipt confirms,
// and the name-filtered LIST is queried EXACTLY ONCE — the resolve, never again.
func TestHetznerLBPostReadBindsOnTheResolvedIDNotTheName(t *testing.T) {
	f := newFakeHzAPI(t)
	st := &hzMutState{}
	// THE STALE LIST: the by-name resolve's answer, frozen before the mutation.
	f.mux.HandleFunc("GET /load_balancers", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-lb" {
			t.Errorf("lb lookup name = %q, want web-lb", got)
		}
		hzWriteJSON(w, 200, `{"load_balancers":[{"id":7,"name":"web-lb","public_net":{"enabled":true,"ipv4":{},"ipv6":{}},`+
			`"load_balancer_type":{"id":1,"name":"lb11"},"algorithm":{"type":"round_robin"},"services":[],"targets":[]}],`+
			`"meta":{"pagination":{"page":1,"per_page":25,"total_entries":1}}}`)
	})
	// THE TRUTH, addressable only by the RESOLVED id.
	hzMutResource(f, "/load_balancers/7", "load_balancer", hzLBEmpty, hzLBServerTargetBody, st)
	hzMutAction(f, "/load_balancers/7/actions/add_target", "301", st)
	hzActionsAllSucceed(f)
	hzServerLookup(f)

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "load-balancer", "add-target", "web-lb", "--server", "42")
	if code != exitOK {
		t.Fatalf("a CORRECT add-target was refused: the post-read re-resolved BY NAME and was handed the stale "+
			"collection body (PDS-D416). exit %d\nstdout: %s\nstderr: %s", code, stdout, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedPresent] != true || payload["target_observed"] != true {
		t.Errorf("receipt = %v, want %s=true and target_observed=true off the single-resource GET",
			payload, hzKeyConfirmedPresent)
	}
	if payload["server"] != "web-1" {
		t.Errorf("receipt server = %v, want the human NAME while the predicate bound on the id", payload["server"])
	}
	if n := f.count("GET", "/load_balancers"); n != 1 {
		t.Errorf("the name-filtered LIST was queried %d time(s), want exactly 1 (the resolve). A post-read that "+
			"re-resolves by name reads a collection body that can be stale in ways no red announces", n)
	}
	if n := f.count("GET", "/load_balancers/7"); n < 1 {
		t.Errorf("the single-resource GET fired %d time(s) — the confirming read must address the resolved id", n)
	}
}

// TestHetznerLBTargetUnionDoesNotConfirmFalsely is trap (b) as a proof: a
// LABEL-SELECTOR target is present, a SERVER target was asked for. A predicate
// that read `.Server` without switching on Type would read a nil pointer (or,
// in the flattened struct, a zero value) and could confirm anyway.
func TestHetznerLBTargetUnionDoesNotConfirmFalsely(t *testing.T) {
	f := newFakeHzAPI(t)
	st := &hzMutState{}
	// The mutation "applies" — and what appears is a label-selector target,
	// not the server target that was requested.
	hzMutResource(f, "/load_balancers/7", "load_balancer", hzLBEmpty, hzLBSelectorTargetBody, st)
	hzMutAction(f, "/load_balancers/7/actions/add_target", "302", st)
	hzActionsAllSucceed(f)
	hzServerLookup(f)

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "load-balancer", "add-target", "7", "--server", "42")
	if code == exitOK {
		t.Fatalf("add-target confirmed a SERVER target against a load balancer whose only target is a "+
			"LABEL SELECTOR — the union was read without switching on Type\nstdout: %s", stdout)
	}
	if !strings.Contains(stderr+stdout, "label_selector") {
		t.Errorf("the refusal should say what IS attached; got stdout=%q stderr=%q", stdout, stderr)
	}
}

// hzLBCreateCase is one create receipt. Creates are CLASS A2: the create
// RESPONSE object is server truth, so they observe FROM it rather than paying a
// second round trip — and each fixture below makes the response differ from the
// request somewhere harmless, which is the only way to show the receipt is
// response-sourced rather than argv-sourced.
type hzLBCreateCase struct {
	name     string
	args     []string
	postPath string
	response string
	actions  bool
	want     []string
	unwanted []string
}

func hzLBCreateCases() []hzLBCreateCase {
	return []hzLBCreateCase{
		{
			// Asked for least_connections; the API reports round_robin. A
			// create CANNOT refuse — it has exactly one source, and that source
			// is the response — so the honest thing is that the receipt shows
			// the RESPONSE. Printing the flag back would have hidden this.
			name: "load-balancer",
			args: []string{"load-balancer", "create", "--name", "web-lb", "--type", "lb11",
				"--location", "nbg1", "--algorithm", "least_connections"},
			postPath: "/load_balancers",
			response: `{"load_balancer":{"id":7,"name":"web-lb","load_balancer_type":{"id":1,"name":"lb11"},` +
				`"location":{"id":1,"name":"nbg1"},"public_net":{"enabled":true,"ipv4":{"ip":"192.0.2.7"},"ipv6":{}},` +
				`"algorithm":{"type":"round_robin"},"services":[],"targets":[]},` +
				`"action":{"id":401,"command":"create_load_balancer","status":"running","progress":0}}`,
			actions: true,
			want: []string{"confirmed_present: true", "ipv4: 192.0.2.7", "load_balancer_type: lb11", "algorithm: round_robin",
				// THE THIRD OUTCOME (PDS-D432): the receipt says so out loud
				// instead of leaving the operator to diff the flag against the
				// output. Phrased as a contrast, never as `<field>: <asked>` —
				// which is what keeps the anti-echo pin below honest.
				"divergence: algorithm — you asked for least_connections, the server reports round_robin"},
			unwanted: []string{"algorithm: least_connections"},
		},
		{
			// Asked to be homed in nbg1; the API placed it in fsn1.
			name:     "floating-ip",
			args:     []string{"floating-ip", "create", "--type", "ipv4", "--home-location", "nbg1", "--name", "web-vip"},
			postPath: "/floating_ips",
			response: `{"floating_ip":{"id":11,"name":"web-vip","ip":"192.0.2.99","type":"ipv4",` +
				`"home_location":{"id":2,"name":"fsn1"},"dns_ptr":[]}}`,
			want: []string{"confirmed_present: true", "ip: 192.0.2.99", "type: ipv4", "home_location: fsn1",
				"divergence: home_location — you asked for nbg1, the server reports fsn1"},
			unwanted: []string{"home_location: nbg1"},
		},
		{
			name:     "primary-ip",
			args:     []string{"primary-ip", "create", "--type", "ipv4", "--datacenter", "nbg1-dc3", "--name", "web-ip"},
			postPath: "/primary_ips",
			response: `{"primary_ip":{"id":19,"name":"web-ip","ip":"192.0.2.50","type":"ipv4","assignee_type":"server",` +
				`"assignee_id":null,"datacenter":{"id":3,"name":"nbg1-dc3","location":{"id":1,"name":"nbg1"}},"dns_ptr":[]}}`,
			want: []string{"confirmed_present: true", "ip: 192.0.2.50", "type: ipv4"},
			// SILENT: --type agrees and --datacenter is DELIBERATELY NOT
			// enrolled (the response answers a datacenter with its location, so
			// enrolling it fires a false advisory on this very fixture — see
			// TestHetznerCreateAdvisoryExclusions).
			unwanted: []string{"divergence"},
		},
		{
			name:     "placement-group",
			args:     []string{"placement-group", "create", "--name", "web-spread", "--type", "spread"},
			postPath: "/placement_groups",
			response: `{"placement_group":{"id":17,"name":"web-spread","type":"spread","servers":[41,42]}}`,
			// `servers: 2` is a fact only the response carries.
			want: []string{"confirmed_present: true", "type: spread", "servers: 2"},
			// SILENT: placement-group --type is rejected client-side unless it
			// is "spread", so the pair is degenerate and not enrolled.
			unwanted: []string{"divergence"},
		},
		{
			name:     "certificate-managed",
			args:     []string{"certificate", "create-managed", "--name", "web-tls", "--domain", "example.com"},
			postPath: "/certificates",
			response: `{"certificate":{"id":13,"name":"web-tls","type":"managed","domain_names":["example.com","www.example.com"],` +
				`"status":{"issuance":"pending","renewal":"unavailable"}},` +
				`"action":{"id":402,"command":"issue_certificate","status":"running","progress":0}}`,
			actions: true,
			// THE DECLARED-PENDING SHAPE: the action completing does not mean a
			// certificate exists, so the receipt reports the issuance state it
			// was handed and says the reading is DECLARED.
			want: []string{"issuance: pending", "declared", "domain_names: [example.com www.example.com]"},
			// SILENT: certificate --domain is NOT enrolled — the response is a
			// legitimate unordered SUPERSET of what was asked, so token
			// equality would advise on every correct managed create.
			unwanted: []string{"issuance: issued", "divergence"},
		},
	}
}

// TestHetznerLBFamilyCreatesObserveTheResponseNotTheRequest pins class A2: the
// receipt is built FROM the create response object, and the request-only extras
// that used to ride beside it are gone.
func TestHetznerLBFamilyCreatesObserveTheResponseNotTheRequest(t *testing.T) {
	for _, tc := range hzLBCreateCases() {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeHzAPI(t)
			f.mux.HandleFunc("POST "+tc.postPath, func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 201, tc.response)
			})
			if tc.actions {
				hzActionsAllSucceed(f)
			}

			stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner"}, tc.args...)...)
			if code != exitOK {
				t.Fatalf("%s create exited %d, stderr: %s\nstdout: %s", tc.name, code, stderr, stdout)
			}
			if !strings.Contains(stdout, "basis: the create response object") {
				t.Errorf("%s receipt = %q, want the confirmation BASIS named — a create's observation is weaker "+
					"than a post-action GET and the receipt must say so", tc.name, stdout)
			}
			for _, want := range tc.want {
				if !strings.Contains(stdout, want) {
					t.Errorf("%s receipt = %q, want %q read off the create RESPONSE", tc.name, stdout, want)
				}
			}
			for _, never := range tc.unwanted {
				if strings.Contains(stdout, never) {
					t.Errorf("%s receipt = %q, still carries the request echo %q", tc.name, stdout, never)
				}
			}
		})
	}
}

// TestHetznerCertificateCreateUploadedObservesTheFingerprint covers the one
// create whose argv is a pair of FILES — kept out of the table because it needs
// them on disk.
func TestHetznerCertificateCreateUploadedObservesTheFingerprint(t *testing.T) {
	f := newFakeHzAPI(t)
	dir := t.TempDir()
	certFile, keyFile := dir+"/cert.pem", dir+"/key.pem"
	if err := os.WriteFile(certFile, []byte("-----BEGIN CERTIFICATE-----\n"), 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyFile, []byte("-----BEGIN PRIVATE KEY-----\n"), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	f.mux.HandleFunc("POST /certificates", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"certificate":{"id":21,"name":"web-tls","type":"uploaded",`+
			`"domain_names":["example.com"],"fingerprint":"aa:bb:cc","not_valid_after":"2027-01-31T00:00:00+00:00"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "certificate", "create-uploaded",
		"--name", "web-tls", "--cert-file", certFile, "--key-file", keyFile)
	if code != exitOK {
		t.Fatalf("create-uploaded exited %d, stderr: %s", code, stderr)
	}
	// The fingerprint, the domain names and the validity window are all facts
	// about the PEM the operator never typed.
	for _, want := range []string{"confirmed_present: true", "fingerprint: aa:bb:cc",
		"domain_names: [example.com]", "not_valid_after: 2027-01-31", "type: uploaded"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("create-uploaded receipt = %q, want %q read off the response", stdout, want)
		}
	}
}

// TestHetznerCreateAdvisoryIsExitNeutral is the PDS-D432 proof, and it runs in
// BOTH directions because a one-directional version is satisfiable by an
// apparatus that never advises at all — or by one that turns every advisory
// into a refusal.
//
// DIRECTION 1: an observation carrying an ADVISORY (and no `field`) is a ✓ at
// exitOK with the divergence in the payload. A create the API ACCEPTED must
// never exit non-zero because the response disagreed with argv — the only
// create refusal stays obj == nil.
// DIRECTION 2: an observation carrying `field` STILL exits exitGeneric. The
// advisory channel is additive; it did not soften the refusal arm.
func TestHetznerCreateAdvisoryIsExitNeutral(t *testing.T) {
	run := func(t *testing.T, label string, obs hzResObservation) (map[string]any, int) {
		t.Helper()
		out, buf := newJSONTestWriter()
		code := hzResObservedResponse(out, "create", "load-balancer", int64(7), "web-lb", nil,
			&hcloud.LoadBalancer{ID: 7, Name: "web-lb"}, func(*hcloud.LoadBalancer) hzResObservation { return obs })
		var payload map[string]any
		if err := json.Unmarshal([]byte(buf()), &payload); err != nil {
			t.Fatalf("%s receipt is not JSON: %v\n%s", label, err, buf())
		}
		t.Logf("%s → exit %d  %s", label, code, buf())
		return payload, code
	}

	advisory := "algorithm — you asked for least_connections, the server reports round_robin"
	adv, advCode := run(t, "advisory [THE THIRD OUTCOME]",
		hzResAgreesWith(map[string]any{"algorithm": "round_robin"}, advisory))
	if advCode != exitOK {
		t.Errorf("a create the API ACCEPTED exited %d because the response disagreed with argv — an advisory is "+
			"REPORTED, never challenged. receipt: %v", advCode, adv)
	}
	if adv["ok"] != true || adv[hzKeyConfirmedPresent] != true {
		t.Errorf("advisory receipt = %v, want a ✓ carrying %s", adv, hzKeyConfirmedPresent)
	}
	if adv[hzKeyDivergence] != advisory {
		t.Errorf("advisory receipt %s = %v, want %q — the divergence must reach the JSON surface, not just the table",
			hzKeyDivergence, adv[hzKeyDivergence], advisory)
	}
	if adv["algorithm"] != "round_robin" {
		t.Errorf("advisory receipt lost the OBSERVED payload (%v) — the whole point of the third outcome is that "+
			"the operator keeps the receipt AND learns about the divergence", adv)
	}

	// DIRECTION 2 — the refusal arm is untouched.
	unmet, unmetCode := run(t, "field [THE REFUSAL, still]", hzResDisagrees("algorithm", "round_robin", "least_connections"))
	if unmetCode == exitOK {
		t.Errorf("an observation carrying `field` exited 0 — the advisory channel swallowed the refusal arm. "+
			"receipt: %v", unmet)
	}
	if unmet["ok"] != false {
		t.Errorf("refusal receipt ok = %v, want false", unmet["ok"])
	}
}

// TestHetznerCreateAdvisoryReachesBothSurfaces proves the advisory rides ONE
// value to both surfaces — the reason it is folded into `extra` rather than
// given a print path of its own, which is how a table-only (or JSON-only)
// receipt starts lying to half its readers.
func TestHetznerCreateAdvisoryReachesBothSurfaces(t *testing.T) {
	const wantLine = "divergence: algorithm — you asked for least_connections, the server reports round_robin"
	lbCase := hzLBCreateCases()[0]

	serve := func(t *testing.T) *fakeHzAPI {
		t.Helper()
		f := newFakeHzAPI(t)
		f.mux.HandleFunc("POST /load_balancers", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, lbCase.response)
		})
		hzActionsAllSucceed(f)
		return f
	}

	serve(t)
	stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner"}, lbCase.args...)...)
	if code != exitOK || !strings.Contains(stdout, "  "+wantLine) {
		t.Errorf("table receipt = %q (exit %d, stderr %q), want the sorted extra line %q", stdout, code, stderr, wantLine)
	}

	serve(t)
	jsonOut, _, jsonCode := runHzCLI(t, "json", append([]string{"hetzner"}, lbCase.args...)...)
	var payload map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, jsonOut)
	}
	if jsonCode != exitOK || payload[hzKeyDivergence] != strings.TrimPrefix(wantLine, "divergence: ") {
		t.Errorf("json receipt %s = %v (exit %d), want the SAME value the table printed", hzKeyDivergence,
			payload[hzKeyDivergence], jsonCode)
	}
}

// TestHetznerCreateAdvisoryExclusions pins the flags that are DELIBERATELY not
// enrolled. Each row is a CORRECT create whose argv token differs from the
// value the response reports for reasons that have nothing to do with the API
// disagreeing — enrol any of them and this test reds with the false advisory it
// would print.
//
// MEASURED, not assumed: enrolling primary-ip --datacenter (asked nbg1-dc3
// against a response whose location is nbg1) emitted
// `divergence: datacenter — you asked for nbg1-dc3, the server reports nbg1`
// at exit 0 on a create that did exactly what it was told.
func TestHetznerCreateAdvisoryExclusions(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		postPath string
		response string
		why      string
	}{
		{
			name:     "primary-ip --datacenter answers as a LOCATION",
			args:     []string{"primary-ip", "create", "--type", "ipv4", "--datacenter", "nbg1-dc3", "--name", "web-ip"},
			postPath: "/primary_ips",
			// PRODUCTION-SHAPED ON PURPOSE, and that is what makes this pin able
			// to FAIL: the API sends `location` at the TOP level
			// (hcloud-go schema/primary_ip.go:19) while the older fixture in
			// hzLBCreateCases omits it — there the observed value is EMPTY and
			// an enrolled --datacenter would be silently SKIPPED rather than
			// caught, which is a pin that cannot red.
			response: `{"primary_ip":{"id":19,"name":"web-ip","ip":"192.0.2.50","type":"ipv4","assignee_type":"server",` +
				`"assignee_id":null,"location":{"id":1,"name":"nbg1"},` +
				`"datacenter":{"id":3,"name":"nbg1-dc3","location":{"id":1,"name":"nbg1"}},"dns_ptr":[]}}`,
			why: "nbg1-dc3 IS in nbg1 — the create is correct and an advisory here is a lie",
		},
		{
			name:     "load-balancer --type on the NUMERIC branch becomes an ID",
			args:     []string{"load-balancer", "create", "--name", "web-lb", "--type", "1", "--location", "nbg1"},
			postPath: "/load_balancers",
			response: `{"load_balancer":{"id":7,"name":"web-lb","load_balancer_type":{"id":1,"name":"lb11"},` +
				`"location":{"id":1,"name":"nbg1"},"public_net":{"enabled":true,"ipv4":{"ip":"192.0.2.7"},"ipv6":{}},` +
				`"algorithm":{"type":"round_robin"},"services":[],"targets":[]},` +
				`"action":{"id":401,"command":"create_load_balancer","status":"running","progress":0}}`,
			why: "--type 1 is an ID reference; the response answers with the type's NAME",
		},
		{
			name:     "certificate --domain is a legitimate SUPERSET",
			args:     []string{"certificate", "create-managed", "--name", "web-tls", "--domain", "example.com"},
			postPath: "/certificates",
			response: `{"certificate":{"id":13,"name":"web-tls","type":"managed","domain_names":["example.com","www.example.com"],` +
				`"status":{"issuance":"pending","renewal":"unavailable"}},` +
				`"action":{"id":402,"command":"issue_certificate","status":"running","progress":0}}`,
			why: "the API adds www. on its own; the ask is a SUBSET, unordered",
		},
		{
			// The one exclusion whose false positive is UNREACHABLE rather than
			// measured: the client rejects every --type but spread before the
			// request leaves, so spread-vs-spread is the only comparison there
			// is. Pinned here for completeness of the four.
			name:     "placement-group --type is client-side degenerate",
			args:     []string{"placement-group", "create", "--name", "web-spread", "--type", "spread"},
			postPath: "/placement_groups",
			response: `{"placement_group":{"id":17,"name":"web-spread","type":"spread","servers":[41,42]}}`,
			why:      "only `spread` can reach the API, so the pair can never disagree",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeHzAPI(t)
			f.mux.HandleFunc("POST "+tc.postPath, func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 201, tc.response)
			})
			hzActionsAllSucceed(f)

			stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner"}, tc.args...)...)
			if code != exitOK {
				t.Fatalf("a CORRECT create exited %d, stderr: %s\nstdout: %s", code, stderr, stdout)
			}
			if strings.Contains(stdout, hzKeyDivergence) {
				t.Errorf("a CORRECT create carries a FALSE advisory — %s was enrolled and must not be (%s)\nreceipt: %q",
					tc.name, tc.why, stdout)
			}
		})
	}
}

// TestHetznerMutationPolarityIsLoadBearing is the HIGH-FLIP-RISK proof, and the
// reason hzResObserved is a SIBLING of hzResDestroyed rather than a reuse of it.
//
// The two helpers are handed the SAME confirming read, twice: one that finds
// nothing, one that finds the resource. Every arm flips. If the polarity were
// ever swapped — or if a builder "simplified" the mutation sites onto
// hzResDestroyed — this test is what says so, and it says so on both inputs so
// a single-direction fix cannot satisfy it.
func TestHetznerMutationPolarityIsLoadBearing(t *testing.T) {
	missing := func(context.Context) (*hcloud.LoadBalancer, *hcloud.Response, error) {
		return nil, nil, nil
	}
	present := func(context.Context) (*hcloud.LoadBalancer, *hcloud.Response, error) {
		return &hcloud.LoadBalancer{ID: 7, Name: "web-lb",
			Algorithm: hcloud.LoadBalancerAlgorithm{Type: hcloud.LoadBalancerAlgorithmTypeRoundRobin}}, nil, nil
	}
	observe := hzObserveLBAlgorithm(hcloud.LoadBalancerAlgorithmTypeRoundRobin)

	run := func(t *testing.T, label string, fn func(out *writer) int) (map[string]any, int) {
		t.Helper()
		out, buf := newJSONTestWriter()
		code := fn(out)
		var payload map[string]any
		if err := json.Unmarshal([]byte(buf()), &payload); err != nil {
			t.Fatalf("%s receipt is not JSON: %v\n%s", label, err, buf())
		}
		t.Logf("%s → exit %d  %s", label, code, buf())
		return payload, code
	}

	// DIRECTION 1 — THE MEASURED FAIL-OPEN. hzResDestroyed reused for a create
	// on a resource the API 404s emits a ✓ that says the thing is GONE, for an
	// action named "create".
	gone, goneCode := run(t, "hzResDestroyed(nil) [THE FAIL-OPEN]", func(out *writer) int {
		return hzResDestroyed(out, context.Background(), "create", "load-balancer", int64(7), "web-lb", nil, missing)
	})
	if goneCode != exitOK || gone["ok"] != true || gone[hzKeyConfirmedGone] != true {
		t.Fatalf("the fail-open this slice exists to stop did not reproduce: exit %d, receipt %v. If hzResDestroyed "+
			"has changed, this proof needs re-deriving before the polarity claim can be trusted", goneCode, gone)
	}

	// …and hzResObserved on the SAME input refuses.
	unmet, unmetCode := run(t, "hzResObserved(nil) [THE FIX]", func(out *writer) int {
		return hzResObserved(out, context.Background(), "create", "load-balancer", int64(7), "web-lb", nil, missing, observe)
	})
	if unmetCode == exitOK {
		t.Errorf("hzResObserved exited 0 on a resource the API says is not there — the nil branch was NOT inverted, "+
			"which is a fail-open on every mutation site at once. receipt: %v", unmet)
	}
	if unmet["ok"] != false {
		t.Errorf("hzResObserved receipt ok = %v, want false", unmet["ok"])
	}
	if unmet[hzKeyConfirmedGone] != nil {
		t.Errorf("hzResObserved receipt carries %s — the destroy vocabulary must never appear on a mutation: %v",
			hzKeyConfirmedGone, unmet)
	}

	// DIRECTION 2 — the mirror. On a resource that IS there, hzResObserved
	// confirms and hzResDestroyed refuses. Without this half, a helper that
	// simply always failed would satisfy direction 1.
	ok, okCode := run(t, "hzResObserved(present)", func(out *writer) int {
		return hzResObserved(out, context.Background(), "change-algorithm", "load-balancer", int64(7), "web-lb", nil, present, observe)
	})
	if okCode != exitOK || ok[hzKeyConfirmedPresent] != true || ok["algorithm"] != "round_robin" {
		t.Errorf("hzResObserved on a readable, agreeing resource = exit %d %v, want a ✓ carrying %s and the "+
			"OBSERVED algorithm", okCode, ok, hzKeyConfirmedPresent)
	}
	still, stillCode := run(t, "hzResDestroyed(present)", func(out *writer) int {
		return hzResDestroyed(out, context.Background(), "delete", "load-balancer", int64(7), "web-lb", nil, present)
	})
	if stillCode == exitOK {
		t.Errorf("hzResDestroyed exited 0 on a resource that is STILL THERE: %v", still)
	}
}

// newJSONTestWriter builds a writer pinned to -o json and returns it with a
// reader for whatever it printed — the seam the polarity proof needs to compare
// two receipts from the SAME input without going through a CLI dispatch that
// would only ever reach one of them.
func newJSONTestWriter() (*writer, func() string) {
	var stdout, stderr strings.Builder
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	return w, func() string {
		if s := strings.TrimSpace(stdout.String()); s != "" {
			return s
		}
		return strings.TrimSpace(stderr.String())
	}
}
