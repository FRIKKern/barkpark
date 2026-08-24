package cli

// scaffy_cmd.go is `bp scaffy` — the CLI surface over internal/scaffy, the one
// implementation of the pinned Scaffy v2 grammar (charter D27/D31/D33–D43).
// The five local verbs:
//
//	bp scaffy validate <path>...             parse + lint, compiler-style findings
//	bp scaffy fmt [--check] <path>...        canonical structural form, in place
//	bp scaffy run <cmd.scaffy> --var K=V...  validate, then apply to the cwd tree
//	bp scaffy remove <cmd.scaffy> --var ...  receipt replay, drift-refused (D36)
//	bp scaffy discover [--since ...]         deterministic git-mining pass (leap 1)
//
// The two remote verbs — `pull` and `ls --remote` (W4, D48–D50) — and the
// pulled-command consent gate live ENTIRELY in scaffy_remote_cmd.go; the
// discover verb lives in scaffy_discover_cmd.go (engine: internal/scaffy
// discover.go); this file only dispatches to them.
//
// PURE LOCAL like make/style: no network, no auth, no manifest — this file
// never touches the server. All grammar + engine work lives in internal/scaffy
// (Parse/Lint/ValidateFile/Format/Run/Remove — the D40 seam); this file only
// walks paths, parses --var K=V, renders reports, and maps results onto the
// stable exit-code scheme:
//
//	0  clean (applied / removed / no-op / no findings / already canonical)
//	2  usage error (exitUsage: bad flag, malformed --var, D37 var-contract
//	   violations, DIRECTION-remove given to `remove` — D36)
//	4  missing path / unreadable or unwritable file / no receipt (exitNotFound —
//	   receipt misses are fs.ErrNotExist-shaped)
//	5  validation findings, guard/assert failures, SCAFFY-DRIFT, or fmt --check
//	   non-fixpoint (exitValidation)
//
// -o json|yaml emits a machine envelope ({ok, files, findings[]} for
// validate; {ok, mode, files, changed[]} for fmt; {ok, command, direction,
// vars, ops, asserts, receipt, duration_ms} for run/remove — D39) per the
// doctor exemplar: the exit code follows the FINDINGS, never the output shape.
// run/remove honour the pre-parsed global --dry-run (g.dryRun): compute
// everything, write and execute NOTHING (D39).

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// runScaffy dispatches the scaffy verbs. args is everything after the noun
// (rest[1:] in Execute). Mirrors the mcp/context two-verb builtin pattern:
// help/empty-verb prints usage and exits 0; an unknown verb is exit 2.
func runScaffy(out *writer, g globals, args []string) int {
	verb := ""
	if len(args) > 0 {
		verb = args[0]
	}
	switch verb {
	case "validate":
		if g.help {
			printScaffyValidateHelp(out)
			return exitOK
		}
		return runScaffyValidate(out, args[1:])
	case "fmt":
		if g.help {
			printScaffyFmtHelp(out)
			return exitOK
		}
		return runScaffyFmt(out, args[1:])
	case "run":
		if g.help {
			printScaffyRunHelp(out)
			return exitOK
		}
		return runScaffyRun(out, g, args[1:])
	case "remove":
		if g.help {
			printScaffyRemoveHelp(out)
			return exitOK
		}
		return runScaffyRemove(out, g, args[1:])
	case "describe":
		// The AST-only contract reader lives in scaffy_describe_cmd.go — this
		// file carries the dispatch case ONLY, so TestScaffyPureLocal's
		// scaffy_cmd.go scan stays satisfied (the D48/D102 precedent).
		if g.help {
			printScaffyDescribeHelp(out)
			return exitOK
		}
		return runScaffyDescribe(out, args[1:])
	case "discover":
		// The git-mining pass lives in scaffy_discover_cmd.go (engine in
		// internal/scaffy/discover.go) — dispatch ONLY, like the remote verbs.
		if g.help {
			printScaffyDiscoverHelp(out)
			return exitOK
		}
		return runScaffyDiscover(out, args[1:])
	case "pull":
		// Remote verbs live in scaffy_remote_cmd.go (W4, D48) — this file stays
		// pure-local, so these cases are dispatch ONLY.
		if g.help {
			printScaffyPullHelp(out)
			return exitOK
		}
		return runScaffyPull(out, g, args[1:])
	case "ls":
		if g.help {
			printScaffyLsHelp(out)
			return exitOK
		}
		return runScaffyLs(out, g, args[1:])
	case "":
		if g.help {
			printScaffyHelp(out)
			return exitOK
		}
		// A bare `bp scaffy` with no verb is incomplete usage (the `bp <noun>`
		// convention in Execute's manifest path); usageErrf keeps -o json parity.
		return usageErrf(out, func() { printScaffyHelp(out) }, "scaffy needs a verb: validate, fmt, run, remove, describe, discover, pull, or ls")
	default:
		return usageErrf(out, func() { printScaffyHelp(out) }, "unknown command %q %q", "scaffy", verb)
	}
}

