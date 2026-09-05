package cli

// cloud_instance_top_scalars_test.go is the SCALAR half of `bp cloud instance
// top`'s render contract: the pressure VERDICT and the space breakdown, plus the
// tripwire that binds the envelope's scalar blocks to what this surface renders.
//
// WHY A SECOND TRIPWIRE. TestMetricTopSpecsCoverTheControlPlaneVitals binds
// metricTopSpecs to the control plane's @vitals — the SERIES half. It is green
// today and would have stayed green through the entire gap this file closes,
// because `pressure` and `space` are scalars on the envelope rather than keys in
// the dynamically-keyed series map: nothing dropped them, they were simply never
// wired. That is exactly how `swap` sat on the wire from #9784 until #12988
// finally rendered it, and how Telemetry.normalize_space/1 sat with no
// production caller at all. A block that ships invisible behind a fully green
// build is the failure mode this file exists to end.
//
// The envelope numbers are guerrilla's calibration state (2026-08-06): swap 93%
// of 2 GB, load 2.64 per core on 2 cores, disk unread — the state in which the
// box answered 6,472 HTTP 500s while `bp cloud status` called it ok/healthy.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// metricsTelemetrySourcePath is the control plane's OWN definition of the space
// block — Telemetry.normalize_space/1, which BarkparkCloud.Metrics.space/1 is a
// thin caller of.
var metricsTelemetrySourcePath = filepath.Join("..", "..", "cloud", "lib", "barkpark_cloud", "telemetry.ex")

