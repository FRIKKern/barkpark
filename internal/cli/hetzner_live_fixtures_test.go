package cli

// hetzner_live_fixtures_test.go — THE PERMANENT RESIDUE OF THE EPIC'S LIVE READS.
//
// scripts/pds-live-hetzner-placement-group.sh drove a real bp verb against the
// real api.hetzner.cloud on 2026-07-31 (--run) and then, on 2026-08-01, made one
// READ-ONLY GET per remaining flat hcloud kind at an id that cannot exist
// (--harvest-only). Those runs needed a live credential and, for --run, a live
// project; this test needs neither. It is how the perishable half of a live proof
// leaves something that rides CI forever.
//
// WHAT THESE ASSERTIONS ARE FOR — PDS-D401. hzResDestroyed's clean "(nil, nil) =
// gone" arm rests on a production assumption stated in hetzner_respost.go's own
// header: that the API answers a missing resource with a JSON 404. hcloud-go's
// errorFromBody returns nil unless hasJSONBody(), so a text/plain 404 would land
// in the "confirmation unavailable" arm instead — the destroy would report "not
// confirmed" on a perfectly successful delete. For twenty-nine waves that was an
// ASSUMPTION across the whole family. It is now measured for every flat kind.
//
// WHY THERE IS NO UNIVERSAL BYTE-COUNT ASSERTION, AND WHY THERE IS NO PAIRWISE
// ONE EITHER. The message is per resource kind, so a single len() constant would
// be a fixture-shaped lie. But the honest harvest ALSO refutes the opposite
// over-reach: `firewall` and `primary-ip` both answer in exactly 138 bytes.
// Pairwise-distinct byte counts across kinds is therefore not a property of the
// API — it was an artefact of a two-kind population. See
// TestPDSLive404MessagesAndLengthsAreNotSingleValued for what replaced it and
// why, and PDS-D442 for the ruling.
//
// WHAT THESE ARMS CANNOT DO, STATED BECAUSE THE ALTERNATIVE IS OVER-READING
// THEM. They do not prove the refusal direction (a lying API that keeps
// returning a deleted resource) — that stays covered by the LYING-FAKE cases in
// hetzner_respost_test.go, and cannot be staged against a correct API at all.
// They prove that the bytes the apparatus reasons about are the bytes production
// actually sends, for one provider and one resource family.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

type pdsLiveFixture struct {
	File        string `json:"file"`
	Kind        string `json:"kind"`
	Segment     string `json:"segment"`
	Request     string `json:"request"`
	HTTPStatus  int    `json:"http_status"`
	ContentType string `json:"content_type"`
	Bytes       int    `json:"bytes"`
	// Record is the VERBATIM TAB-delimited `curl -w` record the harvest
	// captured: "<http_code>\t<content_type>\t<size_download>". The three
	// fields above are derived from it rather than typed, which is what makes
	// them non-accidental. It is empty on the wave-30 rows, which predate the
	// machine record and say so in Provenance.
	Record               string `json:"record"`
	Provenance           string `json:"provenance"`
	Sha256Chunked        string `json:"sha256_chunked"`
	ErrorCode            string `json:"error_code"`
	Note                 string `json:"note"`
	MessageTokenOverride string `json:"message_token_override"`
	MessageTokenReason   string `json:"message_token_reason"`
}

type pdsLiveRefusal struct {
	Kind      string `json:"kind"`
	RefusedBy string `json:"refused_by"`
	Ground    string `json:"ground"`
}

type pdsLiveManifest struct {
	EmittedBy    string `json:"emitted_by"`
	HarvestedAt  string `json:"harvested_at"`
	HarvestedBy  string `json:"harvested_by"`
	API          string `json:"api"`
	KindCoverage struct {
		FlatKinds []string `json:"flat_kinds"`
		Harvested []string `json:"harvested"`
		Pending   []string `json:"pending"`
	} `json:"kind_coverage"`
	Refusals []pdsLiveRefusal `json:"refusals"`
	Chain    string           `json:"chain"`
	Fixtures []pdsLiveFixture `json:"fixtures"`
}

func loadPDSLiveManifest(t *testing.T) pdsLiveManifest {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "pds_live_hetzner_fixtures.json"))
	if err != nil {
		t.Fatalf("read the live-proof manifest: %v", err)
	}
	var m pdsLiveManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse the live-proof manifest: %v", err)
	}
	if len(m.Fixtures) == 0 {
		t.Fatal("the live-proof manifest lists no fixtures — an empty manifest would make every assertion below vacuously true")
	}
	if m.HarvestedBy == "" || m.HarvestedAt == "" {
		t.Fatal("the manifest does not say when it was harvested or by what — an undated body is not evidence")
	}
	return m
}

