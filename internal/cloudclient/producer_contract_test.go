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
	"bytes"
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
// EMPTY, AND THAT IS THE GOAL STATE, not a gap. History:
//
//	port           — CLOSED by the producer (#15095): deployment_json/1 emits it.
//	runtime_target — CLOSED by DELETING the field (dr-w11-payload-divergence-close).
//	                 The plane derives it from site.kind and sends it only on the
//	                 box's deploy/rollback payloads, never on a deployment row,
//	                 so SiteDeployment stopped declaring it.
//
// The positive control below no longer leans on a live dormant field to prove
// the guard can see one; it plants a synthetic tag instead.
var dormantTags = map[string]string{}

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

// unsentTags is the guard's one computation: the declared tags the producer
// cannot emit, sorted, and never nil (so an empty result compares equal to an
// empty waiver under reflect.DeepEqual — a nil-vs-empty mismatch would red the
// guard on the one state it exists to reach).
func unsentTags(producer map[string]bool, declared []string) []string {
	unsent := []string{}
	for _, tag := range declared {
		if !producer[tag] {
			unsent = append(unsent, tag)
		}
	}
	sort.Strings(unsent)
	return unsent
}

// THE GUARD. Every tag SiteDeployment decodes must be a key the producer can
// send — except the waived ones, which must be EXACTLY the waiver.
func TestSiteDeploymentDecoderMatchesProducer(t *testing.T) {
	producer := producerKeys(t)

	unsent := unsentTags(producer, declaredTags(reflect.TypeOf(SiteDeployment{})))

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
// pins that the machinery can still SEE a dormant field: if the extractor
// breaks open (returns every identifier, or the tag walk stops finding
// fields), `unsent` empties and the guard above would pass over a real
// regression.
//
// It used to lean on the LIVE defect (port + runtime_target, measured on
// origin/main 2026-08-24) and Fatal on an empty waiver. Both specimens are now
// closed, so the control plants its own: SiteDeployment's REAL declared tags
// plus one synthetic name no serializer emits, fed through the SAME
// unsentTags the guard uses. It must report exactly the plant — a wide
// extractor misses it, a blind one reports real tags beside it.
func TestGuardStillDetectsTheKnownDormantFields(t *testing.T) {
	producer := producerKeys(t)

	for tag := range dormantTags {
		if producer[tag] {
			t.Errorf("the producer now emits %q — this control is stale; if the field "+
				"is genuinely live, remove it from dormantTags", tag)
		}
	}

	const plant = "dr_w11_planted_dormant_tag"
	declared := append(declaredTags(reflect.TypeOf(SiteDeployment{})), plant)
	got := unsentTags(producer, declared)
	want := make([]string, 0, len(dormantTags)+1)
	for k := range dormantTags {
		want = append(want, k)
	}
	want = append(want, plant)
	sort.Strings(want)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("planted a tag no serializer emits; the guard computation reported %v, "+
			"want exactly %v — the extractor or the tag walk has stopped discriminating", got, want)
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
	//   36 -> 38 (#17640, task dr-w21-bl-route-decision-reaches-no-plane):
	//            +route_status, +route_detail — the box's Caddy ARM decision
	//            (charter D608's SIBLING channel, never a stage). This arm did
	//            print both names, which is how the addition was found; neither
	//            is decoded by cloudclient yet, and the cloud-side census carries
	//            two matching `:unread` rows naming that follow-up.
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
// population the retired producerKeyCount named. Re-measured 2026-09-11 against
// origin/main f707ef829 with #17640's serializer hunk applied: 36 + 2 = 38.
var expectedProducerKeys = []string{
	// deployment_json/1
	"id", "site_id", "status", "git_ref", "artifact_url", "image_tag",
	"build_log_url", "failure_reason", "failure_class", "failure_reason_raw",
	"refusal_phase", "failure_code", "failure_message", "deferral_depth",
	"deferral_bound", "deferral_cause", "became_live_at", "environment", "branch",
	"preview_host", "preview_url", "trigger", "source", "artifact_sha256",
	"console", "detail", "build_id", "content_rev", "stage", "slot", "port",
	"health_exit_code",
	// #17640 (task dr-w21-bl-route-decision-reaches-no-plane, charter D608): the
	// box's Caddy ARM decision. Emitted immediately after `health_exit_code` in
	// deployment_json/1, and listed here in that same position so a diff of this
	// literal keeps reading like a diff of the serializer.
	"route_status", "route_detail",
	"inserted_at", "updated_at",
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

// ---------------------------------------------------------------------------
// THE SECOND PRODUCER: `BarkparkCloud.Sites.BuildLogBytes` -> SiteBuildLogBytes.
//
// Same defect, different pair. #17752 landed the build-log BYTES sub-route and
// said in its own body that this file was correctly untouched, "no Go decoder
// learns a key in this PR (c3 is the cli lane and is only REQUESTED below), and
// when the cli lane builds c3 and declares a struct for this payload, its tags
// belong in that file's expected-key set in serializer order." This is that.
//
// The producer here is NOT the cloud router: `BuildLogBytes` keeps an EXPLICIT
// field allowlist, `@bytes_keys`, precisely so a box that grows a field cannot
// have it relayed. That sigil plus the envelope keys the module merges around it
// is the complete set of keys this route can put on the wire, and it is read
// from source for the same reason deployment_json/1 is: a hand-typed second copy
// drifts silently.

// buildLogBytesProducerPath is the module that owns the wire shape.
func buildLogBytesProducerPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "cloud", "lib", "barkpark_cloud", "sites", "build_log_bytes.ex")
}

// reBytesKeysSigil captures the body of `@bytes_keys ~w( … )`, which may span
// several lines.
var reBytesKeysSigil = regexp.MustCompile(`(?s)@bytes_keys\s+~w\(([^)]*)\)`)

// buildLogBytesAllowlist returns the words of `@bytes_keys`, i.e. every record
// field `BuildLogBytes.record/1` can copy off the box's answer.
func buildLogBytesAllowlist(t *testing.T) map[string]bool {
	t.Helper()
	path := buildLogBytesProducerPath(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		// Fatal, never skipped: a guard that stands down when it cannot see the
		// producer is the dark-gate failure this whole file exists to prevent.
		t.Fatalf("cannot read the bytes producer at %s: %v", path, err)
	}
	m := reBytesKeysSigil.FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatalf("@bytes_keys ~w(…) not found in %s — the allowlist this guard reads "+
			"has moved or changed shape; re-establish the pairing before editing this test", path)
	}
	keys := map[string]bool{}
	for _, w := range strings.Fields(m[1]) {
		keys[w] = true
	}
	return keys
}

