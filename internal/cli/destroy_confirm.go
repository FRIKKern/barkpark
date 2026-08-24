package cli

// destroy_confirm.go is the destructive-op confirmation gate for the
// MANIFEST-DRIVEN command surface — the counterpart to hetzner_confirm.go,
// which gates the hand-wired `bp cloud hetzner …` verbs.
//
// WHY A SECOND GATE, AND WHY IT IS NOT A FORK OF THE FIRST. runCommand already
// carries one confirmation: the prod write-guard (run.go), `cmd.Writes &&
// isProd(...)`. It is the wrong instrument for a credential destroy on two
// counts, both measured with the shipped binary against the live manifest:
//
//   - It is keyed on the TARGET, not the OPERATION. `bp token revoke <id>`
//     against a local instance, or against any server whose /v1/meta advertises
//     production:false, skips the guard entirely — no prompt, no preview, the
//     credential is gone. Prod-ness is not what makes revoking a token
//     irreversible.
//   - When it does fire, it names the VERB and the SERVER and nothing else:
//     "⚠ PROD: token revoke writes to https://…". It never names the token. An
//     operator confirming a revoke is being asked to approve an id they cannot
//     see, which is the same as not being asked.
//
// So this gate is operation-keyed, server-agnostic, and its whole point is the
// preview line. It runs AFTER the prod guard (a prod credential destroy answers
// both) and immediately before the request is sent.
//
// The contract, matching confirmProdWrite's stream discipline — the sibling that
// guards this same manifest path — rather than hzConfirmDestroy's:
//
//   - --yes proceeds. The preview still prints: "print WHAT is being destroyed
//     before doing it" is the guarantee, and it must not evaporate in scripts.
//   - Non-TTY without --yes REFUSES, naming --yes. Deliberately the OPPOSITE of
//     hzConfirmDestroy's non-TTY pass-through: those verbs are hand-wired with
//     a flag-less script path as a documented hard guarantee, whereas nothing
//     scripted has ever reached these manifest verbs (they had no client-side
//     gate at all until now), so there is no such path to preserve — and a
//     credential destroy is the wrong place to fail open.
//   - Interactive: preview, then [y/N] on stderr. Anything but y/yes aborts and
//     NOTHING is sent.
//
// Adding a verb here is a one-line registry entry. It is a CLIENT-side table
// because the manifest carries no `destructive` field: `writes: true` is all a
// command declares, and it cannot tell `member-add` from `member-rm`.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/mattn/go-isatty"
)

// destroyStdin is the confirm prompt's input, and destroyStdinIsTTY decides
// whether the prompt can be answered at all. Package vars (the hzStdin seam
// idiom) so tests can drive the prompt with an in-memory reader.
var destroyStdin io.Reader = os.Stdin

// destroyStdinIsTTY gates on the ANSWER stream (stdin) and the PROMPT stream
// (stderr), exactly as confirmProdWrite does and deliberately NOT on stdout:
// `bp token revoke … -o json > receipt.json` leaves an operator at a terminal
// who can still answer.
var destroyStdinIsTTY = func(r io.Reader) bool {
	f, ok := r.(*os.File)
	return ok && isatty.IsTerminal(f.Fd()) && isatty.IsTerminal(os.Stderr.Fd())
}

// destroyTarget describes one destroy-tier manifest command: the human noun for
// what dies, the positional arg naming the victim, and the sibling LIST command
// whose inventory the preview is resolved from.
//
// lookupCmd/lookupKey/lookupMatch are what turn an opaque id into a sentence.
// The lookup is the command's own sibling read on the SAME scoped path with the
// SAME credentials — never a hand-rolled URL — so a workspace the caller cannot
// read is a workspace whose preview honestly comes back empty.
type destroyTarget struct {
	kind        string   // "token", "seat" — what the operator is destroying
	argName     string   // the positional arg that names it
	lookupNoun  string   // sibling list command, e.g. "token"
	lookupVerb  string   // e.g. "ls"
	lookupKey   string   // envelope key holding the rows, e.g. "tokens"
	lookupMatch []string // row fields the arg value may match, in order
	previewCols []string // row fields to show first, in order
}

