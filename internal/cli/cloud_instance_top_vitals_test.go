package cli

// cloud_instance_top_vitals_test.go covers the vitals the fold ADDED to
// `bp cloud instance top`: swap (in three honest states), the BEAM's own
// footprint, and the named database breakdown that answers "what is taking up
// space". It also carries the SILENT-DROP tripwire binding metricTopSpecs to the
// control plane's own @vitals list — the failure mode this surface is uniquely
// exposed to, because MetricsResult.Series is a dynamically-keyed map and a key
// the renderer omits vanishes with zero red.
//
// The envelope numbers are guerrilla's REAL captured readings (2026-08-06):
// swap 55% of 2 GB, BEAM 1.26 GB resident with 330 MB paged out, a 3.52 GB
// database whose two biggest relations are 81.3% of it.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// metricsVitalsSourcePath is the control plane's OWN definition of the series key
// set — Metrics's @vitals list, which `series/1` is a Map.new over.
var metricsVitalsSourcePath = filepath.Join("..", "..", "cloud", "lib", "barkpark_cloud", "metrics.ex")

// controlPlaneVitalKeys parses the series keys out of Metrics's @vitals literal.
func controlPlaneVitalKeys(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(metricsVitalsSourcePath)
	if err != nil {
		t.Fatalf("read metrics.ex: %v", err)
	}
	src := string(raw)
	start := strings.Index(src, "@vitals [")
	if start < 0 {
		t.Fatalf("metrics.ex no longer declares @vitals — the render contract moved")
	}
	end := strings.Index(src[start:], "\n  ]")
	if end < 0 {
		t.Fatalf("metrics.ex @vitals literal is unterminated")
	}
	matches := regexp.MustCompile(`\{:(\w+),`).FindAllStringSubmatch(src[start:start+end], -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out
}

func metricTopSpecKeys() []string {
	out := make([]string, 0, len(metricTopSpecs))
	for _, s := range metricTopSpecs {
		out = append(out, s.key)
	}
	return out
}

// TestMetricTopSpecsCoverTheControlPlaneVitals is the SILENT-DROP tripwire.
// cloudclient.MetricsResult.Series is a dynamically-keyed map, so a series the
// control plane emits and metricTopSpecs omits is dropped with ZERO red — an
// invisible number behind a fully green build. Binding the two lists makes
// widening @vitals without widening the renderer fail HERE instead of shipping
// silence.
func TestMetricTopSpecsCoverTheControlPlaneVitals(t *testing.T) {
	want := controlPlaneVitalKeys(t)
	if len(want) == 0 {
		t.Fatal("parsed zero vitals from metrics.ex — the tripwire would be vacuous")
	}
	rendered := map[string]bool{}
	for _, spec := range metricTopSpecs {
		rendered[spec.key] = true
	}
	for _, key := range want {
		if !rendered[key] {
			t.Errorf("control plane emits series %q but metricTopSpecs never renders it — it would be dropped silently", key)
		}
	}
	if len(metricTopSpecs) != len(want) {
		t.Errorf("metricTopSpecs has %d entries %v, metrics.ex @vitals has %d %v",
			len(metricTopSpecs), metricTopSpecKeys(), len(want), want)
	}
}

// TestSwapStatValueThreeStates: swap's headline carries three honest states and
// mints NO new reason word — the disambiguation rides entirely in the data the
// agent already sends (the percent travels with its total precisely for this).
func TestSwapStatValueThreeStates(t *testing.T) {
	// (1) MEASURED, and there is none. Never "0%" — five of six boxes are here.
	none := swapStatValue("swap", cloudclient.MetricsSwap{UsedPct: fp(0), TotalBytes: fp(0)})
	if none != "none configured" {
		t.Fatalf("swapless box = %q want %q", none, "none configured")
	}
	if strings.Contains(none, "%") {
		t.Fatalf("the swapless state must never render a percent, got %q", none)
	}

	// (2) MEASURED, and there is swap: the percent is only interpretable against
	// the size it is a percent OF. (Guerrilla's real reading.)
	real := swapStatValue("swap", cloudclient.MetricsSwap{UsedPct: fp(55), TotalBytes: fp(2147479552)})
	if real != "55% of 2.0 GB" {
		t.Fatalf("configured swap = %q want %q", real, "55% of 2.0 GB")
	}

	// (3) NOT measured (the -1 sentinel the CP already nils, or a pre-upgrade
	// agent that sends neither key) → "" so the caller falls through to the
	// EXISTING unmeasured arm. No third vocabulary is minted.
	for name, s := range map[string]cloudclient.MetricsSwap{
		"both absent":        {},
		"pct only":           {UsedPct: fp(55)},
		"total only":         {TotalBytes: fp(2147479552)},
		"zero pct, no total": {UsedPct: fp(0)},
	} {
		if got := swapStatValue("swap", s); got != "" {
			t.Fatalf("%s: want fall-through to the unmeasured arm, got %q", name, got)
		}
	}

	// Non-swap series never take the override.
	if got := swapStatValue("cpu", cloudclient.MetricsSwap{UsedPct: fp(0), TotalBytes: fp(0)}); got != "" {
		t.Fatalf("cpu must not take the swap headline, got %q", got)
	}
}

// swapStatItem pulls the swap cell out of the rendered stat grid.
func swapStatItem(t *testing.T, res cloudclient.MetricsResult) map[string]any {
	t.Helper()
	blocks := metricsBlocks(res)
	if len(blocks) == 0 {
		t.Fatal("no blocks rendered")
	}
	items, _ := blocks[0].Attrs["items"].([]any)
	for i, spec := range metricTopSpecs {
		if spec.key == "swap" {
			return items[i].(map[string]any)
		}
	}
	t.Fatal("metricTopSpecs carries no swap entry")
	return nil
}

// TestMetricsBlocksSwapStates: the three states as the operator SEES them in the
// stat grid — and a swapless box draws no swap sparkline (a flat run of honest
// 0s would imply a meter that does not exist).
func TestMetricsBlocksSwapStates(t *testing.T) {
	var swapless cloudclient.MetricsResult
	swapless.Series = map[string][]cloudclient.MetricPoint{
		"cpu":  {{Value: fp(12)}},
		"swap": {{Value: fp(0)}, {Value: fp(0)}},
	}
	swapless.Latest.Swap = cloudclient.MetricsSwap{UsedPct: fp(0), TotalBytes: fp(0)}
	item := swapStatItem(t, swapless)
	if item["value"] != "none configured" {
		t.Fatalf("swapless stat=%v want 'none configured'", item["value"])
	}
	if _, hasSpark := item["spark"]; hasSpark {
		t.Fatal("a swapless box must not draw a swap sparkline — there is nothing to trend")
	}

	var swapping cloudclient.MetricsResult
	swapping.Series = map[string][]cloudclient.MetricPoint{"swap": {{Value: fp(40)}, {Value: fp(55)}}}
	swapping.Latest.Swap = cloudclient.MetricsSwap{UsedPct: fp(55), TotalBytes: fp(2147479552)}
	item = swapStatItem(t, swapping)
	if item["value"] != "55% of 2.0 GB" {
		t.Fatalf("swapping stat=%v want '55%% of 2.0 GB'", item["value"])
	}
	if spark, _ := item["spark"].([]any); len(spark) != 2 {
		t.Fatalf("a swapping box must trend its swap, spark=%v", item["spark"])
	}

	var blind cloudclient.MetricsResult
	blind.Series = map[string][]cloudclient.MetricPoint{"cpu": {{Value: fp(3)}}, "swap": {{Value: nil}}}
	item = swapStatItem(t, blind)
	if item["value"] != "—" {
		t.Fatalf("unmeasured swap stat=%v want the existing em dash", item["value"])
	}
}

// TestMetricsBlocksBeamFootprint: the BEAM's own bytes render as human sizes and
// stay OUT of the shared line chart (one axis carrying a 0-100 percent and a
// 1.2e9 byte count flattens every percent line to the floor).
func TestMetricsBlocksBeamFootprint(t *testing.T) {
	var res cloudclient.MetricsResult
	res.Series = map[string][]cloudclient.MetricPoint{
		"cpu":       {{Value: fp(12)}},
		"beam_pss":  {{Value: fp(1000000000)}, {Value: fp(1258798080)}},
		"beam_swap": {{Value: fp(329543680)}},
	}
	blocks := metricsBlocks(res)
	items, _ := blocks[0].Attrs["items"].([]any)
	byLabel := map[string]map[string]any{}
	for i, spec := range metricTopSpecs {
		byLabel[spec.label] = items[i].(map[string]any)
	}
	if got := byLabel["BEAM"]["value"]; got != "1.2 GB" {
		t.Fatalf("BEAM stat=%v want 1.2 GB", got)
	}
	if got := byLabel["BEAM swapped"]["value"]; got != "314.3 MB" {
		t.Fatalf("BEAM swapped stat=%v want 314.3 MB", got)
	}
	series, _ := blocks[1].Attrs["series"].([]any)
	for _, s := range series {
		if label := s.(map[string]any)["label"]; label == "BEAM" || label == "BEAM swapped" {
			t.Fatalf("byte-scale %v must stay out of the shared percent chart", label)
		}
	}
}

// TestStorageLinesNamesTheConsumers: "what is taking up space", answered with
// NAMED consumers, in three honest states.
func TestStorageLinesNamesTheConsumers(t *testing.T) {
	// Guerrilla's real numbers: two relations are 81.3% of a 3.52 GB database.
	l := cloudclient.MetricsLatest{
		DBSize: fp(3525639191),
		TopRelations: []cloudclient.RelationSize{
			{Name: "mutation_events", Bytes: 1534328832},
			{Name: "revisions", Bytes: 1332666368},
		},
	}
	head, blocks := storageLines(l)
	for _, want := range []string{"database: 3.3 GB", "top 2 = 81.3% of it"} {
		if !strings.Contains(head, want) {
			t.Fatalf("storage head %q missing %q", head, want)
		}
	}
	if len(blocks) != 1 || blocks[0].Type != "bar-chart" {
		t.Fatalf("want one bar-chart block, got %+v", blocks)
	}
	bars, _ := blocks[0].Attrs["bars"].([]any)
	if len(bars) != 2 {
		t.Fatalf("bars=%d want 2", len(bars))
	}
	if label := bars[0].(map[string]any)["label"]; label != "mutation_events 1.4 GB" {
		t.Fatalf("bar label=%v want the named consumer with its size", label)
	}
	if max := blocks[0].Attrs["max"]; max != 3525639191.0 {
		t.Fatalf("bar max=%v want the database total (bar length IS the share)", max)
	}

	// Unmeasured breakdown: the size still prints, and says the list is missing.
	head, blocks = storageLines(cloudclient.MetricsLatest{DBSize: fp(1024)})
	if !strings.Contains(head, "top relations not reported") || len(blocks) != 0 {
		t.Fatalf("unmeasured breakdown = %q / %d blocks", head, len(blocks))
	}

	// Measured-and-EMPTY is a different fact from unmeasured.
	head, _ = storageLines(cloudclient.MetricsLatest{
		DBSize:       fp(1024),
		TopRelations: []cloudclient.RelationSize{},
	})
	if !strings.Contains(head, "no relations reported") {
		t.Fatalf("measured-empty = %q", head)
	}

	// Nothing measured at all → no section, never a zeroed one.
	if head, blocks := storageLines(cloudclient.MetricsLatest{}); head != "" || blocks != nil {
		t.Fatalf("all-absent storage must render nothing, got %q / %+v", head, blocks)
	}
}

// TestCloudInstanceTopRendersTheNewVitals drives the WHOLE command against a fake
// control plane serving guerrilla's captured shape, and proves the operator
// actually SEES swap, the BEAM and the named space hogs.
func TestCloudInstanceTopRendersTheNewVitals(t *testing.T) {
	const envelope = `{"ok":true,"collected_at":"2026-08-06T12:58:00Z","instance":{"id":"11111111-2222-3333-4444-555555555555","host":"guerrilla.barkpark.cloud","provider":"hetzner"},"beat":{"last_seen_at":"2026-08-06T12:57:30Z","age_seconds":30,"status":"live"},"points":2,` +
		`"series":{"cpu":[{"at":"t0","value":90},{"at":"t1","value":100}],"mem":[{"at":"t0","value":60},{"at":"t1","value":64}],"disk":[{"at":"t0","value":76},{"at":"t1","value":76}],"load":[{"at":"t0","value":4.1},{"at":"t1","value":5.27}],` +
		`"swap":[{"at":"t0","value":40},{"at":"t1","value":55}],"beam_pss":[{"at":"t0","value":1000000000},{"at":"t1","value":1258798080}],"beam_swap":[{"at":"t0","value":0},{"at":"t1","value":329543680}]},` +
		`"latest":{"db_size":3525639191,"top_relations":[{"name":"mutation_events","bytes":1534328832},{"name":"revisions","bytes":1332666368}],"swap":{"used_pct":55,"total_bytes":2147479552},"beam":{"pss_bytes":1258798080,"swap_bytes":329543680}},` +
		`"service_health":{"pass":7,"total":7,"failing":[]}}`

	newMetricsServer(t, 200, envelope)
	stdout, stderr, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	for _, want := range []string{
		"Swap", "55% of 2.0 GB", // the vital Memory hides
		"BEAM", "1.2 GB", // the process the kernel OOM-kills
		"database: 3.3 GB", "top 2 = 81.3% of it",
		"mutation_events 1.4 GB", "revisions 1.2 GB",
		"service health: 7/7 passing",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("top output missing %q:\n%s", want, stdout)
		}
	}
}