// runScaffyValidate is `bp scaffy validate [--repo <root>] [--var K=V...]
// <path>...`. Each path is a .scaffy file or a directory (a directory
// validates its *.scaffy files, sorted, non-recursive). Findings print
// compiler-style "file:line: RULE-ID message" followed by an indented
// fix-hint line; the exit code is 5 on ANY finding (D27), 0 when every file
// is clean.
//
// --repo <root> turns on the opt-in repo-aware layer (D5): after a file
// validates text-clean, scaffy.RepoCheck verifies every IN-op's target file
// exists under <root> and every structural anchor resolves there — uniquely
// where the matcher demands it. Substitution-dependent anchors ({{.tokens}})
// are checked only when the full --var set is supplied (repeatable, like
// run); without vars they are skipped and the count is reported — never a
// vacuous green.
func runScaffyValidate(out *writer, args []string) int {
	paths, repo, vars, uerr := parseScaffyValidateArgs(args)
	if uerr != "" {
		return usageErrf(out, func() { printScaffyValidateHelp(out) }, "%s", uerr)
	}
	if len(paths) == 0 {
		return usageErrf(out, func() { printScaffyValidateHelp(out) }, "scaffy validate needs at least one <path>")
	}

	files, err := collectScaffyFiles(paths)
	if err != nil {
		return useError(out, "io", "scaffy validate: "+err.Error(), exitNotFound)
	}

	var findings []scaffy.Finding
	skippedToken := 0
	anchorsOK := 0
	for _, f := range files {
		src, rerr := os.ReadFile(f)
		if rerr != nil {
			return useError(out, "io", "scaffy validate: "+rerr.Error(), exitNotFound)
		}
		fileFindings := scaffy.ValidateFile(f, src)
		findings = append(findings, fileFindings...)
		// Repo-aware checks run only on a text-clean file — anchors on a
		// malformed AST are noise (D5). A bad --var set is a usage error.
		if repo != "" && len(fileFindings) == 0 {
			res, cerr := scaffy.RepoCheck(f, src, scaffy.RepoCheckOptions{RepoRoot: repo, Vars: vars})
			if cerr != nil {
				var varErr *scaffy.VarError
				if errors.As(cerr, &varErr) {
					return usageErrf(out, func() { printScaffyValidateHelp(out) }, "scaffy validate --var: %v", cerr)
				}
				return useError(out, "io", "scaffy validate: "+cerr.Error(), exitNotFound)
			}
			findings = append(findings, res.Findings...)
			skippedToken += res.SkippedToken
			anchorsOK += res.AnchorsOK
		}
	}

	if out.machineOut() {
		env := map[string]any{
			"ok":       len(findings) == 0,
			"files":    len(files),
			"findings": scaffyFindingsJSON(findings),
		}
		if repo != "" {
			env["repo"] = repo
			env["anchors_ok"] = anchorsOK
			env["anchors_skipped_token"] = skippedToken
		}
		out.emitStructured(env)
	} else {
		for _, f := range findings {
			out.outf("%s", f.String())
			if f.Hint != "" {
				out.outf("  hint: %s", f.Hint)
			}
		}
		if len(findings) == 0 {
			out.outf("clean: %d file(s), 0 findings", len(files))
		} else {
			out.outf("%d finding(s) across %d file(s)", len(findings), len(files))
		}
		// The repo-aware summary line — always printed under --repo, so a
		// clean run still names the anchors verified and the token-bearing
		// anchors skipped for want of --var (never a silent green).
		if repo != "" {
			line := fmt.Sprintf("repo: %d anchor(s) verified against %s", anchorsOK, repo)
			if skippedToken > 0 {
				line += fmt.Sprintf(", %d token-bearing anchor(s) skipped (supply --var to check them)", skippedToken)
			}
			out.outf("%s", line)
		}
	}

	if len(findings) > 0 {
		return exitValidation
	}
	return exitOK
}