// destroyTargets is the registry. Keyed on manifest command ID so a server that
// renames a noun/verb cannot silently un-gate the operation.
var destroyTargets = map[string]destroyTarget{
	// Irreversible: the credential is dead the moment this lands, and every
	// process holding it starts 401ing. The id is a UUID from `token ls`, so
	// without a preview the operator is confirming a string, not a decision.
	"token.revoke": {
		kind:        "token",
		argName:     "id",
		lookupNoun:  "token",
		lookupVerb:  "ls",
		lookupKey:   "tokens",
		lookupMatch: []string{"id"},
		previewCols: []string{"label", "name", "kind", "permissions", "dataset", "role", "last_used_at", "expires_at", "revoked_at"},
	},
	// Reversible by re-seating, but instantaneous: the human loses Studio and
	// API reach the moment it lands. The arg is already readable (an e-mail),
	// so the preview's job here is the ROLE — demoting your co-owner out of the
	// workspace and removing a `member` look identical on the command line.
	"workspace.member-rm": {
		kind:        "seat",
		argName:     "principal_ref",
		lookupNoun:  "workspace",
		lookupVerb:  "member-ls",
		lookupKey:   "members",
		lookupMatch: []string{"identity", "email", "principal_id", "id"},
		previewCols: []string{"identity", "principal_type", "role"},
	},
}

// destroyRefArgs re-resolves cmd's positional args so the gate can name the
// same target the request will. It reports gated=false — and does no work —
// for every command that is not in the registry, which is all but two of them.
//
// It re-runs splitArgs/bindArgs rather than threading the map out of
// buildManifestRequest because both are PURE: they read only the declared arg
// list and the tail, and neither touches os.Stdin (only buildBody does, which
// is why buildManifestRequest must still run exactly once). A parse error here
// is not this gate's to report — buildManifestRequest already surfaced it with
// the usage block — so it degrades to an empty map, which confirmDestroy reads
// as "nothing to preview".
func destroyRefArgs(cmd manifest.Command, tail []string) (map[string]string, bool) {
	if _, gated := destroyTargets[cmd.ID]; !gated {
		return nil, false
	}
	posArgs, _, err := splitArgs(cmd, tail)
	if err != nil {
		return map[string]string{}, true
	}
	argMap, err := bindArgs(cmd, posArgs)
	if err != nil {
		return map[string]string{}, true
	}
	return argMap, true
}

// requireStatedScope refuses a destroy whose workspace/project was never stated
// — it fell through to the baked "default" floor rather than coming from -w/-p,
// a set BARKPARK_* var, a repo .barkpark.json, or the saved config.
//
// WHY THIS IS NOT PARANOIA. `bp token revoke <id>` with no -w silently resolves
// to /w/default/p/default/... The server's cross-tenant rail then downgrades the
// misfire to a 404 — but ONLY while `default` is empty or unreachable. On a
// local instance `default` is THE real, populated workspace, which is precisely
// the shape an operator develops against. So the mechanism that makes this
// harmless is the last remaining layer, and it is the layer that varies by
// environment. A silent substitution on a credential destroy is the wrong
// default even where it currently costs nothing.
//
// SCOPED TO DESTROY-TIER, DELIBERATELY. Reads and non-destructive writes keep
// the ambient floor untouched; `bp token ls` with no -w still works exactly as
// before. Widening this to every scoped command would change behaviour shared
// across the whole CLI to buy nothing — the asymmetry is what justifies it here.
//
// It is keyed on PROVENANCE, never on the value: ctx.Workspace == "default"
// cannot tell `-w default` from no -w, and a workspace genuinely named `default`
// is a real workspace whose owner must still be able to administer it. Say it
// explicitly and the destroy proceeds.
//
// The check applies only to the placeholders the command's URL actually
// consumes. A destroy-tier verb that self-scopes (its own path carries the
// workspace) is unaffected, and a scope the URL never reads is not something to
// refuse over.
func requireStatedScope(ctx manifest.Context, cmd manifest.Command, target destroyTarget) (string, bool) {
	var missing []string
	if commandReadsPlaceholder(cmd, "workspace_slug", "workspace", "ws") && !ctx.WorkspaceExplicit {
		missing = append(missing, "-w <workspace>")
	}
	if commandReadsPlaceholder(cmd, "project_slug", "project", "p") && !ctx.ProjectExplicit {
		missing = append(missing, "-p <project>")
	}
	if len(missing) == 0 {
		return "", false
	}
	return fmt.Sprintf(
		"refusing to destroy a %s without a stated scope — %s fell back to %q/%q, "+
			"which is a real workspace on some instances. Name it: %s "+
			"(or set BARKPARK_WORKSPACE/BARKPARK_PROJECT, or `bp use <server>`)",
		target.kind, strings.Join(missing, " and "),
		ctx.Workspace, ctx.Project, strings.Join(missing, " "),
	), true
}

