package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// migrateBatchSize is how many createOrReplace mutations we POST per request on
// the execute path. Documents can be large (rich block bodies), so we keep the
// batch modest to stay well under any request-size limit while still amortising
// the per-request overhead. 50 is the documented default.
const migrateBatchSize = 50

// migratePageSize is how many documents we pull per query page when enumerating
// the source. The source query endpoint caps at its own limit; 100 mirrors the
// CLI's --all pagination default.
const migratePageSize = 100

// migrateEndpoint is one resolved server end of a migration: the saved name, the
// URL, the kind (local/cloud), and a built apiclient.Client carrying that
// server's token + scope. The Client is used for nothing but its scope fields
// here — the raw HTTP calls go through doRequest with scoped URLs — but holding
// it keeps the scope resolution in one place.
type migrateEndpoint struct {
	name      string
	url       string
	kind      string
	token     string
	workspace string
	project   string
}

// scopedURL builds a workspace/project-scoped /v1/ URL for this endpoint by
// delegating to apiclient.ScopedURL — the one owner of the scoped URL scheme —
// so a migration honours the same tenancy routing the rest of the CLI uses.
// (e.url is already trailing-slash-trimmed at populate in endpointFrom, so the
// TrimRight folded into ScopedURL is a no-op here — byte-identical.)
func (e migrateEndpoint) scopedURL(suffix string) string {
	return apiclient.ScopedURL(e.url, e.workspace, e.project, suffix)
}

func (e migrateEndpoint) authHeaders() map[string]string {
	h := map[string]string{}
	if e.token != "" {
		h["Authorization"] = "Bearer " + e.token
	}
	return h
}

// migratePlan is the computed-first plan, the dry-run payload, and the spine the
// execute path walks. Types is ordered (sorted) so output is stable.
type migratePlan struct {
	from           migrateEndpoint
	to             migrateEndpoint
	dataset        string
	types          []migrateTypeCount
	total          int
	includeSchemas bool
	schemaCount    int
}

type migrateTypeCount struct {
	Type  string `json:"type"`
	Count int    `json:"count"`
}

