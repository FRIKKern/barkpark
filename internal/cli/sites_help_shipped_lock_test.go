package cli

// sites_help_shipped_lock_test.go — HELP MUST NOT OFFER WHAT THE DOOR REFUSES.
//
// THE DEFECT THIS EXISTS FOR. PR #16529 narrowed POST /v1/sites: the create
// door now accepts only the SHIPPED half of the site enums — the frameworks a
// spawner can actually build (Site.shipped_frameworks/0) and the scale modes a
// runtime can actually honour (Site.shipped_scale_modes/0) — and answers
// anything else with a 422 naming the shipped list. `bp sites create --help`
// kept advertising the whole stored vocabulary: a `--scale-mode` alternation
// offering a mode with no runtime, and a `--framework` alternation offering
// three frameworks with no builder. A flag value the help offers and the
// server refuses is the same over-claim, one layer out.
//
// WHY A HAND-EDIT ALONE IS NOT THE FIX. Retyping the shipped list into a Go
// comment produces two hand-maintained copies of one truth — the unlocked
// mirror. The next framework that ships (or unships) moves the Elixir and
// leaves the help behind, silently, exactly as it did here. So this test reads
// the PRODUCER, from source, and asserts the help advertises precisely what it
// found.
//
// WHAT THIS DOES.
//
//	1. Parses cloud/lib/barkpark_cloud/registry/site.ex for four module
//	   attributes: the stored VOCABULARY (@container_frameworks +
//	   @static_frameworks, @scale_modes) and the SHIPPED subsets
//	   (@shipped_starters keys + @starterless_frameworks, @shipped_scale_modes).
//	2. Extracts every value the help text ADVERTISES — the operand of a
//	   `--framework` / `--scale-mode` in any comment, usage string or error
//	   string in sites_cmd.go, including `a|b|c` alternations.
//	3. Asserts the advertised set equals the shipped set exactly, in BOTH
//	   directions: an unshipped value advertised is a failure, and a shipped
//	   value the help never names is a failure too.
//
// THE NON-VACUITY GUARD. A lock that reads zero values passes everything, so
// every read is floored: an empty attribute, an empty advertised set, or a
// shipped value outside the vocabulary is a hard failure, not a skip. And
// TestSitesHelpAdvertisementExtractorIsNotBlind feeds the extractor the exact
// pre-fix text and asserts it recovers the refused values — if the regexes ever
// stop seeing the help, the lock says so instead of going quietly green.
//
// Cited by SYMBOL, never by line: `grep -n 'shipped_scale_modes' ` on the
// registry and `grep -n -- '--scale-mode' ` on sites_cmd.go find every anchor
// this file depends on, and cannot rot.

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// siteRegistryRelPath is the producer. It is in the same repository as this
// module, so the lock reads the real file, never a fixture copy of it.
const siteRegistryRelPath = "cloud/lib/barkpark_cloud/registry/site.ex"

// sitesCmdRelPath is the consumer whose help text is under lock.
const sitesCmdRelPath = "internal/cli/sites_cmd.go"

var (
	// `@name ~w(a b c)` on one line.
	reElixirWordList = func(name string) *regexp.Regexp {
		return regexp.MustCompile(`(?m)^\s*@` + regexp.QuoteMeta(name) + `\s+~w\(([^)]*)\)`)
	}
	// `@name %{"k" => "v", ...}` on one line.
	reElixirMapAttr = func(name string) *regexp.Regexp {
		return regexp.MustCompile(`(?m)^\s*@` + regexp.QuoteMeta(name) + `\s+%\{([^}]*)\}`)
	}
	reElixirMapKey = regexp.MustCompile(`"([a-z0-9_]+)"\s*=>`)

	// An advertised flag operand: the flag, whitespace, then a bare token or a
	// `a|b|c` alternation. `=`-joined forms in the PARSER (`"--framework="`)
	// carry no whitespace and are deliberately not matched — they are code, not
	// advertisement.
	reAdvertisedFramework = regexp.MustCompile(`--framework[ \t]+(?:one of[ \t]+)?([a-z_][a-z0-9_]*(?:\|[a-z_][a-z0-9_]*)*)`)
	reAdvertisedScaleMode = regexp.MustCompile(`--scale-mode[ \t]+([a-z_][a-z0-9_]*(?:\|[a-z_][a-z0-9_]*)*)`)
)

func repoRootForShippedLock(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for dir := wd; ; {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no go.mod above %s", wd)
		}
		dir = parent
	}
}