// buildLogBytesEnvelopeKeys are the keys `BuildLogBytes` merges AROUND the
// allowlist — the base every answer carries and the refusal shape the non-200s
// use. They are not in `@bytes_keys` (that sigil is the box-record allowlist
// only), so each is anchored individually against the source below rather than
// taken on trust.
var buildLogBytesEnvelopeKeys = []string{
	"deployment_id", "build_id", "available",
	"error", "detail", "reason", "box_log_state",
	// The 502 arm's own two keys. Added 2026-09-18 with task-3468f99ad5a4e9b8:
	// the producer has merged them since the route was written, and the Go
	// struct simply never declared them.
	"box_status", "box_error",
	// The reducer's other two keys. `box_error` is NOT written literally in
	// BuildLogBytes any more — #19341 moved all three spellings into
	// `BoxErrorEnvelope.fields/1` — so these are anchored by FOLLOWING the
	// call, not by matching a literal. See boxErrorEnvelopeKeys below.
	"box_error_message", "box_error_request_id",
}

// expectedBuildLogBytesTags is the pinned json tag list of SiteBuildLogBytes, IN
// THE SERIALIZER'S ORDER: `wire/3`'s base (`deployment_id`, `build_id`), then
// `available`, then `@bytes_keys` in its own declared order, then the refusal
// envelope. Pinned 2026-09-11 against origin/main 843c22742.
//
// A diff of this literal reads like a diff of `BuildLogBytes`. Renaming a struct
// tag without renaming it here reds TestSiteBuildLogBytesTagsAreLockedInOrder.
var expectedBuildLogBytesTags = []string{
	// wire/3 base + the served/withheld flag
	"deployment_id", "build_id", "available",
	// @bytes_keys, in its declared order
	"slug", "record", "log_state", "log_scrub", "log_path", "log_bytes",
	"tail_bytes", "truncated", "tail", "evicted_at",
	// the refusal envelope, then the box_error reducer's three keys in the
	// order `BoxErrorEnvelope.wire/3` writes them
	"error", "detail", "reason", "box_log_state", "box_status", "box_error",
	"box_error_message", "box_error_request_id",
}

