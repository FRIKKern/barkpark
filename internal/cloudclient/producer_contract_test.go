package cloudclient

// producer_contract_test.go — A DECODER MUST NOT OUTLIVE ITS PRODUCER.
//
// THE DEFECT THIS EXISTS FOR. SiteDeployment has declared `Port` (json:"port")
// and `RuntimeTarget` (json:"runtime_target") since #3976, 2026-07-17 — a commit
// that touched internal/cli and internal/cloudclient and NOTHING in cloud/. The
// control plane's deployment_json/1 has never emitted either key. Five weeks of
// a decoder for keys the producer was never taught to send. Nothing lies today
// (every render site guards on non-empty first), but the fields look shipped,
// and that confusion is measurable: it is part of why the node-slot surfacing
// row read as a CLI task when its blocker was a missing database column.
//
// WHY NO EXISTING TEST CATCHES IT — the transferable part. The CLI tests
// hand-write fixtures that SUPPLY runtime_target and port and then assert the
// struct decoded them (cloud_site_cmd_test.go:356, :513, asserted at :389).
// Those tests are meaningful and pass honestly; they prove the decode works.
// They simply cannot notice that production never sends the keys. THE FIXTURE
// IS RICHER THAN REALITY — the inverse of the usual vacuous-green, where a
// fixture is too POOR to exercise the code. A too-generous fixture is harder to
// spot precisely because the test looks healthy: it validates a contract only
// one side of which exists. No hand-written fixture can ever catch this class;
// only a comparison against the REAL producer can.
//
// WHAT THIS DOES. Reads the actual Elixir serializer that feeds SiteDeployment
// and asserts every json tag the Go struct declares is a key that serializer
// can emit. The producer side is read from source, never from a fixture, so it
// cannot drift out of agreement with itself.
//
// THE PAIRING, established by reading the routes: SiteDeployment is decoded
// from `{"deployment": …}` bodies (postSiteDeploy, SpawnSiteDeployment) which
// the control plane fills from EITHER `deployment_json/1` or its wrapper
// `site_deployment_json/3` — the latter being `deployment_json/1` plus `:stages`
// and `:url`. Both live in the CLOUD router, cloud/lib/barkpark_cloud/web/
// router.ex, which is NOT the api/ router of the same basename. The union of
// both functions is what the producer can send.
//
// Cited by SYMBOL, not by line: this file exists because an anchor rotted
// silently, and its first version cited five call sites by line number in a
// file that moves constantly. `grep -n 'deployment_json' ` on the cloud router
// finds every one of them and cannot go stale.

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// dormantTags is the WAIVER: json tags SiteDeployment declares that the
// producer provably does not send. It is pinned as an exact set, not a
// threshold, for the same reason the run-level-reader census pins a count — a
// waiver that can grow silently is not a waiver.
//
// Adding a tag here is a deliberate act that needs a reason. Removing one
// happens when the producer learns to send it, or the field is deleted.
//
//	port           — task-4f91a03ea23aaba7 will make the CP emit it (node slot port)
//	runtime_target — same row; today it reaches the BOX payload only, never the
//	                 deployment JSON the CLI reads
var dormantTags = map[string]string{
	"runtime_target": "#3976 added the decoder; it rides the box payload, not the CLI-facing deployment JSON. Same producer row.",
}

// repoRoot walks up from the test's working directory to the module root.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 12; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("could not find go.mod walking up from the test directory")
	return ""
}

var (
	// A top-level key inside deployment_json/1's map literal. The body is a
	// single-level `%{ … }` with every key at exactly six spaces — verified, and
	// re-verified by TestProducerExtractorIsNotBlind below, which fails if this
	// assumption ever stops holding.
	reTopKey = regexp.MustCompile(`^\s{6}([a-z_][a-z0-9_]*):(\s|$)`)
	// `|> Map.put(:stages, …)` in the wrapper.
	reMapPut = regexp.MustCompile(`Map\.put\(:([a-z_][a-z0-9_]*),`)
)