// TestCloudInstanceTopSwaplessBox: the MAJORITY case reads "none configured" —
// neutral, and never a percent.
func TestCloudInstanceTopSwaplessBox(t *testing.T) {
	const envelope = `{"ok":true,"collected_at":"2026-08-06T12:58:00Z","instance":{"id":"11111111-2222-3333-4444-555555555555","host":"jarl.barkpark.cloud","provider":"hetzner"},"beat":{"last_seen_at":"2026-08-06T12:57:30Z","age_seconds":5,"status":"live"},"points":1,` +
		`"series":{"cpu":[{"at":"t0","value":12}],"swap":[{"at":"t0","value":0}]},` +
		`"latest":{"db_size":null,"top_relations":null,"swap":{"used_pct":0,"total_bytes":0},"beam":{"pss_bytes":null,"swap_bytes":null}},` +
		`"service_health":{"pass":0,"total":0,"failing":[]}}`

	newMetricsServer(t, 200, envelope)
	stdout, _, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d", code)
	}
	if !strings.Contains(stdout, "none configured") {
		t.Fatalf("a swapless box must say 'none configured':\n%s", stdout)
	}
	if strings.Contains(stdout, "0% of") {
		t.Fatalf("a swapless box must never render a swap percent:\n%s", stdout)
	}
	// db_size + top_relations were not reported → no storage section at all,
	// never a zeroed one.
	if strings.Contains(stdout, "database:") {
		t.Fatalf("an unmeasured database must draw no storage line:\n%s", stdout)
	}
}
