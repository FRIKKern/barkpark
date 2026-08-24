package cli

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/mattn/go-runewidth"
)

// renderTable prints a human-readable table for the common API payload shapes:
//
//   - {"documents":[…]} — a list query: one row per doc, columns from the union
//     of keys (id/title first), volatile/underscore keys deprioritised.
//   - a single object — key/value pairs, one per line.
//   - an array of objects — same column logic as documents.
//   - anything else — falls back to pretty JSON.
//
// Table output is for eyeballs only; piped consumers get json/yaml/minimal.
func renderTable(out *writer, payload []byte) {
	var v any
	if json.Unmarshal(payload, &v) != nil {
		out.outf("%s", string(payload))
		return
	}

	switch t := v.(type) {
	case map[string]any:
		if rows, ok := envelopeRows(t); ok {
			renderRows(out, rows, t)
			return
		}
		// Single-object GET envelopes ({webhook: {...}}, {schema: {...}}): render
		// the inner object's fields, not "webhook  {…json…}" crammed into one cell.
		if obj, ok := singleObjectEnvelope(t); ok {
			renderKV(out, obj)
			return
		}
		// Backstop for a wrapper envelope whose row key nobody added to
		// listEnvelopeKeys. Without it the rows reach renderKV, which hands the
		// whole array to cellString and truncates it to 60 display cells — a
		// line that LOOKS like output and carries almost none of the data.
		if unknownListEnvelope(out, t) {
			return
		}
		renderKV(out, t)
	case []any:
		renderRows(out, t, nil)
	default:
		out.renderRaw(payload)
	}
}

// listEnvelopeKeys are the keys the API's list envelopes carry their rows
// under: query/search use "documents", the tasks endpoints "docs", media
// "assets". The admin/tenancy list commands each carry their own key —
// workspace.ls "workspaces", workspace.project-ls "projects", schema.ls
// "schemas", webhook.ls "webhooks", plugin.ls "plugins", share.ls "shares",
// secret.ls "secrets".
// media.collections uses "collections"; media.collection-assets (and media
// search) carry their hits under "hits"; doc.backlinks uses "backlinks";
// doc.related "related"; the tag reads (tag.browse) "tags". A key missing here
// is not cosmetic: renderTable falls through to renderKV and crams the whole
// array into ONE key/value cell (and minimal prints a bare "ok") — valid
// output, zero information. Add a list command's envelope key here whenever its
// default_output is "table".
//
// "related" and "tags" are content-collidable: Envelope.render (api) flattens a
// document's content fields to the top level, so a doc.get payload (also table
// output) can carry its OWN top-level "tags" (or "related") array. Those keys
// are safe here ONLY because envelopeRows refuses the list treatment for a
// single document (it carries "_id"); a wrapper envelope never does.
//
// The tickets plugin's operator list verb — ticket.inbox (triage) — carries its
// rows under "tickets" (the submitter's own-threads list is curl-only, not a bp
// verb; charter Decision 11), and ticket-key.ls carries its named credentials
// under "keys"; without them those tables collapse into a single crammed cell.
// ("keys" is safe to claim: the only other "keys" payload, the sites env-set
// receipt, goes through emitStructured and never reaches this renderer.)
//
// The tenancy/credential admin verbs were the drift this list kept losing to:
// workspace.member-ls carries "members", token.ls "tokens", access.ls /
// access.mine "grants", and webhook.deliveries "deliveries". token.ls is the
// costly one — it is the ONLY way to see which credentials can reach a
// workspace and which are still unrevoked, and on a live instance with ~100
// tokens it printed a single 60-cell cell ending in "...", so neither the ids
// `token revoke` needs nor the revoked_at the verb exists to report were
// visible. The keys are listed here, but the real backstop is
// unknownListEnvelope below: this list can drift again, and the next verb to
// arrive must not have to wait for someone to notice.
var listEnvelopeKeys = []string{
	"documents", "docs", "assets", "collections", "hits", "backlinks", "related",
	"revisions", "workspaces", "projects", "schemas", "webhooks", "plugins",
	"shares", "secrets", "tickets", "keys", "tags",
	"members", "tokens", "grants", "deliveries",
}

// envelopeRows finds the row list of a list-envelope payload, trying the known
// envelope keys in order. ok=false when none holds a JSON array.
func envelopeRows(m map[string]any) ([]any, bool) {
	// A single document is never a list envelope: it carries its own "_id" and
	// renders as key/value, not as a table of one of its array-valued content
	// fields. Envelope.render (api) flattens content to the top level, so a
	// tagged doc.get payload carries a top-level "tags" (and could carry
	// "related") array — without this guard those content-collidable keys would
	// hijack `doc get` into tabulating that field instead of showing the doc.
	// A wrapper envelope ({related:[…],count}, {tags:[…]}, {documents:[…]}) has
	// no "_id".
	if _, isDoc := m["_id"]; isDoc {
		return nil, false
	}
	for _, k := range listEnvelopeKeys {
		if rows, ok := m[k].([]any); ok {
			return rows, true
		}
	}
	return nil, false
}

