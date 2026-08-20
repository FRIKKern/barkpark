package cli

// hetzner_respost_test.go proves the destroy post-condition apparatus on ALL
// TWELVE full destroys, in both directions, against fixtures that cannot lie by
// accident.
//
// PDS-D401 — WHY EVERY FIXTURE HERE IS EXPLICIT
// ---------------------------------------------
// http.ServeMux's default 404 is text/plain. hcloud-go only decodes an API
// error when the body is JSON, so an UNREGISTERED read-back path produces a
// TRANSPORT error and lands in the "not confirmed" arm — while PRODUCTION
// returns a JSON 404 and lands in the "gone" arm. A test that forgets the
// fixture therefore proves the WRONG ARM and still reads green. Two things stop
// that here: every honest case registers a STATEFUL handler that returns the
// resource until the DELETE fires and a JSON 404 afterwards, and
// TestHetznerDestroyUnregisteredPathIsATransportErrorNotAGoneProof pins the
// difference so the vacuity is a measured fact rather than a comment.
//
// The second trap this file dodges is the SILENT STALE 200: seven of the eight
// hcloud kinds had NO single-resource GET fixture anywhere in the package, so a
// post-read could land on a registered LIST handler and be handed a stale 200
// that no red announces. Each row below registers its own single-resource path.

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// hzJSON404 writes the 404 shape PRODUCTION returns — a JSON error body, which
// hcloud-go decodes into ErrorCodeNotFound and the SDK's GetByID converts into
// the clean (nil, resp, nil) miss. This is the whole point of PDS-D401: the
// fixture must produce the arm production produces.
func hzJSON404(w http.ResponseWriter, kind string) {
	hzWriteJSON(w, 404, `{"error":{"code":"not_found","message":"`+kind+` not found","details":{}}}`)
}

// hzStatefulResource registers a single-resource GET that tells the truth about
// a DELETE: present until the destroy fires, an honest JSON 404 after. `gone` is
// flipped by the DELETE handler the caller registers.
func hzStatefulResource(f *fakeHzAPI, path, kind, body string, gone *bool, mu *sync.Mutex) {
	f.mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if *gone {
			hzJSON404(w, kind)
			return
		}
		hzWriteJSON(w, 200, body)
	})
}

// hzActionsAllSucceed answers the action poll for EXACTLY the ids asked for.
// Returning a fixed list instead trips the SDK's own len(updates) != len(running)
// guard with "actions not found: []" — a fixture bug that looks like a product
// bug, so the fake mirrors the API's filtering rather than guessing.
func hzActionsAllSucceed(f *fakeHzAPI) {
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		var rows []string
		for _, id := range r.URL.Query()["id"] {
			rows = append(rows, `{"id":`+id+`,"status":"success","progress":100}`)
		}
		hzWriteJSON(w, 200, `{"actions":[`+strings.Join(rows, ",")+`],"meta":{"pagination":{"page":1,"per_page":50,"total_entries":`+
			strconv.Itoa(len(rows))+`}}}`)
	})
}

// hzDestroyCase is one full destroy: what to run, which single-resource path
// carries both the resolve and the confirming read, and what the API hands back.
type hzDestroyCase struct {
	name     string   // receipt kind, as it appears in the payload
	args     []string // argv after "hetzner"
	getPath  string   // the ONE single-resource path (resolve + read-back)
	delPath  string   // the DELETE path
	delBody  string   // the DELETE response body
	delCode  int      // the DELETE response status
	body     string   // the resource's 200 body
	waitsFor bool     // the verb waits on an action (needs GET /actions)
}

