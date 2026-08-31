package cli

// paper_wc_cmd.go — the BPML working copy (masterplan W3): `bp paper
// pull|status|diff|push`, git's verbs because the sync problem is git's
// problem. Papers live as files under <repo-root>/.barkpark/papers/ next to a
// pristine snapshot and a rev anchor; THIN by law — the CLI never parses BPML.
// `push` sends the edited text and the SERVER derives the op batch
// (apiclient/paper.go → POST /papers/:slug/sync), so the grammar keeps its
// single Elixir owner and nobody hand-writes an op. These verbs share the
// `paper` noun with view/capture (paper_cmd.go): read verbs render, working-
// copy verbs edit.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

const paperStateFile = "state.json"

type paperAnchor struct {
	Server   string `json:"server"`
	Rev      string `json:"rev"`
	PulledAt string `json:"pulled_at"`
}

type paperWCState struct {
	Papers map[string]paperAnchor `json:"papers"`
}

// paperWCDir resolves <repo-root>/.barkpark/papers: BARKPARK_PAPER_DIR wins
// (tests, unusual layouts), else the directory holding .barkpark.json (the
// same root-walk the repo context file uses), else the cwd.
func paperWCDir() (string, error) {
	if env := os.Getenv("BARKPARK_PAPER_DIR"); env != "" {
		return env, nil
	}

	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}

	root := cwd
	if path, ok := findRepoFile(cwd); ok {
		root = filepath.Dir(path)
	}

	return filepath.Join(root, ".barkpark", "papers"), nil
}

func paperWCFile(dir, slug string) string { return filepath.Join(dir, slug+".bpml") }

func paperWCPristine(dir, slug string) string {
	return filepath.Join(dir, ".pristine", slug+".bpml")
}

func loadPaperWCState(dir string) (*paperWCState, error) {
	st := &paperWCState{Papers: map[string]paperAnchor{}}

	raw, err := os.ReadFile(filepath.Join(dir, paperStateFile))
	if os.IsNotExist(err) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, st); err != nil {
		return nil, fmt.Errorf("%s is unreadable: %w", filepath.Join(dir, paperStateFile), err)
	}
	if st.Papers == nil {
		st.Papers = map[string]paperAnchor{}
	}
	return st, nil
}

func savePaperWCState(dir string, st *paperWCState) error {
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, paperStateFile), append(raw, '\n'), 0o644)
}

func paperWCClient(ctx manifest.Context) *apiclient.Client {
	return apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	})
}

