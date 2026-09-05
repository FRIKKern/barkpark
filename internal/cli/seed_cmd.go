package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runSeed is the `bp seed <type> [--count N] [--dataset <ds>] [--yes]` built-in.
// It fabricates schema-valid-ish sample documents for a content type and writes
// them via POST /v1/data/mutate as createOrReplace ops, so a fresh dataset has
// something to read against without hand-authoring fixtures.
//
// Honesty: seed generates SOLID v1 primitives and v2 values (composite recurses;
// arrayOf populates from its `of` element shape; localizedText fills nob/eng).
// codelist stays empty (a valid value needs the registry seed does not fetch).
// Documents land as DRAFTS (createOrReplace with a draft id is not auto-
// published) so the server's lenient draft validation applies — a deep v2
// schema may still warn. It is a dev convenience, not a fixtures framework.
//
// args is everything after the `seed` noun (rest[1:] in Execute).
func runSeed(out *writer, g globals, ctx manifest.Context, args []string) int {
	typ := ""
	count := 3
	dataset := ""
	yes := g.yes
	publish := false

	if g.help {
		usageSeed(out, true)
		return exitOK
	}

	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--count", "-n":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--count")
			if err != nil {
				return usageErrf(out, func() { usageSeed(out, false) }, "%v", err)
			}
			c, perr := parseCount(v)
			if perr != nil {
				return usageErrf(out, nil, "%v", perr)
			}
			count = c
			i = ni
		case "--dataset", "-d":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--dataset")
			if err != nil {
				return usageErrf(out, func() { usageSeed(out, false) }, "%v", err)
			}
			dataset = v
			i = ni
		case "--yes":
			yes = true
			i++
		case "--publish":
			publish = true
			i++
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				return usageErrf(out, func() { usageSeed(out, false) }, "unknown seed flag %q", a)
			}
			if typ == "" {
				typ = a
			} else {
				return usageErrf(out, func() { usageSeed(out, false) }, "too many arguments; usage: bp seed <type>")
			}
			i++
		}
	}

	if typ == "" {
		return usageErrf(out, func() { usageSeed(out, false) }, "seed needs a content <type>")
	}
	if dataset == "" {
		dataset = ctx.Dataset
	}
	if dataset == "" {
		dataset = "production"
	}

	// 1. Pull the RAW schema for the dataset (parse it ourselves — apiclient's
	// LoadSchemas flattens v2 subfields, which we need for composite shapes).
	schema, serr := seedFetchSchema(ctx, dataset, typ)
	if serr != nil {
		hint := "run `bp schema ls` to list types; check --dataset"
		if !renderErrorEnvelope(out, "not_found", serr.Error(), "", hint) {
			out.userErr("%v", serr)
			out.errf("  hint: %s", hint)
		}
		return exitNotFound
	}

	// 2. Generate the docs.
	docs := make([]map[string]any, 0, count)
	for n := 1; n <= count; n++ {
		docs = append(docs, generateDoc(schema, n))
	}

	// 3. Prod write-guard — never silently seed a prod/cloud target. The empty
	// manifest kills isProd's Server.Name leg, so the URL heuristic (fail-closed
	// since onb-backlog-isprod-custom-host-write-confirm) is the whole decision
	// here; a server advertising production:false on /v1/meta skips the confirm.
	if isProd(ctx, &manifest.Manifest{}) && !yes && !serverDeclaredNonProd(ctx.Server) {
		guardCmd := manifest.Command{Noun: "seed", Verb: typ}
		if !confirmProdWrite(out, guardCmd, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	// 4. POST the mutations as createOrReplace.
	mutations := make([]map[string]any, 0, len(docs))
	for _, d := range docs {
		mutations = append(mutations, map[string]any{"createOrReplace": d})
	}
	body, _ := json.Marshal(map[string]any{"mutations": mutations})

	u := ctxScopedURL(ctx, "/v1/data/mutate/"+url.PathEscape(dataset))
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = "application/json"
	status, respBody, err := doRequest("POST", u, headers, body)
	if err != nil {
		if !renderErrorEnvelope(out, "request_failed", "request failed: "+err.Error(), "", "") {
			out.userErr("request failed: %v", err)
		}
		return exitGeneric
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit
	}
	// THE RECEIPT THIS VERB PRINTS IS ENTIRELY LOCAL. `count` is len(docs) and
	// `ids` are read off the documents we SENT, so every number below survives
	// a 200 that said nothing — an empty body, a proxy page, `null`, `{}` or an
	// error envelope on a 2xx all printed `{"ok":true,"count":3,"ids":[…]}` at
	// rc=0. Nothing in the receipt was ever a measurement, which is why the
	// screen has to run BEFORE it, not inside it.
	if rc, handled := screenBuiltinWriteReceipt(out, "seed mutate", status, respBody); handled {
		return rc
	}

	ids := make([]string, len(docs))
	for i, d := range docs {
		ids[i], _ = d["_id"].(string)
	}

	// 5. --publish: a second mutate batch publishing each seeded id, so the docs
	// are visible to the published API (the default public read) — not just as
	// drafts. Matches the create-then-publish flow the starter seed scripts use.
	if publish {
		pstatus, prespBody, perr := doRequest("POST", u, headers, seedPublishBody(ids, typ))
		if perr != nil {
			if !renderErrorEnvelope(out, "request_failed", "publish request failed: "+perr.Error(), "", "") {
				out.userErr("publish request failed: %v", perr)
			}
			return exitGeneric
		}
		if pstatus < 200 || pstatus >= 300 {
			ae := classifyError(pstatus, prespBody)
			renderError(out, ae)
			return ae.exit
		}
		// The publish batch is a SECOND write with its own receipt, and
		// `published: true` in the payload below is asserted off this response
		// alone. Screening only the create batch would leave the receipt saying
		// "published" over a publish nobody heard back from.
		if rc, handled := screenBuiltinWriteReceipt(out, "seed publish", pstatus, prespBody); handled {
			return rc
		}
	}

	state := "draft(s)"
	if publish {
		state = "published doc(s)"
	}
	payload := map[string]any{"ok": true, "type": typ, "dataset": dataset, "count": len(docs), "ids": ids, "published": publish}
	switch out.output {
	case "json":
		out.renderJSON(payload)
		return exitOK
	case "yaml":
		out.renderYAML(toGeneric(payload))
		return exitOK
	}
	out.outf("seeded %d %s %s into %s", len(docs), typ, state, dataset)
	for _, id := range ids {
		out.outf("  %s", id)
	}
	return exitOK
}

// seedPublishBody builds the mutate batch that publishes each seeded id. The
// publish op takes the published (drafts-prefix-free) id, which is exactly the
// `seed-<type>-<n>` id createOrReplace was given. Pure — unit-tested.
func seedPublishBody(ids []string, typ string) []byte {
	muts := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		muts = append(muts, map[string]any{"publish": map[string]any{"id": id, "type": typ}})
	}
	body, _ := json.Marshal(map[string]any{"mutations": muts})
	return body
}