// commandReadsPlaceholder reports whether any of names appears as a
// :placeholder in the URL the command will actually build — its flat
// path_template PLUS the scoped_prefix, since the prefix is where
// :workspace_slug lives for every command in the destroy registry.
func commandReadsPlaceholder(cmd manifest.Command, names ...string) bool {
	tmpl := cmd.HTTP.PathTemplate
	if cmd.ScopedPrefix != nil {
		tmpl = *cmd.ScopedPrefix + tmpl
	}
	for _, n := range names {
		if strings.Contains(tmpl, ":"+n) {
			return true
		}
	}
	return false
}

// confirmDestroy gates one destroy-tier manifest command. It returns true to
// proceed. The caller must abort without sending when it returns false.
//
// args carries the already-resolved positional values, so the preview names the
// same target the request will (no second parse that could disagree with it).
func confirmDestroy(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, args map[string]string) bool {
	target, gated := destroyTargets[cmd.ID]
	if !gated {
		return true
	}

	// THE SCOPE MUST BE STATED, NOT INHERITED. Refuse before the preview: with no
	// stated scope there is no defensible workspace to preview AGAINST, and
	// reading an ambient one would put a credential inventory the operator never
	// asked for on their screen.
	if msg, refuse := requireStatedScope(ctx, cmd, target); refuse {
		out.userErr("%s", msg)
		return false
	}

	ref := args[target.argName]
	if ref == "" {
		// No resolvable target: buildManifestRequest would already have failed
		// on the required arg. Nothing to preview, nothing to gate.
		return true
	}

	// The preview is best-effort by design: a stale server without the sibling
	// list verb, a 403, or an id absent from the inventory must not BLOCK the
	// operation (the server's own cross-tenant rail is the authority — an id
	// that names no seat here 404s). It must, however, say so, so an operator
	// never reads silence as "found it, looks fine".
	out.errf("%s", destroyPreview(g, ctx, m, target, ref))

	if g.yes {
		return true
	}

	if !destroyStdinIsTTY(destroyStdin) {
		out.userErr("destroying this %s needs confirmation — re-run with --yes", target.kind)
		return false
	}

	prompt := fmt.Sprintf("Permanently destroy this %s? [y/N] ", target.kind)
	if out.color {
		prompt = "\033[31m" + prompt + "\033[0m"
	}
	fmt.Fprint(out.stderr, prompt)
	line, _ := bufio.NewReader(destroyStdin).ReadString('\n')
	answer := strings.TrimSpace(strings.ToLower(line))
	return answer == "y" || answer == "yes"
}