// elixirDefpBody returns the source lines of `defp <name>(` through its
// matching `end` at the same indentation.
func elixirDefpBody(t *testing.T, src []string, name string) []string {
	t.Helper()
	head := regexp.MustCompile(`^(\s*)defp ` + regexp.QuoteMeta(name) + `\(`)
	start, indent := -1, 0
	for i, ln := range src {
		if m := head.FindStringSubmatch(ln); m != nil && strings.HasSuffix(strings.TrimRight(ln, " "), " do") {
			start, indent = i, len(m[1])
			break
		}
	}
	if start < 0 {
		t.Fatalf("%s/1 not found in the control plane router — the pairing this guard "+
			"depends on has moved; re-establish it before editing this test", name)
	}
	for j := start + 1; j < len(src); j++ {
		ln := src[j]
		if strings.TrimSpace(ln) == "end" && len(ln)-len(strings.TrimLeft(ln, " ")) == indent {
			return src[start : j+1]
		}
	}
	t.Fatalf("no terminating `end` for %s/1", name)
	return nil
}

// producerKeys reads the REAL serializer and returns every key it can emit.
func producerKeys(t *testing.T) map[string]bool {
	t.Helper()
	path := filepath.Join(repoRoot(t), "cloud", "lib", "barkpark_cloud", "web", "router.ex")
	raw, err := os.ReadFile(path)
	if err != nil {
		// Deliberately fatal, never skipped: a guard that quietly stands down
		// when it cannot see the producer is the dark-gate failure this file
		// exists to prevent.
		t.Fatalf("cannot read the control-plane router at %s: %v", path, err)
	}
	src := strings.Split(string(raw), "\n")

	keys := map[string]bool{}
	for _, ln := range elixirDefpBody(t, src, "deployment_json") {
		if strings.HasPrefix(strings.TrimSpace(ln), "#") {
			continue
		}
		if m := reTopKey.FindStringSubmatch(ln); m != nil {
			keys[m[1]] = true
		}
	}
	// The wrapper's additions (:stages, :url) — the same body, different shape.
	for _, m := range reMapPut.FindAllStringSubmatch(
		strings.Join(elixirDefpBody(t, src, "site_deployment_json"), "\n"), -1) {
		keys[m[1]] = true
	}
	return keys
}

// declaredTags returns the json tag names on a struct, skipping `-`.
func declaredTags(typ reflect.Type) []string {
	var out []string
	for i := 0; i < typ.NumField(); i++ {
		tag := typ.Field(i).Tag.Get("json")
		if tag == "" || tag == "-" {
			continue
		}
		if name := strings.Split(tag, ",")[0]; name != "" {
			out = append(out, name)
		}
	}
	return out
}

// THE GUARD. Every tag SiteDeployment decodes must be a key the producer can
// send — except the waived ones, which must be EXACTLY the waiver.
func TestSiteDeploymentDecoderMatchesProducer(t *testing.T) {
	producer := producerKeys(t)

	var unsent []string
	for _, tag := range declaredTags(reflect.TypeOf(SiteDeployment{})) {
		if !producer[tag] {
			unsent = append(unsent, tag)
		}
	}
	sort.Strings(unsent)

	want := make([]string, 0, len(dormantTags))
	for k := range dormantTags {
		want = append(want, k)
	}
	sort.Strings(want)

	if !reflect.DeepEqual(unsent, want) {
		for _, tag := range unsent {
			if _, waived := dormantTags[tag]; !waived {
				t.Errorf("SiteDeployment declares json:%q but the control plane's "+
					"deployment_json/1 (+ site_deployment_json/3) never emits that key. "+
					"json.Unmarshal drops unmodelled keys silently, so this field will "+
					"read as its zero value forever while looking like a shipped feature. "+
					"Either teach the producer to send it, remove the field, or add it to "+
					"dormantTags WITH A REASON.", tag)
			}
		}
		for _, tag := range want {
			if !contains(unsent, tag) {
				t.Errorf("json:%q is in dormantTags but the producer now DOES send it — "+
					"the waiver is stale. Delete the entry; the field is live.", tag)
			}
		}
		t.Errorf("unsent tags = %v, waiver = %v", unsent, want)
	}
}