// seedField is the subset of a schema field the generator needs. It is parsed
// from the RAW /v1/schemas JSON (NOT apiclient.LoadSchemas, which discards v2
// subfields) so composite shapes round-trip.
type seedField struct {
	Name       string                     `json:"name"`
	Type       string                     `json:"type"`
	Options    []string                   `json:"options"`
	RefType    string                     `json:"refType"`
	Fields     []seedField                `json:"fields"`
	Of         *seedField                 `json:"-"` // populated by UnmarshalJSON (object OR array)
	Format     string                     `json:"format"`
	Validation map[string]json.RawMessage `json:"validation"`
}

// UnmarshalJSON tolerates an arrayOf `of` in BOTH shapes a v2 schema legitimately
// uses: the common single element-shape OBJECT (`"of": {"type": "reference"}`)
// and the multi-member ARRAY (`"of": [{"type": "object"}]` — e.g. the tickets
// plugin's arrayOf-of-union, api/lib/barkpark/plugins/tickets.ex). `bp seed`
// fetches and parses EVERY registered type in the dataset, so a single
// array-shaped `of` ANYWHERE must not abort the whole parse: with a plain
// `Of *seedField` the standard decoder errored `json: cannot unmarshal array
// into Go struct field seedField.schemas.fields.of`, which broke `bp seed`
// (and the AGENT-ONRAMPS CREATE arc) against any instance carrying such a
// schema. The array form collapses to its FIRST member shape — enough for the
// generator to fabricate a representative element; an empty/absent/scalar `of`
// yields no element shape (a valid empty-array draft).
func (f *seedField) UnmarshalJSON(data []byte) error {
	// A distinct alias type (no custom unmarshaler) decodes every field EXCEPT
	// `of` by reflection — including nested `fields`, which recurse back through
	// this method — while `of` arrives raw for shape-aware handling below.
	type rawSeedField struct {
		Name       string                     `json:"name"`
		Type       string                     `json:"type"`
		Options    []string                   `json:"options"`
		RefType    string                     `json:"refType"`
		Fields     []seedField                `json:"fields"`
		Of         json.RawMessage            `json:"of"`
		Format     string                     `json:"format"`
		Validation map[string]json.RawMessage `json:"validation"`
	}
	var r rawSeedField
	if err := json.Unmarshal(data, &r); err != nil {
		return err
	}
	f.Name = r.Name
	f.Type = r.Type
	f.Options = r.Options
	f.RefType = r.RefType
	f.Fields = r.Fields
	f.Format = r.Format
	f.Validation = r.Validation
	f.Of = decodeOfShape(r.Of)
	return nil
}