// runMigrate is the `bp migrate <from> <to> [flags]` built-in. It is SAFETY-
// FIRST: it always computes a full plan, prints it on a dry-run (the default),
// and only writes when --yes is set. A cloud target is never written without
// --yes and always prints the ⚠ warning.
//
// args is everything after the `migrate` noun, i.e. rest[1:] in Execute.
func runMigrate(out *writer, g globals, args []string) int {
	// `bp migrate --help` — parseGlobals consumed the flag into g.help, so honor
	// it here (usage to stdout, exit 0) instead of falling through to the
	// "needs <from> and <to>" argument error. Parity with seed/make/tinker.
	if g.help {
		usageMigrate(out, true)
		return exitOK
	}
	opt, perr := parseMigrateArgs(args)
	if perr != nil {
		out.userErr("%v", perr)
		usageMigrate(out, false)
		return exitUsage
	}

	// The GLOBAL parser (parseGlobals) consumes --yes, --dry-run, -d/--dataset,
	// -o/--json BEFORE migrate sees its args, reflecting them in `g`. So the
	// global layer is the source of truth for those; the migrate-local parser
	// only handles the pass-through flags (--type, --include-schemas) plus the
	// same flags when they slip through unconsumed. We merge: a global wins when
	// set, else the local parse.
	if g.yes {
		opt.yes = true
	}
	if g.dataset != "" && opt.dataset == "" {
		opt.dataset = g.dataset
	}

	if opt.from == "" || opt.to == "" {
		out.userErr("migrate needs <from> and <to> servers")
		usageMigrate(out, false)
		return exitUsage
	}

	// Output: honour an explicit -o; otherwise human (table) on a tty, json piped.
	// applyGlobals already resolved out.output; "table" is treated as human here.
	// Both json|yaml are machine shapes — the machine emitters go through
	// emitStructured, which handles both, so yaml is never silently downgraded.
	machineOut := out.output == "json" || out.output == "yaml"

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return migrateError(out, machineOut, "config", "read config: "+cerr.Error(), exitGeneric)
	}

	// Resolve from/to to known servers (name | DisplayName | URL).
	fromEntry, ok := cfg.FindServer(opt.from)
	if !ok {
		return migrateUnknownServer(out, machineOut, cfg, opt.from)
	}
	toEntry, ok := cfg.FindServer(opt.to)
	if !ok {
		return migrateUnknownServer(out, machineOut, cfg, opt.to)
	}

	dataset := opt.dataset
	if dataset == "" {
		dataset = firstNonEmptyStr(fromEntry.Dataset, "production")
	}

	// Token resolution per endpoint: the saved entry's token wins; else a shared
	// fallback (the global --token flag, then BARKPARK_API_TOKEN). The fallback
	// is the same value on both ends — fine for the common single-dev-token case;
	// for distinct creds, save them on the server entries via `bp setup`.
	fallbackTok := migrateFallbackToken(g)
	from := endpointFrom(cfg, fromEntry, fallbackTok)
	to := endpointFrom(cfg, toEntry, fallbackTok)

	// 1. Determine the set of types to migrate.
	var types []string
	if opt.typ != "" {
		types = []string{opt.typ}
	} else {
		enumerated, eerr := migrateListTypes(from, dataset)
		if eerr != nil {
			out.userErr("cannot enumerate source types: %v", eerr)
			out.errf("  hint: the source token needs admin to GET /v1/schemas/%s,", dataset)
			out.errf("        or pass --type <t> to migrate a single known type.")
			return exitAuth
		}
		types = enumerated
	}
	if len(types) == 0 {
		return migrateError(out, machineOut, "empty", "no document types to migrate", exitNotFound)
	}

	// 2. Compute per-type counts from the SOURCE (always — this is the plan).
	plan := migratePlan{
		from:           from,
		to:             to,
		dataset:        dataset,
		includeSchemas: opt.includeSchemas,
	}
	for _, t := range types {
		docs, qerr := migrateFetchAll(from, dataset, t)
		if qerr != nil {
			out.userErr("query source %s/%s failed: %v", dataset, t, qerr)
			return exitGeneric
		}
		plan.types = append(plan.types, migrateTypeCount{Type: t, Count: len(docs)})
		plan.total += len(docs)
	}
	if opt.includeSchemas {
		if names, serr := migrateListTypes(from, dataset); serr == nil {
			plan.schemaCount = len(names)
		}
	}

	targetIsCloud := to.kind == "cloud"

	// 3a. DRY-RUN (default unless --yes): print the plan, write NOTHING.
	if !opt.yes {
		return migratePrintDryRun(out, machineOut, plan, targetIsCloud)
	}

	// 3b. EXECUTE (--yes). Cloud-target guard: print the loud warning first. The
	// guard NEVER writes to a cloud target without --yes — and since we are inside
	// the --yes branch, --yes is the gate that has been satisfied.
	if targetIsCloud {
		out.errf("⚠ writing %d docs to %s [cloud]", plan.total, to.url)
	}

	return migrateExecute(out, machineOut, plan)
}

// endpointFrom builds a migrateEndpoint from a known ServerEntry: URL, kind, the
// token (saved entry token, else the shared fallback), and the workspace/project
// scope (defaulting to "default").
func endpointFrom(cfg *Config, e ServerEntry, fallbackToken string) migrateEndpoint {
	return migrateEndpoint{
		name:      cfg.DisplayName(e),
		url:       strings.TrimRight(e.Server, "/"),
		kind:      cfg.KindOf(e),
		token:     firstNonEmptyStr(e.Token, fallbackToken),
		workspace: firstNonEmptyStr(e.Workspace, "default"),
		project:   firstNonEmptyStr(e.Project, "default"),
	}
}

// migrateFallbackToken resolves the shared fallback token used when a saved
// server entry carries no token of its own: the global --token flag first, then
// BARKPARK_API_TOKEN from the environment.
func migrateFallbackToken(g globals) string {
	if g.token != "" {
		return g.token
	}
	return os.Getenv("BARKPARK_API_TOKEN")
}