// hzFullDestroys is the population this slice pays: the TEN hcloud full
// destroys. The two object-storage destroys take the declared non-binding read
// and are proven separately (they speak S3, not the hcloud API).
func hzFullDestroys() []hzDestroyCase {
	return []hzDestroyCase{
		{
			name: "volume", args: []string{"volume", "delete", "7", "--yes"},
			getPath: "/volumes/7", delPath: "/volumes/7", delCode: 204, delBody: `{}`,
			body: `{"volume":{"id":7,"name":"data-7","status":"available","size":10}}`,
		},
		{
			name: "network", args: []string{"network", "delete", "5", "--yes"},
			getPath: "/networks/5", delPath: "/networks/5", delCode: 204, delBody: `{}`,
			body: `{"network":{"id":5,"name":"net-5","ip_range":"10.0.0.0/16","subnets":[],"routes":[],"servers":[]}}`,
		},
		{
			name: "firewall", args: []string{"firewall", "delete", "6", "--yes"},
			getPath: "/firewalls/6", delPath: "/firewalls/6", delCode: 204, delBody: `{}`,
			body: `{"firewall":{"id":6,"name":"fw-6","rules":[],"applied_to":[]}}`,
		},
		{
			name: "load-balancer", args: []string{"load-balancer", "delete", "3", "--yes"},
			getPath: "/load_balancers/3", delPath: "/load_balancers/3", delCode: 204, delBody: `{}`,
			body: `{"load_balancer":{"id":3,"name":"lb-3","public_net":{},"private_net":[],` +
				`"algorithm":{"type":"round_robin"},"services":[],"targets":[],` +
				`"load_balancer_type":{"id":1,"name":"lb11"}}}`,
		},
		{
			name: "floating-ip", args: []string{"floating-ip", "delete", "8", "--yes"},
			getPath: "/floating_ips/8", delPath: "/floating_ips/8", delCode: 204, delBody: `{}`,
			body: `{"floating_ip":{"id":8,"name":"fip-8","type":"ipv4","ip":"1.2.3.4"}}`,
		},
		{
			name: "primary-ip", args: []string{"primary-ip", "delete", "9", "--yes"},
			getPath: "/primary_ips/9", delPath: "/primary_ips/9", delCode: 204, delBody: `{}`,
			body: `{"primary_ip":{"id":9,"name":"pip-9","type":"ipv4","ip":"5.6.7.8"}}`,
		},
		{
			name: "placement-group", args: []string{"placement-group", "delete", "4", "--yes"},
			getPath: "/placement_groups/4", delPath: "/placement_groups/4", delCode: 204, delBody: `{}`,
			body: `{"placement_group":{"id":4,"name":"pg-4","type":"spread","servers":[]}}`,
		},
		{
			name: "certificate", args: []string{"certificate", "delete", "2", "--yes"},
			getPath: "/certificates/2", delPath: "/certificates/2", delCode: 204, delBody: `{}`,
			body: `{"certificate":{"id":2,"name":"cert-2","type":"uploaded","domain_names":["a.example"]}}`,
		},
		{
			name: "zone", args: []string{"dns", "zone", "delete", "11", "--yes"},
			getPath: "/zones/11", delPath: "/zones/11", delCode: 200,
			delBody:  `{"action":{"id":81,"command":"delete_zone","status":"running","progress":0}}`,
			body:     `{"zone":{"id":11,"name":"example.com","mode":"primary","status":"ok","ttl":3600}}`,
			waitsFor: true,
		},
		{
			// A record resolves nothing: the confirming read uses the
			// (zone, name, type) key the verb already holds.
			name: "record", args: []string{"dns", "record", "delete", "--zone", "example.com", "--type", "A", "--name", "www", "--yes"},
			getPath: "/zones/example.com/rrsets/www/A", delPath: "/zones/example.com/rrsets/www/A", delCode: 200,
			delBody:  `{"action":{"id":82,"command":"delete_rrset","status":"running","progress":0}}`,
			body:     `{"rrset":{"id":"www/A","name":"www","type":"A","ttl":300,"records":[{"value":"1.2.3.4"}]}}`,
			waitsFor: true,
		},
	}
}