// THE ORDER LOCK. Not merely a set: the row asks for serializer ORDER, and order
// is what makes the literal above readable as a diff of the producer.
func TestSiteBuildLogBytesTagsAreLockedInOrder(t *testing.T) {
	got := declaredTags(reflect.TypeOf(SiteBuildLogBytes{}))
	if !reflect.DeepEqual(got, expectedBuildLogBytesTags) {
		t.Errorf("SiteBuildLogBytes json tags = %v\nwant (serializer order)             = %v\n"+
			"Either the struct gained/lost/renamed a tag, or the field order moved. If "+
			"BuildLogBytes really changed, update expectedBuildLogBytesTags in the "+
			"producer's order and cite the PR; otherwise the decoder just went silently "+
			"deaf to a key json.Unmarshal will now drop.", got, expectedBuildLogBytesTags)
	}
}

// THE PRODUCER LOCK. Every tag the Go struct decodes must be a key
// `BuildLogBytes` can actually put on the wire — the allowlist sigil for the
// record fields, an anchored source match for the envelope ones.
func TestSiteBuildLogBytesDecoderMatchesProducer(t *testing.T) {
	allowlist := buildLogBytesAllowlist(t)
	raw, err := os.ReadFile(buildLogBytesProducerPath(t))
	if err != nil {
		t.Fatalf("cannot read the bytes producer: %v", err)
	}
	src := string(raw)

	// THE INDIRECTION IS PART OF THE PRODUCER. A key this module emits through
	// a shared reducer it CALLS is written just as surely as one spelled out
	// here; only the spelling moved modules. Reading the literal alone made
	// this guard red on #19341, a refactor with an UNCHANGED wire shape — and a
	// guard that reds on a no-op refactor teaches the edit-the-test reflex.
	indirect := producerIndirectKeys(t, src)

	envelope := map[string]bool{}
	for _, k := range buildLogBytesEnvelopeKeys {
		if !strings.Contains(src, k+":") && !indirect[k] {
			t.Errorf("the envelope key %q is written neither literally in BuildLogBytes "+
				"nor by any reducer it calls — either the producer dropped it (the Go "+
				"field will read as its zero value forever) or this anchor is stale.", k)
			continue
		}
		envelope[k] = true
	}

	for _, tag := range declaredTags(reflect.TypeOf(SiteBuildLogBytes{})) {
		if !allowlist[tag] && !envelope[tag] {
			t.Errorf("SiteBuildLogBytes declares json:%q but BuildLogBytes neither lists "+
				"it in @bytes_keys nor writes it into an envelope. json.Unmarshal drops "+
				"unmodelled keys silently, so this field would read as its zero value "+
				"forever while looking like a shipped feature.", tag)
		}
	}
}

// NOT-BLIND CONTROL. An extractor that returns an empty (or a wildly wide) set
// makes the guard above vacuous in one direction and noisy in the other, so the
// allowlist is pinned as a SET — the same lesson expectedProducerKeys records
// above, where a cardinality pin fired on every honest addition and named a
// number instead of a key.
func TestBuildLogBytesAllowlistExtractorIsNotBlind(t *testing.T) {
	allowlist := buildLogBytesAllowlist(t)

	want := []string{
		"slug", "build_id", "record", "log_state", "log_scrub", "log_path",
		"log_bytes", "tail_bytes", "truncated", "tail", "evicted_at",
	}
	for _, k := range want {
		if !allowlist[k] {
			t.Errorf("the extractor did not find %q in @bytes_keys, which BuildLogBytes "+
				"demonstrably lists — the parse is blind and every finding it reports is "+
				"untrustworthy", k)
		}
	}
	for k := range allowlist {
		if !contains(want, k) {
			t.Errorf("the extractor found %q, which this control does not pin. Either the "+
				"parse went WIDE (matching past the sigil's closing paren) or BuildLogBytes "+
				"genuinely gained a relayed field — if the latter, add it here AND to "+
				"expectedBuildLogBytesTags in the serializer's order, and teach the Go "+
				"struct to decode it.", k)
		}
	}
}