// migrateListTypes enumerates the source dataset's document types via
// GET /v1/schemas/:dataset, returning the schema names sorted. A non-2xx or
// unparseable body is an error (admin not granted, server down, etc.).
func migrateListTypes(ep migrateEndpoint, dataset string) ([]string, error) {
	u := ep.scopedURL("/v1/schemas/" + url.PathEscape(dataset))
	status, body, err := doRequest("GET", u, ep.authHeaders(), nil)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, body)
		return nil, fmt.Errorf("status %d: %s", status, ae.errorMessage())
	}
	var env struct {
		Schemas []struct {
			Name string `json:"name"`
		} `json:"schemas"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return nil, fmt.Errorf("parse schema list: %w", jerr)
	}
	names := make([]string, 0, len(env.Schemas))
	for _, s := range env.Schemas {
		if s.Name != "" {
			names = append(names, s.Name)
		}
	}
	sort.Strings(names)
	return names, nil
}

// migrateFetchAll pages through every document of one type on the source using
// perspective=raw (so BOTH drafts and published rows migrate faithfully) and
// returns the raw document JSON objects. Pagination loops until a short page.
func migrateFetchAll(ep migrateEndpoint, dataset, typ string) ([]json.RawMessage, error) {
	var all []json.RawMessage
	offset := 0
	for {
		u := ep.scopedURL("/v1/data/query/" + url.PathEscape(dataset) + "/" + url.PathEscape(typ))
		u += fmt.Sprintf("?perspective=raw&limit=%d&offset=%d", migratePageSize, offset)
		status, body, err := doRequest("GET", u, ep.authHeaders(), nil)
		if err != nil {
			return nil, err
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, body)
			return nil, fmt.Errorf("status %d: %s", status, ae.errorMessage())
		}
		docs, qerr := migrateExtractDocs(body)
		if qerr != nil {
			return nil, qerr
		}
		all = append(all, docs...)
		if len(docs) < migratePageSize {
			break
		}
		offset += migratePageSize
	}
	return all, nil
}

// migrateExtractDocs pulls result.documents out of a query response body. The
// query endpoint wraps the payload in {"result":{…,"documents":[…]}}; we unwrap
// it and return the raw per-document JSON objects so they round-trip verbatim.
func migrateExtractDocs(body []byte) ([]json.RawMessage, error) {
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
		// Fallback: an unwrapped {"documents":[…]} (filterresponse off).
		Documents []json.RawMessage `json:"documents"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("parse query response: %w", err)
	}
	if env.Result.Documents != nil {
		return env.Result.Documents, nil
	}
	return env.Documents, nil
}

// migratePrintDryRun renders the plan and writes nothing.
func migratePrintDryRun(out *writer, machineOut bool, plan migratePlan, targetIsCloud bool) int {
	if machineOut {
		out.emitStructured(migratePlanJSON(plan, true, nil, 0, nil))
		return exitOK
	}

	out.outf("migration plan (DRY RUN — nothing written)")
	out.outf("  from:    %s [%s] — %s", plan.from.name, plan.from.kind, plan.from.url)
	out.outf("  to:      %s [%s] — %s", plan.to.name, plan.to.kind, plan.to.url)
	out.outf("  dataset: %s", plan.dataset)
	out.outf("  policy:  createOrReplace (overwrite-by-id on target)")
	if plan.includeSchemas {
		out.outf("  schemas: %d source schema(s) would be POSTed to the target first", plan.schemaCount)
	}
	out.outf("")
	out.outf("  %-24s %s", "TYPE", "DOCS")
	for _, tc := range plan.types {
		out.outf("  %-24s %d", tc.Type, tc.Count)
	}
	out.outf("  %-24s %d", "TOTAL", plan.total)
	out.outf("")
	if targetIsCloud {
		out.outf("⚠ target %s is CLOUD — a real run writes to a remote server.", plan.to.url)
	}
	out.outf("would migrate %d docs across %d type(s) from %s to %s; re-run with --yes to execute",
		plan.total, len(plan.types), plan.from.name, plan.to.name)
	return exitOK
}