// TestPDSLiveFixturesRecordTheirOwnKindAndLength pins each harvested body to the
// kind and byte count the live run measured, ONE ENTRY AT A TIME. A fixture
// edited by hand (or re-harvested from a different kind) fails here rather than
// silently changing what the other tests are reasoning about.
//
// IT IS ALSO WHAT MAKES THE OTHER ARMS MEAN ANYTHING. Every test below reads
// MANIFEST integers, not file bytes; they are only about production because this
// arm pins manifest bytes to disk bytes.
func TestPDSLiveFixturesRecordTheirOwnKindAndLength(t *testing.T) {
	m := loadPDSLiveManifest(t)
	seen := map[string]bool{}
	for _, f := range m.Fixtures {
		if f.File == "" || f.Kind == "" {
			t.Errorf("manifest entry %+v does not name both a file and the KIND it came from", f)
			continue
		}
		if seen[f.File] {
			t.Errorf("%s is listed twice in the manifest", f.File)
		}
		seen[f.File] = true

		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Errorf("%s: %v", f.File, err)
			continue
		}
		if got := len(body); got != f.Bytes {
			t.Errorf("%s (%s): manifest records %d bytes, the file on disk is %d — the manifest and the harvested body have drifted apart",
				f.File, f.Kind, f.Bytes, got)
		}
		// PREFIX, not equality: content_type is a parameterised header value and
		// the manifest now carries whatever curl actually reported. Demanding
		// exact equality is the same positional assumption that made the wave-30
		// harvest narrate "the SERVER 404 (charset=utf-8 bytes)".
		if !strings.HasPrefix(f.ContentType, "application/json") {
			t.Errorf("%s: content_type %q — every harvested body is a JSON body", f.File, f.ContentType)
		}
		var anyDoc map[string]any
		if err := json.Unmarshal(body, &anyDoc); err != nil {
			t.Errorf("%s: not JSON at all: %v", f.File, err)
		}
	}
}

// TestPDSLive404sAreJSONNotFound is PDS-D401's measurement: production answers a
// missing resource with a JSON body carrying error.code = not_found, which is
// exactly the condition under which hcloud-go returns the clean (nil, nil) that
// hzResDestroyed reads as "gone".
func TestPDSLive404sAreJSONNotFound(t *testing.T) {
	m := loadPDSLiveManifest(t)
	n := 0
	for _, f := range m.Fixtures {
		if f.HTTPStatus != 404 {
			continue
		}
		n++
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		env := pdsErrorEnvelope(body)
		if env.Error.Code != "not_found" {
			t.Errorf("%s (%s): error.code = %q, want not_found — hzResDestroyed's gone arm reasons about this exact shape",
				f.File, f.Kind, env.Error.Code)
		}
		if env.Error.Message == "" {
			t.Errorf("%s: the 404 carries no message", f.File)
		}
		if f.ErrorCode != env.Error.Code {
			t.Errorf("%s: the manifest records error_code=%q but the body says %q", f.File, f.ErrorCode, env.Error.Code)
		}
	}
	if n < 2 {
		t.Fatalf("only %d harvested 404 bodies — the point of harvesting more than one KIND is that one kind cannot establish the shape is uniform", n)
	}
}

// pdsErrorEnvelope is the shape hcloud-go's errorFromBody reads. A body that is
// not JSON at all yields the zero value, which every caller treats as "no
// error.code" — that is the honest reading, not a swallowed parse failure.
func pdsErrorEnvelope(body []byte) struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
} {
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &env)
	return env
}

// ─── THE COHERENCE ARM ───────────────────────────────────────────────────────
//
// pdsCoherenceProblems reads the DECLARED status and the BODY together. This is
// the only arm that reaches the historical mutation, and PDS-D440 measured
// exactly why: a real api.hetzner.cloud 401 envelope committed as
// http_status:200, WITH a fully-verifying machine marker (run id, verbatim curl
// records, per-body sha256, a folded chain — every digest checking out), passes
// both marker arms and all four of the arms this file shipped before wave 32. No
// digest can ever reach it, because http_status and content_type are TRANSPORT
// facts that are simply absent from the committed bytes: an honestly computed
// digest over a mislabelled row still verifies.
//
// THE REVERSE DIRECTION FIRING IS A FINDING, NOT A BUG. If some future kind
// genuinely answers >= 400 with a body carrying no error.code, this arm reds —
// and that red is the discovery that PDS-D401's assumption has a hole, not a
// broken test. Do not "fix" it by deleting the check; record the kind and decide
// what the destroy apparatus should do about it.
func pdsCoherenceProblems(status int, body []byte) []string {
	var problems []string
	code := pdsErrorEnvelope(body).Error.Code
	switch {
	case status >= 200 && status < 300 && code != "":
		problems = append(problems, fmt.Sprintf(
			"declared HTTP %d (a SUCCESS) over a body carrying error.code=%q — a successful response does not carry an error envelope; the status is a claim the bytes contradict",
			status, code))
	case status >= 400 && code == "":
		problems = append(problems, fmt.Sprintf(
			"declared HTTP %d (a FAILURE) over a body carrying no error.code — hcloud-go's errorFromBody would return nil here, so the gone arm cannot bind on it",
			status))
	}
	return problems
}