// elixirMapKeysBetween pulls the TOP-LEVEL keys out of one Elixir map literal by
// their indentation: a map returned from a function body sits at six spaces and
// its nested maps at eight, so the shallower match is exactly the block's own key
// set and never its children's.
func elixirMapKeysBetween(t *testing.T, path, start, end string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	src := string(raw)
	i := strings.Index(src, start)
	if i < 0 {
		t.Fatalf("%s no longer contains %q — the scalar contract moved", filepath.Base(path), start)
	}
	j := strings.Index(src[i+len(start):], end)
	if j < 0 {
		t.Fatalf("%s: %q is unterminated (no %q after it)", filepath.Base(path), start, end)
	}
	body := src[i : i+len(start)+j]
	matches := regexp.MustCompile(`(?m)^      (\w+):`).FindAllStringSubmatch(body, -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out
}

// controlPlaneScalarKeys is the envelope's SCALAR key set, block by block, read
// off the control plane's own code — never off its docstring, which can drift
// from what build/3 actually folds.
func controlPlaneScalarKeys(t *testing.T) map[string][]string {
	t.Helper()
	return map[string][]string{
		"latest": elixirMapKeysBetween(t, metricsVitalsSourcePath,
			"defp latest(%AgentEvent{} = event) do", "\n  end"),
		"pressure": elixirMapKeysBetween(t, metricsVitalsSourcePath,
			"def pressure(latest) when is_map(latest) do", "\n  def pressure(_)"),
		"space": elixirMapKeysBetween(t, metricsTelemetrySourcePath,
			"def normalize_space(payload) when is_map(payload) do", "\n  def normalize_space(_)"),
	}
}

// controlPlaneSignalKeys is @pressure_signals' key list — the signals the verdict
// is made of, each of which the terminal view must name with its reading.
func controlPlaneSignalKeys(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(metricsVitalsSourcePath)
	if err != nil {
		t.Fatalf("read metrics.ex: %v", err)
	}
	src := string(raw)
	i := strings.Index(src, "@pressure_signals [")
	j := strings.Index(src, "@pressure_ladder")
	if i < 0 || j < i {
		t.Fatal("metrics.ex no longer declares @pressure_signals before @pressure_ladder")
	}
	matches := regexp.MustCompile(`key: "(\w+)"`).FindAllStringSubmatch(src[i:j], -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out
}

// metricScalarRenders maps "<block>.<key>" to a substring the terminal view MUST
// print for scalarWitnessEnvelope below. Declaring a key here is not enough: the
// witness is looked for in the REAL rendered output, so a key that is listed and
// not actually rendered fails just as loudly as one that is missing.
var metricScalarRenders = map[string]string{
	"latest.db_size":       "database: 3.3 GB",
	"latest.top_relations": "mutation_events 1.4 GB",
	"latest.swap":          "93% of 2.0 GB",
	"latest.beam":          "1.2 GB",

	"pressure.state":    "pressure: struggling",
	"pressure.measured": "judged on 3 of 4 signals",
	"pressure.of":       "of 4 signals",
	"pressure.signals":  "swap: 93% — struggling",

	"space.root":           "root 24.0 GB of 40.0 GB used",
	"space.journal_bytes":  "journal: 512.0 MB",
	"space.db_size":        "database: 1.5 GB",
	"space.top_relations":  "documents 1.0 GB",
	"space.sites":          "top 2 of 37 sites",
	"space.consumer_roots": "/var/lib/containerd",
	"space.residual":       "unaccounted:",
	"space.reported_at":    "reported 2026-08-06T12:45:00Z",
}

// metricScalarNotRendered is the OTHER half of the ledger: keys that are
// deliberately not printed as their own value, each with the reason. A new key
// belongs in neither map until someone decides, and that is the point — the
// default for an unclassified key is RED, so a block added to the control plane
// cannot ship invisible through this surface.
var metricScalarNotRendered = map[string]string{
	"latest.load15": "an INPUT to the verdict, not a reading of its own: the control plane divides it " +
		"by the core count and publishes the result as the `load` signal (unit per_core). Printing the " +
		"raw average beside a per-core verdict invites the reader to re-derive a judgement the CP already made.",
	"latest.cores": "read as a CAPABILITY inference, not a vital: spaceLines keys 'this agent CAN report " +
		"space' off a readable core count (the space probe and cpu_cores entered the agent in one commit). " +
		"Nobody charts a core count.",
	"latest.mem": "the mem SERIES carries this number into the stat grid, and " +
		"TestMetricTopSpecsCoverTheControlPlaneVitals already binds that. Printing it twice would be two " +
		"places for one reading to disagree with itself.",
	"latest.disk": "same as latest.mem — the disk SERIES renders it, and the series tripwire binds that.",
}

// scalarWitnessEnvelope is guerrilla's calibration state with EVERY scalar block
// populated, so a witness that does not appear is a block this surface does not
// render rather than a fixture that did not carry it.
const scalarWitnessEnvelope = `{"ok":true,"collected_at":"2026-08-06T12:58:00Z",` +
	`"instance":{"id":"11111111-2222-3333-4444-555555555555","host":"guerrilla.barkpark.cloud","provider":"hetzner"},` +
	`"beat":{"last_seen_at":"2026-08-06T12:57:30Z","age_seconds":30,"status":"live"},"points":2,` +
	`"series":{"cpu":[{"at":"t0","value":90},{"at":"t1","value":100}],"mem":[{"at":"t0","value":60},{"at":"t1","value":62}],` +
	`"disk":[{"at":"t0","value":76},{"at":"t1","value":76}],"load":[{"at":"t0","value":4.1},{"at":"t1","value":5.27}],` +
	`"swap":[{"at":"t0","value":88},{"at":"t1","value":93}],"beam_pss":[{"at":"t0","value":1000000000},{"at":"t1","value":1258798080}],` +
	`"beam_swap":[{"at":"t0","value":0},{"at":"t1","value":329543680}]},` +
	`"latest":{"db_size":3525639191,"top_relations":[{"name":"mutation_events","bytes":1534328832},{"name":"revisions","bytes":1332666368}],` +
	`"swap":{"used_pct":93,"total_bytes":2147479552},"beam":{"pss_bytes":1258798080,"swap_bytes":329543680},` +
	`"load15":5.27,"cores":2,"mem":62,"disk":76},` +
	`"pressure":{"state":"struggling","measured":3,"of":4,"signals":[` +
	`{"key":"swap","state":"struggling","value":93,"unit":"pct","watch_at":50,"struggling_at":80},` +
	`{"key":"mem","state":"calm","value":62,"unit":"pct","watch_at":85,"struggling_at":92},` +
	`{"key":"load","state":"struggling","value":2.635,"unit":"per_core","watch_at":1.0,"struggling_at":1.5},` +
	`{"key":"disk","state":"unknown","value":null,"unit":"pct","watch_at":75,"struggling_at":90}]},` +
	`"space":{"root":{"used_bytes":25769803776,"total_bytes":42949672960},"journal_bytes":536870912,` +
	`"db_size":1610612736,"top_relations":[{"name":"documents","bytes":1073741824},{"name":"audit_log","bytes":268435456}],` +
	`"sites":{"dir":"/opt/barkpark/sites","bytes":8589934592,"count":37,` +
	`"top":[{"name":"search-capstone","bytes":5368709120},{"name":"hundesteder","bytes":2147483648}]},` +
	`"consumer_roots":[{"path":"/var/lib/containerd","status":"read","bytes":21474836480,"count":3,` +
	`"top":[{"name":"io.containerd.snapshotter.v1.overlayfs","bytes":19327352832}],"degraded":null,"degraded_count":null,"excluded_reason":null}],` +
	`"residual":{"status":"computed","bytes":4294967296,"of_bytes":25769803776,"measured_bytes":21474836480,` +
	`"counted_roots":1,"excluded_roots":0,"pg_source":"probe","reason":null},` +
	`"reported_at":"2026-08-06T12:45:00Z"},` +
	`"service_health":{"pass":7,"total":7,"failing":[]}}`

// TestCloudInstanceTopScalarsCoverTheControlPlane is the SCALAR silent-drop
// tripwire — the sibling of TestMetricTopSpecsCoverTheControlPlaneVitals.
//
// It fails in three independent ways, and that is deliberate: an unclassified
// key (the control plane grew a scalar nobody wired), a declared witness that
// does not appear in the real render (the wiring was removed or reworded), and a
// stale ledger entry (a key the control plane no longer emits). A tripwire that
// can only fail one way rots into a list nobody maintains.
func TestCloudInstanceTopScalarsCoverTheControlPlane(t *testing.T) {
	blocks := controlPlaneScalarKeys(t)
	total := 0
	for block, keys := range blocks {
		if len(keys) == 0 {
			t.Fatalf("parsed ZERO keys for the %q block — the tripwire would be vacuous", block)
		}
		total += len(keys)
	}

	newMetricsServer(t, 200, scalarWitnessEnvelope)
	stdout, stderr, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}

	seen := map[string]bool{}
	for block, keys := range blocks {
		for _, key := range keys {
			id := block + "." + key
			seen[id] = true
			witness, rendered := metricScalarRenders[id]
			_, excused := metricScalarNotRendered[id]
			switch {
			case rendered && excused:
				t.Errorf("%s is listed BOTH as rendered and as not-rendered — one answer, not two", id)
			case !rendered && !excused:
				t.Errorf("the control plane emits scalar %s and `bp cloud instance top` neither renders it "+
					"nor states why not — it would ship invisible behind a green build", id)
			case rendered && !strings.Contains(stdout, witness):
				t.Errorf("%s claims to render %q and the terminal view does not print it:\n%s", id, witness, stdout)
			case excused && strings.TrimSpace(metricScalarNotRendered[id]) == "":
				t.Errorf("%s is excused with an empty reason — an excuse nobody wrote is not a decision", id)
			}
		}
	}

	for id := range metricScalarRenders {
		if !seen[id] {
			t.Errorf("metricScalarRenders lists %s, which the control plane no longer emits — a stale ledger "+
				"entry silently shrinks what this tripwire covers", id)
		}
	}
	for id := range metricScalarNotRendered {
		if !seen[id] {
			t.Errorf("metricScalarNotRendered lists %s, which the control plane no longer emits", id)
		}
	}

	if got := len(metricScalarRenders) + len(metricScalarNotRendered); got != total {
		t.Errorf("the scalar ledger holds %d entries, the control plane emits %d scalar keys %v",
			got, total, blocks)
	}

	// Every signal the verdict is made of is NAMED with its reading. A verdict
	// that lists only what fired is a verdict whose confidence cannot be judged.
	for _, key := range controlPlaneSignalKeys(t) {
		label := pressureSignalLabel(key)
		if !strings.Contains(stdout, "  "+label+": ") {
			t.Errorf("pressure signal %q (rendered as %q) never reaches the terminal view:\n%s", key, label, stdout)
		}
	}
}

// TestPressureLinesStates walks the verdict's four states through the renderer.
func TestPressureLinesStates(t *testing.T) {
	// NO BLOCK AT ALL is not a verdict. An older control plane has said nothing
	// about this box, and printing "unknown" for it would state as a fact about
	// the BOX something we only hold about the CP.
	if lines := pressureLines(nil); lines != nil {
		t.Fatalf("a control plane that sent no pressure block must render nothing, got %v", lines)
	}

	// STRUGGLING, with the numbers that produced the word.
	struggling := strings.Join(pressureLines(&cloudclient.MetricsPressure{
		State: "struggling", Measured: fp(2), Of: fp(2),
		Signals: []cloudclient.MetricsPressureSignal{
			{Key: "swap", State: "struggling", Value: fp(93), Unit: "pct", WatchAt: fp(50), StrugglingAt: fp(80)},
			{Key: "load", State: "watch", Value: fp(1.235), Unit: "per_core", WatchAt: fp(1), StrugglingAt: fp(1.5)},
		},
	}), "\n")
	for _, want := range []string{
		"pressure: struggling — this box is struggling",
		"  swap: 93% — struggling (watch at 50, struggling at 80)",
		"  load: 1.24 per core — watch (watch at 1, struggling at 1.5)",
	} {
		if !strings.Contains(struggling, want) {
			t.Fatalf("struggling verdict missing %q in:\n%s", want, struggling)
		}
	}
	if strings.Contains(struggling, "judged on") {
		t.Fatalf("a COMPLETE verdict must not carry the partial caveat:\n%s", struggling)
	}

	// PARTIAL — and the caveat rides even on a CALM verdict, because a clean
	// bill drawn from one of four signals is the shape that let a sick box read
	// healthy.
	partial := strings.Join(pressureLines(&cloudclient.MetricsPressure{
		State: "calm", Measured: fp(1), Of: fp(4),
		Signals: []cloudclient.MetricsPressureSignal{
			{Key: "swap", State: "calm", Value: fp(4), Unit: "pct", WatchAt: fp(50), StrugglingAt: fp(80)},
			{Key: "mem", State: "unknown", Unit: "pct"},
			{Key: "load", State: "unknown", Unit: "per_core"},
			{Key: "disk", State: "unknown", Unit: "pct"},
		},
	}), "\n")
	for _, want := range []string{
		"pressure: calm — no resource pressure",
		"  mem" + "ory: not measured — no reading",
		"judged on 1 of 4 signals — no reading for memory, load, disk",
	} {
		if !strings.Contains(partial, want) {
			t.Fatalf("partial verdict missing %q in:\n%s", want, partial)
		}
	}

	// NOTHING MEASURED → "unknown", never calm and never an omission.
	unknown := strings.Join(pressureLines(&cloudclient.MetricsPressure{
		State: "unknown", Measured: fp(0), Of: fp(4),
		Signals: []cloudclient.MetricsPressureSignal{{Key: "swap", State: "unknown", Unit: "pct"}},
	}), "\n")
	if !strings.Contains(unknown, "pressure: unknown — no vitals to judge") {
		t.Fatalf("nothing measured must read unknown:\n%s", unknown)
	}
	if strings.Contains(unknown, "calm") {
		t.Fatalf("an unknown verdict must never say calm:\n%s", unknown)
	}

	// A WORD WE DO NOT KNOW folds onto unknown — never toward reassurance.
	future := strings.Join(pressureLines(&cloudclient.MetricsPressure{State: "sizzling"}), "\n")
	if !strings.Contains(future, "pressure: unknown") || strings.Contains(future, "calm") {
		t.Fatalf("an unrecognised state must fold onto unknown, got:\n%s", future)
	}

	// An UNKNOWN SIGNAL KEY renders as itself rather than vanishing — the same
	// silent-drop rule metricTopSpecs carries for the series half.
	novel := strings.Join(pressureLines(&cloudclient.MetricsPressure{
		State: "watch", Measured: fp(1), Of: fp(1),
		Signals: []cloudclient.MetricsPressureSignal{
			{Key: "iowait", State: "watch", Value: fp(31), Unit: "pct"},
		},
	}), "\n")
	if !strings.Contains(novel, "  iowait: 31% — watch") {
		t.Fatalf("an unknown signal must render as itself:\n%s", novel)
	}
}

// TestCloudInstanceTopRendersTheStrugglingVerdict drives the WHOLE command: a box
// the control plane calls "struggling" says so at a terminal, not only under
// `-o json` — which is the entire complaint this row was filed on.
func TestCloudInstanceTopRendersTheStrugglingVerdict(t *testing.T) {
	newMetricsServer(t, 200, scalarWitnessEnvelope)
	stdout, stderr, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	for _, want := range []string{
		"pressure: struggling",
		"swap: 93% — struggling",
		"load: 2.64 per core — struggling",
		"disk: not measured — no reading",
		"judged on 3 of 4 signals — no reading for disk",
		"top 2 of 37 sites",
		"documents 1.0 GB",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("terminal view missing %q:\n%s", want, stdout)
		}
	}
}

