package cli

// paper_export_cmd.go — `bp paper export <slug>`: a paper OUT of the server in
// the exact shape that puts it back IN.
//
// ── THE RETRIEVAL CENSUS (BP-ONB-21, measured 2026-09-18 against the LIVE
// served manifest of guerrilla.barkpark.cloud + this tree) ────────────────────
//
// The audit's want-list was "bulldocs get/list/export". Two thirds of it had
// already shipped by the time the row was worked — papers are ordinary
// `_type: "paper"` documents, so the GENERIC doc verbs are the get and the
// list, and no paper-specific twin is owed:
//
//	want    | what exists TODAY                              | verdict
//	--------+------------------------------------------------+---------------
//	get     | `bp doc get paper <slug>` (stored row, manifest | EXISTS — the
//	        | `doc.get`); `bp paper view <slug>` (rendered);  | generic verb
//	        | `bp paper pull <slug>` (BPML working copy)      | IS the get
//	list    | `bp doc ls paper`, `bp doc query paper --filter | EXISTS — same;
//	        | …` (manifest `doc.ls` / `doc.query`)            | paginated
//	export  | nothing. `doc get` returns the STORED ROW       | MISSING →
//	        | (_id/_rev/_type/_createdAt…), which the publish | this file
//	        | endpoint does not accept; `paper pull` writes   |
//	        | BPML into .barkpark/papers/ as a side effect,   |
//	        | never a payload on stdout                       |
//
// Also on the paper/doc nouns and NOT retrieval: `bp paper new|status|diff|
// push`, `bp paper capture`, `bp paper access`, `bp doc backlinks|related|
// history|revision|restore-revision|publish|unpublish|…`, and the write half
// `bp bulldocs publish|patch|propose`.
//
// RULED ACCEPTABLE, with the why: no `bulldocs get` / `bulldocs ls` verb is
// added to the plugin manifest. `bulldocs.ex`'s own cli_commands moduledoc
// already carries that ruling — the reader at `/papers/:slug` is a LiveView,
// not a JSON route, so a plugin verb would have to invent an `http.path_template`
// — and the generic `doc get|ls paper` already answers both, against a real
// route, with perspective/expand/fields/pagination the plugin twin would have
// to re-implement. Duplicating them under a second noun buys a synonym and a
// second thing to keep true.
//
// So `export` is the one genuine gap, and it needs NO api/ change: it rides the
// existing `GET /papers/:slug/source?format=json` route (the same route
// `paper pull` reads as `format=bpml`) and reshapes the reader envelope into
// the publish body. Round trip:
//
//	bp paper export <slug> > p.json && bp bulldocs publish <slug> --file p.json
//
// TWO CAVEATS, deliberately not papered over. First, the publish WALL requires
// a label spine (a description of 20+ characters and 1-12 weighted tags) that
// the reader source route does not serve — it serves what a reader renders.
// Export therefore makes a second, best-effort read of the stored row for
// description + tags, and when it cannot recover them it says so on stderr
// rather than handing over a payload that looks complete and is refused.
// Second: the source route resolves task
// references in blocks before serving them (`Content.Papers.resolve_tasks_in_blocks`),
// so a paper carrying task blocks exports them HYDRATED. That is what the
// reader shows and what re-publishing re-derives; it is not the byte image of
// the stored row. A caller who wants the stored row wants `bp doc get paper`.

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runPaperExport writes one paper as a publish-ready payload: stdout by
// default (so it pipes straight into `bp bulldocs publish --file -`), or to
// `--out <path>`. The payload is the ONLY thing on stdout — every receipt goes
// to stderr — because a redirect is the expected use.
func runPaperExport(out *writer, g globals, ctx manifest.Context, args []string) int {
	slug := ""
	dest := ""

	for i := 0; i < len(args); i++ {
		switch arg := args[i]; arg {
		case "--out":
			if i+1 >= len(args) {
				out.userErr("paper export: --out needs a path")
				usagePaper(out, false)
				return exitUsage
			}
			dest = args[i+1]
			i++
		default:
			if slug != "" {
				out.userErr("paper export: exactly one <slug>")
				usagePaper(out, false)
				return exitUsage
			}
			slug = arg
		}
	}

	if slug == "" {
		out.userErr("paper export: exactly one <slug>")
		usagePaper(out, false)
		return exitUsage
	}

	payload, apiErr, err := paperWCClient(ctx).PaperExportPayload(slug)
	if err != nil {
		out.userErr("paper export %s: %v", slug, err)
		return exitGeneric
	}
	if apiErr != nil {
		renderPaperAPIErr(out, "export "+slug, apiErr)
		return exitGeneric
	}

	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		out.userErr("paper export %s: %v", slug, err)
		return exitGeneric
	}
	body = append(body, '\n')

	// A payload missing the label spine still publishes NOTHING: say so on
	// stderr (never stdout — stdout is the payload) before the caller pipes it.
	if len(payload.SpineMissing) > 0 {
		out.errf("bp: paper export %s: no %s on the stored row — the publish wall requires a description (20+ chars) and 1-12 weighted tags, so re-publishing this payload as-is will be refused",
			slug, strings.Join(payload.SpineMissing, " or "))
	}

	if dest != "" {
		if err := os.WriteFile(dest, body, 0o644); err != nil {
			out.userErr("paper export %s: %v", slug, err)
			return exitGeneric
		}
		out.outf("exported %s → %s (%d bytes)", slug, dest, len(body))
		return exitOK
	}

	fmt.Fprint(out.stdout, string(body))
	return exitOK
}
