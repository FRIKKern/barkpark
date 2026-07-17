package cli

// scaffy_discover_cmd.go is `bp scaffy discover` — the deterministic git-
// mining pass (Scaffy leap 1): rank the repo's accretion files and co-
// creation pairs by measured frequency, cross-referenced against the served
// catalog (SERVED / PARTIAL / UNSERVED). Pure local like the rest of the
// scaffy noun: git + the committed corpus, no server, no auth, no manifest.
// The engine lives in internal/scaffy (scaffy.Discover — the D40 seam);
// this file only parses flags, renders the table / machine envelope, and
// maps errors onto the stable exit-code scheme. The canonical reference
// oracle for the numbers is tooling/scaffy-mine/mine.sh (its README carries
// the parity contract).

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// runScaffyDiscover is `bp scaffy discover [--since <date|duration>]
// [--until <rev>] [--min-support N] [--top N]`. Read-only: exit 0 on a
// successful report, 2 on usage errors, 4 when git/the rev is unavailable.
func runScaffyDiscover(out *writer, args []string) int {
	opts, uerr := parseScaffyDiscoverArgs(args)
	if uerr != "" {
		return usageErrf(out, func() { printScaffyDiscoverHelp(out) }, "scaffy discover: %s", uerr)
	}
	rep, err := scaffy.Discover(opts)
	if err != nil {
		if errors.Is(err, scaffy.ErrSinceFormat) {
			return usageErrf(out, func() { printScaffyDiscoverHelp(out) }, "scaffy discover: %v", err)
		}
		return useError(out, "io", "scaffy discover: "+err.Error(), exitNotFound)
	}
	if out.machineOut() {
		out.emitStructured(map[string]any{
			"ok":               true,
			"window":           toGeneric(rep.Window),
			"min_support":      rep.MinSupport,
			"top":              rep.Top,
			"catalog_dir":      rep.CatalogDir,
			"catalog_commands": rep.CatalogCommands,
			"accretion":        toGeneric(rep.Accretion),
			"co_creation":      toGeneric(rep.CoCreation),
			"note":             rep.Note,
			"duration_ms":      rep.DurationMS,
		})
		return exitOK
	}
	renderScaffyDiscover(out, rep)
	return exitOK
}

// renderScaffyDiscover is the human table: window + thresholds first (honest
// output — every number is reproducible from that header), then the two
// ranked sections, then the frequency-not-verdict note.
func renderScaffyDiscover(out *writer, rep *scaffy.DiscoverReport) {
	short := rep.Window.UntilSHA
	if len(short) > 9 {
		short = short[:9]
	}
	out.outf("window: %s → %s (%s, commit day %s), --no-merges, %d commits",
		rep.Window.Since, rep.Window.UntilRev, short, rep.Window.UntilDay, rep.Window.Commits)
	out.outf("        %s", rep.Window.Derivation)
	out.outf("        recent sub-window: %s → %s (last %dd before the until day)",
		rep.Window.RecentSince, rep.Window.UntilDay, rep.Window.RecentDays)
	out.outf("thresholds: min-support %d, top %d · catalog: %s (%d commands)",
		rep.MinSupport, rep.Top, rep.CatalogDir, rep.CatalogCommands)
	out.outf("")

	out.outf("accretion candidates — commits × revolving-cast partners (files existing at the until commit)")
	out.outf("  recent = commits in the last %dd · DECOMPOSED = one in-window commit deleted >50%% of the file's current lines", rep.Window.RecentDays)
	out.outf("%4s %8s %7s %9s %6s %7s %6s  %-10s %s", "#", "commits", "recent", "partners", "pure", "mostly", "mixed", "coverage", "file")
	for _, c := range rep.Accretion {
		cov := strings.ToUpper(c.Coverage)
		if len(c.CoveredBy) > 0 {
			cov += " (" + strings.Join(c.CoveredBy, ", ") + ")"
		}
		file := c.Path
		if c.Decomp.Detected {
			// Loud, evidence-carrying: the ranked churn is mostly pre-decomposition.
			file += fmt.Sprintf("  ⚠ DECOMPOSED (one commit −%d vs %d lines now)", c.Decomp.MaxDelete, c.Decomp.CurrentLines)
		}
		out.outf("%4d %8d %7d %9d %6d %7d %6d  %-10s %s",
			c.Rank, c.Commits, c.RecentCommits, c.Partners, c.Shape.PureAdd, c.Shape.MostlyAdd, c.Shape.Mixed, cov, file)
	}
	if len(rep.Accretion) == 0 {
		out.outf("  (no files reach min-support %d in the window)", rep.MinSupport)
	}
	out.outf("")

	out.outf("co-creation pairs — same-commit basename-paired creations (strict) / any-pair commits (loose)")
	out.outf("%7s %6s  %-22s %-14s %s", "strict", "loose", "pair", "coverage", "hot dirs")
	for _, r := range rep.CoCreation {
		var dirs []string
		for _, d := range r.TopDirs {
			dirs = append(dirs, fmt.Sprintf("%s (%d)", d.Dir, d.Count))
		}
		cov := "UNSERVED"
		if len(r.CoveredBy) > 0 {
			// Shape-level coverage is inherently partial: some clusters of the
			// pair are commanded, never all of them.
			cov = "PARTIAL"
		}
		out.outf("%7d %6d  %-22s %-14s %s", r.Strict, r.Loose,
			"*"+r.SrcSuffix+" + *"+r.TestSuffix, cov, strings.Join(dirs, ", "))
		if len(r.CoveredBy) > 0 {
			out.outf("%7s %6s  %-22s covered by: %s", "", "", "", strings.Join(r.CoveredBy, ", "))
		}
	}
	out.outf("")
	out.outf("note: %s.", rep.Note)
}

