package scaffy

// receipt_test.go — the D35 uniform fat receipt: location + keying
// (per command + resolved vars), the store-resolved-images envelope,
// and byte-exact image round-trips through JSON.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestReceiptFatEnvelope(t *testing.T) {
	root := seedWidgetTree(t)
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	rep := runFixture(t, root, vars)

	// Location: <root>/.scaffy/receipts/<concept>--<primary-var-kebab>--<key12>.json
	wantDir := filepath.Join(root, ".scaffy", "receipts")
	if filepath.Dir(rep.Receipt) != wantDir {
		t.Fatalf("receipt dir: got %s, want %s", filepath.Dir(rep.Receipt), wantDir)
	}
	base := filepath.Base(rep.Receipt)
	if ok, _ := regexp.MatchString(`^widget--timeline--[0-9a-f]{12}\.json$`, base); !ok {
		t.Fatalf("receipt name %q does not match <concept>--<primary-var-kebab>--<sha12>.json", base)
	}

	r, err := ReadReceipt(rep.Receipt)
	if err != nil {
		t.Fatal(err)
	}
	if r.ReceiptVersion != 1 {
		t.Fatalf("receipt_version: %d", r.ReceiptVersion)
	}
	if r.Command != fixturePath {
		t.Fatalf("command: %q", r.Command)
	}
	src, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	if r.SourceSHA256 != sha256Hex(src) {
		t.Fatal("source_sha256 does not match the command file bytes")
	}
	if r.Direction != "add" {
		t.Fatalf("direction: %q", r.Direction)
	}
	for k, v := range vars {
		if r.Vars[k] != v {
			t.Fatalf("vars[%s]: %q, want %q", k, r.Vars[k], v)
		}
	}
	if _, err := time.Parse(time.RFC3339, r.Timestamp); err != nil {
		t.Fatalf("timestamp %q not RFC3339: %v", r.Timestamp, err)
	}

	// Every mutating op recorded, in apply order: 4 CREATE, 2 INSERT,
	// 2 REPLACE.
	if len(r.Ops) != 8 {
		t.Fatalf("want 8 receipt ops, got %d", len(r.Ops))
	}

	// CREATE: post-image is the written bytes, sha over exactly those.
	create := r.Ops[0]
	if create.Kind != "create" || create.Path != "internal/widgets/timeline.go" {
		t.Fatalf("op 0: %+v", create)
	}
	disk := readTreeFile(t, root, create.Path)
	if string(create.PostImage) != disk {
		t.Fatal("create post-image is not the written bytes")
	}
	if create.PostSHA256 != sha256Hex([]byte(disk)) {
		t.Fatal("create post_sha256 mismatch")
	}
	// The 0-byte empty-fence create still carries a checkable sha (D26).
	gitkeep := r.Ops[1]
	if gitkeep.Path != "internal/widgets/timeline/.gitkeep" || len(gitkeep.PostImage) != 0 || gitkeep.PostSHA256 != sha256Hex(nil) {
		t.Fatalf("gitkeep op: %+v", gitkeep)
	}

	// REPLACE family is fat both ways: pre-image (the consumed anchor)
	// AND post-image (the emitted payload).
	var cron *ReceiptOp
	for i := range r.Ops {
		if r.Ops[i].Kind == "replace" && r.Ops[i].Path == "api/config/config.exs" {
			cron = &r.Ops[i]
		}
	}
	if cron == nil {
		t.Fatal("cron replace op missing from receipt")
	}
	wantPre := "       {\"* * * * *\", Barkpark.Workers.Tail}\n"
	if string(cron.PreImage) != wantPre {
		t.Fatalf("cron pre-image: %q, want %q", cron.PreImage, wantPre)
	}
	if cron.PreSHA256 != sha256Hex([]byte(wantPre)) {
		t.Fatal("cron pre_sha256 mismatch")
	}
	wantPost := "       {\"* * * * *\", Barkpark.Workers.Tail},\n" +
		"       # scaffy:add-widget Timeline MARK:cron-timeline\n" +
		"       {\"0 * * * *\", Barkpark.Workers.Timeline}\n"
	if string(cron.PostImage) != wantPost {
		t.Fatalf("cron post-image: %q, want %q", cron.PostImage, wantPost)
	}
	if cron.Mark != "cron-timeline" {
		t.Fatalf("cron mark: %q", cron.Mark)
	}

	// INSERT records the injected payload as its post-image.
	var reg *ReceiptOp
	for i := range r.Ops {
		if r.Ops[i].Kind == "insert-after-first" {
			reg = &r.Ops[i]
		}
	}
	if reg == nil || !strings.Contains(string(reg.PostImage), "MARK:registry-timeline") {
		t.Fatalf("registry insert receipt op wrong: %+v", reg)
	}
}