// writePaperWCCopy writes the working file AND the pristine snapshot — the
// pair every later status/diff/push compares against.
func writePaperWCCopy(dir, slug, bpml string) error {
	if err := os.MkdirAll(filepath.Join(dir, ".pristine"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(paperWCFile(dir, slug), []byte(bpml), 0o644); err != nil {
		return err
	}
	return os.WriteFile(paperWCPristine(dir, slug), []byte(bpml), 0o644)
}

// ── pull ────────────────────────────────────────────────────────────────────

func runPaperPull(out *writer, g globals, ctx manifest.Context, args []string) int {
	if len(args) != 1 {
		out.userErr("paper pull: exactly one <slug>")
		usagePaper(out, false)
		return exitUsage
	}
	slug := args[0]

	dir, err := paperWCDir()
	if err != nil {
		out.userErr("paper pull: %v", err)
		return exitGeneric
	}

	bpml, rev, apiErr, err := paperWCClient(ctx).PaperPullBpml(slug)
	if err != nil {
		out.userErr("paper pull %s: %v", slug, err)
		return exitGeneric
	}
	if apiErr != nil {
		renderPaperAPIErr(out, "pull "+slug, apiErr)
		return exitGeneric
	}

	if err := writePaperWCCopy(dir, slug, bpml); err != nil {
		out.userErr("paper pull %s: %v", slug, err)
		return exitGeneric
	}

	st, err := loadPaperWCState(dir)
	if err != nil {
		out.userErr("paper pull %s: %v", slug, err)
		return exitGeneric
	}
	st.Papers[slug] = paperAnchor{Server: ctx.Server, Rev: rev, PulledAt: time.Now().UTC().Format(time.RFC3339)}
	if err := savePaperWCState(dir, st); err != nil {
		out.userErr("paper pull %s: %v", slug, err)
		return exitGeneric
	}

	if out.output == "json" || out.output == "yaml" {
		out.renderJSON(map[string]any{"ok": true, "slug": slug, "rev": rev, "path": paperWCFile(dir, slug), "bytes": len(bpml)})
		return exitOK
	}
	out.outf("pulled %s @ rev %s → %s (%d bytes)", slug, rev, paperWCFile(dir, slug), len(bpml))
	return exitOK
}

// ── status ──────────────────────────────────────────────────────────────────

func runPaperStatus(out *writer, g globals, ctx manifest.Context, args []string) int {
	dir, err := paperWCDir()
	if err != nil {
		out.userErr("paper status: %v", err)
		return exitGeneric
	}

	st, err := loadPaperWCState(dir)
	if err != nil {
		out.userErr("paper status: %v", err)
		return exitGeneric
	}

	var slugs []string
	if len(args) == 1 {
		slugs = args
	} else {
		for slug := range st.Papers {
			slugs = append(slugs, slug)
		}
		sort.Strings(slugs)
	}

	if len(slugs) == 0 {
		out.outf("no tracked papers — start with: bp paper pull <slug>")
		return exitOK
	}

	client := paperWCClient(ctx)
	rows := make([]map[string]any, 0, len(slugs))

	for _, slug := range slugs {
		anchor, tracked := st.Papers[slug]
		row := map[string]any{"slug": slug, "tracked": tracked}

		if tracked {
			row["rev"] = anchor.Rev
			local, lerr := os.ReadFile(paperWCFile(dir, slug))
			pristine, perr := os.ReadFile(paperWCPristine(dir, slug))

			switch {
			case lerr != nil:
				row["local"] = "missing"
			case perr != nil:
				row["local"] = "no-pristine"
			case string(local) == string(pristine):
				row["local"] = "clean"
			default:
				row["local"] = "edited"
			}

			// The remote check is best-effort: offline is a fact to report,
			// never a failure that hides the local half. A 404 is NOT an
			// outage — for a scaffolded paper (rev-0 anchor, never pushed)
			// "the server has no such paper yet" is the expected truth, and
			// push is what will create it.
			if _, rev, apiErr, err := client.PaperPullBpml(slug); err != nil {
				row["remote"] = "unreachable"
			} else if apiErr != nil && apiErr.Status == 404 {
				row["remote"] = "absent (push will create it)"
			} else if apiErr != nil {
				row["remote"] = "unreachable"
			} else if rev == anchor.Rev {
				row["remote"] = "current"
			} else {
				row["remote"] = fmt.Sprintf("behind (server @ %s)", rev)
			}
		}

		rows = append(rows, row)
	}

	if out.output == "json" || out.output == "yaml" {
		out.renderJSON(map[string]any{"ok": true, "papers": rows})
		return exitOK
	}

	for _, row := range rows {
		if tracked, _ := row["tracked"].(bool); !tracked {
			out.outf("%s: not tracked — bp paper pull %s", row["slug"], row["slug"])
			continue
		}
		out.outf("%s @ %s · local %s · remote %s", row["slug"], row["rev"], row["local"], row["remote"])
	}
	return exitOK
}

// ── diff ────────────────────────────────────────────────────────────────────

func runPaperWCDiff(out *writer, g globals, args []string) int {
	if len(args) != 1 {
		out.userErr("paper diff: exactly one <slug>")
		usagePaper(out, false)
		return exitUsage
	}
	slug := args[0]

	dir, err := paperWCDir()
	if err != nil {
		out.userErr("paper diff: %v", err)
		return exitGeneric
	}

	local, err := os.ReadFile(paperWCFile(dir, slug))
	if err != nil {
		out.userErr("paper diff %s: no working copy — bp paper pull %s", slug, slug)
		return exitGeneric
	}
	pristine, err := os.ReadFile(paperWCPristine(dir, slug))
	if err != nil {
		out.userErr("paper diff %s: no pristine snapshot — bp paper pull %s", slug, slug)
		return exitGeneric
	}

	lines := paperWCDiffLines(strings.Split(string(pristine), "\n"), strings.Split(string(local), "\n"))
	if len(lines) == 0 {
		out.outf("%s: clean (local matches the last pull)", slug)
		return exitOK
	}
	for _, l := range lines {
		out.outf("%s", l)
	}
	return exitOK
}

// paperWCDiffLines is a minimal LCS line diff — enough to show an edit
// honestly. Unchanged runs collapse to a "… N unchanged" marker; the BPML
// files this walks are a few KB, so the quadratic table is fine.
func paperWCDiffLines(a, b []string) []string {
	n, m := len(a), len(b)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else if lcs[i+1][j] >= lcs[i][j+1] {
				lcs[i][j] = lcs[i+1][j]
			} else {
				lcs[i][j] = lcs[i][j+1]
			}
		}
	}

	var outLines []string
	changed := false
	sameRun := 0

	flushSame := func() {
		if sameRun > 0 {
			outLines = append(outLines, fmt.Sprintf("  … %d unchanged line(s)", sameRun))
			sameRun = 0
		}
	}

	i, j := 0, 0
	for i < n && j < m {
		switch {
		case a[i] == b[j]:
			sameRun++
			i++
			j++
		case lcs[i+1][j] >= lcs[i][j+1]:
			flushSame()
			outLines = append(outLines, "- "+a[i])
			changed = true
			i++
		default:
			flushSame()
			outLines = append(outLines, "+ "+b[j])
			changed = true
			j++
		}
	}
	for ; i < n; i++ {
		flushSame()
		outLines = append(outLines, "- "+a[i])
		changed = true
	}
	for ; j < m; j++ {
		flushSame()
		outLines = append(outLines, "+ "+b[j])
		changed = true
	}

	if !changed {
		return nil
	}
	flushSame()
	return outLines
}