// POSITIVE CONTROL. A guard that finds nothing validates everything. This
// pins that the machinery can still SEE the known defect: if the extractor
// breaks open (returns every identifier, or the tag walk stops finding
// fields), `unsent` empties and the guard above would pass over a real
// regression. Measured on origin/main 2026-08-24: exactly port + runtime_target.
func TestGuardStillDetectsTheKnownDormantFields(t *testing.T) {
	producer := producerKeys(t)

	for tag := range dormantTags {
		if producer[tag] {
			t.Errorf("the producer now emits %q — this control is stale; if the field "+
				"is genuinely live, remove it from dormantTags", tag)
		}
	}
	if len(dormantTags) == 0 {
		t.Fatal("dormantTags is empty — with nothing to detect, the guard cannot be " +
			"shown to work at all")
	}
}

// NEGATIVE CONTROL. The mirror of the arm above: if the extractor returned an
// EMPTY key set, every tag would read as unsent and the guard would fire on
// everything — loud, but for the wrong reason, and it would be "fixed" by
// padding the waiver until the guard meant nothing. These are keys the
// serializer provably carries; the extractor must find them.
func TestProducerExtractorIsNotBlind(t *testing.T) {
	producer := producerKeys(t)

	// A spread across the map: first key, last key, the multi-line `console:`
	// entry whose value spans four lines, and both wrapper additions.
	for _, key := range []string{
		"id", "site_id", "status", "stage", "build_id", "failure_reason",
		"failure_class", "console", "detail", "inserted_at", "updated_at",
		"stages", "url",
	} {
		if !producer[key] {
			t.Errorf("the extractor did not find %q, which deployment_json/1 "+
				"demonstrably emits — the parse is blind and every finding it "+
				"reports is untrustworthy", key)
		}
	}

	// THE SET, not the count. Until 2026-09-06 this arm pinned `len(producer)`
	// to an integer. That integer moved four times in one day on honest field
	// additions (31 -> 34, #15095; 34 -> 36, #16511) and each move reddened
	// main's Go gate with a message that named a NUMBER — "extracted 36, expected
	// 34" — and left the reader to diff two source files by hand to learn WHICH
	// key had appeared. A cardinality pin is a tripwire on GROWTH, not a guard
	// against drift: it fires on every legitimate change and cannot tell an added
	// top-level key from a regex that started matching a nested one, because
	// both read as "+1". Four re-pins in a day is the shape of a guard that is
	// about to be waved through, and the eighth re-pin is what lets the wide
	// regex in.
	//
	// The set keeps BOTH directions the count had, and names the offender:
	//
	//   MISSING a key  -> the parse went BLIND (a real key no longer found), or the
	//                     serializer genuinely dropped it. Either way, the message
	//                     says which one.
	//   EXTRA key      -> the parse went WIDE (matching an identifier that is not
	//                     a top-level key — a field inside `console:`'s Enum.map,
	//                     an argument name, a nested map), or the serializer
	//                     genuinely gained a key. The NAME tells the two apart in
	//                     one glance: `failure_code` is a key deployment_json/1
	//                     now emits, `port` inside a nested map is not.
	//
	// Every extra key is also one that can mask a genuinely dormant field by
	// coincidence (measured: a regex relaxed from `^\s{6}(\w+):` to a bare
	// `(\w+):` still let the dormant-tag guard PASS, only because nothing nested
	// happened to be named `port`), which is why the wide direction is pinned at
	// all rather than being a floor.
	//
	// This list MOVES when the serializer legitimately gains or loses a key.
	// That is intended: the contract changed, and someone should look — and the
	// diff of this literal IS the look. The fix for an honest addition is one
	// line: add the key here, in its place in the serializer's order, with the PR
	// that taught deployment_json/1 to send it. History of the pin:
	//   31 -> 34 (#15095, task-5d3febd051e63c1d): +slot, +port, +health_exit_code.
	//   34 -> 36 (#16511, task-f156b5e43bfbfe91): +failure_code, +failure_message —
	//            reddened main's Go gate from 3d238fdd8 (2026-09-06 17:21Z) until
	//            the count moved (#16547); this arm would have printed the two
	//            names instead.
	if missing, extra := producerKeySetDiff(producer); len(missing)+len(extra) > 0 {
		if len(missing) > 0 {
			t.Errorf("the extractor no longer finds %v, which deployment_json/1 (+ "+
				"site_deployment_json/3) is pinned to emit. Either the parse has gone BLIND "+
				"(a real key stopped matching reTopKey — live fields will be reported as "+
				"never-sent) or the serializer genuinely dropped the key. If the serializer "+
				"changed, remove the key from expectedProducerKeys and say why.", missing)
		}
		if len(extra) > 0 {
			t.Errorf("the extractor found %v, which expectedProducerKeys does not list. "+
				"Either the parse has gone WIDE (matching an identifier that is not a "+
				"top-level key, which can mask a dormant field) or the serializer genuinely "+
				"gained the key. If it is a real top-level key of deployment_json/1 or a "+
				"Map.put in site_deployment_json/3, add it to expectedProducerKeys in the "+
				"serializer's order and cite the PR that added it.", extra)
		}
	}
}

