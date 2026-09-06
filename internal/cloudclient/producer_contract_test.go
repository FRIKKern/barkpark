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

	// EXACT COUNT, not a floor — and the upper half is the load-bearing one.
	//
	// A LOWER count means the parse went blind, which the spot checks above
	// already catch. A HIGHER count means it went WIDE: matching identifiers
	// that are not top-level keys (a field inside `console:`'s Enum.map, an
	// argument name, a nested map) silently ENLARGES the set of keys the
	// producer is believed to send, and every extra key is one that can mask a
	// genuinely dormant field by coincidence. Measured: a regex relaxed from
	// `^\s{6}(\w+):` to a bare `(\w+):` still let the guard PASS — it found the
	// same two dormant tags, but only because nothing nested happened to be
	// named `port`. That is a guard passing by luck, which is the exact defect
	// this file exists to prevent, so the count is pinned in both directions.
	//
	// This number MOVES when the serializer legitimately gains or loses a key.
	// That is intended: the contract changed, and someone should look.
	// 31 -> 34 (#15095, task-5d3febd051e63c1d): deployment_json/1 gained `slot`, `port`
	// and `health_exit_code` (the served-slot truth, nullable health). `port` left
	// dormantTags in the same change — the producer now sends it, so the waiver
	// was stale and this guard said so on main (measured 2026-09-02).
	// 34 -> 36 (#16511, task-f156b5e43bfbfe91): deployment_json/1 gained
	// `failure_code` and `failure_message` — the fused refusal string unfused
	// into a typed code + message beside the composite `failure_reason`. This
	// pin was the only consumer that noticed; it reddened main's Go gate from
	// 3d238fdd8 (2026-09-06 17:21Z) until this line moved.
	const producerKeyCount = 36 // deployment_json/1's 34 + site_deployment_json/3's stages + url
	if len(producer) != producerKeyCount {
		direction := "WIDE — it is matching identifiers that are not top-level keys, " +
			"which can mask a dormant field"
		if len(producer) < producerKeyCount {
			direction = "BLIND — it is missing real keys, so live fields will be " +
				"reported as never-sent"
		}
		t.Errorf("extracted %d producer keys, expected exactly %d. The parse has gone %s. "+
			"If the serializer genuinely changed, update producerKeyCount and say why.",
			len(producer), producerKeyCount, direction)
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