func TestPDSLiveManifestStatusAndBodyCohere(t *testing.T) {
	m := loadPDSLiveManifest(t)
	for _, f := range m.Fixtures {
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		for _, p := range pdsCoherenceProblems(f.HTTPStatus, body) {
			t.Errorf("%s (%s): %s", f.File, f.Kind, p)
		}
	}

	// THE HISTORICAL MUTATION, staged rather than described. This is the shape
	// PDS-D439 measured live: an UNAUTHENTICATED GET returns a JSON envelope
	// carrying error.code, and it is what a credential-less harvest would have
	// banked as a 404 fixture. Committed as http_status:200, every other arm in
	// this file passes it.
	unauthorised := []byte(`{"error":{"code":"unauthorized","message":"unable to authenticate"}}`)
	if got := pdsCoherenceProblems(200, unauthorised); len(got) == 0 {
		t.Error("a 401 envelope declared http_status:200 raised NO coherence problem — the arm that is supposed to catch the historical mutation does not catch it")
	}
	// And the reverse direction, which is a FINDING when it fires on real data.
	if got := pdsCoherenceProblems(404, []byte(`{"ok":true}`)); len(got) == 0 {
		t.Error("a 404 over a body with no error.code raised no problem — the reverse direction is not wired")
	}
	// The control: honest rows must NOT raise. Without it both checks above
	// would pass on a predicate that simply complained about everything.
	if got := pdsCoherenceProblems(404, []byte(`{"error":{"code":"not_found","message":"volume not found"}}`)); len(got) != 0 {
		t.Errorf("an honest 404 raised a coherence problem: %v", got)
	}
	if got := pdsCoherenceProblems(200, []byte(`{"placement_group":{"id":1}}`)); len(got) != 0 {
		t.Errorf("an honest 200 raised a coherence problem: %v", got)
	}
}

// ─── THE WRONG-PATH ARM ──────────────────────────────────────────────────────
//
// PDS-D440: a well-formed 404 harvested from the WRONG collection passes status,
// content-type and error.code all three — measured, with the pre-wave-32 suite
// 4/4 green on a planted wrong-path fixture. The harvester writes the code it
// read, so nothing about the body betrays which path produced it. The only thing
// that can is the message, checked against the path the manifest itself claims.
//
// ITS LIMIT, STATED HERE SO NOBODY OVER-READS IT: this is containment on the
// COLLECTION token only. A right-collection/wrong-id harvest is invisible to it,
// and so is any kind whose message does not name its own collection — `network`
// answers "entity not found" and needs an override, which weakens this arm for
// that one row and says so in the manifest.
var pdsSegmentInRequest = regexp.MustCompile(`/v1/([a-z_]+)/`)

// pdsExpectedMessageToken derives the token from the manifest's own `request`
// line — NOT from the kind label, because the label is what a mistyped harvest
// gets right while the path is what it gets wrong. An EMPTY override falls
// through to the derived token rather than making the check vacuous.
func pdsExpectedMessageToken(request, override string) string {
	if override != "" {
		return strings.ToLower(override)
	}
	mm := pdsSegmentInRequest.FindStringSubmatch(request)
	if len(mm) != 2 {
		return ""
	}
	seg := strings.TrimSuffix(mm[1], "s")
	return strings.ReplaceAll(seg, "_", " ")
}

