package cli

import (
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"sort"
	"strings"

	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/manifest"
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
	// The value column starts after the padded key plus the two-space gutter;
	// continuation lines hang there so a wrapped value reads as one block
	// instead of restarting at column 0 under the key.
	valueCol := width + 2
	avail := out.kvValueWidth(valueCol)
	hang := strings.Repeat(" ", valueCol)
	for _, k := range keys {
		v := cellString(obj[k])
		segs := wrapKVValue(v, avail)
		if len(segs) == 1 {
			// The value is the last thing on the line (no padding), so bare ==
			// painted input; paintCell is a no-op unless color is on AND v is a
			// status token.
			out.outf("%s  %s", runewidth.FillRight(k, width), out.paintCell(v, v))
			continue
		}
		// A value that needed WRAPPING is prose, never a status token — the
		// painter keys on the WHOLE cell (statusRole/semrole.Color match a bare
		// "failed", not a sentence containing it), so painting per-segment could
		// only ever fire on a fragment the wrap happened to isolate, colouring one
		// line of a paragraph for no reason. Wrapped values go out unpainted.
		for i, seg := range segs {
			if i == 0 {
				out.outf("%s  %s", runewidth.FillRight(k, width), seg)
				continue
			}
			out.outf("%s%s", hang, seg)
		}
	}
}

// kvMinValueWidth is the narrowest value column renderKV will wrap into. Below
// it the wrap stops helping and starts shredding: a 10-cell column turns a URL
// into a column of fragments that is harder to read — and harder to copy out of
// — than the terminal's own hard wrap. So a window narrower than key + gutter +
// 20 cells gets the UNWRAPPED line, which is the pre-existing behaviour.
const kvMinValueWidth = 20

// kvValueWidth resolves how many display cells renderKV may spend on a value
// before wrapping, given the column the value starts at.
//
// Three-way, and the zero is load-bearing: 0 means DO NOT WRAP.
//
//   - kvWrapWidth set (tests, and any future --width flag) wins outright.
//   - else the real terminal, and only when stdout is genuinely an *os.File we
//     can size. A bytes.Buffer under test is never sized — so the wrap cannot
//     depend on whether the suite happens to run attached to a terminal, and a
//     test that merely sets w.isTTY does not silently acquire wrapping.
//   - else 0: piped/redirected output stays byte-identical to today, one value
//     per line, because the consumer downstream is grep or a golden file, not
//     an 80-column window.
//
// A window too narrow to hold kvMinValueWidth also answers 0 (see above), as
// does any non-positive size the terminal reports — dividing a value into a
// zero-width column is a hang, not a cosmetic improvement.
func (w *writer) kvValueWidth(valueCol int) int {
	total := w.kvWrapWidth
	if total <= 0 {
		total = w.terminalWidth()
	}
	if total <= 0 {
		return 0
	}
	avail := total - valueCol
	if avail < kvMinValueWidth {
		return 0
	}
	return avail
}