// destroyPreview resolves ref against the sibling list command and renders the
// one-line description of what is about to die. Every failure mode returns a
// line that NAMES the failure — the caller prints whatever comes back.
func destroyPreview(g globals, ctx manifest.Context, m *manifest.Manifest, target destroyTarget, ref string) string {
	head := fmt.Sprintf("about to destroy %s %s", target.kind, ref)

	lookup, ok := m.Tree().Lookup(target.lookupNoun, target.lookupVerb)
	if !ok {
		return head + " — no `bp " + target.lookupNoun + " " + target.lookupVerb +
			"` on this server, so its identity could not be shown"
	}

	// Headless dispatch, exactly as the MCP handlers use it: no rendering, no
	// guards, no stdout. g.yes is set because the prod write-guard lives in
	// runCommand and this read must never prompt (it is a GET regardless), and
	// --dry-run is cleared so a previewed dry run still reads the inventory
	// rather than previewing nothing.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	status, body, err := execManifestCommand(lg, ctx, m, *lookup, nil)
	if err != nil {
		return head + " — could not read the inventory to show its identity: " + err.Error()
	}
	if status < 200 || status >= 300 {
		return head + fmt.Sprintf(" — inventory read answered HTTP %d, so its identity could not be shown", status)
	}

	row, found := findDestroyRow(body, target, ref)
	if !found {
		return head + " — no matching row in `bp " + target.lookupNoun + " " + target.lookupVerb +
			"`; the server will refuse if it does not reach this workspace"
	}
	return head + " — " + describeDestroyRow(row, target.previewCols)
}

// findDestroyRow pulls the row whose match field equals ref out of the list
// envelope. A body that is not the expected envelope shape yields found=false —
// the preview then says so rather than guessing.
func findDestroyRow(body []byte, target destroyTarget, ref string) (map[string]any, bool) {
	var envelope map[string]json.RawMessage
	if json.Unmarshal(body, &envelope) != nil {
		return nil, false
	}
	raw, ok := envelope[target.lookupKey]
	if !ok {
		return nil, false
	}
	var rows []map[string]any
	if json.Unmarshal(raw, &rows) != nil {
		return nil, false
	}
	for _, row := range rows {
		for _, field := range target.lookupMatch {
			if v, ok := row[field]; ok && previewScalar(v) == ref {
				return row, true
			}
		}
	}
	return nil, false
}

// describeDestroyRow renders the preview fields as `k=v` pairs. Declared columns
// come first in their declared order; anything else the server sent follows in
// sorted order, so a field added server-side shows up instead of being dropped
// by a client-side allowlist. Empty/null values are omitted — a wall of
// `expires_at=` teaches nothing.
func describeDestroyRow(row map[string]any, cols []string) string {
	seen := map[string]bool{}
	var parts []string
	appendPair := func(k string) {
		if seen[k] {
			return
		}
		seen[k] = true
		v := previewScalar(row[k])
		if v == "" {
			return
		}
		parts = append(parts, k+"="+v)
	}
	for _, k := range cols {
		appendPair(k)
	}
	var rest []string
	for k := range row {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	for _, k := range rest {
		appendPair(k)
	}
	if len(parts) == 0 {
		return "(the inventory row carried no readable fields)"
	}
	return strings.Join(parts, " ")
}

// previewScalar renders one JSON value for the preview line. A JSON null and an
// absent key both render empty (and are then omitted); a list renders
// comma-joined, which is what `permissions` is. Anything else falls back to a
// compact marshal rather than Go's %v, so a nested object stays valid JSON.
//
// Deliberately NOT run.go's scalarString, which is a first-non-empty-of-many
// rev picker over string|float64 ONLY: it renders a list as "" (so
// `permissions` — the single most important field on a token about to be
// revoked — would vanish from the preview) and truncates every float to an
// int64. Different question, different function.
func previewScalar(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%.6f", t), "0"), ".")
	case []any:
		items := make([]string, 0, len(t))
		for _, item := range t {
			items = append(items, previewScalar(item))
		}
		return strings.Join(items, ",")
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return ""
		}
		return string(b)
	}
}
