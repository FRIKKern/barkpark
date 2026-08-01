package cli

// hetzner_respost_basis_test.go — PDS-D437's proofs: that hzResObserved's
// trailing variadic basis reaches the receipt, that the GENERIC INFERENCE still
// works with it passed, and that the three object-store call sites now name the
// read they actually perform while the ten hcloud callers keep saying GET.
//
// WHY INFERENCE IS PROVEN POSITIVELY AND NOT BY "the build passed": no call
// site in the package instantiates hzResObserved[T] explicitly — `grep -rn
// 'hzResObserved\[' internal/cli/` returns the definition and nothing else — so
// type inference is load-bearing at all thirteen. A green build is consistent
// with a signature whose variadic accidentally participated in unification and
// forced every caller to a wrong T that happened to compile. A test that calls
// it with T INFERRED, passes the basis, and then checks the observe hook FIRED
// is not consistent with that.

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// basisProbe is a package-local type on purpose. Using hcloud.LoadBalancer here
// would let a reader wonder whether inference is riding some hcloud-specific
// path; a type with no relationship to anything the apparatus knows about
// leaves only the inference itself.
type basisProbe struct{ id int64 }

// TestHzResObservedInfersTWithAnExplicitBasis is the POSITIVE inference proof
// and the basis-resolution table in one: every arm calls hzResObserved with T
// inferred from the read closure AND the trailing basis supplied, and every arm
// asserts the observe hook actually ran before reading the emitted basis.
func TestHzResObservedInfersTWithAnExplicitBasis(t *testing.T) {
	cases := []struct {
		name  string
		basis []string
		want  string
	}{
		{"omitted — the ten hcloud callers", nil, hzResBasisGet},
		{"explicit HEAD — object put, backup create", []string{hzResBasisHead}, hzResBasisHead},
		{"explicit list scan — bucket create", []string{hzResBasisListScan}, hzResBasisListScan},
		// FOOTGUN (2): an empty string must degrade to the default. A receipt
		// whose confirmation_basis is "" is worse than one naming the default —
		// a reader cannot tell it apart from the key being absent.
		{"empty string falls back, never blank", []string{""}, hzResBasisGet},
		// FOOTGUN (1): two bases COMPILE. The first wins, and that is pinned so
		// the behaviour is a decision rather than an accident.
		{"two bases — the first wins", []string{hzResBasisHead, hzResBasisListScan}, hzResBasisHead},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// T is INFERRED here, from the closure's return type. Nothing in
			// this file writes hzResObserved[basisProbe](…).
			read := func(context.Context) (*basisProbe, *hcloud.Response, error) {
				return &basisProbe{id: 7}, nil, nil
			}
			observed := false
			observe := func(p *basisProbe) hzResObservation {
				observed = true
				return hzResAgrees(map[string]any{"probe_id": p.id})
			}

			out, buf := newJSONTestWriter()
			code := hzResObserved(out, context.Background(), "probe", "probe-kind", int64(7), "probe-7", nil,
				read, observe, tc.basis...)
			if code != exitOK {
				t.Fatalf("exit %d, want 0: %s", code, buf())
			}
			// THE INFERENCE ASSERTION. A signature that compiled but never
			// reached the observe hook — or reached it with a T the call site
			// did not mean — cannot leave this true alongside probe_id below.
			if !observed {
				t.Fatal("the observe hook never ran: hzResObserved compiled with T inferred but did not " +
					"call observe(fresh), so the receipt was not built from the read")
			}

			var payload map[string]any
			if err := json.Unmarshal([]byte(buf()), &payload); err != nil {
				t.Fatalf("receipt is not JSON: %v\n%s", err, buf())
			}
			if payload["probe_id"] != float64(7) {
				t.Errorf("receipt = %v, want probe_id 7 — the OBSERVED value, proving T inferred to basisProbe",
					payload)
			}
			if got, _ := payload[hzKeyConfirmBasis].(string); got != tc.want {
				t.Errorf("%s = %q, want %q", hzKeyConfirmBasis, got, tc.want)
			}
		})
	}
}