func TestPDSLiveFixturesComeFromTheirDeclaredPath(t *testing.T) {
	m := loadPDSLiveManifest(t)
	checked := 0
	for _, f := range m.Fixtures {
		if f.HTTPStatus != 404 {
			continue
		}
		if f.MessageTokenOverride != "" && len(f.MessageTokenReason) < 40 {
			t.Errorf("%s (%s): message_token_override=%q with no stated measured reason — an unexplained override is how a wrong-path harvest talks its way past this arm",
				f.File, f.Kind, f.MessageTokenOverride)
		}
		token := pdsExpectedMessageToken(f.Request, f.MessageTokenOverride)
		if token == "" {
			t.Errorf("%s (%s): no collection token could be derived from request %q", f.File, f.Kind, f.Request)
			continue
		}
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		msg := strings.ToLower(pdsErrorEnvelope(body).Error.Message)
		if !strings.Contains(msg, token) {
			t.Errorf("%s (%s): the body says %q but the manifest claims it came from %q, whose collection token is %q — either the harvest read the wrong path or the manifest mislabels it",
				f.File, f.Kind, msg, f.Request, token)
		}
		checked++
	}
	if checked < 2 {
		t.Fatalf("only %d rows were path-checked — this arm is vacuous below two", checked)
	}

	// THE PLANTED WRONG-PATH ROW. It is a well-formed 404: application/json,
	// error.code=not_found, a real message. Status, content-type and error.code
	// all pass on it; only the token check reds.
	planted := []byte(`{"error":{"code":"not_found","message":"volume not found","details":{}}}`)
	if got := pdsCoherenceProblems(404, planted); len(got) != 0 {
		t.Errorf("the planted wrong-path body should be coherent (that is the point): %v", got)
	}
	if pdsErrorEnvelope(planted).Error.Code != "not_found" {
		t.Error("the planted wrong-path body should carry error.code=not_found")
	}
	wrongToken := pdsExpectedMessageToken("GET /v1/networks/999999999", "")
	if wrongToken != "network" {
		t.Fatalf("token derivation broke: got %q", wrongToken)
	}
	if strings.Contains(strings.ToLower(string(planted)), wrongToken) {
		t.Error("the planted wrong-path row did NOT red — a volume body filed under /v1/networks/ passed the token check, so this arm is decorative")
	}
	// And an empty override must fall through, never short-circuit to vacuous.
	if pdsExpectedMessageToken("GET /v1/volumes/999999999", "") != "volume" {
		t.Error("an empty override did not fall through to the derived token")
	}
}

// ─── THE LENGTH RELAXATION ───────────────────────────────────────────────────
//
// TestPDSLive404LengthsDifferByKind (wave 30) asserted PAIRWISE-DISTINCT BYTE
// COUNTS across kinds. The honest wave-32 harvest REFUTES that property: on real
// bytes `firewall` and `primary-ip` are both exactly 138. PDS-D429 predicted the
// collision as a pigeonhole certainty (the envelope is a fixed prefix plus the
// message, and ten kinds land in a narrow band) and PDS-D442 authorised the
// relaxation. It is replaced here, in the same commit, by the two properties the
// old test actually MEANT:
//
//	(a) error.message is PAIRWISE DISTINCT ACROSS KINDS — the real claim, since
//	    what varies per kind is the message, not its length. (Within-kind is
//	    structurally unfalsifiable at one body per kind.)
//	(b) at least TWO distinct byte counts exist — a FIXED structural floor,
//	    which is just the spelling of "not single-valued". A floor SCALED to the
//	    kind count reds on honest data (2 distinct lengths, 10 kinds) and would
//	    be the same over-reach in a new costume.
//
// THE FILTER IS THE WHOLE CRITERION. Both arms compute over http_status == 404
// ONLY, and that filter is PRESERVED from the incumbent, not added. Unfiltered,
// arm (b) is not merely weak but UNFALSIFIABLE: the permanent 186-byte 200
// fixture supplies a second length by itself, forever, even on a corpus with one
// single 404. The demo below proves both directions on a MANIFEST-SHAPED corpus
// (uniform 404s PLUS a non-404) — a 404-only demo would not, because the broken
// unfiltered build reds on that too and would certify itself.
//
// BOTH ARMS READ MANIFEST INTEGERS. They are about production only because
// TestPDSLiveFixturesRecordTheirOwnKindAndLength pins manifest bytes to disk
// bytes; that coupling is undocumented nowhere else, so it is stated here.
func pds404Distinctness(m pdsLiveManifest, filter bool) []string {
	var problems []string
	messages := map[string]string{}
	lengths := map[int]bool{}
	kinds := map[string]bool{}
	for _, f := range m.Fixtures {
		if filter && f.HTTPStatus != 404 {
			continue
		}
		kinds[f.Kind] = true
		lengths[f.Bytes] = true
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		msg := f.Note // only used when the body is unreadable, e.g. a synthetic corpus
		if err == nil {
			msg = pdsErrorEnvelope(body).Error.Message
		}
		if other, dup := messages[msg]; dup && other != f.Kind {
			problems = append(problems, fmt.Sprintf(
				"the %s and %s bodies carry the SAME error.message (%q) — the per-kind message is the property this file reasons about",
				other, f.Kind, msg))
		}
		messages[msg] = f.Kind
	}
	if len(kinds) < 2 {
		problems = append(problems, fmt.Sprintf("only %d kind(s) in scope — distinctness is vacuous below two", len(kinds)))
	}
	if len(lengths) < 2 {
		problems = append(problems, fmt.Sprintf(
			"every body in scope is the same length (%d distinct count across %d kinds) — that is the single-valued shape a universal byte-count assertion would look defensible on",
			len(lengths), len(kinds)))
	}
	return problems
}