func readFileForShippedLock(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		// A lock that cannot read its producer must FAIL, never skip: a skip is
		// indistinguishable from a pass in a CI summary.
		t.Fatalf("read %s: %v", path, err)
	}
	if len(b) == 0 {
		t.Fatalf("%s is empty — the lock has nothing to read", path)
	}
	return string(b)
}

// elixirWordListAttr returns the words of a `@name ~w(...)` attribute. An
// attribute that is missing, or present but empty, is a failure.
func elixirWordListAttr(t *testing.T, src, name string) []string {
	t.Helper()
	m := reElixirWordList(name).FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("@%s not found in %s as a one-line ~w(...) attribute — the extractor has gone blind or the attribute moved", name, siteRegistryRelPath)
	}
	words := strings.Fields(m[1])
	if len(words) == 0 {
		t.Fatalf("@%s parsed to ZERO words — refusing to lock the help against an empty set", name)
	}
	return words
}

// elixirMapAttrKeys returns the string keys of a `@name %{"k" => …}` attribute.
func elixirMapAttrKeys(t *testing.T, src, name string) []string {
	t.Helper()
	m := reElixirMapAttr(name).FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("@%s not found in %s as a one-line %%{...} attribute", name, siteRegistryRelPath)
	}
	var keys []string
	for _, k := range reElixirMapKey.FindAllStringSubmatch(m[1], -1) {
		keys = append(keys, k[1])
	}
	if len(keys) == 0 {
		t.Fatalf("@%s parsed to ZERO keys — refusing to lock the help against an empty set", name)
	}
	return keys
}

// advertisedValues returns the distinct operands the help text offers for one
// flag, restricted to tokens that are part of the producer's vocabulary. A
// capture that holds no vocabulary word at all is prose (`--framework
// framework key (optional)`) and contributes nothing. sites is the number of
// places in the file that advertise the flag, used as the non-vacuity floor.
func advertisedValues(src string, re *regexp.Regexp, vocab map[string]bool) (values []string, sites int) {
	seen := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(src, -1) {
		hit := false
		for _, tok := range strings.Split(m[1], "|") {
			if vocab[tok] {
				hit = true
				if !seen[tok] {
					seen[tok] = true
					values = append(values, tok)
				}
			}
		}
		if hit {
			sites++
		}
	}
	sort.Strings(values)
	return values, sites
}

func setOf(words []string) map[string]bool {
	m := make(map[string]bool, len(words))
	for _, w := range words {
		m[w] = true
	}
	return m
}

func sortedUnique(words []string) []string {
	out := make([]string, 0, len(words))
	seen := map[string]bool{}
	for _, w := range words {
		if !seen[w] {
			seen[w] = true
			out = append(out, w)
		}
	}
	sort.Strings(out)
	return out
}