// migrateExecute performs the real migration: optional schema copy first, then a
// batched createOrReplace write of every source document onto the target.
func migrateExecute(out *writer, machineOut bool, plan migratePlan) int {
	var migrated []migrateTypeCount
	var migrateErrors []string
	totalMigrated := 0

	// Optional: migrate schemas first so the target knows the types before docs
	// land. Best-effort per schema; a failure is recorded but does not abort the
	// document copy (the target may already carry the type).
	schemasMigrated := 0
	if plan.includeSchemas {
		n, errs := migrateSchemas(out, machineOut, plan)
		schemasMigrated = n
		migrateErrors = append(migrateErrors, errs...)
	}

	for _, tc := range plan.types {
		docs, qerr := migrateFetchAll(plan.from, plan.dataset, tc.Type)
		if qerr != nil {
			msg := fmt.Sprintf("query %s: %v", tc.Type, qerr)
			migrateErrors = append(migrateErrors, msg)
			if !machineOut {
				out.errf("  ✗ %s", msg)
			}
			continue
		}

		written := 0
		for start := 0; start < len(docs); start += migrateBatchSize {
			end := start + migrateBatchSize
			if end > len(docs) {
				end = len(docs)
			}
			batch := docs[start:end]
			// The count descends from the WRITE RETURN, never from len(batch):
			// migrateWriteBatch reads how many results the server handed back.
			confirmed, werr := migrateWriteBatch(plan.to, plan.dataset, batch)
			if werr != nil {
				msg := fmt.Sprintf("write %s batch [%d:%d]: %v", tc.Type, start, end, werr)
				migrateErrors = append(migrateErrors, msg)
				if !machineOut {
					out.errf("  ✗ %s", msg)
				}
				continue
			}
			written += confirmed
		}

		migrated = append(migrated, migrateTypeCount{Type: tc.Type, Count: written})
		totalMigrated += written
		if !machineOut {
			out.outf("%s", migrateTypeReceipt(tc.Type, written, len(docs)))
		}
	}

	if machineOut {
		out.emitStructured(migratePlanJSON(plan, false, migrated, totalMigrated, migrateErrors))
		if len(migrateErrors) > 0 {
			return exitGeneric
		}
		return exitOK
	}

	out.outf("")
	if plan.includeSchemas {
		out.outf("schemas migrated: %d", schemasMigrated)
	}
	out.outf("migrated %d/%d docs across %d type(s) from %s to %s",
		totalMigrated, plan.total, len(migrated), plan.from.name, plan.to.name)
	if len(migrateErrors) > 0 {
		out.errf("completed with %d error(s):", len(migrateErrors))
		for _, e := range migrateErrors {
			out.errf("  - %s", e)
		}
		return exitGeneric
	}
	return exitOK
}

// migrateSchemas copies every source schema onto the target via
// POST /v1/schemas/:dataset. Returns the count successfully POSTed and any
// per-schema errors. Best-effort: the target may already have a schema.
func migrateSchemas(out *writer, machineOut bool, plan migratePlan) (int, []string) {
	var errs []string
	// Fetch the full source schema list (with fields), not just names.
	u := plan.from.scopedURL("/v1/schemas/" + url.PathEscape(plan.dataset))
	status, body, err := doRequest("GET", u, plan.from.authHeaders(), nil)
	if err != nil || status < 200 || status >= 300 {
		errs = append(errs, fmt.Sprintf("fetch source schemas: status %d", status))
		return 0, errs
	}
	var env struct {
		Schemas []json.RawMessage `json:"schemas"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		errs = append(errs, "parse source schemas: "+jerr.Error())
		return 0, errs
	}

	count := 0
	target := plan.to.scopedURL("/v1/schemas/" + url.PathEscape(plan.dataset))
	headers := plan.to.authHeaders()
	headers["Content-Type"] = "application/json"
	for _, raw := range env.Schemas {
		st, rb, werr := doRequest("POST", target, headers, raw)
		if werr != nil {
			errs = append(errs, "POST schema: "+werr.Error())
			continue
		}
		if st < 200 || st >= 300 {
			ae := classifyError(st, rb)
			errs = append(errs, fmt.Sprintf("POST schema: status %d: %s", st, ae.errorMessage()))
			continue
		}
		// count++ used to fire on the STATUS alone — nothing here ever read rb —
		// so a gateway page or an empty 200 per schema still produced
		// `✓ schemas: N POSTed to target` AND put N in the -o json receipt. Its
		// sibling migrateWriteBatch already refuses to report a number it could
		// not measure (migrateBatchWritten); this arm is that same law applied to
		// the schema half, which was measuring nothing at all.
		if serr := builtinWriteReceiptErr("POST schema", st, rb); serr != nil {
			errs = append(errs, serr.Error())
			continue
		}
		count++
	}
	if !machineOut && count > 0 {
		out.outf("  ✓ schemas: %d POSTed to target", count)
	}
	return count, errs
}

// migrateTypeReceipt renders one type's migration line. Both numbers it prints
// are measurements: `written` is the count of results the SERVER returned for
// the batches (see migrateBatchWritten), `total` is how many documents the
// source handed us. When they disagree the line refuses the checkmark and says
// how many writes went unconfirmed — a receipt that printed ✓ over a short
// write would be claiming a post-condition nothing measured (PDS-D313 class A3).
func migrateTypeReceipt(typ string, written, total int) string {
	if written != total {
		return fmt.Sprintf("  ! %-24s %d/%d — the server confirmed %d write results for the %d documents sent",
			typ, written, total, written, total)
	}
	return fmt.Sprintf("  ✓ %-24s %d/%d", typ, written, total)
}

// migrateBatchWritten reads how many documents the server said it wrote out of
// a 2xx /v1/data/mutate response. `results` carries exactly one entry per
// applied mutation (Content.Mutations.do_apply_mutations maps the batch 1:1
// through Enum.map_reduce), so its LENGTH is the measurement; len(docs) is only
// what we asked for. A response we cannot read is an error, not a full count:
// "we could not tell" must never be reported as "all of them landed".
func migrateBatchWritten(respBody []byte) (int, error) {
	var parsed struct {
		Results []json.RawMessage `json:"results"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return 0, fmt.Errorf("write accepted but its response did not parse, so the number written is unknown: %w", err)
	}
	if parsed.Results == nil {
		return 0, fmt.Errorf("write accepted but the response carried no results array, so the number written is unknown")
	}
	return len(parsed.Results), nil
}