// parseScaffyValidateArgs parses `bp scaffy validate`'s argument shape:
// positional paths plus the opt-in --repo <root> (or --repo=<root>) and a
// repeatable --var K=V (or --var=K=V, split on the FIRST = so values may
// carry =). A dangling --repo/--var, an empty var key, a missing =, a
// duplicate var key, a second --repo, or any other flag is a usage error.
func parseScaffyValidateArgs(args []string) (paths []string, repo string, vars map[string]string, errMsg string) {
	vars = map[string]string{}
	repoSet := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--repo":
			if i+1 >= len(args) {
				return nil, "", nil, "--repo needs a <root> argument"
			}
			i++
			if repoSet {
				return nil, "", nil, "duplicate --repo"
			}
			repo, repoSet = args[i], true
		case strings.HasPrefix(a, "--repo="):
			if repoSet {
				return nil, "", nil, "duplicate --repo"
			}
			repo, repoSet = strings.TrimPrefix(a, "--repo="), true
		case a == "--var", strings.HasPrefix(a, "--var="):
			var kv string
			if a == "--var" {
				if i+1 >= len(args) {
					return nil, "", nil, "--var needs a K=V argument"
				}
				i++
				kv = args[i]
			} else {
				kv = strings.TrimPrefix(a, "--var=")
			}
			eq := strings.Index(kv, "=")
			if eq <= 0 {
				return nil, "", nil, fmt.Sprintf("malformed --var %q — expected K=V", kv)
			}
			k, v := kv[:eq], kv[eq+1:]
			if _, dup := vars[k]; dup {
				return nil, "", nil, fmt.Sprintf("duplicate --var %q", k)
			}
			vars[k] = v
		case strings.HasPrefix(a, "-") && a != "-":
			return nil, "", nil, fmt.Sprintf("unknown validate flag %q", a)
		default:
			paths = append(paths, a)
		}
	}
	if len(vars) > 0 && !repoSet {
		return nil, "", nil, "--var only applies with --repo (text-level validate takes no vars)"
	}
	return paths, repo, vars, ""
}

// runScaffyFmt is `bp scaffy fmt [--check] <path>...`. Without --check it
// rewrites each non-canonical file in place (exit 0); with --check it lists
// the non-fixpoint files, writes NOTHING, and exits 5 when any exist (D27).
// A file fmt cannot canonicalize (unclosed fence — the payload boundary is
// undecidable) is a validation-level red, never a rewrite.
func runScaffyFmt(out *writer, args []string) int {
	check := false
	paths, badFlag := splitScaffyArgs(args, func(a string) bool {
		if a == "--check" {
			check = true
			return true
		}
		return false
	})
	if badFlag != "" {
		return usageErrf(out, func() { printScaffyFmtHelp(out) }, "unknown fmt flag %q", badFlag)
	}
	if len(paths) == 0 {
		return usageErrf(out, func() { printScaffyFmtHelp(out) }, "scaffy fmt needs at least one <path>")
	}

	files, err := collectScaffyFiles(paths)
	if err != nil {
		return useError(out, "io", "scaffy fmt: "+err.Error(), exitNotFound)
	}

	var changed []string
	for _, f := range files {
		src, rerr := os.ReadFile(f)
		if rerr != nil {
			return useError(out, "io", "scaffy fmt: "+rerr.Error(), exitNotFound)
		}
		formatted, ferr := scaffy.Format(src)
		if ferr != nil {
			msg := fmt.Sprintf("scaffy fmt: %s: %v", f, ferr)
			// refuseWithRemedy, not a bare userErr: this refusal's whole remedy
			// is the follow-up command, and the human shape used to print the
			// parse error with no word about `bp scaffy validate`. (The two
			// sibling refusals below already show their per-finding hints
			// inline, so they keep their own rendering.)
			refuseWithRemedy(out, "validation", msg, "run `bp scaffy validate` for the full findings")
			return exitValidation
		}
		if bytes.Equal(formatted, src) {
			continue
		}
		changed = append(changed, f)
		if check {
			continue // --check never writes
		}
		mode := fs.FileMode(0o644)
		if info, serr := os.Stat(f); serr == nil {
			mode = info.Mode().Perm()
		}
		if werr := os.WriteFile(f, formatted, mode); werr != nil {
			return useError(out, "io", "scaffy fmt: "+werr.Error(), exitNotFound)
		}
	}

	if out.machineOut() {
		fmtMode := "write"
		if check {
			fmtMode = "check"
		}
		changedJSON := make([]any, 0, len(changed))
		for _, f := range changed {
			changedJSON = append(changedJSON, f)
		}
		out.emitStructured(map[string]any{
			"ok":      !check || len(changed) == 0,
			"mode":    fmtMode,
			"files":   len(files),
			"changed": changedJSON,
		})
	} else {
		for _, f := range changed {
			out.outf("%s", f)
		}
		switch {
		case check && len(changed) > 0:
			out.outf("%d file(s) not canonical (run `bp scaffy fmt` to rewrite)", len(changed))
		case check:
			out.outf("canonical: %d file(s) already a fixpoint", len(files))
		case len(changed) > 0:
			out.outf("rewrote %d of %d file(s)", len(changed), len(files))
		default:
			out.outf("canonical: %d file(s) already a fixpoint", len(files))
		}
	}

	if check && len(changed) > 0 {
		return exitValidation
	}
	return exitOK
}

