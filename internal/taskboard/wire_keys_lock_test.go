package taskboard

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// The Go half of the cross-seam wire lock. The BLOCKING half lives at
// api/test/barkpark_web/controllers/taskboard_wire_lock_test.exs — a Go test
// trips no required merge context, so it cannot be the lock; it can only
// pin the CONSUMER side of the same four names.
//
// What this file adds that the Elixir file cannot: the four load-bearing key
// names are read out of the real struct tags with reflect, so renaming a tag
// in fetch.go (rather than on the producer) reds here, and the fixtures are
// asserted to actually CARRY those keys — a fixture that dropped them would
// leave the whole board suite exercising nothing.
//
// board_fixture.json is deliberately absent from wireFixtures: it is a
// marshalled Go struct (PascalCase keys, Go on both ends, no drift axis).
var wireFixtures = []string{
	"tasks_fixture.json",
	"detail_fixture.json",
	"cluster_fixture.json",
	"flat_queue_fixture.json",
}

// jsonTags returns the json tag names declared on a struct type.
func jsonTags(t *testing.T, typ reflect.Type) map[string]bool {
	t.Helper()
	tags := map[string]bool{}
	for i := 0; i < typ.NumField(); i++ {
		if tag, ok := typ.Field(i).Tag.Lookup("json"); ok {
			for j := 0; j < len(tag); j++ {
				if tag[j] == ',' {
					tag = tag[:j]
					break
				}
			}
			if tag != "" && tag != "-" {
				tags[tag] = true
			}
		}
	}
	return tags
}

// TestWireKeyTagsAreTheNamesTheProducerEmits pins the four names the board
// decides work EXISTS from. The Elixir sibling proves the producer still
// emits them; this proves the decoder still asks for them.
func TestWireKeyTagsAreTheNamesTheProducerEmits(t *testing.T) {
	claimTags := jsonTags(t, reflect.TypeOf(claimWire{}))
	for _, name := range []string{"worker", "epoch", "previous_worker", "expired_at"} {
		if !claimTags[name] {
			t.Fatalf("claimWire no longer reads json:%q — tags: %v\n"+
				"worker+epoch are the CAS the whole board keys on; previous_worker+"+
				"expired_at are the swept-lease display fields.", name, claimTags)
		}
	}

	docTags := jsonTags(t, reflect.TypeOf(taskWire{}))
	if !docTags["claim"] {
		t.Fatalf("taskWire no longer reads json:%q — tags: %v", "claim", docTags)
	}

	// The readiness key itself: decodePrime's anonymous envelope is not
	// reflectable, so assert it end to end instead — a prime body whose ready
	// entries are keyed "doc_id" must produce exactly that readyID.
	extras, err := decodePrime([]byte(`{"ok":true,"counts":{},"ready":[{"doc_id":"r1"}]}`))
	if err != nil {
		t.Fatalf("decodePrime on a well-formed body: %v", err)
	}
	if !extras.readyIDs["r1"] {
		t.Fatalf("decodePrime no longer reads the readiness queue off json:%q with "+
			"entries keyed json:%q — readyIDs=%v.\n"+
			"Readiness is DERIVED: storage never holds \"ready\"; composeSnapshot "+
			"overlays it from this queue. A rename here shows ZERO ready rows.",
			"ready", "doc_id", extras.readyIDs)
	}
}

// TestWireFixturesStillCarryTheLoadBearingKeys refuses on an empty read and
// proves each hand-held snapshot still exercises the readiness overlay and
// the claim CAS.
func TestWireFixturesStillCarryTheLoadBearingKeys(t *testing.T) {
	for _, name := range wireFixtures {
		name := name
		t.Run(name, func(t *testing.T) {
			path := filepath.Join("testdata", name)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v (a missing fixture must FAIL, not skip)", path, err)
			}
			var fx struct {
				Docs  []json.RawMessage `json:"docs"`
				Prime json.RawMessage   `json:"prime"`
			}
			if err := json.Unmarshal(raw, &fx); err != nil {
				t.Fatalf("decode %s: %v", path, err)
			}
			if len(fx.Docs) == 0 {
				t.Fatalf("%s carries zero docs — an empty read must FAIL", path)
			}
			if len(fx.Prime) == 0 {
				t.Fatalf("%s carries no prime envelope", path)
			}

			// The whole docs slice must flow through the SAME decoder the live
			// fetch uses — no test-only shortcut.
			tasks, _, err := decodeTaskListFull(raw)
			if err != nil {
				t.Fatalf("decodeTaskListFull(%s): %v", path, err)
			}
			extras, err := decodePrime(fx.Prime)
			if err != nil {
				t.Fatalf("decodePrime(%s): %v", path, err)
			}
			if len(extras.readyIDs) == 0 {
				t.Fatalf("%s: prime.ready is empty — the fixture cannot exercise readiness", path)
			}

			// NON-VACUITY: at least one row STORED open that becomes ready only
			// through the readiness overlay. That is the exact case a rename breaks.
			overlaid := 0
			claimed := 0
			for _, task := range tasks {
				if task.Lifecycle == "open" && extras.readyIDs[task.DocID] {
					overlaid++
				}
				if task.Claim != nil && task.Claim.Worker != "" && task.Claim.Epoch != 0 {
					claimed++
				}
				if task.Lifecycle == "ready" {
					t.Fatalf("%s stores %q as a lifecycle_status; readiness is DERIVED", path, "ready")
				}
			}
			if overlaid == 0 {
				t.Fatalf("%s holds no row stored open that the readiness overlay lifts to ready", path)
			}
			if claimed == 0 {
				t.Fatalf("%s holds no row carrying both claim.worker and claim.epoch", path)
			}
		})
	}
}