// migrateWriteBatch writes a batch of raw source documents to the target as
// createOrReplace mutations. Each source document JSON object becomes the body
// of a createOrReplace op verbatim, so _id/_type and every field round-trip.
// It returns the number of writes the SERVER confirmed — the length of the
// `results` array it handed back, not the length of the batch we sent.
func migrateWriteBatch(ep migrateEndpoint, dataset string, docs []json.RawMessage) (int, error) {
	if len(docs) == 0 {
		return 0, nil
	}
	mutations := make([]map[string]json.RawMessage, 0, len(docs))
	for _, d := range docs {
		mutations = append(mutations, map[string]json.RawMessage{"createOrReplace": d})
	}
	bodyMap := map[string]any{"mutations": mutations}
	body, merr := json.Marshal(bodyMap)
	if merr != nil {
		return 0, merr
	}

	u := ep.scopedURL("/v1/data/mutate/" + url.PathEscape(dataset))
	headers := ep.authHeaders()
	headers["Content-Type"] = "application/json"
	status, respBody, err := doRequest("POST", u, headers, body)
	if err != nil {
		return 0, err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return 0, fmt.Errorf("status %d: %s", status, ae.errorMessage())
	}
	return migrateBatchWritten(respBody)
}

// migratePlanJSON projects a plan (and, on execute, the result) onto the JSON
// shape documented for -o json.
func migratePlanJSON(plan migratePlan, dryRun bool, migrated []migrateTypeCount, totalMigrated int, errs []string) map[string]any {
	endpointJSON := func(e migrateEndpoint) map[string]any {
		return map[string]any{"name": e.name, "url": e.url, "kind": e.kind}
	}
	obj := map[string]any{
		"from":            endpointJSON(plan.from),
		"to":              endpointJSON(plan.to),
		"dataset":         plan.dataset,
		"types":           plan.types,
		"total":           plan.total,
		"include_schemas": plan.includeSchemas,
		"dry_run":         dryRun,
	}
	if !dryRun {
		if migrated == nil {
			migrated = []migrateTypeCount{}
		}
		if errs == nil {
			errs = []string{}
		}
		obj["migrated"] = migrated
		obj["total_migrated"] = totalMigrated
		obj["errors"] = errs
	}
	return obj
}

// parsedMigrateArgs holds the resolved migrate flags + positionals.
type parsedMigrateArgs struct {
	from           string
	to             string
	dataset        string
	typ            string
	includeSchemas bool
	yes            bool
}