// runScaffyRun is `bp scaffy run <command.scaffy> --var K=V...`. Validate-first
// (the engine's ValidateFile pre-gate refuses on ANY finding — exit 5, nothing
// applied), then scaffy.Run applies the ops, persists the fat receipt under
// .scaffy/receipts/ and executes the closing asserts (D33–D40). The repo root
// is the cwd — the same resolution every IN path in the corpus assumes (D35).
// The global --dry-run computes everything and touches nothing (D39).
func runScaffyRun(out *writer, g globals, args []string) int {
	path, vars, uerr := parseScaffyVarArgs("run", args)
	if uerr != "" {
		return usageErrf(out, func() { printScaffyRunHelp(out) }, "scaffy run: %s", uerr)
	}
	root, err := os.Getwd()
	if err != nil {
		return useError(out, "io", "scaffy run: "+err.Error(), exitNotFound)
	}
	// A PULLED command (adjacent .provenance.json sidecar) is consent-gated
	// before a real run (D49): dry-run first, enumerate the substituted CMDs,
	// then --yes or an interactive confirm. The gate lives with the rest of
	// the remote surface in scaffy_remote_cmd.go; sidecar-less (repo-authored)
	// files skip it entirely — the W3 behavior, unchanged.
	if !g.dryRun && scaffyIsPulled(path) {
		proceed, code := scaffyRunConsent(out, g, path, vars, root)
		if !proceed {
			return code
		}
	}
	report, err := scaffy.Run(scaffy.RunOptions{CommandPath: path, Vars: vars, DryRun: g.dryRun, RepoRoot: root})
	if err != nil {
		return scaffyEngineError(out, "run", err, func() { printScaffyRunHelp(out) })
	}
	return renderScaffyReport(out, "run", report)
}

// runScaffyRemove is `bp scaffy remove <command.scaffy> --var K=V...` —
// RECEIPT REPLAY (D36): load the receipt keyed by command + the SAME vars the
// run was applied with, invert its ops in reverse, drift-refused per op. A
// DIRECTION-remove command is a `bp scaffy run` target, never an object of
// `remove` — the engine refuses it citing D36 and the CLI maps that to a
// usage error (exit 2). A missing receipt is fs.ErrNotExist-shaped → exit 4;
// SCAFFY-DRIFT → exit 5 with nothing written.
func runScaffyRemove(out *writer, g globals, args []string) int {
	path, vars, uerr := parseScaffyVarArgs("remove", args)
	if uerr != "" {
		return usageErrf(out, func() { printScaffyRemoveHelp(out) }, "scaffy remove: %s", uerr)
	}
	root, err := os.Getwd()
	if err != nil {
		return useError(out, "io", "scaffy remove: "+err.Error(), exitNotFound)
	}
	report, err := scaffy.Remove(scaffy.RemoveOptions{CommandPath: path, Vars: vars, DryRun: g.dryRun, RepoRoot: root})
	if err != nil {
		return scaffyEngineError(out, "remove", err, func() { printScaffyRemoveHelp(out) })
	}
	return renderScaffyReport(out, "remove", report)
}

// parseScaffyVarArgs hand-rolls the run/remove argument shape: exactly one
// positional <command.scaffy> plus a repeatable --var K=V (both `--var K=V`
// and `--var=K=V` spellings). Values split on the FIRST `=` so a value may
// itself carry `=`; an empty key, a missing `=`, a dangling --var, a duplicate
// key, or any other flag is a usage error (returned as errMsg — exit 2 at the
// caller). The D37 contract (unknown/missing/newline vars) is enforced by the
// engine and surfaces as a VarError, also exit 2.
func parseScaffyVarArgs(verb string, args []string) (path string, vars map[string]string, errMsg string) {
	vars = map[string]string{}
	var paths []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		var kv string
		switch {
		case a == "--var":
			if i+1 >= len(args) {
				return "", nil, "--var needs a K=V argument"
			}
			i++
			kv = args[i]
		case strings.HasPrefix(a, "--var="):
			kv = strings.TrimPrefix(a, "--var=")
		case strings.HasPrefix(a, "-") && a != "-":
			return "", nil, fmt.Sprintf("unknown %s flag %q", verb, a)
		default:
			paths = append(paths, a)
			continue
		}
		eq := strings.Index(kv, "=")
		if eq <= 0 {
			return "", nil, fmt.Sprintf("malformed --var %q — expected K=V", kv)
		}
		k, v := kv[:eq], kv[eq+1:]
		if _, dup := vars[k]; dup {
			return "", nil, fmt.Sprintf("duplicate --var %q", k)
		}
		vars[k] = v
	}
	if len(paths) != 1 {
		return "", nil, fmt.Sprintf("%s needs exactly one <command.scaffy> (got %d)", verb, len(paths))
	}
	return paths[0], vars, ""
}