func TestPDSLive404MessagesAndLengthsAreNotSingleValued(t *testing.T) {
	m := loadPDSLiveManifest(t)
	for _, p := range pds404Distinctness(m, true) {
		t.Errorf("live corpus: %s", p)
	}

	// THE DEMO CORPUS IS MANIFEST-SHAPED: uniform-length 404s PLUS a non-404,
	// which is the only shape that separates the filtered build from the broken
	// unfiltered one. Bodies are absent from disk on purpose, so Note carries
	// the stand-in message.
	demo := pdsLiveManifest{Fixtures: []pdsLiveFixture{
		{File: "absent-a", Kind: "alpha", HTTPStatus: 404, Bytes: 100, Note: "alpha not found"},
		{File: "absent-b", Kind: "beta", HTTPStatus: 404, Bytes: 100, Note: "beta not found"},
		{File: "absent-c", Kind: "gamma", HTTPStatus: 200, Bytes: 186, Note: "a permanent 200 fixture"},
	}}
	if got := pds404Distinctness(demo, true); len(got) == 0 {
		t.Error("FILTERED: a corpus of uniform-length 404s did not red — the byte floor is not doing anything")
	}
	if got := pds404Distinctness(demo, false); len(got) != 0 {
		t.Errorf("UNFILTERED: the same corpus RED, so this demo cannot separate the builds: %v", got)
	} else {
		t.Log("UNFILTERED on the same manifest-shaped corpus: GREEN. That is the greenwash the 404 filter prevents — the 200 fixture supplies a second length by itself, forever.")
	}
	// And the message arm, separately: duplicate messages across kinds must red
	// even when the lengths are fine.
	dupMsg := pdsLiveManifest{Fixtures: []pdsLiveFixture{
		{File: "absent-d", Kind: "alpha", HTTPStatus: 404, Bytes: 100, Note: "entity not found"},
		{File: "absent-e", Kind: "beta", HTTPStatus: 404, Bytes: 111, Note: "entity not found"},
	}}
	if got := pds404Distinctness(dupMsg, true); len(got) == 0 {
		t.Error("two kinds sharing one error.message did not red — the message arm is decorative")
	}
	// The positive control on the predicate itself.
	fine := pdsLiveManifest{Fixtures: []pdsLiveFixture{
		{File: "absent-f", Kind: "alpha", HTTPStatus: 404, Bytes: 100, Note: "alpha not found"},
		{File: "absent-g", Kind: "beta", HTTPStatus: 404, Bytes: 111, Note: "beta not found"},
	}}
	if got := pds404Distinctness(fine, true); len(got) != 0 {
		t.Errorf("an honest two-kind corpus RED: %v — the predicate refuses everything", got)
	}
}

// ─── THE MACHINE MARKER ──────────────────────────────────────────────────────
//
// What this proves is NON-ACCIDENTABILITY, NOT UNFORGEABILITY: nothing in a
// committed text file is unforgeable without a secret, and PDS-D440 measured a
// fully-verifying marker sitting happily on top of a mislabelled row. Its job is
// narrower and worth having anyway — that nobody TYPED a number into the
// manifest. Every http_status/content_type/bytes on a harvested row is derived
// from the verbatim curl record stored beside it, and every digest is derived
// from the bytes on disk.
func pdsChunkedSHA256(b []byte) string {
	sum := sha256.Sum256(b)
	h := hex.EncodeToString(sum[:])
	var parts []string
	for i := 0; i < len(h); i += 8 {
		parts = append(parts, h[i:i+8])
	}
	return strings.Join(parts, "-")
}