// TestCloudInstanceTopWithoutPressureIsUnchanged: an OLDER control plane sends no
// `pressure` and no `space`, and its output must not gain a verdict nobody
// computed. Absence of a block is a fact about the control plane, never about
// the box.
func TestCloudInstanceTopWithoutPressureIsUnchanged(t *testing.T) {
	const envelope = `{"ok":true,"collected_at":"2026-08-06T12:58:00Z",` +
		`"instance":{"id":"11111111-2222-3333-4444-555555555555","host":"guerrilla.barkpark.cloud","provider":"hetzner"},` +
		`"beat":{"last_seen_at":"2026-08-06T12:57:30Z","age_seconds":30,"status":"live"},"points":1,` +
		`"series":{"cpu":[{"at":"t0","value":12}]},` +
		`"latest":{"db_size":null,"top_relations":null,"swap":{"used_pct":null,"total_bytes":null},"beam":{"pss_bytes":null,"swap_bytes":null}},` +
		`"service_health":{"pass":3,"total":3,"failing":[]}}`

	newMetricsServer(t, 200, envelope)
	stdout, _, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d", code)
	}
	if strings.Contains(stdout, "pressure:") {
		t.Fatalf("a control plane that sent no verdict must draw no verdict line:\n%s", stdout)
	}
	if strings.Contains(stdout, "sites") && !strings.Contains(stdout, "host space:") {
		t.Fatalf("no space report must not grow a sites breakdown:\n%s", stdout)
	}
}