// TestHetznerFullDestroysConfirmGone is the HONEST direction on all ten hcloud
// full destroys: the resource really is gone afterwards, so the receipt earns
// its ✓ and says WHY (confirmed_gone) rather than leaning on the exit code.
func TestHetznerFullDestroysConfirmGone(t *testing.T) {
	for _, tc := range hzFullDestroys() {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeHzAPI(t)
			var mu sync.Mutex
			gone := false
			hzStatefulResource(f, tc.getPath, tc.name, tc.body, &gone, &mu)
			f.mux.HandleFunc("DELETE "+tc.delPath, func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				gone = true
				mu.Unlock()
				hzWriteJSON(w, tc.delCode, tc.delBody)
			})
			if tc.waitsFor {
				hzActionsAllSucceed(f)
			}

			stdout, stderr, code := runHzCLI(t, "json", append([]string{"hetzner"}, tc.args...)...)
			if code != exitOK {
				t.Fatalf("%s destroy exited %d, stderr: %s\nstdout: %s", tc.name, code, stderr, stdout)
			}
			var payload map[string]any
			if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
				t.Fatalf("%s receipt is not JSON: %v\n%s", tc.name, err, stdout)
			}
			if payload["ok"] != true {
				t.Errorf("%s receipt ok = %v, want true", tc.name, payload["ok"])
			}
			if payload[hzKeyConfirmedGone] != true {
				t.Errorf("%s receipt = %v — a destroy that does not carry %s=true is claiming success on the "+
					"exit code alone, which is exactly what this apparatus exists to stop", tc.name, payload, hzKeyConfirmedGone)
			}
			// THE READ-BACK MUST HAVE HAPPENED. A receipt can carry
			// confirmed_gone=true and still be a lie if nothing re-read: the
			// single-resource path is hit ONCE to resolve and AGAIN to confirm
			// (the record has no resolve, so once is its floor).
			floor := 2
			if tc.name == "record" {
				floor = 1
			}
			if got := f.count("GET", tc.getPath); got < floor {
				t.Errorf("%s: GET %s happened %d time(s), want >= %d — the confirming read never fired, "+
					"so confirmed_gone was asserted without an observation", tc.name, tc.getPath, got, floor)
			}
		})
	}
}

// TestHetznerFullDestroysRefuseALyingFake is the DISHONEST direction, and the
// arm that decides whether this slice is worth anything: the API accepts the
// DELETE and then keeps handing the resource back. The verb must REFUSE the
// claim at a non-zero exit and say so in words — a ✓ here is a receipt that
// tells an operator something is deleted while it is still running and still
// billing.
func TestHetznerFullDestroysRefuseALyingFake(t *testing.T) {
	for _, tc := range hzFullDestroys() {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeHzAPI(t)
			// THE LIE: a static 200 forever, before and after the DELETE.
			f.mux.HandleFunc("GET "+tc.getPath, func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 200, tc.body)
			})
			f.mux.HandleFunc("DELETE "+tc.delPath, func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, tc.delCode, tc.delBody)
			})
			if tc.waitsFor {
				hzActionsAllSucceed(f)
			}

			stdout, stderr, code := runHzCLI(t, "json", append([]string{"hetzner"}, tc.args...)...)
			if code == exitOK {
				t.Fatalf("%s destroy exited 0 against a fake that KEEPS RETURNING THE RESOURCE — "+
					"the receipt claimed a destruction that did not happen\nstdout: %s", tc.name, stdout)
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
			if !strings.Contains(msg, "STILL READABLE") || !strings.Contains(msg, tc.name) {
				t.Errorf("%s refusal message = %q — it must NAME the resource and say it is still readable, "+
					"or the operator cannot tell a refusal from a transport hiccup", tc.name, msg)
			}
		})
	}
}