// ── push ────────────────────────────────────────────────────────────────────

func runPaperPush(out *writer, g globals, ctx manifest.Context, args []string) int {
	check := false
	var pos []string
	for _, a := range args {
		switch a {
		case "--check":
			check = true
		default:
			pos = append(pos, a)
		}
	}
	if len(pos) != 1 {
		out.userErr("paper push: exactly one <slug>")
		usagePaper(out, false)
		return exitUsage
	}
	slug := pos[0]

	dir, err := paperWCDir()
	if err != nil {
		out.userErr("paper push: %v", err)
		return exitGeneric
	}

	local, err := os.ReadFile(paperWCFile(dir, slug))
	if err != nil {
		out.userErr("paper push %s: no working copy — bp paper new %s (fresh) or bp paper pull %s (existing) first", slug, slug, slug)
		return exitGeneric
	}

	// --check: the validate-all dry-run (POST /v1/plugins/bulldocs/papers/
	// validate). Every violation in one reply, NOTHING written, no anchor
	// touched — see the wall before the wall sees you.
	if check {
		return runPaperPushCheck(out, ctx, slug, string(local))
	}

	st, err := loadPaperWCState(dir)
	if err != nil {
		out.userErr("paper push %s: %v", slug, err)
		return exitGeneric
	}
	anchor, ok := st.Papers[slug]
	if !ok || anchor.Rev == "" {
		out.userErr("paper push %s: no rev anchor — bp paper pull %s first", slug, slug)
		return exitGeneric
	}
	if anchor.Server != "" && anchor.Server != ctx.Server {
		out.userErr("paper push %s: pulled from %s but the active server is %s — switch servers or re-pull",
			slug, anchor.Server, ctx.Server)
		return exitGeneric
	}

	result, apiErr, err := paperWCClient(ctx).PaperSync(slug, string(local), anchor.Rev)
	if err != nil {
		out.userErr("paper push %s: %v", slug, err)
		return exitGeneric
	}
	if apiErr != nil {
		renderPaperAPIErr(out, "push "+slug, apiErr)
		return exitGeneric
	}

	if result.Unchanged {
		if out.output == "json" || out.output == "yaml" {
			out.renderJSON(map[string]any{"ok": true, "slug": slug, "unchanged": true, "rev": result.Rev})
			return exitOK
		}
		out.outf("%s: nothing to push (working copy matches the server)", slug)
		return exitOK
	}

	// Converge on the server's canonical spelling — the post-normalization
	// truth — and advance the anchor to the new rev.
	if err := writePaperWCCopy(dir, slug, result.Bpml); err != nil {
		out.userErr("paper push %s: applied @ rev %s but the local rewrite failed: %v — re-pull to converge",
			slug, result.Rev, err)
		return exitGeneric
	}
	anchor.Rev = result.Rev
	anchor.PulledAt = time.Now().UTC().Format(time.RFC3339)
	// A scaffolded paper (bp paper new) anchors with no server — it was born
	// offline. Its first landed push binds the anchor to the server it created
	// the paper on, so the cross-server drift guard above works from then on.
	if anchor.Server == "" {
		anchor.Server = ctx.Server
	}
	st.Papers[slug] = anchor
	if err := savePaperWCState(dir, st); err != nil {
		out.userErr("paper push %s: applied @ rev %s but the anchor save failed: %v — re-pull to converge",
			slug, result.Rev, err)
		return exitGeneric
	}

	if out.output == "json" || out.output == "yaml" {
		out.renderJSON(map[string]any{"ok": true, "slug": slug, "rev": result.Rev, "op_count": result.OpCount})
		return exitOK
	}
	out.outf("pushed %s: %d op(s) applied, now @ rev %s (file converged on canonical)", slug, result.OpCount, result.Rev)
	return exitOK
}