// unknownListEnvelope renders a wrapper envelope that carries rows under a key
// listEnvelopeKeys does not know, and reports whether it did.
//
// It exists because that list is a hand-maintained mirror of the API's list
// envelopes, and a hand-maintained mirror drifts: four keys (members, tokens,
// grants, deliveries) had accumulated behind it, and `bp token ls` — the only
// way to enumerate the credentials that can reach a workspace — answered a
// ~100-token live inventory with one truncated cell and exit 0. Naming the four
// keys fixes those four verbs; this fixes the NEXT one, which is the failure
// that actually recurs.
//
// Scope is deliberately narrow. It only ever fires for a map that reached
// renderKV — so after envelopeRows and singleObjectEnvelope have both declined
// — and it refuses a single document outright (the "_id" guard below, the same
// one envelopeRows uses). That refusal is what keeps it off the
// content-collidable ground the listEnvelopeKeys comment warns about:
// Envelope.render (api) flattens a document's content fields to the top level,
// so a doc.get payload can carry array-valued fields of its own; those still
// render as today's key/value lines, not as hijacked tables.
//
// Sibling context is preserved rather than dropped: workspace.dataset-ls
// returns {workspace:…, project:…, datasets:[…]}, and printing only the
// datasets table would silently withhold which workspace they belong to. The
// non-row keys render first as key/value lines, then each row array follows
// under its own labelled heading.
func unknownListEnvelope(out *writer, m map[string]any) bool {
	// A single document is never a list envelope — its array-valued content
	// fields are the document, not rows about it.
	if _, isDoc := m["_id"]; isDoc {
		return false
	}
	var rowKeys []string
	rest := make(map[string]any, len(m))
	for _, k := range sortedKeys(m) {
		if arr, isArr := m[k].([]any); isArr && containsObject(arr) {
			rowKeys = append(rowKeys, k)
			continue
		}
		rest[k] = m[k]
	}
	if len(rowKeys) == 0 {
		return false
	}
	if len(rest) > 0 {
		renderKV(out, rest)
	}
	for _, k := range rowKeys {
		out.outf("")
		out.outf("%s:", k)
		// meta is nil: the count line belongs to a known list envelope, whose
		// count/total live beside the rows. An unknown envelope has no such
		// contract, so claiming a count here would be inventing one.
		renderRows(out, m[k].([]any), nil)
	}
	return true
}

// containsObject reports whether a JSON array holds at least one object, i.e.
// whether it has columns to tabulate. A bare scalar array ({"datasets":
// ["production","staging"]}) reads fine as a single key/value line and is left
// alone — promoting it to a one-column table would be noise, not information.
func containsObject(arr []any) bool {
	for _, v := range arr {
		if _, ok := v.(map[string]any); ok {
			return true
		}
	}
	return false
}

// singleObjectEnvelopeKeys are the keys a single-object GET nests its object
// under — webhook.get → {webhook: {...}}, schema.get → {_schemaVersion, schema:
// {...}}, doc.revision → {revision: {...}}, ticket.show → {ok, ticket: {...}}
// (the operator thread detail; the login-ticket endpoint's "ticket" is a string,
// which the map guard below never matches). Unlike doc.get / media.get (which use
// the {result: …} wrapper that unwrapResult already strips), these carry their
// own key, so renderTable otherwise falls to renderKV and crams the whole object
// into one cell. A known list, NOT a heuristic: "first object-valued key" would
// wrongly unwrap a doc whose only non-system field is an object (e.g. a
// portableText body).
var singleObjectEnvelopeKeys = []string{"webhook", "schema", "revision", "ticket"}

// singleObjectEnvelope returns the inner object of a single-object envelope, if
// the payload carries one of the known keys with a JSON-object value.
func singleObjectEnvelope(m map[string]any) (map[string]any, bool) {
	for _, k := range singleObjectEnvelopeKeys {
		if obj, ok := m[k].(map[string]any); ok {
			return obj, true
		}
	}
	return nil, false
}