// scaffyEngineError maps a Run/Remove error onto the exit-code scheme:
//
//	VarError (D37 contract + the D36 direction-remove refusal) → usage, 2
//	ValidationError (pre-gate findings)                        → 5
//	DriftError (SCAFFY-DRIFT refusal, nothing written)         → 5
//	PathMissingError / fs.ErrNotExist (command file, receipt)  → 4
//	ApplyError + anything else (guard/anchor/engine defect)    → 5
func scaffyEngineError(out *writer, verb string, err error, usageHelp func()) int {
	var (
		varErr   *scaffy.VarError
		valErr   *scaffy.ValidationError
		driftErr *scaffy.DriftError
		pathErr  *scaffy.PathMissingError
	)
	switch {
	case errors.As(err, &varErr):
		return usageErrf(out, usageHelp, "scaffy %s: %v", verb, err)
	case errors.As(err, &valErr):
		if !renderErrorEnvelope(out, "validation", err.Error(), "", "run `bp scaffy validate` for the full findings") {
			for _, f := range valErr.Findings {
				out.outf("%s", f.String())
				if f.Hint != "" {
					out.outf("  hint: %s", f.Hint)
				}
			}
			out.userErr("scaffy %s: command failed validation — nothing applied", verb)
		}
		return exitValidation
	case errors.As(err, &driftErr):
		if !renderErrorEnvelope(out, "drift", err.Error(), "", "resolve the drifted region by hand (or remove the later sibling first), then retry") {
			for _, f := range driftErr.Findings {
				out.outf("%s", f.String())
			}
			out.userErr("scaffy %s: drift refusal — nothing written", verb)
		}
		return exitValidation
	case errors.As(err, &pathErr), errors.Is(err, fs.ErrNotExist):
		return useError(out, "not_found", fmt.Sprintf("scaffy %s: %v", verb, err), exitNotFound)
	default:
		return useError(out, "apply", fmt.Sprintf("scaffy %s: %v", verb, err), exitValidation)
	}
}

// renderScaffyReport renders a Run/Remove report in the house voice (D39) or
// as the machine envelope, and returns the exit code: 5 when an executed
// assert failed (report.Ok false), else 0 — a full-skip no-op is success.
func renderScaffyReport(out *writer, verb string, rep *scaffy.RunReport) int {
	if out.machineOut() {
		env := map[string]any{
			"ok":          rep.Ok,
			"command":     rep.Command,
			"direction":   rep.Direction,
			"vars":        toGeneric(rep.Vars),
			"ops":         toGeneric(rep.Ops),
			"asserts":     toGeneric(rep.Asserts),
			"receipt":     rep.Receipt,
			"duration_ms": rep.DurationMS,
		}
		if rep.DryRun {
			env["dry_run"] = true
			env["diffs"] = toGeneric(rep.Diffs)
		}
		out.emitStructured(env)
	} else {
		for _, op := range rep.Ops {
			out.outf("%s", scaffyOpLine(op, rep.DryRun))
		}
		if rep.DryRun {
			for _, d := range rep.Diffs {
				out.outf("--- %s", d.Path)
				for _, l := range d.Lines {
					out.outf("%s", l)
				}
			}
		}
		for _, a := range rep.Asserts {
			out.outf("%s", scaffyAssertLine(a))
		}
		if rep.Receipt != "" && !rep.DryRun && verb == "run" {
			out.outf("receipt: %s", rep.Receipt)
		}
		out.outf("%s", scaffySummaryLine(verb, rep))
	}
	if !rep.Ok {
		return exitValidation
	}
	return exitOK
}

// scaffyOpLine is one op's status line (D39 vocabulary: ● created ·
// ○ injected @MARK · ○ replaced @MARK · = skipped + reason ·
// ✕ deleted/removed · ● restored). Dry-run speaks in would-form.
func scaffyOpLine(op scaffy.OpResult, dry bool) string {
	glyph, word := "●", op.Status
	switch op.Status {
	case scaffy.OpInjected, scaffy.OpReplaced:
		glyph = "○"
	case scaffy.OpSkipped:
		glyph = "="
	case scaffy.OpDeleted, scaffy.OpRemoved:
		glyph = "✕"
	}
	if dry {
		would := map[string]string{
			scaffy.OpCreated: "would create", scaffy.OpInjected: "would inject",
			scaffy.OpReplaced: "would replace",
			scaffy.OpDeleted:  "would delete", scaffy.OpRemoved: "would remove",
			scaffy.OpRestored: "would restore", scaffy.OpSkipped: "would skip",
		}
		if w, ok := would[op.Status]; ok {
			word = w
		}
	}
	line := fmt.Sprintf("%s %s %s", glyph, word, op.Path)
	if op.Mark != "" && op.Status != scaffy.OpCreated {
		line += " @MARK:" + op.Mark
	}
	if op.Reason != "" {
		line += " — " + op.Reason
	}
	return line
}