// wrapKVValue splits a KV value into the lines it occupies at the given value
// width. width <= 0 (see kvValueWidth) means no wrapping: one line, verbatim.
//
// Wrapping is on DISPLAY CELLS, not bytes and not runes — ansi.StringWidth and
// ansi.Wrap both count the columns a terminal actually spends, so a CJK
// ideograph costs two, a combining mark zero, and an emoji two. A byte- or
// len()-keyed split would break a multi-byte rune in half and mis-measure every
// non-ASCII value in the payload. ansi.Wrap breaks on spaces; a single token
// longer than the column (a URL, a base64 blob) still has to go somewhere, so
// ansi.Hardwrap finishes the job on any segment that came back overlong.
func wrapKVValue(v string, width int) []string {
	if width <= 0 || ansi.StringWidth(v) <= width {
		return []string{v}
	}
	var lines []string
	for _, seg := range strings.Split(ansi.Wrap(v, width, " "), "\n") {
		if ansi.StringWidth(seg) > width {
			lines = append(lines, strings.Split(ansi.Hardwrap(seg, width, false), "\n")...)
			continue
		}
		lines = append(lines, seg)
	}
	return lines
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

	cols := pickColumns(rows, out.requestedColumns)
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
// columns (_id/id/title/name/subject/slug/worker — a ticket's title is its
// subject, and a roster row's identity is its worker) lead, ahead of status;
// the rest follow alphabetically; underscore "system" keys are dropped from the
// table view to keep it readable (full data is one -o json away).
//
// requested is the projection the CALLER named (`--fields title,description`),
// empty when the columns are INFERRED. The two are not the same question. An
// inferred column that is empty on every row of the page carries no
// information, so deriving columns from the keys PRESENT is right for it. A
// requested one is a question the caller asked: dropping it answers "there is
// no such field" with the same silence as "no row on this page has a value",
// and those are not interchangeable — a sparse catalog page hid the
// `description` column that `scaffy ls --remote` projects on purpose, at exit
// 0. So a named column is rendered even when every cell is blank; an unnamed
// one keeps today's behaviour, and a key NOT in the payload and NOT requested
// is still absent (rendering every key would defeat the projection).
func pickColumns(rows []any, requested []string) []string {
	seen := map[string]bool{}
	hasObject := false
	for _, r := range rows {
		if obj, ok := r.(map[string]any); ok {
			hasObject = true
			for k := range obj {
				seen[k] = true
			}
		}
	}

	lead := []string{}
	// "worker" leads "status" on purpose. A fleet roster row (`bp fleet roster`)
	// carries no identity key at all — no _id/id/title/name/subject/slug — so
	// before "worker" joined this list the only lead column was "status" and the
	// row rendered status, agent, capacity, last_seen, scope, ttl_s, worker: the
	// one cell naming WHICH worker the row is about sorted LAST, alphabetically,
	// off the right edge of a narrow terminal. kubectl-style reading is
	// subject-then-state, so the subject comes first.
	for _, k := range []string{"_id", "id", "title", "name", "subject", "slug", "worker", "status"} {
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
	if !hasObject {
		// A bare scalar array has no columns to name; renderRows wraps it in a
		// synthetic "value" column. Honouring a projection here would print a
		// header of empty columns over data that has no keys at all.
		return cols
	}
	return withRequestedColumns(cols, lead, requested)
}

// withRequestedColumns folds the caller's explicit projection into the inferred
// column list: every requested name appears, in the order it was requested,
// whether or not any row on the page carries a value for it.
//
// Ordering is deliberately conservative. Identity columns the caller did NOT
// name (_id, which the API returns on every projected row) keep their front
// seat, so `--fields title,description` reads `_id  title  description` —
// today's table plus the column that was silently missing, not a reshuffle.
// Inferred columns the caller did not name follow, in pickColumns' order.
// Returns cols untouched when nothing was requested.
func withRequestedColumns(cols, lead, requested []string) []string {
	req := make([]string, 0, len(requested))
	inReq := make(map[string]bool, len(requested))
	for _, r := range requested {
		r = strings.TrimSpace(r)
		if r == "" || inReq[r] {
			continue
		}
		inReq[r] = true
		req = append(req, r)
	}
	if len(req) == 0 {
		return cols
	}
	merged := make([]string, 0, len(cols)+len(req))
	added := make(map[string]bool, len(cols)+len(req))
	add := func(c string) {
		if !added[c] {
			added[c] = true
			merged = append(merged, c)
		}
	}
	for _, c := range lead {
		if !inReq[c] {
			add(c)
		}
	}
	for _, c := range req {
		add(c)
	}
	for _, c := range cols {
		if !inReq[c] {
			add(c)
		}
	}
	return merged
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

// fieldsProjectionFlag is the manifest flag whose value is a comma-separated
// response projection (`--fields title,description` on doc.get/ls/query and
// search.query). It is also the query-string parameter the API reads, which is
// why requestedColumnsFromURL can answer off the RESOLVED url.
const fieldsProjectionFlag = "fields"

// requestedColumnsFromURL reads the caller's explicit column projection off the
// url the dispatch actually resolved, for the table renderer to honour.
//
// The RESOLVED url is the honest source. The projection can arrive as a
// command-local flag, and applyQuery is the one place that decides whether a
// value reaches the server at all (a knob the client drops never becomes a
// column) — so reading the url cannot claim a projection the request did not
// carry. The manifest declaration is still required first: `fields` is only a
// projection on the commands that declare it, and a route that grows an
// unrelated `?fields=` parameter must not silently reshape its table.
//
// Returns nil for a command with no such flag, a url that carries no `fields`,
// or an empty value.
func requestedColumnsFromURL(cmd manifest.Command, rawURL string) []string {
	if !commandDeclaresFlag(cmd, fieldsProjectionFlag) {
		return nil
	}
	i := strings.IndexByte(rawURL, '?')
	if i < 0 {
		return nil
	}
	q, err := url.ParseQuery(rawURL[i+1:])
	if err != nil {
		return nil
	}
	return splitFieldsProjection(q.Get(fieldsProjectionFlag))
}

// splitFieldsProjection splits a comma-separated projection value into column
// names, dropping empties and preserving the caller's order.
func splitFieldsProjection(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	cols := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			cols = append(cols, p)
		}
	}
	return cols
}