func TestPDSLiveManifestIsMachineEmitted(t *testing.T) {
	m := loadPDSLiveManifest(t)
	if !strings.Contains(m.EmittedBy, "pds-live-hetzner-placement-group.sh") {
		t.Errorf("emitted_by = %q — the manifest does not name the script that wrote it", m.EmittedBy)
	}
	harvested := 0
	var chainSrc []string
	for _, f := range m.Fixtures {
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		if want := pdsChunkedSHA256(body); f.Sha256Chunked != want {
			t.Errorf("%s: sha256_chunked = %q, the bytes on disk hash to %q", f.File, f.Sha256Chunked, want)
		}
		chainSrc = append(chainSrc, strings.Join([]string{
			f.File, strconv.Itoa(f.HTTPStatus), f.ContentType, strconv.Itoa(f.Bytes), f.Sha256Chunked,
		}, "|"))

		switch f.Provenance {
		case "harvest-only":
			harvested++
			parts := strings.Split(f.Record, "\t")
			if len(parts) != 3 {
				t.Errorf("%s: record %q is not the three TAB-delimited curl fields", f.File, f.Record)
				continue
			}
			if parts[0] != strconv.Itoa(f.HTTPStatus) || parts[1] != f.ContentType || parts[2] != strconv.Itoa(f.Bytes) {
				t.Errorf("%s: the row (%d, %q, %d) does not match its own curl record %q — a number in this manifest was typed, not derived",
					f.File, f.HTTPStatus, f.ContentType, f.Bytes, f.Record)
			}
		case "wave-30-run":
			// These predate the machine record. Their bytes and digest are still
			// derived from disk; their status and content-type are the wave-30
			// run's transcription and the provenance label is what says so.
			if f.Record != "" {
				t.Errorf("%s: provenance wave-30-run but it carries a curl record — one of the two is wrong", f.File)
			}
		default:
			t.Errorf("%s: provenance %q is neither harvest-only nor wave-30-run", f.File, f.Provenance)
		}
	}
	if harvested < 1 {
		t.Error("no row in the manifest carries a machine record — the emitter has never run against a live API")
	}
	if want := pdsChunkedSHA256([]byte(strings.Join(chainSrc, "\n"))); m.Chain != want {
		t.Errorf("chain = %q, folding the rows gives %q — a row was added, removed or edited without re-emitting", m.Chain, want)
	}
	if m.Chain == "" {
		t.Error("the manifest carries no chain")
	}
}