// scaffyAssertLine is ONE line per assertion (D39 — per-surface grouping is
// dropped; a CMD echo strips its trailing hash-comment for display only).
func scaffyAssertLine(a scaffy.AssertResult) string {
	subject := a.Path
	if a.Kind == "cmd" {
		subject = stripTrailingHashComment(a.Text)
	} else if a.Text != "" {
		subject = fmt.Sprintf("%s %q", a.Path, a.Text)
	}
	switch a.Status {
	case scaffy.AssertPass:
		return fmt.Sprintf("✔ pass %s %s", a.Kind, subject)
	case scaffy.AssertFail:
		line := fmt.Sprintf("✕ fail %s %s", a.Kind, subject)
		if a.Detail != "" {
			line += " — " + a.Detail
		}
		return line
	case scaffy.AssertDeferred:
		return fmt.Sprintf("… deferred %s %s — TIER ci, runs in the PR", a.Kind, subject)
	case scaffy.AssertWouldRun:
		return fmt.Sprintf("… would run %s %s", a.Kind, subject)
	}
	return fmt.Sprintf("? %s %s %s", a.Status, a.Kind, subject)
}

// stripTrailingHashComment drops a trailing ` # …` sh comment from a CMD echo.
// Display-only — the executed string is always the verbatim Assert text (D38).
func stripTrailingHashComment(s string) string {
	if i := strings.Index(s, " #"); i >= 0 {
		return strings.TrimRight(s[:i], " ")
	}
	return s
}

// scaffySummaryLine is the closing line: "applied — N created, M injected,
// K mark(s), duration" (or the remove/dry-run/no-op variants, D39).
func scaffySummaryLine(verb string, rep *scaffy.RunReport) string {
	counts := map[string]int{}
	marks, skipped := 0, 0
	for _, op := range rep.Ops {
		if op.Status == scaffy.OpSkipped {
			skipped++
			continue
		}
		counts[op.Status]++
		if op.Mark != "" {
			marks++
		}
	}
	var parts []string
	for _, s := range []string{scaffy.OpCreated, scaffy.OpInjected, scaffy.OpReplaced, scaffy.OpRestored, scaffy.OpRemoved, scaffy.OpDeleted} {
		if counts[s] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", counts[s], s))
		}
	}
	if marks > 0 {
		parts = append(parts, fmt.Sprintf("%d mark(s)", marks))
	}
	if skipped > 0 {
		parts = append(parts, fmt.Sprintf("%d skipped", skipped))
	}
	dur := fmt.Sprintf("%dms", rep.DurationMS)

	if rep.DryRun {
		if len(parts) == 0 || !wouldMutate(rep) {
			return fmt.Sprintf("dry-run — no-op: nothing would change (%s), %s", strings.Join(orNone(parts), ", "), dur)
		}
		return fmt.Sprintf("dry-run — %s, %s; nothing written, no receipt, no CMDs run", strings.Join(parts, ", "), dur)
	}
	if !rep.Mutated {
		if verb == "remove" {
			return fmt.Sprintf("no-op — already retracted (%s), %s", strings.Join(orNone(parts), ", "), dur)
		}
		return fmt.Sprintf("no-op — nothing to do (%s), %s", strings.Join(orNone(parts), ", "), dur)
	}
	head := "applied"
	if verb == "remove" {
		head = "removed"
	}
	line := fmt.Sprintf("%s — %s, %s", head, strings.Join(parts, ", "), dur)
	if !rep.Ok {
		line += " — ASSERT FAILED"
	}
	return line
}

// wouldMutate reports whether a dry-run computed any pending change.
func wouldMutate(rep *scaffy.RunReport) bool {
	for _, op := range rep.Ops {
		if op.Status != scaffy.OpSkipped {
			return true
		}
	}
	return false
}

// orNone renders an empty part list as "all skipped" for the no-op lines.
func orNone(parts []string) []string {
	if len(parts) == 0 {
		return []string{"all skipped"}
	}
	return parts
}

// splitScaffyArgs separates positional paths from flags. local (when non-nil)
// claims verb-local flags; any other dash token is returned as badFlag so the
// caller can raise the usage error with its own help.
func splitScaffyArgs(args []string, local func(string) bool) (paths []string, badFlag string) {
	for _, a := range args {
		if local != nil && local(a) {
			continue
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			return nil, a
		}
		paths = append(paths, a)
	}
	return paths, ""
}

// collectScaffyFiles expands each arg: a directory contributes its *.scaffy
// files (sorted, non-recursive); a plain file passes through as-is. A path
// that does not exist, or a path set that yields zero files, is an error —
// fail-loud per the scaffy doctrine, never a vacuous green.
func collectScaffyFiles(paths []string) ([]string, error) {
	var files []string
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		if info.IsDir() {
			matches, gerr := filepath.Glob(filepath.Join(p, "*.scaffy"))
			if gerr != nil {
				return nil, fmt.Errorf("%s: %v", p, gerr)
			}
			sort.Strings(matches)
			files = append(files, matches...)
			continue
		}
		files = append(files, p)
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no .scaffy files found under the given path(s)")
	}
	return files, nil
}

// scaffyFindingsJSON shapes findings for the machine envelope. Hint is
// omitted when empty so the JSON mirrors the human view's optional hint line.
func scaffyFindingsJSON(findings []scaffy.Finding) []any {
	arr := make([]any, 0, len(findings))
	for _, f := range findings {
		m := map[string]any{
			"file":    f.File,
			"line":    f.Line,
			"rule":    f.Rule,
			"message": f.Msg,
		}
		if f.Hint != "" {
			m["hint"] = f.Hint
		}
		arr = append(arr, m)
	}
	return arr
}