// expectedProducerKeys is the pinned key SET of deployment_json/1 (in the
// serializer's own order, so a diff of this literal reads like a diff of the
// serializer) followed by site_deployment_json/3's two Map.put additions.
// Pinned 2026-09-06 against origin/main 4e7dd109f: 34 + 2 = 36 keys, the same
// population the retired producerKeyCount named.
var expectedProducerKeys = []string{
	// deployment_json/1
	"id", "site_id", "status", "git_ref", "artifact_url", "image_tag",
	"build_log_url", "failure_reason", "failure_class", "failure_reason_raw",
	"refusal_phase", "failure_code", "failure_message", "deferral_depth",
	"deferral_bound", "deferral_cause", "became_live_at", "environment", "branch",
	"preview_host", "preview_url", "trigger", "source", "artifact_sha256",
	"console", "detail", "build_id", "content_rev", "stage", "slot", "port",
	"health_exit_code", "inserted_at", "updated_at",
	// site_deployment_json/3
	"stages", "url",
}

// producerKeySetDiff returns the pinned keys the extractor did NOT find
// (missing) and the keys it found that are NOT pinned (extra), both sorted so
// the failure message is stable.
func producerKeySetDiff(producer map[string]bool) (missing, extra []string) {
	expected := make(map[string]bool, len(expectedProducerKeys))
	for _, k := range expectedProducerKeys {
		expected[k] = true
		if !producer[k] {
			missing = append(missing, k)
		}
	}
	for k := range producer {
		if !expected[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	return missing, extra
}

// THE PIN MUST BE A SET. A duplicate entry in expectedProducerKeys would let a
// 36-line literal describe 35 keys and nobody would notice, because the diff
// arm above is keyed on membership. Refuse it here.
func TestExpectedProducerKeysHasNoDuplicates(t *testing.T) {
	seen := map[string]bool{}
	for _, k := range expectedProducerKeys {
		if seen[k] {
			t.Errorf("expectedProducerKeys lists %q twice", k)
		}
		seen[k] = true
	}
	if len(seen) == 0 {
		t.Fatal("expectedProducerKeys is empty — with nothing pinned, the diff arm cannot fail")
	}
}

func contains(hay []string, needle string) bool {
	for _, s := range hay {
		if s == needle {
			return true
		}
	}
	return false
}