// TestSitesCreateHelpAdvertisesExactlyTheShippedSet is the lock. It reds when
// EITHER side moves: put an unshipped value back in the help, or drop a value
// from the Elixir shipped list, and the two sets stop matching.
func TestSitesCreateHelpAdvertisesExactlyTheShippedSet(t *testing.T) {
	root := repoRootForShippedLock(t)
	registry := readFileForShippedLock(t, filepath.Join(root, filepath.FromSlash(siteRegistryRelPath)))
	help := readFileForShippedLock(t, filepath.Join(root, filepath.FromSlash(sitesCmdRelPath)))

	// The stored vocabulary — every value the schema will LOAD and serialize,
	// including rows written before the create door narrowed.
	frameworkVocab := sortedUnique(append(
		elixirWordListAttr(t, registry, "container_frameworks"),
		elixirWordListAttr(t, registry, "static_frameworks")...,
	))
	scaleModeVocab := sortedUnique(elixirWordListAttr(t, registry, "scale_modes"))

	// The shipped subsets — what the create door actually ACCEPTS.
	shippedFrameworks := sortedUnique(append(
		elixirMapAttrKeys(t, registry, "shipped_starters"),
		elixirWordListAttr(t, registry, "starterless_frameworks")...,
	))
	shippedScaleModes := sortedUnique(elixirWordListAttr(t, registry, "shipped_scale_modes"))

	for _, c := range []struct {
		name    string
		shipped []string
		vocab   []string
	}{
		{"framework", shippedFrameworks, frameworkVocab},
		{"scale_mode", shippedScaleModes, scaleModeVocab},
	} {
		vs := setOf(c.vocab)
		for _, s := range c.shipped {
			if !vs[s] {
				t.Fatalf("%s: shipped value %q is outside the stored vocabulary %v — the extractor is reading the wrong attributes", c.name, s, c.vocab)
			}
		}
	}

	// What the help offers today.
	advFrameworks, fwSites := advertisedValues(help, reAdvertisedFramework, setOf(frameworkVocab))
	advScaleModes, smSites := advertisedValues(help, reAdvertisedScaleMode, setOf(scaleModeVocab))

	if fwSites == 0 {
		t.Fatalf("found ZERO --framework advertisements in %s — the extractor has gone blind; a lock over an empty set proves nothing", sitesCmdRelPath)
	}
	if smSites == 0 {
		t.Fatalf("found ZERO --scale-mode advertisements in %s — the extractor has gone blind; a lock over an empty set proves nothing", sitesCmdRelPath)
	}

	for _, c := range []struct {
		flag       string
		advertised []string
		shipped    []string
		vocab      []string
		producer   string
		sites      int
	}{
		{"--framework", advFrameworks, shippedFrameworks, frameworkVocab, "Site.shipped_frameworks/0", fwSites},
		{"--scale-mode", advScaleModes, shippedScaleModes, scaleModeVocab, "Site.shipped_scale_modes/0", smSites},
	} {
		shipped := setOf(c.shipped)

		// Direction 1 — the help offers something the door refuses.
		var overClaimed []string
		for _, v := range c.advertised {
			if !shipped[v] {
				overClaimed = append(overClaimed, v)
			}
		}
		if len(overClaimed) > 0 {
			t.Errorf("%s help in %s advertises %v, which %s does NOT ship (shipped: %v). "+
				"POST /v1/sites answers those with a 422 — remove them from the help or ship them.",
				c.flag, sitesCmdRelPath, overClaimed, c.producer, c.shipped)
		}

		// Direction 2 — the door accepts something the help never names.
		advertised := setOf(c.advertised)
		var unadvertised []string
		for _, v := range c.shipped {
			if !advertised[v] {
				unadvertised = append(unadvertised, v)
			}
		}
		if len(unadvertised) > 0 {
			t.Errorf("%s: %s ships %v but the help in %s never names it (advertised: %v, across %d site(s)). "+
				"The shipped list moved and the help did not follow.",
				c.flag, c.producer, unadvertised, sitesCmdRelPath, c.advertised, c.sites)
		}
	}
}

// TestSitesHelpAdvertisementExtractorIsNotBlind is the lock's own non-vacuity
// proof. It feeds the extractor the VERBATIM pre-fix help lines (origin/main
// 9ae424d38) and asserts it recovers the values #16529 made refusable. If a
// future edit to the help's shape stops the regexes matching, this fails —
// rather than the lock above passing because it saw nothing.
func TestSitesHelpAdvertisementExtractorIsNotBlind(t *testing.T) {
	const preFix = `
//                   [--framework nextjs] [--domain <d>] [--scale-mode always_on|zero]
//	--framework  one of nextjs|nuxt|sveltekit|astro|static (server default
//	--scale-mode always_on|zero. Optional.
//	--framework                framework key (optional)
//	--scale-mode               always_on|zero (optional)
		case a == "--scale-mode":
		case strings.HasPrefix(a, "--scale-mode="):
			scaleMode = a[len("--scale-mode="):]
`
	frameworkVocab := setOf([]string{"nextjs", "nuxt", "sveltekit", "astro", "hugo", "static"})
	scaleModeVocab := setOf([]string{"always_on", "zero"})

	gotFW, fwSites := advertisedValues(preFix, reAdvertisedFramework, frameworkVocab)
	wantFW := []string{"astro", "nextjs", "nuxt", "static", "sveltekit"}
	if strings.Join(gotFW, ",") != strings.Join(wantFW, ",") {
		t.Errorf("framework extractor on the pre-fix text: got %v, want %v", gotFW, wantFW)
	}
	if fwSites != 2 {
		t.Errorf("framework advertisement sites in the pre-fix text: got %d, want 2 (the `framework key (optional)` line is prose, not an advertisement)", fwSites)
	}

	gotSM, smSites := advertisedValues(preFix, reAdvertisedScaleMode, scaleModeVocab)
	wantSM := []string{"always_on", "zero"}
	if strings.Join(gotSM, ",") != strings.Join(wantSM, ",") {
		t.Errorf("scale-mode extractor on the pre-fix text: got %v, want %v", gotSM, wantSM)
	}
	if smSites != 3 {
		t.Errorf("scale-mode advertisement sites in the pre-fix text: got %d, want 3 (the two parser `--scale-mode=` lines are code, not advertisement)", smSites)
	}
}