// TestHetznerDestroyReadErrorIsNotConfirmed pins the third arm, and it is the
// arm that keeps this apparatus safe to ship: the DELETE was accepted, the
// CONFIRMING READ failed. Reporting a failed verb here would be the same lie
// pointing the other way and would push an operator into deleting twice. So:
// exit 0, no ✓, and the words "not confirmed".
func TestHetznerDestroyReadErrorIsNotConfirmed(t *testing.T) {
	// A FRESH fake per run: the fixture is stateful (the read errors only AFTER
	// the delete), so reusing one across two runs would poison the resolve of
	// the second and red for the wrong reason.
	arm := func(t *testing.T) {
		t.Helper()
		f := newFakeHzAPI(t)
		var mu sync.Mutex
		deleted := false
		f.mux.HandleFunc("GET /volumes/7", func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			gone := deleted
			mu.Unlock()
			if !gone {
				hzWriteJSON(w, 200, `{"volume":{"id":7,"name":"data-7","status":"available","size":10}}`)
				return
			}
			// A JSON 500: an API-shaped error, not a miss.
			hzWriteJSON(w, 500, `{"error":{"code":"server_error","message":"rate limited","details":{}}}`)
		})
		f.mux.HandleFunc("DELETE /volumes/7", func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			deleted = true
			mu.Unlock()
			hzWriteJSON(w, 204, `{}`)
		})
	}

	arm(t)
	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "volume", "delete", "7", "--yes")
	if code != exitOK {
		t.Fatalf("an unreadable confirmation exited %d — a failed READ is not a failed DELETE; stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload["complete"] != false || payload[hzKeyConfirmedGone] != false {
		t.Errorf("receipt = %v, want complete=false and %s=false — an unconfirmed destroy must not read as a ✓",
			payload, hzKeyConfirmedGone)
	}
	note, _ := payload["note"].(string)
	if !strings.Contains(note, hzNotConfirmedPhras) {
		t.Errorf("note = %q, want it to say %q", note, hzNotConfirmedPhras)
	}
	if payload[hzKeyConfirmErr] == nil {
		t.Errorf("receipt = %v, want %s naming WHY the confirmation could not be made", payload, hzKeyConfirmErr)
	}

	// The table view must not print a ✓ either — the shape a human reads is
	// where this lie would actually land.
	arm(t)
	stdout, _, code = runHzCLI(t, "table", "hetzner", "volume", "delete", "7", "--yes")
	if code != exitOK {
		t.Fatalf("table-view unconfirmed destroy exited %d", code)
	}
	if strings.Contains(stdout, "✓") || !strings.Contains(stdout, hzNotConfirmedPhras) {
		t.Errorf("table receipt = %q, want a ⚠ carrying %q and no ✓", stdout, hzNotConfirmedPhras)
	}
}

// TestHetznerVolumeDeleteImpostorNameDoesNotRefuse is the PDS-D400 proof, and
// the reason the gone-check is a closure over the RESOLVED id rather than a
// re-run of the user's token.
//
// The trap: hzResolve delegates to the SDK's getByIDOrName, which on a numeric
// token that 404s FALLS THROUGH to a name-filtered LIST. So if the confirming
// read re-ran `42`, a DIFFERENT volume merely NAMED "42" would come back and the
// receipt would refuse a delete that was entirely correct — a false red on a
// destroy, which sends an operator back to delete it again.
//
// The fixture makes that impostor exist. Two assertions: the correct delete is
// confirmed, and the name-filtered LIST is NEVER queried — the second is the
// structural one, because it stays true even if the impostor's shape changes.
func TestHetznerVolumeDeleteImpostorNameDoesNotRefuse(t *testing.T) {
	f := newFakeHzAPI(t)
	var mu sync.Mutex
	gone := false
	f.mux.HandleFunc("GET /volumes/42", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if gone {
			hzJSON404(w, "volume")
			return
		}
		hzWriteJSON(w, 200, `{"volume":{"id":42,"name":"data-42","status":"available","size":10}}`)
	})
	f.mux.HandleFunc("DELETE /volumes/42", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gone = true
		mu.Unlock()
		hzWriteJSON(w, 204, `{}`)
	})
	// THE IMPOSTOR: a live volume whose NAME is the deleted volume's id.
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volumes":[{"id":99,"name":"42","status":"available","size":10}],"meta":{"pagination":{"page":1,"per_page":25,"total_entries":1}}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "volume", "delete", "42", "--yes")
	if code != exitOK {
		t.Fatalf("a CORRECT delete was refused because another volume is NAMED \"42\" — the gone-check "+
			"re-ran the user's token instead of binding to the resolved id (PDS-D400). exit %d, stdout: %s, stderr: %s",
			code, stdout, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedGone] != true {
		t.Errorf("receipt = %v, want %s=true", payload, hzKeyConfirmedGone)
	}
	if n := f.count("GET", "/volumes"); n != 0 {
		t.Errorf("the name-filtered LIST was queried %d time(s) — the confirming read must address the "+
			"RESOLVED id and nothing else, or a same-named neighbour can veto a correct destroy", n)
	}
}