// ─── THE REDUCER, AND EVERY DECODER THAT MUST KEEP UP WITH IT ────────────────
//
// THE DEFECT THIS SECTION EXISTS FOR (task-bb5b44bcc5e233af). The guard above
// anchored each envelope key with strings.Contains(src, k+":") against ONE
// producer file. #19341 moved `box_error:` out of BuildLogBytes and into the
// shared reducer `BoxErrorEnvelope.fields/1`. The wire shape did not change by
// one byte; the guard went red anyway — a FALSE red, and the kind that gets
// silenced by editing the test.
//
// And underneath it, the real drift the guard could not see: fields/1 has
// ALWAYS returned THREE keys (box_error, box_error_message,
// box_error_request_id) and the Go structs declared one. json.Unmarshal drops
// unmodelled keys in silence, so the box's own message and request_id — the two
// facts that route an incident to the box instead of to this client — read as
// "" forever while looking shipped. The guard was blind to it because its key
// list was a SECOND HAND-TYPED COPY of the producer's: the stale set asserted
// against the stale set.
//
// So the reducer's key set is now READ FROM THE REDUCER, and the set of modules
// subject to it is DERIVED by walking cloud/lib for callers — never a list
// typed here, which is a snapshot of what someone checked rather than a rule
// about what exists.

// boxErrorEnvelopePath is the reducer that owns the box_error* wire keys.
func boxErrorEnvelopePath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "cloud", "lib", "barkpark_cloud", "sites", "box_error_envelope.ex")
}

// reBoxErrorWireMap captures the map literal `wire/3` builds — the ONE place
// the reducer names its wire keys.
var reBoxErrorWireMap = regexp.MustCompile("(?s)defp wire\\([^)]*\\) do\\s*%\\{(.*?)\\n\\s*\\}")

// reWireKey pulls `some_key:` out of that map literal.
var reWireKey = regexp.MustCompile(`(?m)^\s*([a-z_][a-z0-9_]*):`)

// boxErrorEnvelopeKeys returns every key BoxErrorEnvelope.fields/1 can put on
// the wire, read from the reducer's own source.
//
// NOT-BLIND, LOUDLY: an unreadable file, an unmatched shape and an empty key
// set are each t.Fatalf, never a pass and never a skip. An extractor that
// returns nothing makes every assertion built on it vacuously true, which is
// the dark-gate failure this whole file exists to prevent.
func boxErrorEnvelopeKeys(t *testing.T) []string {
	t.Helper()
	path := boxErrorEnvelopePath(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("cannot read the box_error reducer at %s: %v", path, err)
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		t.Fatalf("the box_error reducer at %s is EMPTY — every key assertion built on "+
			"it would pass vacuously", path)
	}
	m := reBoxErrorWireMap.FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatalf("`defp wire(…) do %%{…}` not found in %s — the reducer this guard reads "+
			"has moved or changed shape; re-establish the pairing before editing this test", path)
	}
	var keys []string
	for _, sub := range reWireKey.FindAllStringSubmatch(m[1], -1) {
		keys = append(keys, sub[1])
	}
	if len(keys) == 0 {
		t.Fatalf("the wire map in %s parsed to ZERO keys — the extractor is blind and "+
			"every finding it reports is untrustworthy", path)
	}
	sort.Strings(keys)
	return keys
}

// producerIndirectKeys returns the wire keys a producer module emits through
// reducers it CALLS, derived by reading each reducer's source. Keyed on the
// call site, so a module that stops calling the reducer stops inheriting its
// keys — the guard follows the code, not a note about the code.
func producerIndirectKeys(t *testing.T, src string) map[string]bool {
	t.Helper()
	keys := map[string]bool{}
	if strings.Contains(src, "BoxErrorEnvelope.fields(") {
		for _, k := range boxErrorEnvelopeKeys(t) {
			keys[k] = true
		}
	}
	return keys
}