// TestSpaceSitesCapSaysWhenItBinds is the cap, in the console's exact semantics:
// "top N of M" when the count exceeds the rendered list, "all M" when it does
// not, and NEITHER claim when the count is absent — because "all N" is the
// strongest statement this line can make and it must not be reachable from an
// unknown.
func TestSpaceSitesCapSaysWhenItBinds(t *testing.T) {
	line := func(sites cloudclient.MetricsSpaceSites) string {
		lines, _ := spaceLines(cloudclient.MetricsResult{Space: &cloudclient.MetricsSpace{Sites: sites}})
		return strings.Join(lines, "\n")
	}
	two := []cloudclient.RelationSize{{Name: "search-capstone", Bytes: 1024}, {Name: "hundesteder", Bytes: 512}}

	// The cap BINDS: two rows out of thirty-seven slugs.
	if got := line(cloudclient.MetricsSpaceSites{Bytes: fp(2048), Count: fp(37), Top: two}); !strings.Contains(got, "top 2 of 37 sites") {
		t.Fatalf("a binding cap must say so, got %q", got)
	}

	// The cap does NOT bind: the list IS the tree.
	if got := line(cloudclient.MetricsSpaceSites{Bytes: fp(2048), Count: fp(2), Top: two}); !strings.Contains(got, "all 2 sites") {
		t.Fatalf("a non-binding cap must say the list is complete, got %q", got)
	}

	// NO COUNT — neither claim. An un-bound list read as complete is the trap.
	noCount := line(cloudclient.MetricsSpaceSites{Bytes: fp(2048), Top: two})
	for _, forbidden := range []string{"all ", "top 2 of"} {
		if strings.Contains(noCount, forbidden) {
			t.Fatalf("an absent count must claim neither cap state, got %q (contains %q)", noCount, forbidden)
		}
	}
	if !strings.Contains(noCount, "site count not reported") {
		t.Fatalf("an absent count must still say it is absent, got %q", noCount)
	}

	// A FAILED WALK (-1) is not a cap state either — it is a failed measurement.
	failed := line(cloudclient.MetricsSpaceSites{Bytes: fp(2048), Count: fp(-1), Top: two})
	if strings.Contains(failed, "all ") || strings.Contains(failed, "of -1") {
		t.Fatalf("a -1 count must claim no cap state, got %q", failed)
	}

	// A count with NO rendered list: the number is real, but there is no list
	// for it to be "all" or "top N" OF.
	bare := line(cloudclient.MetricsSpaceSites{Bytes: fp(2048), Count: fp(9)})
	if !strings.Contains(bare, "9 sites") || strings.Contains(bare, "all 9") {
		t.Fatalf("a count with no list must state the count and claim no cap, got %q", bare)
	}
}