// TestHetznerDestroyUnregisteredPathIsATransportErrorNotAGoneProof is the
// ANTI-VACUITY CONTROL for PDS-D401, and it is the test that makes every other
// fixture in this file load-bearing.
//
// It asserts the trap EXISTS: with the read-back path left unregistered, the
// mux answers text/plain 404, hcloud-go cannot decode it as an API error, and
// the SDK returns a TRANSPORT ERROR. The verb then lands in the "not confirmed"
// arm — NOT the "gone" arm production would take. So a lazily-written proof
// would be measuring the wrong thing while printing green, and the JSON 404
// fixtures above are the difference between a proof and a decoration.
func TestHetznerDestroyUnregisteredPathIsATransportErrorNotAGoneProof(t *testing.T) {
	f := newFakeHzAPI(t)
	first := true
	var mu sync.Mutex
	// Only the RESOLVE is answered; the confirming read hits the mux default.
	f.mux.HandleFunc("GET /volumes/7", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		serve := first
		first = false
		mu.Unlock()
		if !serve {
			// The bare mux default: text/plain, no JSON body.
			http.NotFound(w, r)
			return
		}
		hzWriteJSON(w, 200, `{"volume":{"id":7,"name":"data-7","status":"available","size":10}}`)
	})
	f.mux.HandleFunc("DELETE /volumes/7", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 204, `{}`)
	})

	stdout, _, code := runHzCLI(t, "json", "hetzner", "volume", "delete", "7", "--yes")
	if code != exitOK {
		t.Fatalf("expected the unconfirmed arm at exit 0, got %d: %s", code, stdout)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedGone] != false {
		t.Fatalf("a text/plain 404 produced %s=%v — if this ever becomes true, the JSON-404 fixtures in "+
			"this file stopped being load-bearing and every 'gone' proof here is vacuous",
			hzKeyConfirmedGone, payload[hzKeyConfirmedGone])
	}
}

// ---------------------------------------------------------------------------
// object storage — the DECLARED NON-BINDING half
// ---------------------------------------------------------------------------

// TestHetznerBucketDeleteDeclaresAbsence: the honest direction. The bucket is
// really gone, so the receipt says so AND names the basis on which it says it.
func TestHetznerBucketDeleteDeclaresAbsence(t *testing.T) {
	deleted := false
	var mu sync.Mutex
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "DELETE" {
			mu.Lock()
			deleted = true
			mu.Unlock()
			return 204, ""
		}
		mu.Lock()
		gone := deleted
		mu.Unlock()
		if gone {
			return 200, `<?xml version="1.0"?><ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>`
		}
		return 200, `<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>` +
			`<Bucket><Name>media</Name><CreationDate>2026-06-15T08:30:00.000Z</CreationDate></Bucket>` +
			`</Buckets></ListAllMyBucketsResult>`
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "bucket", "delete", "--name", "media", "--yes")...)
	if code != exitOK {
		t.Fatalf("bucket delete exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedAbs] != true {
		t.Errorf("receipt = %v, want %s=true", payload, hzKeyConfirmedAbs)
	}
	if basis, _ := payload[hzKeyConfirmBasis].(string); basis == "" {
		t.Errorf("receipt = %v, want %s naming WHAT was read — an unqualified absence claim on an endpoint "+
			"with no documented consistency model is exactly the overclaim this epic is about", payload, hzKeyConfirmBasis)
	}
}