// runPaperPushCheck POSTs the working copy to the validate-all dry-run
// (`POST /v1/plugins/bulldocs/papers/validate` — the same endpoint the create
// wall mirrors) and renders every violation. Read-only by contract: the server
// persists nothing and the local anchor/pristine are never touched. Exit 0
// when the wall would accept the document; exit 1 with the violation list when
// it would refuse.
func runPaperPushCheck(out *writer, ctx manifest.Context, slug, bpml string) int {
	payload, err := json.Marshal(map[string]string{"bpml": bpml})
	if err != nil {
		out.userErr("paper push %s --check: %v", slug, err)
		return exitGeneric
	}

	u := strings.TrimRight(ctx.Server, "/") + "/v1/plugins/bulldocs/papers/validate"
	headers := map[string]string{"Content-Type": "application/json"}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}

	status, body, err := doRequest("POST", u, headers, payload)
	if err != nil {
		out.userErr("paper push %s --check: %v", slug, err)
		return exitGeneric
	}
	if status < 200 || status >= 300 {
		renderPaperAPIErr(out, "push "+slug+" --check", decodePaperCheckErr(status, body))
		return exitGeneric
	}

	var verdict struct {
		Valid      bool `json:"valid"`
		Violations []struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Hint    string `json:"hint"`
			Line    int    `json:"line"`
		} `json:"violations"`
	}
	if jerr := json.Unmarshal(body, &verdict); jerr != nil {
		out.userErr("paper push %s --check: unparsable validate reply: %v", slug, jerr)
		return exitGeneric
	}

	if out.output == "json" || out.output == "yaml" {
		out.renderRaw(body)
		if verdict.Valid {
			return exitOK
		}
		return exitGeneric
	}

	if verdict.Valid {
		out.outf("%s: valid — the publish wall would accept this push (dry-run; nothing written)", slug)
		return exitOK
	}
	out.userErr("%s: the publish wall would refuse this push — %d violation(s):", slug, len(verdict.Violations))
	for _, v := range verdict.Violations {
		line := ""
		if v.Line > 0 {
			line = fmt.Sprintf("line %d: ", v.Line)
		}
		out.errf("  %s[%s] %s", line, v.Code, v.Message)
		if v.Hint != "" {
			out.errf("    fix: %s", v.Hint)
		}
	}
	return exitGeneric
}

// decodePaperCheckErr adapts a non-2xx validate reply into the shared
// PaperAPIErr renderer — same envelope shape as pull/sync refusals.
// It reads the envelope through internal/apierr and takes `error.errors` — the
// paper-specific teach list — in a SECOND pass, exactly as
// apiclient.decodePaperErr does. This function was a line-for-line fork of that
// one; both now share the parser, so a malformed teach list costs only the
// teach list instead of dropping code, message and hint together.
func decodePaperCheckErr(status int, body []byte) *apiclient.PaperAPIErr {
	env, ok := apierr.Parse(body)
	if !ok || env.Code == "" {
		msg := strings.TrimSpace(string(body))
		if len(msg) > 200 {
			msg = msg[:200] + "…"
		}
		return &apiclient.PaperAPIErr{Status: status, Code: fmt.Sprintf("http_%d", status), Message: msg}
	}
	var teach struct {
		Error struct {
			Errors []apiclient.PaperTeachErr `json:"errors"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &teach)
	return &apiclient.PaperAPIErr{
		Status: status, Code: env.Code, Message: env.Message,
		Hint: env.Hint, Errors: teach.Error.Errors,
	}
}

// renderPaperAPIErr prints the server's refusal the way the server teaches it:
// the envelope's message + hint, then each BPML teaching error with its line.
func renderPaperAPIErr(out *writer, what string, apiErr *apiclient.PaperAPIErr) {
	out.errf("paper %s: %s (%d): %s", what, apiErr.Code, apiErr.Status, apiErr.Message)
	if apiErr.Hint != "" {
		out.errf("  fix: %s", apiErr.Hint)
	}
	for _, te := range apiErr.Errors {
		line := ""
		if te.Line > 0 {
			line = fmt.Sprintf("line %d: ", te.Line)
		}
		out.errf("  %s%s — %s", line, te.Message, te.Hint)
	}
}