// renderKV prints a single object as aligned key: value lines.
func renderKV(out *writer, obj map[string]any) {
	keys := sortedKeys(obj)
	// Width is measured in terminal display cells, not bytes or runes: a CJK
	// ideograph is one rune but occupies two columns, so a rune width would
	// under-pad it and shear the alignment. runewidth.StringWidth accounts for
	// wide (east-asian) and zero-width (combining) runes; FillRight pads to that
	// same cell width. Matches renderRows below.
	width := 0
	for _, k := range keys {
		if n := runewidth.StringWidth(k); n > width {
			width = n
		}
	}
	for _, k := range keys {
		v := cellString(obj[k])
		// The value is the last thing on the line (no padding), so bare == painted
		// input; paintCell is a no-op unless color is on AND v is a status token.
		out.outf("%s  %s", runewidth.FillRight(k, width), out.paintCell(v, v))
	}
}

// renderRows prints a list of objects as a column table. meta (the enclosing
// envelope) supplies an optional count line.
func renderRows(out *writer, rows []any, meta map[string]any) {
	if len(rows) == 0 {
		out.outf("(no rows)")
		// A user who passed `?count=true` precisely to learn the match total
		// (filter matched zero vs. offset past the end) still wants it here.
		renderCountMeta(out, meta)
		return
	}

	cols := pickColumns(rows)
	if len(cols) == 0 {
		// No object keys to columnize — a bare array of scalars (e.g. a
		// `["a","b"]` list response, which renderTable's []any case forwards
		// here). Without this the loop below produced an empty header + blank
		// rows and silently DROPPED the values. Wrap each element in a single
		// "value" column so the data renders through the normal machinery.
		wrapped := make([]any, len(rows))
		for i, r := range rows {
			wrapped[i] = map[string]any{"value": r}
		}
		rows = wrapped
		cols = []string{"value"}
	}
	// Header. Widths are measured in terminal display cells (runewidth), not
	// bytes or runes: a CJK ideograph is one rune but two columns, and a
	// combining mark is one rune but zero columns — a rune width would shear the
	// alignment for either. The separator repeats "-" (one cell each) to the same
	// cell width, and joinCols pads with FillRight to match.
	widths := make([]int, len(cols))
	for i, c := range cols {
		widths[i] = runewidth.StringWidth(c)
	}
	cells := make([][]string, 0, len(rows))
	for _, r := range rows {
		obj, _ := r.(map[string]any)
		row := make([]string, len(cols))
		for i, c := range cols {
			// Cap each cell in the TABLE so a single long string value (title, url,
			// slug) can't stretch its column past the terminal. renderKV (the
			// single-object key:value view) intentionally shows full values.
			s := truncateCell(cellString(obj[c]), cellMaxRunes)
			row[i] = s
			if n := runewidth.StringWidth(s); n > widths[i] {
				widths[i] = n
			}
		}
		cells = append(cells, row)
	}

	out.outf("%s", joinCols(cols, widths))
	sep := make([]string, len(cols))
	for i := range cols {
		sep[i] = strings.Repeat("-", widths[i])
	}
	out.outf("%s", joinCols(sep, widths))
	for _, row := range cells {
		// Data rows go through the status-role painter (header/separator never do).
		out.outf("%s", joinColsPainted(out, row, widths))
	}

	renderCountMeta(out, meta)
}

// renderCountMeta prints the trailing count/total lines a list envelope carries.
// Silent when meta is nil or has no "count" key. Emitted after both the table
// and the "(no rows)" path so a `?count=true` caller always gets the total.
func renderCountMeta(out *writer, meta map[string]any) {
	if meta == nil {
		return
	}
	c, ok := meta["count"]
	if !ok {
		return
	}
	out.outf("")
	out.outf("count: %s", cellString(c))
	// `?count=true` adds the full match count (paginator total).
	if t, ok := meta["total"]; ok {
		out.outf("total: %s", cellString(t))
	}
}

func joinCols(cells []string, widths []int) string {
	parts := make([]string, len(cells))
	for i, c := range cells {
		// FillRight pads to display-cell width (see renderRows) rather than fmt's
		// rune-counting %-*s, so wide/zero-width runes don't shear the columns.
		parts[i] = runewidth.FillRight(c, widths[i])
	}
	return strings.TrimRight(strings.Join(parts, "  "), " ")
}

// joinColsPainted is joinCols for DATA rows: it pads each cell to its column
// width (measured on the BARE string upstream, so padding is unchanged) and then
// paints the padded cell in the semantic color of its status role. Padding
// happens before coloring — the ANSI bytes never enter the width math — so the
// columns stay aligned. With color OFF (--no-color, a pipe, any non-tty)
// paintCell is a no-op and the result is byte-for-byte identical to joinCols;
// that byte-identity is the charter's hard guarantee (decision 12) and is
// asserted by a test.
func joinColsPainted(out *writer, cells []string, widths []int) string {
	parts := make([]string, len(cells))
	for i, c := range cells {
		parts[i] = out.paintCell(runewidth.FillRight(c, widths[i]), c)
	}
	return strings.TrimRight(strings.Join(parts, "  "), " ")
}