// TestPDSLiveManifestRecordsItsRefusals — a kind the harvest declined must leave
// a trace. A silently skipped kind is indistinguishable from a kind nobody
// thought of, which is the same disease the census arms exist to cure.
func TestPDSLiveManifestRecordsItsRefusals(t *testing.T) {
	m := loadPDSLiveManifest(t)
	if len(m.Refusals) == 0 {
		t.Fatal("the manifest records no refusals at all — `record` cannot be harvested by the flat shape and that has to be written down somewhere")
	}
	byKind := map[string]pdsLiveRefusal{}
	for _, r := range m.Refusals {
		if len(r.Ground) < 80 {
			t.Errorf("refusal of %q carries no real ground (%d chars) — a refusal without a reason is an omission wearing a field name", r.Kind, len(r.Ground))
		}
		byKind[r.Kind] = r
	}
	rec, ok := byKind["record"]
	if !ok {
		t.Fatal("`record` is not recorded as a refusal")
	}
	if !strings.Contains(rec.Ground, "rrsets") {
		t.Errorf("the ground for refusing `record` does not name the structural reason (records live only under /zones/<zone>/rrsets/...): %q", rec.Ground)
	}
	for _, k := range m.KindCoverage.FlatKinds {
		if k == "record" {
			t.Error("`record` is refused AND listed as a flat harvest kind — those cannot both be true")
		}
	}
	// The flat kinds and the harvested kinds must agree with the rows.
	present := map[string]bool{}
	for _, f := range m.Fixtures {
		present[f.Kind] = true
	}
	var missing []string
	for _, k := range m.KindCoverage.FlatKinds {
		if !present[k] {
			missing = append(missing, k)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Logf("flat kinds still unharvested: %v — an honest gap, visible rather than implied", missing)
	}
}

// pdsCredentialScanner is the ONE regex, shared by the scan and by the mutation
// that proves the scan can fail. PDS-D441: it is NOT widened and there is NO
// field whitelist — a fake 64-character token parked in a whitelisted `sha256`
// slot passes a whitelist while this unchanged scanner reds it. The cost of
// leaving it alone is that digests must be hyphen-chunked, which they are.
var pdsCredentialScanner = regexp.MustCompile(`[A-Za-z0-9]{32,}`)
var pdsBearerScanner = regexp.MustCompile(`(?i)bearer\s+\S+|authorization`)

// TestPDSLiveFixturesCarryNoCredential is the PDS-D102 discipline applied to this
// slice's own output: assert over the committed bytes rather than trusting the
// author who committed them. The live runs spent a 64-character Hetzner token and
// a Barkpark admin token; neither may have leaked into the residue.
//
// WHAT IT CANNOT DO — ITS LIMIT, STATED SO NOBODY READS IT AS A PRIVACY GATE.
// This is a credential-SHAPE guard and nothing more. It scans each fixture with
// exactly two patterns, both defined immediately above:
//
//	pdsCredentialScanner = `[A-Za-z0-9]{32,}`
//	pdsBearerScanner     = `(?i)bearer\s+\S+|authorization`
//
// Read them literally and the blind spot is arithmetic. `[A-Za-z0-9]{32,}` needs
// 32 UNBROKEN alphanumerics, so every dotted, colon-separated or hyphenated value
// is invisible to it: an IPv4 literal (89.167.28.206 — dots break the run), an
// IPv6 literal (colons break it), a dns_ptr hostname (dots), an hcloud datacenter
// id (fsn1-dc14 — a hyphen, and only 9 characters anyway), a region label, a
// server name, an ssh key comment. The bearer pattern only fires on the literal
// word "bearer" or "authorization". None of that is a credential shape, and all
// of it is topology. TestPDSLiveFixturesCarryNoTopology below is the arm that
// covers it; this one deliberately stays unwidened (PDS-D441).
func TestPDSLiveFixturesCarryNoCredential(t *testing.T) {
	entries, err := filepath.Glob(filepath.Join("testdata", "pds_live_*"))
	if err != nil || len(entries) == 0 {
		t.Fatalf("no pds_live_* fixtures found to scan (err=%v)", err)
	}
	// A 32+ character unbroken hex/base64-ish run is what every credential in
	// this repo looks like; document ids and revs are shorter or hyphenated.
	for _, path := range entries {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if mm := pdsCredentialScanner.Find(body); mm != nil {
			t.Errorf("%s contains a %d-character unbroken alphanumeric run (%q…) — that is the shape of a credential, not of a harvested API body",
				path, len(mm), string(mm[:8]))
		}
		if mm := pdsBearerScanner.Find(body); mm != nil {
			t.Errorf("%s mentions %q — no authorization material belongs in a committed fixture", path, string(mm))
		}
	}

	// THE MUTATION. The manifest now carries per-body digests, and the tempting
	// "fix" for the collision above is to widen this regex or to exempt a
	// `sha256` field by name. Both were measured weaker (PDS-D441): a planted
	// 64-character token in a whitelisted slot passes a whitelist. The scanner
	// stayed as it was, so it must still red on one.
	planted := []byte(`{"sha256":"deadbeefcafebabe0123456789abcdeffedcba9876543210deadbeefcafebabe"}`)
	if pdsCredentialScanner.Find(planted) == nil {
		t.Error("a planted 64-character token did NOT red the scanner — the regex has been widened and the scan no longer protects anything")
	}
	// …and the chunked form of the SAME digest must pass, which is the whole
	// reason the emitter chunks.
	chunked := []byte(`{"sha256_chunked":"deadbeef-cafebabe-01234567-89abcdef-fedcba98-76543210-deadbeef-cafebabe"}`)
	if mm := pdsCredentialScanner.Find(chunked); mm != nil {
		t.Errorf("the hyphen-chunked digest still reds the scanner (%q) — the chunking does not solve the collision", string(mm))
	}
}

// ---------------------------------------------------------------------------
// THE TOPOLOGY ARM — what the credential scan structurally cannot see.
// ---------------------------------------------------------------------------

// pdsTopologyScanners are the shapes a harvested cloud-API body can carry that
// leak WHERE we run rather than WHAT we authenticate with. Each is kept narrow
// enough to name what it found; breadth here buys false reds, not safety.
var pdsTopologyScanners = []struct {
	shape string
	re    *regexp.Regexp
}{
	// A dotted quad with real octet bounds, so "1.2.3.4" reds but a version
	// string like "999.999.999.999" or a float does not.
	{"IPv4 literal", regexp.MustCompile(`\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b`)},
	// Five or more colon-separated hex groups. An RFC3339 timestamp
	// ("2026-07-31T20:11:35Z") has only three groups, so it does not red here —
	// that bound is what keeps this arm quiet on the committed manifest.
	{"IPv6 literal", regexp.MustCompile(`(?i)\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){4,}\b`)},
	// A dotted DNS name under a public TLD — a dns_ptr, a rDNS record, an
	// endpoint we host. Deliberately not matching bare filenames (.json, .go,
	// .sh), which are not topology.
	{"hostname", regexp.MustCompile(`(?i)\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:cloud|com|net|org|io|de|eu|dev)\b`)},
	// hcloud's own datacenter identifiers: <location><n>-dc<n>, plus the
	// three-letter overseas locations.
	{"datacenter id", regexp.MustCompile(`(?i)\b(?:fsn1|nbg1|hel1|ash|hil|sin)-dc[0-9]+\b`)},
}

// pdsTopologyAllowed is the ONE exemption, and it is named rather than
// pattern-shaped so that adding a second one is a visible edit.
//
//	api.hetzner.cloud — the VENDOR's public API endpoint. It is Hetzner's own
//	published address, it appears in the manifest's "api" field as the
//	provenance of every harvested body, and it says nothing about our estate.
//
// Nothing else is exempt. In particular the prod box's address (docs/ops/PROD_OPS.md
// carries 89.167.28.206 in plain sight) is NOT allowlisted here: this arm exists to
// stop a future fixture-only edit from pasting an address into testdata, and an
// address that is already public elsewhere is still not something a harvested
// 404 body has any reason to contain.
var pdsTopologyAllowed = map[string]bool{
	"api.hetzner.cloud": true,
}

type pdsTopologyFinding struct {
	shape string
	match string
}

func pdsScanTopology(body []byte) []pdsTopologyFinding {
	var found []pdsTopologyFinding
	text := string(body)
	for _, s := range pdsTopologyScanners {
		for _, m := range s.re.FindAllString(text, -1) {
			if pdsTopologyAllowed[strings.ToLower(m)] {
				continue
			}
			found = append(found, pdsTopologyFinding{shape: s.shape, match: m})
		}
	}
	return found
}

// TestPDSLiveFixturesCarryNoTopology closes the gap the credential scan's own doc
// comment now states: `[A-Za-z0-9]{32,}` cannot see a dotted, colon-separated or
// hyphenated value, so every IP, hostname and datacenter id in a harvested body
// sails past it. The fixtures under testdata/pds_live_* are the residue of real
// calls against a real provider; the next harvest wave could easily bring back a
// 200 body carrying a public_net block, and — since a fixtures-only PR now runs
// the Go job — this is the instrument that would say so.
//
// It reds on nothing committed today: the 404 bodies are pure error envelopes and
// the one 200 body is a placement group with an empty servers list.
func TestPDSLiveFixturesCarryNoTopology(t *testing.T) {
	entries, err := filepath.Glob(filepath.Join("testdata", "pds_live_*"))
	if err != nil || len(entries) == 0 {
		t.Fatalf("no pds_live_* fixtures found to scan (err=%v)", err)
	}
	for _, path := range entries {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		for _, f := range pdsScanTopology(body) {
			t.Errorf("%s contains a topology value [%s: %q] — committed fixtures record what an API SAID, not where we run; scrub it, or add a named exemption to pdsTopologyAllowed with its source",
				path, f.shape, f.match)
		}
	}

	// THE MUTATION, kept in-tree so the arm can never go quietly blind. Each
	// planted body is the thing a real harvest would drag in; every one of them
	// must red the scanner. A greened-out arm that still passes over the clean
	// fixtures is indistinguishable from a working one WITHOUT this table.
	for _, tc := range []struct {
		name  string
		body  string
		shape string
	}{
		{"prod box IPv4", `{"server":{"public_net":{"ipv4":{"ip":"89.167.28.206"}}}}`, "IPv4 literal"},
		{"private IPv4", `{"private_net":[{"ip":"10.0.0.2"}]}`, "IPv4 literal"},
		{"IPv6 literal", `{"public_net":{"ipv6":{"ip":"2a01:4f8:1c1c:abcd::1"}}}`, "IPv6 literal"},
		{"dns_ptr hostname", `{"dns_ptr":"static.206.28.167.89.clients.your-server.de"}`, "hostname"},
		{"our own endpoint", `{"webhook":"https://api.barkpark.cloud/v1/hooks"}`, "hostname"},
		{"datacenter id", `{"datacenter":{"name":"fsn1-dc14"}}`, "datacenter id"},
	} {
		found := pdsScanTopology([]byte(tc.body))
		if len(found) == 0 {
			t.Errorf("mutation %q: a planted %s did NOT red the topology scan — the arm has gone blind and the committed fixtures prove nothing", tc.name, tc.shape)
			continue
		}
		var sawShape bool
		for _, f := range found {
			if f.shape == tc.shape {
				sawShape = true
			}
		}
		if !sawShape {
			t.Errorf("mutation %q: reddened as %v, but not as a %s — the arm fires for the wrong reason", tc.name, found, tc.shape)
		}
	}

	// …and the one allowlisted value must stay quiet, or every future harvest
	// manifest reds on its own provenance field.
	if found := pdsScanTopology([]byte(`{"api":"https://api.hetzner.cloud/v1"}`)); len(found) != 0 {
		t.Errorf("the vendor endpoint api.hetzner.cloud reds the topology scan (%v) — the allowlist entry no longer matches what the manifest writes", found)
	}
}