// TestHetznerBucketDeleteStillListedIsNotAClaim is the object-storage LYING
// FAKE: the DELETE is accepted and the bucket keeps showing up. Because Hetzner
// documents NO consistency model, this is reported rather than treated as a
// failure — but it is emphatically NOT a ✓, and the words say why.
func TestHetznerBucketDeleteStillListedIsNotAClaim(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "DELETE" {
			return 204, ""
		}
		return 200, `<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>` +
			`<Bucket><Name>media</Name><CreationDate>2026-06-15T08:30:00.000Z</CreationDate></Bucket>` +
			`</Buckets></ListAllMyBucketsResult>`
	}}
	withFakeS3(t, f)

	stdout, _, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "bucket", "delete", "--name", "media", "--yes")...)
	if code != exitOK {
		t.Fatalf("a still-listed bucket must be REPORTED, not failed (no consistency model to fail against); exit %d", code)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedAbs] != false || payload["complete"] != false {
		t.Errorf("receipt = %v, want %s=false and complete=false", payload, hzKeyConfirmedAbs)
	}
	note, _ := payload["note"].(string)
	if !strings.Contains(note, "STILL LISTED") || !strings.Contains(note, hzNotConfirmedPhras) {
		t.Errorf("note = %q — it must say the bucket is still listed and that absence is %q", note, hzNotConfirmedPhras)
	}

	stdout, _, _ = runHzCLI(t, "table", storageArgs("hetzner", "storage", "bucket", "delete", "--name", "media", "--yes")...)
	if strings.Contains(stdout, "✓") {
		t.Errorf("table receipt = %q — a bucket that is still listed must never print a ✓", stdout)
	}
}

// TestHetznerObjectRmDeclaresAbsence + its lying twin: the same contract on the
// second object-storage destroy, whose confirming read is a prefix list on the
// exact key.
func TestHetznerObjectRmDeclaresAbsence(t *testing.T) {
	deleted := false
	var mu sync.Mutex
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "DELETE" {
			mu.Lock()
			deleted = true
			mu.Unlock()
			return 204, ""
		}
		mu.Lock()
		gone := deleted
		mu.Unlock()
		if gone {
			return 200, `<?xml version="1.0"?><ListBucketResult><Name>bkt</Name><KeyCount>0</KeyCount></ListBucketResult>`
		}
		return 200, `<?xml version="1.0"?><ListBucketResult><Name>bkt</Name><KeyCount>1</KeyCount>` +
			`<Contents><Key>a/b.txt</Key><Size>12</Size><LastModified>2026-06-01T10:00:00.000Z</LastModified></Contents>` +
			`</ListBucketResult>`
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "rm", "--bucket", "bkt", "--key", "a/b.txt", "--yes")...)
	if code != exitOK {
		t.Fatalf("object rm exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedAbs] != true {
		t.Errorf("receipt = %v, want %s=true", payload, hzKeyConfirmedAbs)
	}
}

func TestHetznerObjectRmStillListedIsNotAClaim(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "DELETE" {
			return 204, ""
		}
		return 200, `<?xml version="1.0"?><ListBucketResult><Name>bkt</Name><KeyCount>1</KeyCount>` +
			`<Contents><Key>a/b.txt</Key><Size>12</Size><LastModified>2026-06-01T10:00:00.000Z</LastModified></Contents>` +
			`</ListBucketResult>`
	}}
	withFakeS3(t, f)

	stdout, _, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "rm", "--bucket", "bkt", "--key", "a/b.txt", "--yes")...)
	if code != exitOK {
		t.Fatalf("a still-listed object must be REPORTED, not failed; exit %d", code)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedAbs] != false || payload["complete"] != false {
		t.Errorf("receipt = %v, want %s=false and complete=false", payload, hzKeyConfirmedAbs)
	}
}

// TestHetznerObjectRmUnreadableListFailsClosed: the confirming read ERRORS. The
// receipt must fail CLOSED — confirmed_absent=false with the reason — never an
// optimistic true, which would be a lie manufactured out of a broken read.
func TestHetznerObjectRmUnreadableListFailsClosed(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "DELETE" {
			return 204, ""
		}
		return 500, `<?xml version="1.0"?><Error><Code>InternalError</Code><Message>boom</Message></Error>`
	}}
	withFakeS3(t, f)

	stdout, _, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "rm", "--bucket", "bkt", "--key", "a/b.txt", "--yes")...)
	if code != exitOK {
		t.Fatalf("a failed confirming READ is not a failed DELETE; exit %d, stdout: %s", code, stdout)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload[hzKeyConfirmedAbs] != false {
		t.Fatalf("receipt = %v — an ERRORING confirmation must fail closed, never report absence", payload)
	}
	note, _ := payload["note"].(string)
	if !strings.Contains(note, hzNotConfirmedPhras) {
		t.Errorf("note = %q, want it to say %q", note, hzNotConfirmedPhras)
	}
}
