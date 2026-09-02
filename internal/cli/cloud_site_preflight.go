package cli

// cloud_site_preflight.go is `bp cloud site preflight [--dir <path>]` — the
// FORWARD, laptop-side build-sanity check that catches a broken site deploy
// BEFORE it ever reaches the box. Every failed deploy round in wave 4 was
// catchable pre-push; this verb is that catch.
//
// It is deliberately DISTINCT from the box-side `--rollback-preflight` flag on
// deploy/site-deploy.sh (a BACKWARD readiness check: "is the previous release
// safe to flip back to?"). This runs on your machine, forward, against the build
// you are about to ship — the help text says so, so the two never blur.
//
// It does two independent things and gates on BOTH:
//
//  1. ENGINE FLOOR — run the shipped `--self-test` harnesses that ride next to the
//     engines (deploy/site-deploy.sh --self-test, deploy/site-deploy-node.sh
//     --self-test). These are the deploy engine's own assertions; if they don't
//     pass, the engine is broken and no local build matters. The gate is FAILS==0,
//     NEVER an exact total: the harnesses grow checks over time (87/87 static,
//     76/76 node today) and pinning a total would rot on every add.
//
//  2. THE CALLER'S SITE — the "catch problems before the box" half: env-contract
//     sanity (an ambient BARKPARK_TOKEN must NOT shadow the per-site token under
//     the BUILD_ALLOW scrub, D7), a REAL `npm ci && npm run build` in --dir, an
//     output-marker scan of the build dir for the bp-build-id / bp-content-rev /
//     bp-doc-id markers HEALTH gates on, and basePath sanity when a base is set.
//
// This is the FIRST Go CLI case of directly exec'ing a deploy/*.sh (every other
// deploy verb reads-then-SSH-streams). It is purely local/offline — it touches
// neither cloudclient nor apiclient. flock(1) is ABSENT on macOS; the self-test
// path avoids it and this verb MUST NEVER hit the real `flock -n 9` path.

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// siteSelfTestTimeout / siteBuildTimeout bound the two exec phases so a wedged
// harness or hung `npm ci` can never spin preflight forever.
const (
	siteSelfTestTimeout = 3 * time.Minute
	siteBuildTimeout    = 10 * time.Minute
)

// siteMarkerNames are the three output markers HEALTH asserts on: the build must
// bake them into its served HTML or the box will reject it at the HEALTH stage.
// Preflight scans for them locally so that rejection is caught before the push.
var siteMarkerNames = []string{"bp-build-id", "bp-content-rev", "bp-doc-id"}

// siteBuildOutputDirs are the framework build dirs preflight scans for markers,
// in the order it prefers them: Astro/Vite `dist/`, generic `build/`, Next.js
// `.next/` and its exported `out/`, Nuxt `.output/public/`.
var siteBuildOutputDirs = []string{"dist", "build", "out", ".next", filepath.Join(".output", "public")}