// ansiReset closes an SGR colour span. It is emitted directly only by paintCell's
// ANSI-16 floor (the pinned semrole.GenANSI16 codes); the 256/truecolor rungs emit
// their own reset through lipgloss. The four roles' hues no longer live here — they
// are sourced from the generated design-token artifact (internal/semrole) so a
// `bp` status cell and the SPA's --ok/--info/--warn/--danger can never drift
// (charter decisions 3, 4, 12).
const ansiReset = "\033[0m"

// statusRole maps a status-like cell value to its semantic color role
// (ok|info|warn|danger), or "" when the value is not a recognised status token.
//
// Charter decision 12: this is the single mapping the renderTable seam consults,
// so every current and future table colours its status cells identically without
// per-command wiring. The vocabulary now lives in the shared internal/semrole
// package (extracted onto the merged #979 seam) so the CLI tables, the cloud
// dashboard, and the portrait task board never drift; statusRole delegates to it.
// The match is case-insensitive on the trimmed value; an unknown string yields ""
// (no color) — never a guess. The eight decision-15 states carry EXACTLY the tone
// the decision-32 fixture (cloud/priv/static/__fixtures__/attention_order.json)
// pins for them — note "behind" is info, not warn ("update available" is news,
// not an alarm) — and TestAttentionVocabularyMatchesFixture holds semrole.For to
// that file. Delegation also gives `bp task … -o table` colored lifecycle cells
// for free (in_progress/blocked/done/closed), since semrole.For carries the task
// vocabulary too.
func statusRole(value string) string {
	return semrole.For(value)
}

// pickColumns builds a stable column list from the union of row keys. Identity
// columns (_id/id/title/name/subject — a ticket's title is its subject) lead;
// the rest follow alphabetically; underscore "system" keys are dropped from the
// table view to keep it readable (full data is one -o json away).
func pickColumns(rows []any) []string {
	seen := map[string]bool{}
	for _, r := range rows {
		if obj, ok := r.(map[string]any); ok {
			for k := range obj {
				seen[k] = true
			}
		}
	}

	lead := []string{}
	for _, k := range []string{"_id", "id", "title", "name", "subject", "slug", "status"} {
		if seen[k] {
			lead = append(lead, k)
			delete(seen, k)
		}
	}

	rest := make([]string, 0, len(seen))
	for k := range seen {
		if strings.HasPrefix(k, "_") {
			continue // hide system columns from the table
		}
		rest = append(rest, k)
	}
	sort.Strings(rest)

	cols := append(lead, rest...)
	if len(cols) == 0 {
		// All keys were system keys; show them rather than an empty table.
		for k := range seen {
			cols = append(cols, k)
		}
		sort.Strings(cols)
	}
	return cols
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// cellString renders a scalar/compound value compactly for a table cell.
func cellString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return sanitizeCell(t)
	case float64:
		if t == math.Trunc(t) && t >= math.MinInt64 && t < math.MaxInt64 {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%g", t)
	case bool:
		if t {
			return "true"
		}
		return "false"
	case map[string]any, []any:
		b, _ := json.Marshal(t)
		return truncateCell(string(b), cellMaxRunes)
	default:
		return sanitizeCell(fmt.Sprintf("%v", t))
	}
}

// sanitizeCell keeps a table cell single-line and escape-free. Author-controlled
// data (a title like "Line1\nLine2") would otherwise break row alignment, a tab
// would desync columns, and an ESC sequence would inject raw terminal escapes.
// Whitespace controls collapse to a space; other C0/DEL bytes are dropped.
func sanitizeCell(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r == '\r' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}

// cellMaxRunes caps a table cell's display width so one long value (a title,
// url, or nested blob) can't blow the whole table past the terminal width. Full
// data is always one `-o json` away.
const cellMaxRunes = 60

// truncateCell caps s at max terminal DISPLAY CELLS, appending "..." when it
// overflows. Display-width-aware (runewidth), NOT rune-count: a CJK ideograph is
// one rune but occupies two columns, so a 40-ideograph cell is 80 cells — a
// rune-count cap would let it blow the very column-width budget the cap exists to
// enforce (and shear the table renderRows/joinCols measure in the same cells).
// runewidth.Truncate is rune-safe (never splits a multibyte rune) and reserves
// room for the tail, so the result's display width is always <= max.
func truncateCell(s string, max int) string {
	if max < 0 {
		max = 0
	}
	if runewidth.StringWidth(s) <= max {
		return s
	}
	// No room for the 3-cell ellipsis: truncate bare (still rune-safe).
	if max < 4 {
		return runewidth.Truncate(s, max, "")
	}
	return runewidth.Truncate(s, max, "...")
}