// decodeOfShape resolves an arrayOf `of` value that may be an OBJECT (one element
// shape) or an ARRAY (a union of member shapes — collapsed to the first). Absent,
// null, an empty array, or any non-object/non-array form yields nil, which the
// arrayOf generator renders as a valid empty array.
func decodeOfShape(raw json.RawMessage) *seedField {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return nil
	}
	switch trimmed[0] {
	case '{':
		var one seedField
		if err := json.Unmarshal(trimmed, &one); err != nil {
			return nil
		}
		return &one
	case '[':
		var many []seedField
		if err := json.Unmarshal(trimmed, &many); err != nil || len(many) == 0 {
			return nil
		}
		return &many[0]
	default:
		return nil
	}
}

// seedSchema is one content type's parsed schema.
type seedSchema struct {
	Name   string      `json:"name"`
	Fields []seedField `json:"fields"`
}

// seedFetchSchema GETs the scoped /v1/schemas/:dataset and returns the named
// type's parsed schema, or an error if the fetch fails or the type is absent.
func seedFetchSchema(ctx manifest.Context, dataset, typ string) (seedSchema, error) {
	u := ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset))
	status, body, err := doRequest("GET", u, ctxAuthHeaders(ctx), nil)
	if err != nil {
		return seedSchema{}, fmt.Errorf("fetch schemas: %v", err)
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, body)
		return seedSchema{}, fmt.Errorf("fetch schemas: %s", ae.errorMessage())
	}
	var env struct {
		Schemas []seedSchema `json:"schemas"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return seedSchema{}, fmt.Errorf("parse schemas: %v", jerr)
	}
	for _, s := range env.Schemas {
		if s.Name == typ {
			return s, nil
		}
	}
	return seedSchema{}, fmt.Errorf("unknown type %q in dataset %q", typ, dataset)
}

// generateDoc fabricates one sample document for schema s, numbered n. The id
// is deterministic (seed-<type>-<n>) so re-running overwrites rather than
// duplicates. _id/_type are always set; every declared field gets a per-type
// fake value. It is a PURE function (no network) so the generator is testable.
func generateDoc(s seedSchema, n int) map[string]any {
	doc := map[string]any{
		"_id":   fmt.Sprintf("seed-%s-%d", s.Name, n),
		"_type": s.Name,
	}
	for _, f := range s.Fields {
		// Never overwrite the system keys with a same-named content field.
		if f.Name == "_id" || f.Name == "_type" {
			continue
		}
		doc[f.Name] = fakeValue(f, n)
	}
	return doc
}

// fakeValue produces a plausible, deterministic value for one field given the
// sequence number n. Solid for v1 primitives and the recursive v2 shapes
// (composite recurses into its subfields; arrayOf populates two elements from
// its `of` element shape; localizedText fills nob/eng). codelist stays empty
// (a valid value needs the registry, which seed does not fetch) — harmless on
// the lenient draft path.
func fakeValue(f seedField, n int) any {
	switch f.Type {
	case "string":
		// A pattern (e.g. a slug regex) → slug-safe value; else a readable label.
		if _, hasPattern := f.Validation["pattern"]; hasPattern {
			return fmt.Sprintf("%s-%d", slugify(f.Name), n)
		}
		return fmt.Sprintf("%s %d", titleCase(f.Name), n)
	case "slug":
		return fmt.Sprintf("%s-%d", slugify(f.Name), n)
	case "text":
		return fmt.Sprintf("Sample %s content for seed document %d. Replace me.", f.Name, n)
	case "richText":
		// richText is Portable Text — an ARRAY of block nodes, not a plain string.
		// A plain string here would not render through @barkpark/react's
		// PortableText (which expects `_type:'block'` nodes) and misrepresents the
		// field's real shape. Emit one normal paragraph, one span — the minimal
		// value the Studio rich-text editor and the renderer both accept. Keys are
		// deterministic (n-based) so re-seeding overwrites byte-for-byte.
		return []any{
			map[string]any{
				"_type":    "block",
				"_key":     fmt.Sprintf("seedblk%d", n),
				"style":    "normal",
				"markDefs": []any{},
				"children": []any{
					map[string]any{
						"_type": "span",
						"_key":  fmt.Sprintf("seedspan%d", n),
						"text":  fmt.Sprintf("Sample %s content for seed document %d. Replace me.", f.Name, n),
						"marks": []any{},
					},
				},
			},
		}
	case "number":
		return n
	case "boolean":
		return n%2 == 0
	case "datetime":
		// Deterministic ISO-8601, spread across days of a fixed month.
		return fmt.Sprintf("2026-01-%02dT12:00:00Z", (n-1)%28+1)
	case "reference":
		ref := f.RefType
		if ref == "" {
			ref = "ref"
		}
		return map[string]any{"_ref": fmt.Sprintf("seed-%s-%d", ref, n)}
	case "select":
		if len(f.Options) > 0 {
			return f.Options[(n-1)%len(f.Options)]
		}
		return "option"
	case "color":
		return "#3366cc" // lit-allow: color-field seed DATA default (a field value, not chrome) — au-w4-cli-chrome-tokens
	case "image", "array":
		// Best-effort: a media reference / array needs real targets we don't have.
		// Leave an empty shape so a draft saves without a dangling pointer.
		if f.Type == "array" {
			return []any{}
		}
		return map[string]any{}
	case "composite", "object":
		obj := map[string]any{}
		for _, sub := range f.Fields {
			obj[sub.Name] = fakeValue(sub, n)
		}
		return obj
	case "arrayOf":
		// Generate two elements from the declared `of` element shape (recursing
		// through fakeValue, so composite/string/reference elements all work). If
		// the schema omits `of`, fall back to an empty array — still a valid draft.
		if f.Of != nil {
			return []any{fakeValue(*f.Of, n), fakeValue(*f.Of, n+1)}
		}
		return []any{}
	case "codelist":
		// Needs a registered issue value; empty is the safe draft placeholder.
		return ""
	case "localizedText":
		return map[string]any{"nob": fmt.Sprintf("Tekst %d", n), "eng": fmt.Sprintf("Text %d", n)}
	default:
		return fmt.Sprintf("%s-%d", slugify(f.Name), n)
	}
}

// slugify lower-cases and dash-joins a field name into a url-safe token.
func slugify(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	repl := strings.NewReplacer(" ", "-", "_", "-")
	s = repl.Replace(s)
	if s == "" {
		return "seed"
	}
	return s
}

// parseCount parses the --count flag, requiring a positive integer.
func parseCount(s string) (int, error) {
	const maxCount = 10000
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("invalid --count %q (want a positive integer)", s)
		}
		n = n*10 + int(r-'0')
		if n > maxCount {
			// guard against int overflow on a very long digit string
			return 0, fmt.Errorf("invalid --count %q (max %d)", s, maxCount)
		}
	}
	if n <= 0 {
		return 0, fmt.Errorf("invalid --count %q (must be >= 1)", s)
	}
	return n, nil
}

// ctxScopedURL builds a workspace/project-scoped /v1/ URL for ctx, mirroring
// migrateEndpoint.scopedURL and apiclient.Client.scopedURL. The flat
// manifest.BuildURL path is INERT in v1 (ScopedMirror=false) but the live
// server serves the scoped mirror, so every hand-rolled data command builds the
// scoped form here.
func ctxScopedURL(ctx manifest.Context, suffix string) string {
	ws := ctx.Workspace
	if ws == "" {
		ws = "default"
	}
	pr := ctx.Project
	if pr == "" {
		pr = "default"
	}
	return fmt.Sprintf("%s/w/%s/p/%s%s",
		strings.TrimRight(ctx.Server, "/"),
		url.PathEscape(ws),
		url.PathEscape(pr),
		suffix)
}

// ctxAuthHeaders returns the bearer header for ctx, or an empty map when no
// token is resolved.
func ctxAuthHeaders(ctx manifest.Context) map[string]string {
	h := map[string]string{}
	if ctx.Token != "" {
		h["Authorization"] = "Bearer " + ctx.Token
	}
	return h
}

// usageSeed prints the seed command signature. An explicit `--help` request
// routes to stdout (toStdout); the error paths keep it on stderr.
func usageSeed(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp seed <type> [--count N] [--dataset <ds>] [--publish] [--yes]")
	p("  fabricate sample documents for a content type and write them as drafts")
	p("")
	p("flags:")
	p("  --count N         how many documents to create (default 3)")
	p("  --dataset <ds>    target dataset (default: resolved dataset / production)")
	p("  --publish         also publish each doc, so it's visible to the published API")
	p("  --yes             skip the prod write confirmation")
	p("")
	p("ids are deterministic (seed-<type>-<n>): re-running overwrites, never duplicates.")
}