func printScaffyHelp(out *writer) {
	out.outf(`usage: bp scaffy <validate|fmt|run|remove|describe|discover> [flags] <path>...

Validate, format, apply and retract .scaffy command files (the pinned Scaffy
v2 grammar + engine, internal/scaffy). Pure local: no server, no auth, no
manifest — run/remove operate on the repo at the current working directory.

commands:
  validate <path>...        parse + lint each file; a directory validates its
                            *.scaffy files. Findings print compiler-style as
                            file:line: RULE-ID message, each with a fix hint.
  fmt [--check] <path>...   rewrite files to canonical structural form in
                            place; --check lists non-fixpoint files and
                            writes nothing. Comment prose and payload bytes
                            are never touched.
  run <command.scaffy> --var K=V...
                            validate-first, then apply the command's ops to
                            the cwd tree, write the fat receipt under
                            .scaffy/receipts/, and run the closing asserts
                            (LOCAL executed, TIER ci deferred to the PR).
                            Guarded re-runs skip clean. Honours --dry-run.
  remove <command.scaffy> --var K=V...
                            receipt replay: invert the run recorded for this
                            command + exact vars, in reverse, drift-refused
                            per op. DIRECTION "remove" commands run FORWARD
                            (bp scaffy run) — never through remove (D36).
  describe <command.scaffy|name>
                            read a command's contract straight off the AST —
                            header, per-variable synthesized kind, op counts
                            keyed by shape, and closing asserts. No run, no
                            repo, no server. -o json for the machine envelope.
  discover [--since <date|duration>] [--until <rev>] [--min-support N] [--top N]
                            mine git history for Scaffy candidates: ranked
                            accretion files (commits × co-change partners ×
                            add-shape split) and co-creation pairs, each
                            cross-referenced against the served catalog
                            (SERVED / PARTIAL / UNSERVED). Deterministic —
                            the window pins to the until commit's day, never
                            wall-clock. Read-only; frequency evidence only.
  pull <concept>[/<variant>]
                            fetch a command document from the connected
                            server: validate-first, byte-identical write +
                            provenance sidecar, never executes anything.
  ls --remote               the server's command catalog. pull and ls are
                            the two server-touching verbs; running a PULLED
                            command is consent-gated (D49).

examples:
  bp scaffy validate scaffy/commands/             # lint the whole corpus
  bp scaffy fmt --check scaffy/commands/          # CI fixpoint gate
  bp scaffy run scaffy/commands/add-migration.scaffy \
      --var Ts=20260716120000 --var MigrationName=AddFoo \
      --var TableName=documents --var ColumnName=foo_at \
      --var ColumnType=:utc_datetime_usec        # scaffold + receipt
  bp scaffy run add-oban-worker.scaffy --var ... --dry-run   # preview only
  bp scaffy remove scaffy/commands/add-migration.scaffy --var ...  # retract
  bp scaffy discover --top 40                     # mine accretion candidates

exit codes:
  0  clean — applied / removed / no-op / no findings / already canonical
  2  usage error (bad flag, malformed --var, remove of a DIRECTION-remove)
  4  missing path / unreadable or unwritable file / no receipt to remove
  5  validation findings, guard/assert failures, SCAFFY-DRIFT, or
     non-fixpoint files (fmt --check)`)
}

func printScaffyRunHelp(out *writer) {
	out.outf(`usage: bp scaffy run <command.scaffy> --var K=V...

Apply one .scaffy command to the repo at the current working directory.
Validate-first: the full validator must report ZERO findings before any op
applies (exit 5 otherwise, nothing written). Ops apply in order over an
in-memory overlay — a failing op writes NOTHING; guarded ops (IF ABSENT,
planted MARKs, ASLONG) skip clean on re-runs, so a full re-run is a no-op.
A mutating run writes a fat receipt to .scaffy/receipts/, keyed by the
command + the exact --var set — bp scaffy remove replays that receipt.
Closing asserts then run: FILE checks and LOCAL CMDs execute (sh -c from the
repo root); TIER ci CMDs are reported deferred, never run locally.

flags:
  --var K=V   set one declared VARIABLE (repeatable; split on the FIRST =,
              so values may contain =). Values must be single-line. Every
              declared variable is required; unknown names are refused.

--dry-run (global) computes everything and touches NOTHING: would-lines per
op, a -/+ per-file diff, LOCAL CMDs listed as would-run, no receipt, exit 0.

-o json|-o yaml emits {ok, command, direction, vars, ops, asserts, receipt,
duration_ms}.

examples:
  bp scaffy run scaffy/commands/add-migration.scaffy \
      --var Ts=$(date -u +%%Y%%m%%d%%H%%M%%S) --var MigrationName=AddFoo \
      --var TableName=documents --var ColumnName=foo_at \
      --var ColumnType=:utc_datetime_usec
  bp scaffy run scaffy/commands/add-oban-worker.scaffy --var ... --dry-run

exit codes:
  0  applied cleanly, or a guarded no-op re-run
  2  usage error — malformed --var, unknown flag, var-contract violation
  4  command file or an op's target file missing from the tree
  5  validation findings, apply defect (anchor/guard), or a failed assert`)
}