// TestSpaceDatabaseNamesItsRelations: postgres inside the space report is a
// NAMED consumer, keeping storageLines' nil/empty split one level up.
func TestSpaceDatabaseNamesItsRelations(t *testing.T) {
	joined := func(sp *cloudclient.MetricsSpace) string {
		lines, _ := spaceLines(cloudclient.MetricsResult{Space: sp})
		return strings.Join(lines, "\n")
	}

	named := joined(&cloudclient.MetricsSpace{
		DBSize: fp(1610612736),
		TopRelations: []cloudclient.RelationSize{
			{Name: "documents", Bytes: 1073741824},
			{Name: "audit_log", Bytes: 268435456},
		},
	})
	for _, want := range []string{"database: 1.5 GB", "top 2 = 83.3% of it", "documents 1.0 GB", "audit_log 256.0 MB"} {
		if !strings.Contains(named, want) {
			t.Fatalf("space database missing %q in:\n%s", want, named)
		}
	}

	// UNMEASURED: the size prints, the missing breakdown says so.
	if got := joined(&cloudclient.MetricsSpace{DBSize: fp(1024)}); !strings.Contains(got, "biggest relations not reported") {
		t.Fatalf("an unmeasured breakdown must say so, got:\n%s", got)
	}

	// MEASURED AND EMPTY is a different fact from unmeasured.
	if got := joined(&cloudclient.MetricsSpace{DBSize: fp(1024), TopRelations: []cloudclient.RelationSize{}}); !strings.Contains(got, "no relations reported") {
		t.Fatalf("a measured-empty breakdown must say so, got:\n%s", got)
	}

	// NOTHING measured → no database line at all, never a zeroed one.
	if got := joined(&cloudclient.MetricsSpace{}); strings.Contains(got, "database:") {
		t.Fatalf("an unmeasured database must draw no line, got:\n%s", got)
	}
}
