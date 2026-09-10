package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestStaleClientRenotifiesAfterInterval is the DETECTOR for the "silently
// behind forever" half of pds-bl-bp-search-false-negative: a release we already
// announced, still not installed updateRenotifyInterval later, must be
// announced AGAIN. Before the renotifyDue gate, `cache.Notified == cache.Latest`
// returned unconditionally and this printed nothing, ever.
func TestStaleClientRenotifiesAfterInterval(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.2.0")

	long := time.Now().UTC().Add(-8 * 24 * time.Hour).Format(time.RFC3339)
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt:  time.Now().UTC().Format(time.RFC3339),
		Latest:     "1.9.0",
		Notified:   "1.9.0",
		NotifiedAt: long,
	})

	var stderr strings.Builder
	finishUpdateNotice(&stderr, &pendingUpdateCheck{cache: loadUpdateCache()})
	if !strings.Contains(stderr.String(), "1.9.0 is available") {
		t.Fatalf("a release announced 8 days ago and STILL not installed must re-announce; got %q", stderr.String())
	}
	if got := readNoticeCache(t, root).NotifiedAt; got == long || got == "" {
		t.Fatalf("notified_at must be re-stamped on the re-announcement; got %q", got)
	}
}

// TestStaleClientStaysQuietInsideInterval is the CONTROL for the test above:
// the re-arm must not defeat the once-per-release anti-spam contract. A release
// announced an hour ago prints nothing.
func TestStaleClientStaysQuietInsideInterval(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.2.0")
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt:  time.Now().UTC().Format(time.RFC3339),
		Latest:     "1.9.0",
		Notified:   "1.9.0",
		NotifiedAt: time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
	})

	var stderr strings.Builder
	finishUpdateNotice(&stderr, &pendingUpdateCheck{cache: loadUpdateCache()})
	if stderr.String() != "" {
		t.Fatalf("a release announced an hour ago must stay quiet; got %q", stderr.String())
	}
}

// TestRenotifyDueOnMissingStamp: a cache written before notified_at existed has
// a pinned Notified and no timestamp. Treating that as "not due" would keep
// exactly the operators this row is about permanently silent, so it is DUE.
// A future stamp is NOT due — re-arming on clock skew would print every run.
func TestRenotifyDueEdges(t *testing.T) {
	now := time.Now().UTC()
	if !renotifyDue("", now) {
		t.Fatal("an empty notified_at (pre-field cache) must be due")
	}
	if !renotifyDue("not-a-time", now) {
		t.Fatal("an unparseable notified_at must be due")
	}
	if renotifyDue(now.Add(48*time.Hour).Format(time.RFC3339), now) {
		t.Fatal("a future notified_at must NOT be due")
	}
}

// TestUnknownNounRefusalNamesStaleClient is the DETECTOR for the arm this row
// actually describes: `unknown command "search"` from a client that KNOWS it is
// behind must say so, because that refusal is how six agents concluded the verb
// did not exist. Without staleClientNote wired into suggestUnknownNoun the
// refusal is silent about freshness.
func TestUnknownNounRefusalNamesStaleClient(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.2.0")
	writeNoticeCache(t, root, updateCheckCache{Latest: "1.9.0"})

	tree := &manifest.Tree{Nouns: []*manifest.TreeNoun{{Name: "doc"}}}
	out, stdout, stderr := newHumanTestWriter()
	if code := suggestUnknownNoun(out, tree, "admin", "search", tokenProvenance{}, ""); code != exitUsage {
		t.Fatalf("exit code must stay exitUsage; got %d", code)
	}
	if !strings.Contains(stderr.String(), "you are running bp 1.2.0") {
		t.Fatalf("a refusal from a behind client must name its own staleness; got %q", stderr.String())
	}
	if stdout.String() != "" {
		t.Fatalf("the note must never touch stdout; got %q", stdout.String())
	}
}

// TestUnknownNounRefusalQuietWhenFresh is the CONTROL: an up-to-date client's
// refusal must be byte-identical to what it always was. If this passes only
// because staleClientNote never fires, the detector above would also fail.
func TestUnknownNounRefusalQuietWhenFresh(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.9.0")
	writeNoticeCache(t, root, updateCheckCache{Latest: "1.9.0"})

	tree := &manifest.Tree{Nouns: []*manifest.TreeNoun{{Name: "doc"}}}
	out, _, stderr := newHumanTestWriter()
	suggestUnknownNoun(out, tree, "admin", "search", tokenProvenance{}, "")
	if strings.Contains(stderr.String(), "you are running bp") {
		t.Fatalf("a current client must not print a staleness note; got %q", stderr.String())
	}
}

// TestStaleClientNoteSilentOnDevBuild: a dev build has no release to compare
// against — the same verdict `bp whoami` reports as UNREPORTED — and the
// harness's ensure_bp builds exactly such a binary, so it must stay silent.
func TestStaleClientNoteSilentOnDevBuild(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "dev")
	writeNoticeCache(t, root, updateCheckCache{Latest: "1.9.0"})
	if note := staleClientNote(); note != "" {
		t.Fatalf("dev builds must stay silent; got %q", note)
	}
}

// TestStaleClientNoteKillSwitch: BARKPARK_NO_UPDATE_NOTICE silences the refusal
// arm too, not only the exit-time notice.
func TestStaleClientNoteKillSwitch(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.2.0")
	writeNoticeCache(t, root, updateCheckCache{Latest: "1.9.0"})
	if staleClientNote() == "" {
		t.Fatal("precondition: the note must fire before the kill switch is set")
	}
	t.Setenv("BARKPARK_NO_UPDATE_NOTICE", "1")
	if note := staleClientNote(); note != "" {
		t.Fatalf("the kill switch must silence the refusal arm; got %q", note)
	}
}

// newHumanTestWriter is newTestWriter in HUMAN output. newTestWriter's
// globals{} resolves to output "json", where usageErrHintf renders the machine
// envelope on stdout and never runs its usageHelp closure at all — which is
// precisely the property TestUnknownNounRefusalNamesStaleClient's stdout
// assertion pins, and the reason the note must be tested on this writer.
func newHumanTestWriter() (*writer, *bytes.Buffer, *bytes.Buffer) {
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.applyGlobals(globals{output: "table", outputSet: true})
	return out, &stdout, &stderr
}

// TestUnknownNounRefusalMachineOutputUnchanged pins the byte-identity promise:
// under -o json the refusal stdout carries the envelope and NOTHING else, even
// from a client the cache proves is behind.
func TestUnknownNounRefusalMachineOutputUnchanged(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "1.2.0")
	writeNoticeCache(t, root, updateCheckCache{Latest: "1.9.0"})
	if staleClientNote() == "" {
		t.Fatal("precondition: the client must be provably behind, or this test measures nothing")
	}

	tree := &manifest.Tree{Nouns: []*manifest.TreeNoun{{Name: "doc"}}}
	out, stdout, stderr := newTestWriter() // globals{} => output "json"
	suggestUnknownNoun(out, tree, "admin", "search", tokenProvenance{}, "")
	const want = "{\"error\":{\"code\":\"usage\",\"message\":\"unknown command \\\"search\\\"\"},\"ok\":false}\n"
	if stdout.String() != want {
		t.Fatalf("machine stdout drifted:\n got %q\nwant %q", stdout.String(), want)
	}
	if stderr.String() != "" {
		t.Fatalf("machine stderr must stay empty; got %q", stderr.String())
	}
}