func printScaffyRemoveHelp(out *writer) {
	out.outf(`usage: bp scaffy remove <command.scaffy> --var K=V...

Retract a previously applied command by RECEIPT REPLAY (D36): load the fat
receipt keyed by this command + the SAME --var set the run used, and invert
its ops in reverse over an overlay. Drift-refusal per op: current bytes must
match the recorded post-image (invert) or the pre-image state (already
retracted — clean skip); anything else refuses fail-loud with a file:line
SCAFFY-DRIFT message and writes NOTHING. Within a mark family, remove later
siblings first (LIFO). The receipt persists — a second remove is a no-op.

DIRECTION "remove" commands (authored inverses, e.g. remove-docs-card) run
FORWARD via bp scaffy run — giving one to this verb is a usage error (D36).

flags:
  --var K=V   the exact vars the run was applied with (repeatable) — they
              key the receipt lookup; different vars miss (exit 4).

--dry-run (global) reports what would be inverted and touches nothing.

-o json|-o yaml emits {ok, command, direction, vars, ops, asserts, receipt,
duration_ms}.

examples:
  bp scaffy remove scaffy/commands/add-migration.scaffy --var Ts=... --var ...
  bp scaffy remove scaffy/commands/add-oban-worker.scaffy --var ... --dry-run

exit codes:
  0  removed byte-clean, or already retracted (idempotent no-op)
  2  usage error — malformed --var, DIRECTION-remove given to remove (D36)
  4  command file missing, or no receipt for this command + vars
  5  SCAFFY-DRIFT refusal or validation findings — nothing written`)
}

func printScaffyValidateHelp(out *writer) {
	out.outf(`usage: bp scaffy validate [--repo <root>] [--var K=V...] <path>...

Parse + lint .scaffy command files against the frozen rule catalog (E-xxx
error / W-xxx warn / P-xxx parse — see internal/scaffy doc.go). Each path is
a .scaffy file or a directory (validates its *.scaffy files). Text-level by
default (D27): no repo access. Every finding prints as

  file:line: RULE-ID message
    hint: the likely fix

--repo <root> adds the opt-in repo-aware layer (D5): after a file validates
text-clean, every IN-op's target file must exist under <root> and every
structural anchor must resolve there — uniquely for REPLACE/REMOVE. Drift is
reported with repo rule IDs (R-001 missing-file / R-002 anchor-not-found /
R-003 anchor-ambiguous). A closing summary always names the anchors verified
and the token-bearing anchors skipped.

flags:
  --repo <root>  check anchors against the working tree rooted at <root>
  --var K=V      resolve one declared VARIABLE so its {{.token}}-bearing
                 anchors can be checked (repeatable; requires the full
                 declared set, like run). Only valid with --repo; without
                 it, token-bearing anchors are skipped and counted.

-o json|-o yaml emits {ok, files, findings:[{file,line,rule,message,hint}]}
(plus repo, anchors_ok, anchors_skipped_token under --repo).

examples:
  bp scaffy validate scaffy/commands/
  bp scaffy validate add-plugin.scaffy add-migration.scaffy
  bp scaffy validate --repo . scaffy/commands/          # anchor drift sweep
  bp scaffy validate --repo . scaffy/commands/add-oban-worker.scaffy \
      --var WorkerName=Foo --var worker_name=foo        # check token anchors
  bp scaffy validate scaffy/commands/ -o json | jq '.findings'

exit codes:
  0  every file clean
  2  usage error
  4  missing path / unreadable file
  5  one or more findings (text or repo-aware drift)`)
}

func printScaffyFmtHelp(out *writer) {
	out.outf(`usage: bp scaffy fmt [--check] <path>...

Rewrite .scaffy files to canonical structural form in place: keyword lines
single-spaced and flush-left, fence lines normalized. Comment prose and
payload bytes are NEVER rewritten, and fmt is idempotent — the committed
corpus is a fixpoint (D27).

flags:
  --check   list files that are not a fixpoint and write nothing — the CI
            gate form; exits 5 when any file would change

-o json|-o yaml emits {ok, mode, files, changed:[...]}.

examples:
  bp scaffy fmt scaffy/commands/
  bp scaffy fmt --check scaffy/commands/

exit codes:
  0  all files already canonical / rewritten successfully
  2  usage error
  4  missing path / unreadable or unwritable file
  5  --check found non-fixpoint file(s), or a file fmt cannot canonicalize`)
}