// runSiteSelfTest execs one engine's `--self-test` harness and returns its
// combined output + the process error. A package var so the unit tests inject a
// fake without shelling out to bash — the cloud_deploy_cmd newDeployFeeder idiom.
var runSiteSelfTest = func(ctx context.Context, script string) (string, error) {
	cmd := exec.CommandContext(ctx, "bash", script, "--self-test")
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// runSiteBuild execs `npm ci` then `npm run build` in dir and returns the
// combined output of whichever step ran + the process error. A package var so
// tests never require node. On success it stays quiet (the tail is only shown on
// failure), the honest "loud on failure, silent on success" build UX.
var runSiteBuild = func(ctx context.Context, dir string) (string, error) {
	var full bytes.Buffer
	for _, step := range [][]string{{"ci"}, {"run", "build"}} {
		cmd := exec.CommandContext(ctx, "npm", step...)
		cmd.Dir = dir
		var buf bytes.Buffer
		cmd.Stdout = &buf
		cmd.Stderr = &buf
		err := cmd.Run()
		full.WriteString(buf.String())
		if err != nil {
			return full.String(), fmt.Errorf("npm %s: %w", strings.Join(step, " "), err)
		}
	}
	return full.String(), nil
}

// findSiteDeployScripts resolves the two engine scripts:
// BARKPARK_SITE_DEPLOY_SCRIPT points at the static engine when set (its node
// sibling is derived beside it); otherwise it walks up from the working directory
// to the first deploy/site-deploy.sh — the exact env-override-then-walk-up shape
// findDeployScript uses for instance-deploy.sh. A package var so tests can stub it.
var findSiteDeployScripts = func() (static, node string, err error) {
	if p := strings.TrimSpace(os.Getenv("BARKPARK_SITE_DEPLOY_SCRIPT")); p != "" {
		if _, serr := os.Stat(p); serr != nil {
			return "", "", fmt.Errorf("BARKPARK_SITE_DEPLOY_SCRIPT=%s: %w", p, serr)
		}
		return p, filepath.Join(filepath.Dir(p), "site-deploy-node.sh"), nil
	}
	dir, werr := os.Getwd()
	if werr != nil {
		return "", "", fmt.Errorf("resolve working directory: %w", werr)
	}
	for {
		cand := filepath.Join(dir, "deploy", "site-deploy.sh")
		if _, serr := os.Stat(cand); serr == nil {
			return cand, filepath.Join(dir, "deploy", "site-deploy-node.sh"), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", "", fmt.Errorf("could not find deploy/site-deploy.sh from the current directory — run `bp cloud site preflight` from inside a Barkpark checkout, or set BARKPARK_SITE_DEPLOY_SCRIPT to the static engine's path")
}

// preflightCheck is one named assertion. On failure it carries the W4 hint
// grammar — observed → expected → next — so the reader always knows what was
// seen, what was wanted, and the single move that fixes it.
type preflightCheck struct {
	name     string
	ok       bool
	skipped  bool   // ran nothing (e.g. no basePath to check) — neither pass nor fail
	observed string // what preflight actually saw (failure only)
	expected string // what a healthy deploy needs (failure only)
	next     string // the one move that fixes it (failure only)
}

// selfTestSummary is the parsed outcome of a `--self-test` harness run. Fails is
// the load-bearing field: the gate keys on it, NOT on Total, so a harness that
// grows from 87 to 90 checks still passes at 90/90.
type selfTestSummary struct {
	Passed   int
	Total    int
	Fails    int
	Terminal string // "PASS", "FAILED", or "" when no terminal line was printed
	Found    bool   // a recognizable "N/M checks passed" or FAILED/PASS line was seen
}

var (
	reSelfTestCount  = regexp.MustCompile(`\[selftest\]\s+(\d+)/(\d+)\s+checks passed`)
	reSelfTestFailed = regexp.MustCompile(`\[selftest\]\s+FAILED\s*\((\d+)\)`)
	reSelfTestPass   = regexp.MustCompile(`\[selftest\]\s+PASS\b`)
)

// parseSelfTest reads the harness's own summary lines. It derives Fails from the
// most authoritative source available: an explicit `FAILED (k)` line wins; else
// Total-Passed from the `N/M checks passed` count; else 0. It NEVER trusts the
// process exit code alone — the gate cross-checks both.
func parseSelfTest(output string) selfTestSummary {
	var s selfTestSummary
	if m := reSelfTestCount.FindStringSubmatch(output); m != nil {
		s.Passed, _ = strconv.Atoi(m[1])
		s.Total, _ = strconv.Atoi(m[2])
		s.Fails = s.Total - s.Passed
		s.Found = true
	}
	if m := reSelfTestFailed.FindStringSubmatch(output); m != nil {
		if k, err := strconv.Atoi(m[1]); err == nil {
			s.Fails = k
		}
		s.Terminal = "FAILED"
		s.Found = true
	} else if reSelfTestPass.MatchString(output) {
		s.Terminal = "PASS"
		s.Found = true
	}
	if s.Fails < 0 {
		s.Fails = 0
	}
	return s
}

// selfTestGate decides whether a harness run clears the engine floor. The
// contract is strict AND non-vacuous: the process must have exited 0, a
// recognizable summary must have been printed (an unparseable run is a FAIL, not
// a silent pass), the terminal line must not be FAILED, and Fails must be 0. It
// asserts FAILS==0, NEVER an exact total.
func selfTestGate(sum selfTestSummary, runErr error) (ok bool, observed, expected, next string) {
	switch {
	case !sum.Found:
		expected = "the harness prints a `[selftest] N/M checks passed` summary and `[selftest] PASS`"
		next = "run it by hand: bash deploy/site-deploy.sh --self-test — the engine or bash toolchain is broken"
		if runErr != nil {
			observed = fmt.Sprintf("no `[selftest]` summary line, and the harness exited with an error (%v)", runErr)
		} else {
			observed = "no `[selftest]` summary line in the harness output"
		}
		return false, observed, expected, next
	case sum.Terminal == "FAILED" || sum.Fails > 0:
		total := sum.Total
		observed = fmt.Sprintf("%d self-test check(s) FAILED", sum.Fails)
		if total > 0 {
			observed = fmt.Sprintf("%d of %d self-test checks FAILED", sum.Fails, total)
		}
		expected = "every engine self-test check passes (FAILS==0)"
		next = "run the harness directly to see which check broke: bash deploy/site-deploy.sh --self-test"
		return false, observed, expected, next
	case runErr != nil:
		// The summary parsed clean but the process still exited non-zero — trust the
		// exit code and fail rather than green a run the shell said was bad.
		observed = fmt.Sprintf("self-test summary parsed clean but the harness exited with an error (%v)", runErr)
		expected = "the harness exits 0 after printing `[selftest] PASS`"
		next = "run it by hand to see the trailing error: bash deploy/site-deploy.sh --self-test"
		return false, observed, expected, next
	default:
		return true, "", "", ""
	}
}

// missingMarkers returns which of the three HEALTH markers are absent from the
// concatenated build HTML. Case-insensitive, name-only (the value is baked at
// real deploy time, not preflight) — it answers "does the build emit the marker
// at all", the thing a laptop build can actually prove.
func missingMarkers(html string) []string {
	lower := strings.ToLower(html)
	var missing []string
	for _, name := range siteMarkerNames {
		if !strings.Contains(lower, strings.ToLower(name)) {
			missing = append(missing, name)
		}
	}
	return missing
}

// ambientTokenShadow reports whether the ambient environment carries a
// BARKPARK_TOKEN (and the value's tail, for the message) — the D7 hazard: it
// would flow into the build under BUILD_ALLOW and SHADOW the per-site token the
// box injects, a live-proven failure mode. lookup is os.LookupEnv in production,
// a map in tests.
func ambientTokenShadow(lookup func(string) (string, bool)) (shadowed bool, tail string) {
	v, ok := lookup("BARKPARK_TOKEN")
	if !ok || strings.TrimSpace(v) == "" {
		return false, ""
	}
	// tokenTail (tokensource.go) is the ONE redaction rule for a credential in a
	// diagnostic — this message's original shape, now shared with the whoami /
	// auth-tier credential labels so all of them show exactly as much and no more.
	return true, tokenTail(v)
}

// basePathOK validates a site base path shape: it must start and end with `/`
// (the engine bakes BARKPARK_SITE_BASE=/sites/<slug>/ and Caddy's handle_path
// strips exactly that prefix — a base without the trailing slash silently 404s
// every asset). Empty is caller's "no base set" and is handled before this.
func basePathOK(base string) bool {
	base = strings.TrimSpace(base)
	return strings.HasPrefix(base, "/") && strings.HasSuffix(base, "/")
}

// runCloudSitePreflight is `bp cloud site preflight [--dir <path>] [--skip-build]`.
func runCloudSitePreflight(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudSitePreflightHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudSitePreflightHelp(out)
		return exitOK
	}

	const usage = "bp cloud site preflight [--dir <path>] [--skip-build]"
	a, perr := parseHzArgs(args, []string{"dir"}, []string{"skip-build"}, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	skipBuild := a.bools["skip-build"]

	// Resolve the site dir: --dir wins, else cwd. It must exist before we promise
	// to build in it.
	dir := strings.TrimSpace(a.val("dir"))
	if dir == "" {
		cwd, werr := os.Getwd()
		if werr != nil {
			return useError(out, "failed", "resolve working directory: "+werr.Error(), exitGeneric)
		}
		dir = cwd
	}
	absDir, aerr := filepath.Abs(dir)
	if aerr == nil {
		dir = absDir
	}
	if fi, serr := os.Stat(dir); serr != nil || !fi.IsDir() {
		return useError(out, "usage", fmt.Sprintf("--dir %q is not a directory", dir), exitUsage)
	}

	// Locate the engine scripts (env-override-then-walk-up). A miss here is fatal:
	// there is no engine floor to stand on.
	staticScript, nodeScript, ferr := findSiteDeployScripts()
	if ferr != nil {
		return useError(out, "failed", ferr.Error(), exitGeneric)
	}

	out.progressf("→ preflight for %s", hzCell(dir))

	var checks []preflightCheck

	// ── Phase 1: engine floor — the shipped self-test harnesses ────────────────
	for _, eng := range []struct{ name, script string }{
		{"engine self-test (static)", staticScript},
		{"engine self-test (node)", nodeScript},
	} {
		checks = append(checks, runOneSelfTest(out, eng.name, eng.script))
	}

	// ── Phase 2: the caller's site ─────────────────────────────────────────────
	checks = append(checks, checkEnvContract(os.LookupEnv))
	checks = append(checks, checkBasePath(dir, os.LookupEnv))

	if skipBuild {
		checks = append(checks, preflightCheck{name: "local build (npm ci && npm run build)", skipped: true})
		checks = append(checks, preflightCheck{name: "output markers", skipped: true})
	} else {
		buildCheck, built := checkLocalBuild(out, dir)
		checks = append(checks, buildCheck)
		if built {
			checks = append(checks, checkOutputMarkers(dir))
		} else {
			// No build dir was produced, so there is nothing to scan — say so
			// honestly rather than reporting a phantom missing-marker failure.
			checks = append(checks, preflightCheck{
				name:     "output markers",
				observed: "the build did not complete, so no output dir was scanned",
				expected: "a build dir (dist/, build/, out/, …) carrying the bp-build-id / bp-content-rev / bp-doc-id markers",
				next:     "fix the build failure above, then re-run preflight",
			})
		}
	}

	return renderPreflight(out, dir, staticScript, nodeScript, checks)
}

// runOneSelfTest runs one harness and turns its parsed summary + the gate verdict
// into a preflightCheck.
func runOneSelfTest(out *writer, name, script string) preflightCheck {
	if _, serr := os.Stat(script); serr != nil {
		return preflightCheck{
			name:     name,
			observed: fmt.Sprintf("engine script not found at %s", script),
			expected: "the shipped deploy/site-deploy*.sh harness sits beside the static engine",
			next:     "run from a full Barkpark checkout, or point BARKPARK_SITE_DEPLOY_SCRIPT at the static engine",
		}
	}
	ctx, cancel := context.WithTimeout(cloudCtx(), siteSelfTestTimeout)
	defer cancel()
	output, runErr := runSiteSelfTest(ctx, script)
	sum := parseSelfTest(output)
	ok, observed, expected, next := selfTestGate(sum, runErr)
	c := preflightCheck{name: name, ok: ok, observed: observed, expected: expected, next: next}
	if ok {
		out.progressf("  ✓ %s — %d/%d checks passed", name, sum.Passed, sum.Total)
	}
	return c
}

// checkEnvContract flags the D7 shadow hazard: an ambient BARKPARK_TOKEN would
// reach npm through BUILD_ALLOW and shadow the per-site token the box injects.
func checkEnvContract(lookup func(string) (string, bool)) preflightCheck {
	c := preflightCheck{name: "env-contract (BUILD_ALLOW scrub)"}
	if shadowed, tail := ambientTokenShadow(lookup); shadowed {
		c.observed = fmt.Sprintf("BARKPARK_TOKEN is set in your shell (%s) — it would flow into the build and SHADOW the per-site token", tail)
		c.expected = "no ambient BARKPARK_TOKEN — the box injects the per-site token at deploy time"
		c.next = "unset BARKPARK_TOKEN in this shell before deploying (unset BARKPARK_TOKEN), or run preflight in a clean env"
		return c
	}
	c.ok = true
	return c
}

// checkBasePath validates a site base path when one is declared — via
// BARKPARK_SITE_BASE / BARKPARK_SITE_BASEPATH, or a `.basepath` file in the site
// dir. When none is declared it's a legitimate skip (a root-served site).
func checkBasePath(dir string, lookup func(string) (string, bool)) preflightCheck {
	c := preflightCheck{name: "basePath sanity"}
	base := ""
	for _, k := range []string{"BARKPARK_SITE_BASE", "BARKPARK_SITE_BASEPATH"} {
		if v, ok := lookup(k); ok && strings.TrimSpace(v) != "" {
			base = strings.TrimSpace(v)
			break
		}
	}
	if base == "" {
		if b, rerr := os.ReadFile(filepath.Join(dir, ".basepath")); rerr == nil {
			base = strings.TrimSpace(string(b))
		}
	}
	if base == "" {
		c.skipped = true
		return c
	}
	if basePathOK(base) {
		c.ok = true
		return c
	}
	c.observed = fmt.Sprintf("base path %q is not framed by slashes", base)
	c.expected = "a base like /sites/<slug>/ — leading AND trailing slash (Caddy's handle_path strips exactly that prefix)"
	c.next = "set the base to /sites/<slug>/ (add the missing slash) — a base without the trailing slash 404s every asset"
	return c
}

// checkLocalBuild runs the real `npm ci && npm run build` in dir. It returns the
// check AND whether a build dir now exists (so the marker scan knows there is
// something to read). A missing package.json is a clean, named failure rather
// than a raw npm error.
func checkLocalBuild(out *writer, dir string) (preflightCheck, bool) {
	c := preflightCheck{name: "local build (npm ci && npm run build)"}
	if _, serr := os.Stat(filepath.Join(dir, "package.json")); serr != nil {
		c.observed = fmt.Sprintf("no package.json in %s", dir)
		c.expected = "a buildable site dir with a package.json and a `build` script"
		c.next = "run preflight from your site's root, or pass --dir <path> pointing at it"
		return c, false
	}
	out.progressf("  … building %s (npm ci && npm run build)…", hzCell(dir))
	ctx, cancel := context.WithTimeout(cloudCtx(), siteBuildTimeout)
	defer cancel()
	output, berr := runSiteBuild(ctx, dir)
	if berr != nil {
		c.observed = fmt.Sprintf("build failed: %v", berr)
		c.expected = "npm ci && npm run build completes cleanly"
		c.next = "fix the build error above and re-run preflight" + siteBuildTail(output)
		return c, false
	}
	c.ok = true
	out.progressf("  ✓ local build passed")
	return c, buildOutputDir(dir) != ""
}

// siteBuildTail returns the last few non-empty lines of a failed build's output,
// prefixed for the `next` hint — enough to see the real error without dumping the
// whole log into a one-line field.
func siteBuildTail(output string) string {
	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	var kept []string
	for _, ln := range lines {
		if strings.TrimSpace(ln) != "" {
			kept = append(kept, strings.TrimSpace(ln))
		}
	}
	if len(kept) == 0 {
		return ""
	}
	if len(kept) > 4 {
		kept = kept[len(kept)-4:]
	}
	return " (last: " + strings.Join(kept, " / ") + ")"
}

// buildOutputDir returns the first framework build dir that exists under dir,
// or "" if none was produced.
func buildOutputDir(dir string) string {
	for _, cand := range siteBuildOutputDirs {
		p := filepath.Join(dir, cand)
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			return p
		}
	}
	return ""
}

// checkOutputMarkers scans the build dir's HTML for the three HEALTH markers. It
// is the local proxy for the box's HEALTH stage: if the markers are absent here,
// the deploy WILL be rejected there.
func checkOutputMarkers(dir string) preflightCheck {
	c := preflightCheck{name: "output markers"}
	outDir := buildOutputDir(dir)
	if outDir == "" {
		c.observed = "no recognized build dir (dist/, build/, out/, .next/, .output/public/) after the build"
		c.expected = "a build dir carrying the served HTML"
		c.next = "confirm your framework writes to one of those dirs, or the build is misconfigured"
		return c
	}
	html := readBuildHTML(outDir)
	if strings.TrimSpace(html) == "" {
		c.observed = fmt.Sprintf("no HTML files under %s", outDir)
		c.expected = "at least one built .html page carrying the markers"
		c.next = "confirm the build renders HTML pages (not just assets)"
		return c
	}
	if missing := missingMarkers(html); len(missing) > 0 {
		c.observed = fmt.Sprintf("built HTML is missing marker(s): %s", strings.Join(missing, ", "))
		c.expected = "every page bakes bp-build-id, bp-content-rev and bp-doc-id <meta> markers (HEALTH asserts on them)"
		c.next = "add the Barkpark meta markers to your layout — the box's HEALTH stage rejects a build without them"
		return c
	}
	c.ok = true
	return c
}

// readBuildHTML concatenates up to a sane cap of the .html files found under
// outDir, so the marker scan sees the built pages without slurping a giant asset
// tree into memory.
func readBuildHTML(outDir string) string {
	const maxFiles = 200
	var b strings.Builder
	seen := 0
	_ = filepath.WalkDir(outDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if seen >= maxFiles {
			return filepath.SkipAll
		}
		if !strings.HasSuffix(strings.ToLower(d.Name()), ".html") {
			return nil
		}
		if data, rerr := os.ReadFile(path); rerr == nil {
			b.Write(data)
			b.WriteByte('\n')
			seen++
		}
		return nil
	})
	return b.String()
}

// renderPreflight prints the check list and returns the exit code: 0 when every
// non-skipped check passed, exitGeneric on the first failure. -o json/yaml emit a
// single envelope. A failed check prints the observed→expected→next block.
func renderPreflight(out *writer, dir, staticScript, nodeScript string, checks []preflightCheck) int {
	failed := 0
	for _, c := range checks {
		if !c.ok && !c.skipped {
			failed++
		}
	}

	if out.machineOut() {
		rows := make([]map[string]any, 0, len(checks))
		for _, c := range checks {
			row := map[string]any{"name": c.name}
			switch {
			case c.skipped:
				row["status"] = "skipped"
			case c.ok:
				row["status"] = "ok"
			default:
				row["status"] = "failed"
				row["observed"] = c.observed
				row["expected"] = c.expected
				row["next"] = c.next
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{
			"ok":            failed == 0,
			"dir":           dir,
			"static_engine": staticScript,
			"node_engine":   nodeScript,
			"failed":        failed,
			"checks":        rows,
		})
		if failed == 0 {
			return exitOK
		}
		return exitGeneric
	}

	out.outf("")
	for _, c := range checks {
		switch {
		case c.skipped:
			out.outf("  – %s (skipped)", c.name)
		case c.ok:
			out.outf("  ✓ %s", c.name)
		default:
			out.outf("  ✗ %s", c.name)
			out.outf("      observed: %s", c.observed)
			out.outf("      expected: %s", c.expected)
			out.outf("      next:     %s", c.next)
		}
	}
	out.outf("")
	if failed == 0 {
		out.outf("✓ preflight passed — the engine self-tests are green and %s is safe to deploy.", hzCell(dir))
		return exitOK
	}
	// A failing preflight IS the value: it exits non-zero so a script (or a human)
	// stops here instead of pushing a build the box would reject.
	out.userErr("preflight failed — %d check(s) above need fixing before you deploy.", failed)
	return exitGeneric
}

// printCloudSitePreflightHelp writes `bp cloud site preflight` usage.
func printCloudSitePreflightHelp(out *writer) {
	const help = `bp cloud site preflight — catch a broken site deploy BEFORE it reaches the box.

USAGE
  bp cloud site preflight [--dir <path>] [--skip-build]

WHAT IT DOES
  Runs, all locally and offline, in two gates:

  1. THE ENGINE FLOOR — the shipped deploy/site-deploy.sh and site-deploy-node.sh
     --self-test harnesses (the deploy engine's own assertions). Gate: every
     check passes (FAILS==0 — the totals grow as checks are added, so nothing is
     pinned to an exact number).

  2. YOUR SITE — the "catch it before the box" half:
       • env-contract: an ambient BARKPARK_TOKEN would shadow the per-site token
         under the build scrub — preflight flags it.
       • a REAL npm ci && npm run build in --dir (or cwd).
       • output markers: the built HTML must bake bp-build-id / bp-content-rev /
         bp-doc-id — the box's HEALTH stage rejects a build without them.
       • basePath sanity when a base is declared (leading + trailing slash).

FLAGS
  --dir <path>   the site to build (default: current directory)
  --skip-build   run the engine self-tests + env-contract only; skip npm build
  -o json        emit the check list as a machine envelope

NOT TO BE CONFUSED WITH
  deploy/site-deploy.sh --rollback-preflight — the BOX-side check that the
  previous release is safe to flip BACK to. This verb is the FORWARD, laptop-side
  check of the build you are about to ship.

OUTPUT + EXIT
  a check list (✓ / ✗ with observed → expected → next on failure).
  0 all checks passed · 1 a check failed · 2 usage.`
	out.outf("%s", help)
}