// TestHzResObservedBasisIsVisibleToAnOperator drives the three object-store
// verbs through the REAL CLI against the S3 fake and quotes the basis each
// receipt printed. A unit-level assertion on hzResObserved could be true while
// the dispatch path never reached the site that passes the basis.
func TestHzResObservedBasisIsVisibleToAnOperator(t *testing.T) {
	basisOf := func(t *testing.T, stdout string) string {
		t.Helper()
		var payload map[string]any
		if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
			t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
		}
		if payload[hzKeyConfirmedPresent] != true {
			t.Fatalf("receipt = %v, want a confirmed ✓ before its basis means anything", payload)
		}
		basis, _ := payload[hzKeyConfirmBasis].(string)
		t.Logf("%s = %q", hzKeyConfirmBasis, basis)
		return basis
	}

	t.Run("bucket create names the listing scan", func(t *testing.T) {
		withFakeS3(t, newFakeS3())
		stdout, stderr, code := runHzCLI(t, "json", storageArgs(
			"hetzner", "storage", "bucket", "create", "--name", "basis-bkt", "--location", "nbg1")...)
		if code != exitOK {
			t.Fatalf("bucket create exited %d, stderr: %s", code, stderr)
		}
		if got := basisOf(t, stdout); got != hzResBasisListScan {
			t.Errorf("bucket create basis = %q, want %q — it scans a LISTING, it does not GET an id",
				got, hzResBasisListScan)
		}
	})

	t.Run("object put names the HEAD", func(t *testing.T) {
		withFakeS3(t, newFakeS3())
		path := filepath.Join(t.TempDir(), "payload.txt")
		if err := os.WriteFile(path, []byte("bytes\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		stdout, stderr, code := runHzCLI(t, "json", storageArgs(
			"hetzner", "storage", "object", "put", "--bucket", "bkt", "--key", "k.txt", "--file", path)...)
		if code != exitOK {
			t.Fatalf("object put exited %d, stderr: %s", code, stderr)
		}
		if got := basisOf(t, stdout); got != hzResBasisHead {
			t.Errorf("object put basis = %q, want %q", got, hzResBasisHead)
		}
	})

	t.Run("backup create names the HEAD", func(t *testing.T) {
		f, _ := multipartS3()
		withFakeS3(t, f)
		withFixedDump(t, "barkpark", []byte("CREATE TABLE parks (id serial);\n"))
		stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "backup", "create",
			"--database-url", "postgres://bp@db.internal/barkpark", "--bucket", "bkt", "--prefix", "prod")...)
		if code != exitOK {
			t.Fatalf("backup create exited %d, stderr: %s", code, stderr)
		}
		if got := basisOf(t, stdout); got != hzResBasisHead {
			t.Errorf("backup create basis = %q, want %q", got, hzResBasisHead)
		}
	})

	// THE OTHER HALF, and without it this proof would be satisfied by a change
	// that simply renamed the default: an hcloud caller that passes NO basis
	// must still say GET. Ten call sites in hetzner_lb_cmd.go are in this arm.
	t.Run("an hcloud mutation still names the GET", func(t *testing.T) {
		f := newFakeHzAPI(t)
		f.mux.HandleFunc("GET /load_balancers/7", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"load_balancer":`+hzLBLeastConn+`}`)
		})
		f.mux.HandleFunc("POST /load_balancers/7/actions/change_algorithm", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"action":{"id":210,"command":"change_algorithm","status":"running","progress":0}}`)
		})
		hzActionsAllSucceed(f)

		stdout, stderr, code := runHzCLI(t, "json", "hetzner", "load-balancer", "change-algorithm", "7",
			"--algorithm", "least_connections")
		if code != exitOK {
			t.Fatalf("change-algorithm exited %d, stderr: %s", code, stderr)
		}
		if got := basisOf(t, stdout); got != hzResBasisGet {
			t.Errorf("change-algorithm basis = %q, want the unchanged default %q", got, hzResBasisGet)
		}
	})
}

// TestHzResBasisOfDegradesRatherThanBlanking pins the resolver directly, so the
// two footguns keep a named home even if every call site above changes.
//
// THE LIMIT THIS FILE DOES NOT COVER, STATED (PDS-D438) and measured both ways:
// swapping ONE SITE's basis constant is caught above (mutation A), but changing
// what a CONSTANT SAYS is not — hzResBasisHead reworded to "single-resource GET
// on the resolved id, verified byte-for-byte" leaves the whole package green at
// ok 29.380s while two receipts print it for an existence HEAD, because every
// assertion here compares the key symbolically against the constant. These
// tests pin that the basis a call site CHOSE arrives intact, never that the
// choice is true of the read. Binding the basis to what the census knows each
// row reads is pds-w32-census-binds-the-basis.
func TestHzResBasisOfDegradesRatherThanBlanking(t *testing.T) {
	if got := hzResBasisOf(nil); got != hzResBasisGet {
		t.Errorf("hzResBasisOf(nil) = %q, want the GET default", got)
	}
	if got := hzResBasisOf([]string{""}); got != hzResBasisGet {
		t.Errorf(`hzResBasisOf([""]) = %q, want the GET default — a blank basis is unreadable`, got)
	}
	if got := hzResBasisOf([]string{hzResBasisHead}); got != hzResBasisHead {
		t.Errorf("hzResBasisOf([head]) = %q, want it through untouched", got)
	}
	for _, b := range []string{hzResBasisGet, hzResBasisResponse, hzResBasisHead, hzResBasisListScan} {
		if strings.TrimSpace(b) == "" {
			t.Errorf("basis constant is blank: %q", b)
		}
	}
}