// boxErrorEnvelopeCallers walks cloud/lib and returns the repo-relative path of
// every module that calls BoxErrorEnvelope.fields/1. DERIVED — a new route that
// adopts the reducer appears here without anyone remembering to add it.
func boxErrorEnvelopeCallers(t *testing.T) []string {
	t.Helper()
	root := filepath.Join(repoRoot(t), "cloud", "lib")
	var found []string
	seen := 0
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".ex") {
			return nil
		}
		seen++
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if strings.Contains(string(raw), "BoxErrorEnvelope.fields(") {
			rel, relErr := filepath.Rel(repoRoot(t), path)
			if relErr != nil {
				return relErr
			}
			found = append(found, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("cannot walk the cloud producers under %s: %v", root, err)
	}
	if seen == 0 {
		t.Fatalf("the walk of %s read ZERO .ex files — an empty caller set would make "+
			"every pairing assertion below vacuously true", root)
	}
	sort.Strings(found)
	return found
}

// boxErrorEnvelopeDecoders pairs each CALLER of the reducer with the Go struct
// that decodes that route's body. The pairing is the judgement a parser cannot
// make; the caller SET it is checked against is derived, so a route that adopts
// the reducer without a paired decoder reds here instead of going quiet.
var boxErrorEnvelopeDecoders = map[string]reflect.Type{
	"cloud/lib/barkpark_cloud/sites/build_log.ex":       reflect.TypeOf(SiteBuildLogRecord{}),
	"cloud/lib/barkpark_cloud/sites/build_log_bytes.ex": reflect.TypeOf(SiteBuildLogBytes{}),
}

// THE SIBLING LOCK. Every key the reducer can emit is declared by EVERY Go
// struct that decodes a body it was merged into — not just the two files the
// filing happened to name.
func TestBoxErrorEnvelopeKeysAreDeclaredByEveryDecoder(t *testing.T) {
	keys := boxErrorEnvelopeKeys(t)
	callers := boxErrorEnvelopeCallers(t)

	for _, caller := range callers {
		typ, ok := boxErrorEnvelopeDecoders[caller]
		if !ok {
			t.Errorf("%s calls BoxErrorEnvelope.fields/1 but no Go struct is paired with "+
				"it here. Either its body is decoded by a struct that must declare %v, or "+
				"nothing in this client reads that route — say which, in the pairing map.",
				caller, keys)
			continue
		}
		tags := declaredTags(typ)
		for _, k := range keys {
			if !contains(tags, k) {
				t.Errorf("%s merges BoxErrorEnvelope.fields/1, which emits %q, but %s does "+
					"not declare it. json.Unmarshal drops unmodelled keys silently, so that "+
					"field reads as its zero value forever while looking shipped.",
					caller, k, typ.Name())
			}
		}
	}

	for paired := range boxErrorEnvelopeDecoders {
		if !contains(callers, paired) {
			t.Errorf("the pairing map lists %q, which no longer calls "+
				"BoxErrorEnvelope.fields/1 — a stale pairing pins a decoder to a producer "+
				"that stopped speaking.", paired)
		}
	}
}

// NOT-BLIND CONTROL for both extractors above. The reducer's key set is pinned
// as a SET, and the caller walk is pinned to find AT LEAST the two routes that
// demonstrably call it. Without this, an extractor that silently matched
// nothing would turn the whole section green and say nothing.
func TestBoxErrorEnvelopeExtractorsAreNotBlind(t *testing.T) {
	keys := boxErrorEnvelopeKeys(t)
	want := []string{"box_error", "box_error_message", "box_error_request_id"}
	if !reflect.DeepEqual(keys, want) {
		t.Errorf("BoxErrorEnvelope.wire/3 parsed to %v, want %v. Either the parse went "+
			"blind/wide, or the reducer genuinely changed its wire keys — if the latter, "+
			"pin the new set HERE and teach every decoder in the pairing map to declare it.",
			keys, want)
	}

	callers := boxErrorEnvelopeCallers(t)
	for _, demonstrated := range []string{
		"cloud/lib/barkpark_cloud/sites/build_log.ex",
		"cloud/lib/barkpark_cloud/sites/build_log_bytes.ex",
	} {
		if !contains(callers, demonstrated) {
			t.Errorf("the caller walk did not find %q, which demonstrably calls "+
				"BoxErrorEnvelope.fields/1 — the walk is blind and every pairing verdict "+
				"it produced is untrustworthy", demonstrated)
		}
	}
}