// TestReceiptKeyedPerCommandAndVars — D35: two runs of the same
// command with different vars persist DISTINCT receipts that coexist
// (and can therefore retract independently, D36).
func TestReceiptKeyedPerCommandAndVars(t *testing.T) {
	root := seedWidgetTree(t)
	rep1 := runFixture(t, root, widgetVars("Timeline", "20260716100000", "42", "43"))
	rep2 := runFixture(t, root, widgetVars("Beacon", "20260716110000", "43", "44"))

	if rep1.Receipt == rep2.Receipt {
		t.Fatalf("different vars must key different receipts, both %q", rep1.Receipt)
	}
	for _, p := range []string{rep1.Receipt, rep2.Receipt} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("receipt %s missing: %v", p, err)
		}
	}
	entries, err := os.ReadDir(filepath.Join(root, ".scaffy", "receipts"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("want 2 coexisting receipts, got %d", len(entries))
	}
	if !strings.HasPrefix(filepath.Base(rep2.Receipt), "widget--beacon--") {
		t.Fatalf("beacon receipt name: %s", filepath.Base(rep2.Receipt))
	}
}

// TestWriteReceiptTempRenameLeavesPreviousIntact — D35's temp-file-
// plus-rename discipline for writeReceipt: a failed staged write (a
// read-only receipts directory) leaves the PREVIOUS receipt's bytes
// untouched and stages no orphaned temp file, rather than truncating
// it the way a single os.WriteFile(O_TRUNC) would.
func TestWriteReceiptTempRenameLeavesPreviousIntact(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: a read-only directory is still writable, so this arm cannot be exercised")
	}
	root := t.TempDir()
	src, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	cmd, findings := Parse(fixturePath, src)
	if len(findings) > 0 {
		t.Fatalf("parse: %v", findings)
	}
	vars := widgetVars("Timeline", "20260716100000", "42", "43")
	opts := RunOptions{CommandPath: fixturePath, Vars: vars, RepoRoot: root}

	firstOps := []ReceiptOp{{Kind: "create", Path: "internal/widgets/timeline.go", PostImage: []byte("v1"), PostSHA256: sha256Hex([]byte("v1"))}}
	path, err := writeReceipt(opts, cmd, src, firstOps, nil)
	if err != nil {
		t.Fatalf("first writeReceipt: %v", err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	receiptsDir := filepath.Dir(path)
	if err := os.Chmod(receiptsDir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(receiptsDir, 0o755) })

	// Probe: confirm this sandbox actually enforces the permission
	// before trusting a pass born from a lock nobody honors.
	if probe, perr := os.CreateTemp(receiptsDir, "probe-*"); perr == nil {
		probe.Close()
		os.Remove(probe.Name())
		t.Skip("this sandbox does not enforce directory write permissions; the permission arm is unreachable here")
	}

	secondOps := []ReceiptOp{{Kind: "create", Path: "internal/widgets/timeline.go", PostImage: []byte("v2-should-never-land"), PostSHA256: sha256Hex([]byte("v2-should-never-land"))}}
	if _, err := writeReceipt(opts, cmd, src, secondOps, nil); err == nil {
		t.Fatal("want an error writing the receipt into a read-only directory, got nil")
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("previous receipt unreadable after the failed write: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("previous receipt corrupted by a failed write:\nbefore %q\nafter  %q", before, after)
	}

	entries, err := os.ReadDir(receiptsDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), "scaffy-tmp") {
			t.Fatalf("temp receipt file left behind: %s", e.Name())
		}
	}
}

// TestReadReceiptTornGivesActionableMessage — a torn/undecodable
// receipt must not brick `bp scaffy remove` with a bare JSON error: the
// message names the receipt path and points at the command that
// regenerates it.
func TestReadReceiptTornGivesActionableMessage(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".scaffy", "receipts")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "widget--timeline--abc123456789.json")
	if err := os.WriteFile(path, []byte(`{"receipt_version":1,"ops":[`), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := ReadReceipt(path)
	if err == nil {
		t.Fatal("want an error reading a torn receipt, got nil")
	}
	msg := err.Error()
	if !strings.Contains(msg, path) {
		t.Fatalf("error must name the receipt path: %v", err)
	}
	if !strings.Contains(msg, "bp scaffy run") {
		t.Fatalf("error must name the command that regenerates it: %v", err)
	}
	if !strings.Contains(msg, "widget") {
		t.Fatalf("error must hint at the concept from the receipt filename: %v", err)
	}
}

func TestKebabize(t *testing.T) {
	for in, want := range map[string]string{
		"widget":       "widget",
		"Fancy Quote":  "fancy-quote",
		"a/b_c":        "a-b-c",
		"--Trim--":     "trim",
		"UPPER":        "upper",
		"dots.and.dot": "dots-and-dot",
	} {
		if got := kebabize(in); got != want {
			t.Fatalf("kebabize(%q) = %q, want %q", in, got, want)
		}
	}
}