// parseScaffyDiscoverArgs parses the discover flag shape. All flags take a
// value (`--flag v` or `--flag=v`); no positionals are accepted.
func parseScaffyDiscoverArgs(args []string) (scaffy.DiscoverOptions, string) {
	var opts scaffy.DiscoverOptions
	seen := map[string]bool{}
	take := func(name string, i *int) (string, string) {
		a := args[*i]
		if seen[name] {
			return "", "duplicate " + name
		}
		seen[name] = true
		if a == name {
			if *i+1 >= len(args) {
				return "", name + " needs a value"
			}
			*i++
			return args[*i], ""
		}
		return strings.TrimPrefix(a, name+"="), ""
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		var v, uerr string
		switch {
		case a == "--since" || strings.HasPrefix(a, "--since="):
			v, uerr = take("--since", &i)
			if uerr == "" {
				if err := scaffy.CheckSinceFormat(v); err != nil {
					uerr = err.Error()
				}
			}
			opts.Since = v
		case a == "--until" || strings.HasPrefix(a, "--until="):
			v, uerr = take("--until", &i)
			opts.Until = v
		case a == "--min-support" || strings.HasPrefix(a, "--min-support="):
			v, uerr = take("--min-support", &i)
			if uerr == "" {
				n, err := strconv.Atoi(v)
				if err != nil || n < 1 {
					uerr = fmt.Sprintf("--min-support needs a positive integer (got %q)", v)
				}
				opts.MinSupport = n
			}
		case a == "--top" || strings.HasPrefix(a, "--top="):
			v, uerr = take("--top", &i)
			if uerr == "" {
				n, err := strconv.Atoi(v)
				if err != nil || n < 1 {
					uerr = fmt.Sprintf("--top needs a positive integer (got %q)", v)
				}
				opts.Top = n
			}
		case strings.HasPrefix(a, "-") && a != "-":
			uerr = fmt.Sprintf("unknown discover flag %q", a)
		default:
			uerr = fmt.Sprintf("discover takes no positional arguments (got %q)", a)
		}
		if uerr != "" {
			return opts, uerr
		}
	}
	return opts, ""
}

func printScaffyDiscoverHelp(out *writer) {
	out.outf(`usage: bp scaffy discover [--since <date|duration>] [--until <rev>]
                          [--min-support N] [--top N]

Mine the repository's git history for Scaffy candidates — deterministically,
read-only, zero tokens. Three passes over batched git-log streams:

  accretion    files with high commit count AND high unique-partner
               diversity (the revolving-cast registry signature), ranked,
               with an uncapped co-change partner count, a ≥2…≥5 support
               histogram (-o json), the PURE_ADD/MOSTLY_ADD/MIXED
               commit-shape split by numstat, a RECENT column (see below),
               and a DECOMPOSED? flag (see below)
  co-creation  same-commit basename-paired creations per suffix rule
               (foo.ex + foo_test.exs, and the .go/.ts/.tsx pairs),
               strict and loose, with the hottest directories
  coverage     every candidate cross-referenced against the served catalog
               (scaffy/commands/*.scaffy op targets): SERVED when a command
               already mechanizes it, PARTIAL when only an ensure-* command
               plants anchors there, UNSERVED otherwise

Recency honesty (the recent column + DECOMPOSED? flag) — a 12-month aggregate
hides files whose ranked churn is mostly PRE-decomposition history no longer
resembling the current file. Two signals expose that divergence in the table:

  recent       commits touching the file inside the last 90 days before the
               until commit's day (a fixed span, pin-derived like the main
               window — never wall-clock). recent << commits means the ranked
               churn is old; the file may already have settled.
  DECOMPOSED?  set when a SINGLE in-window commit gutted the file. Rule, exact:
                 deletions > additions  AND  deletions > (current lines)/2
               where "current lines" is the file's line count at the until
               commit (one batched cat-file, deterministic). It is the honest
               approximation of ">50% of the file's lines removed in one
               commit" — current lines stand in for the pre-commit count, which
               numstat deltas cannot reconstruct across a partial window. A
               DECOMPOSED file's high rank is a GHOST: the mined churn predates
               the split. Reported as a "⚠ DECOMPOSED (one commit −D vs L
               lines now)" suffix on the file, and decomposition.{detected,
               max_delete,current_lines} in -o json.

Deterministic by construction: the window derives from the --until commit's
own commit day (never wall-clock "now"), merge commits are excluded, and all
output is sorted — the same checkout yields the same report on any day. The
canonical reference oracle is tooling/scaffy-mine/mine.sh; this verb is its
living, whole-repo successor.

flags:
  --since <v>       window start: a YYYY-MM-DD date, or a duration before
                    the until commit's day — <N>d|w|m|y (default: 12m)
  --until <rev>     the commit the window is pinned to (default: HEAD);
                    pass a fixed SHA to reproduce a published run exactly
  --min-support N   minimum commits for an accretion candidate (default: 5)
  --top N           accretion candidates reported (default: 20)

-o json|-o yaml emits {ok, window, min_support, top, catalog_dir,
catalog_commands, accretion, co_creation, note, duration_ms}.

Counts are FREQUENCY evidence, not verdicts — a candidate earns a command
(or a cut) only through the survey step.

examples:
  bp scaffy discover                          # 12 months before HEAD's day
  bp scaffy discover --top 40 --min-support 10
  bp scaffy discover --since 6m -o json | jq '.accretion[:5]'
  bp scaffy discover --until 591fdcd53        # reproduce the pinned canon window

exit codes:
  0  report produced
  2  usage error (bad flag, malformed --since, non-positive N)
  4  not a git repository, git unavailable, or --until rev not found`)
}