// parseMigrateArgs parses `<from> <to>` plus migrate-local flags. The global
// parser already stripped -o/--json/--yes etc., but migrate is a built-in that
// bypasses the manifest runner — so it accepts --yes and --dataset/--type/
// --include-schemas/--dry-run here too (and tolerates a -o json that the global
// parser consumed). --dry-run is the default, so it is accepted as a no-op for
// explicitness. --yes flips to execute.
func parseMigrateArgs(args []string) (parsedMigrateArgs, error) {
	var p parsedMigrateArgs
	var pos []string
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--dataset":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--dataset")
			if err != nil {
				return p, err
			}
			p.dataset = v
			i = ni
		case "--type":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--type")
			if err != nil {
				return p, err
			}
			p.typ = v
			i = ni
		case "--include-schemas":
			p.includeSchemas = true
			i++
		case "--dry-run":
			// Default behaviour; accepted for explicitness. No-op (the absence of
			// --yes is what keeps us in dry-run).
			i++
		case "--yes":
			p.yes = true
			i++
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				return p, fmt.Errorf("unknown migrate flag %q", a)
			}
			pos = append(pos, a)
			i++
		}
	}
	if len(pos) > 2 {
		return p, fmt.Errorf("too many arguments; usage: bp migrate <from> <to>")
	}
	if len(pos) >= 1 {
		p.from = pos[0]
	}
	if len(pos) >= 2 {
		p.to = pos[1]
	}
	return p, nil
}

// splitFlagToken splits "--key=value" into ("--key","value",true); a bare
// "--key" returns ("--key","",false); a non-flag returns the token verbatim as
// key with hasInline=false.
func splitFlagToken(a string) (key, val string, hasInline bool) {
	if !strings.HasPrefix(a, "--") {
		return a, "", false
	}
	if eq := strings.IndexByte(a, '='); eq >= 0 {
		return a[:eq], a[eq+1:], true
	}
	return a, "", false
}

// flagValue resolves a value flag's value from the inline form or the next arg,
// returning the new index to continue from.
func flagValue(args []string, i int, inlineVal string, hasInline bool, name string) (string, int, error) {
	if hasInline {
		return inlineVal, i + 1, nil
	}
	if i+1 >= len(args) {
		return "", i, fmt.Errorf("flag %s needs a value", name)
	}
	return args[i+1], i + 2, nil
}

// migrateUnknownServer is the clean miss path for an unresolvable <from>/<to>.
// Lists known names and exits 2 (usage), mirroring `bp use`'s miss path.
func migrateUnknownServer(out *writer, machineOut bool, cfg *Config, q string) int {
	names := knownNames(cfg)
	if machineOut {
		out.emitStructured(map[string]any{
			"ok": false,
			"error": map[string]any{
				"code":    "not_found",
				"message": "no known server matches " + q,
				"known":   names,
			},
		})
		return exitUsage
	}
	out.userErr("no known server matches %q", q)
	if len(names) > 0 {
		out.errf("known servers: %s", joinComma(names))
		out.errf("run `bp servers` for details, or pass a full URL.")
	} else {
		out.errf("no saved servers yet — run 'bp setup --target connect --server <url>'")
	}
	return exitUsage
}

// migrateError emits a structured {ok:false,error:{code,message}} on -o json|yaml,
// else a one-line stderr message, and returns the exit code.
func migrateError(out *writer, machineOut bool, code, msg string, exit int) int {
	if machineOut {
		out.emitStructured(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": code, "message": msg},
		})
		return exit
	}
	out.userErr("%s", msg)
	return exit
}

// usageMigrate prints the migrate command signature. When help is true the user
// explicitly asked for it (`bp migrate --help`), so it goes to stdout and the
// caller exits 0; on an argument error it goes to stderr alongside a non-zero
// exit. Matches the seed/make/tinker help convention.
func usageMigrate(out *writer, help bool) {
	p := out.errf
	if help {
		p = out.outf
	}
	p("usage: bp migrate <from> <to> [flags]")
	p("  copy documents from one barkpark server to another (createOrReplace, by-id)")
	p("")
	p("flags:")
	p("  --dataset <name>    dataset to migrate (default production)")
	p("  --type <t>          migrate just one type (else all source types)")
	p("  --include-schemas   POST source schemas to the target first")
	p("  --dry-run           plan only, write nothing (DEFAULT)")
	p("  --yes               execute the migration (required to write)")
	p("  -o json             machine-readable plan / result")
	p("")
	p("safety: dry-run by default; a real run needs --yes; a cloud target is")
	p("        never written without --yes and prints a ⚠ warning.")
}

// firstNonEmptyStr returns the first non-blank string, or "".
func firstNonEmptyStr(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
