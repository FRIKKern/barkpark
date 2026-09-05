package cli

// cloud_webhook_cmd.go is `bp cloud webhook <verb> <instance> …` — the terminal
// twin of the console's Webhooks panel (epic charter C6/C7, decisions D46/D51).
// It is the operator's way to CONTROL a managed instance's webhooks from the
// CLI without ever holding an instance token: every verb calls the control-plane
// INSTANCE-API PROXY (`/v1/barkparks/:id/api/webhooks*`), authenticated with the
// CLOUD session token via internal/cloudclient. The proxy decrypts the instance
// admin token server-side and relays — the browser and the CLI only ever see the
// uniform proxy envelope (D51).
//
// Verb set (the wave-C2 ratified spellings — C6's copy-as-CLI chips emit exactly
// these, so they MUST parse):
//
//	list       <instance>
//	show       <instance> <webhook-id>
//	create     <instance> <url>            [--name <n>] [--events a,b] [--types a,b]
//	edit       <instance> <webhook-id>     [--name] [--url] [--events] [--types] (partial PUT)
//	rm         <instance> <webhook-id>     [--yes]      (typed-resource confirm)
//	toggle     <instance> <webhook-id>                  (PUT {active:<flipped>})
//	rotate     <instance> <webhook-id>                  (prints the new secret ONCE)
//	deliveries <instance> <webhook-id>
//	replay     <instance> <webhook-id> <event-id>
//	reconcile  <instance>                  [--dry-run]  (re-assert the doc-type filter)
//
// Every verb takes `--dataset <ds>` (default "production") and the CLI-wide
// `-o json|yaml|table|minimal`. `-o json` emits the proxy envelope VERBATIM —
// the envelope IS the contract (D4), so nothing is reshaped. The table path
// paints status cells through the shared statusRole seam (D12) so a red row here
// and a red dot in the dashboard mean the same thing.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// runCloudWebhook is the `bp cloud webhook <verb> …` dispatcher. It requires a
// Cloud session token (`bp login`) for EVERY verb — even a bare-UUID instance —
// because the proxy call itself is Bearer-authed against the control plane.
func runCloudWebhook(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (so `bp cloud webhook list -h`
	// helps instead of erroring as an unknown flag) — the runLoginCloud / cloud12
	// per-verb convention. No positional can legitimately start with "-".
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudWebhookHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudWebhookHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing webhook command (run `bp cloud webhook -h` for usage)", exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to control an instance's webhooks, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runWebhookList(out, cfg, rest)
	case "show", "get":
		return runWebhookShow(out, cfg, rest)
	case "create", "add":
		return runWebhookCreate(out, cfg, rest)
	case "edit", "update":
		return runWebhookEdit(out, cfg, rest)
	case "rm", "delete", "del":
		return runWebhookRm(out, cfg, rest)
	case "toggle":
		return runWebhookToggle(out, cfg, rest)
	case "rotate":
		return runWebhookRotate(out, cfg, rest)
	case "deliveries":
		return runWebhookDeliveries(out, cfg, rest)
	case "replay":
		return runWebhookReplay(out, cfg, rest)
	case "reconcile":
		// g rides along because --dry-run is a GLOBAL flag: parseGlobals strips it
		// from args ANYWHERE on the line, so a verb that only looked at its own
		// parsed flags would never see it — and would WRITE on a dry run. See
		// runWebhookReconcile.
		return runWebhookReconcile(out, g, cfg, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown webhook command %q (run `bp cloud webhook -h` for usage)", verb), exitUsage)
	}
}

// ---------------------------------------------------------------------------
// Verb runners
// ---------------------------------------------------------------------------

func runWebhookList(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook list <instance> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 1, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	dataset := webhookDataset(a)
	res, err := cfg.CloudClient().WebhookList(cloudCtx(), id, dataset)
	if err != nil {
		return cloudFail(out, "list webhooks", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	renderWebhookList(out, res.Data, dataset)
	return exitOK
}

func runWebhookShow(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook show <instance> <webhook-id> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, err := cfg.CloudClient().WebhookShow(cloudCtx(), id, webhookDataset(a), pos[1])
	if err != nil {
		return cloudFail(out, "show webhook", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	renderTable(out, res.Data)
	return exitOK
}

func runWebhookCreate(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook create <instance> <url> [--name <n>] [--events a,b] [--types a,b] [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset", "name", "events", "types"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	body := map[string]any{"url": pos[1]}
	if name := strings.TrimSpace(a.val("name")); name != "" {
		body["name"] = name
	}
	if events := a.list("events"); len(events) > 0 {
		body["events"] = events
	}
	if types := a.list("types"); len(types) > 0 {
		body["types"] = types
	}
	res, err := cfg.CloudClient().WebhookCreate(cloudCtx(), id, webhookDataset(a), body)
	if err != nil {
		return cloudFail(out, "create webhook", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	wh := webhookObject(res.Data)
	out.outf("created webhook %s", webhookCell(wh["id"]))
	renderTable(out, res.Data)
	return exitOK
}

// runWebhookEdit is the full-edit twin of the console's Webhooks edit panel
// (D36: one product, two surfaces). It PUTs a PARTIAL update through the generic
// WebhookUpdate capability — ONLY the flags the caller actually passed enter the
// body, so an omitted field keeps its stored value (the upstream changeset
// merges what it receives). Passing zero editable flags is a usage error, caught
// BEFORE any instance resolve so it never touches the network. `edit` and
// `update` are the two blessed spellings.
func runWebhookEdit(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook edit <instance> <webhook-id> [--name <n>] [--url <u>] [--events a,b] [--types a,b] [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset", "name", "url", "events", "types"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	ref, whID := pos[0], pos[1]

	// Partial-update body: presence of the flag KEY (not a non-empty value) decides
	// inclusion, so `--name ""` deliberately clears a name and an omitted --name is
	// left untouched. events/types coerce nil → [] so an explicit clear PUTs an
	// empty list rather than a null.
	body := map[string]any{}
	if _, present := a.vals["name"]; present {
		body["name"] = a.val("name")
	}
	if _, present := a.vals["url"]; present {
		body["url"] = a.val("url")
	}
	if _, present := a.vals["events"]; present {
		ev := a.list("events")
		if ev == nil {
			ev = []string{}
		}
		body["events"] = ev
	}
	if _, present := a.vals["types"]; present {
		ty := a.list("types")
		if ty == nil {
			ty = []string{}
		}
		body["types"] = ty
	}
	if len(body) == 0 {
		return useError(out, "usage", "nothing to edit — pass at least one of --name/--url/--events/--types (usage: "+usage+")", exitUsage)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, err := cfg.CloudClient().WebhookUpdate(cloudCtx(), id, webhookDataset(a), whID, body)
	if err != nil {
		return cloudFail(out, "edit webhook", err)
	}
	if code, done := webhookRespond(out, res, ref); done {
		return code
	}
	wh := webhookObject(res.Data)
	out.outf("updated webhook %s", webhookCell(wh["id"]))
	renderTable(out, res.Data)
	return exitOK
}

func runWebhookRm(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook rm <instance> <webhook-id> [--dataset <ds>] [--yes]"
	a, err := parseHzArgs(rest, []string{"dataset"}, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	ref, whID := pos[0], pos[1]
	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	dataset := webhookDataset(a)
	yes := a.bools["yes"]
	client := cfg.CloudClient()

	// Interactive branch only: fetch the endpoint first so the confirm names the
	// real URL and accepts EITHER the id or the URL. --yes and a non-TTY stdin
	// (scripts / CI) skip both the fetch and the prompt (D5 passthrough). A
	// mismatch below aborts before any DELETE is issued.
	url := ""
	if !yes && hzStdinIsTTY(hzStdin) {
		show, serr := client.WebhookShow(cloudCtx(), id, dataset, whID)
		if serr != nil {
			return cloudFail(out, "read webhook", serr)
		}
		if !show.OK {
			code, _ := webhookRespond(out, show, ref)
			return code
		}
		url = webhookURL(show.Data)
	}
	if cerr := webhookConfirmDelete(hzStdin, out, whID, url, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}

	res, err := client.WebhookDelete(cloudCtx(), id, dataset, whID)
	if err != nil {
		return cloudFail(out, "delete webhook", err)
	}
	if code, done := webhookRespond(out, res, ref); done {
		return code
	}
	out.outf("deleted webhook %s (and its delivery history)", whID)
	return exitOK
}

func runWebhookToggle(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook toggle <instance> <webhook-id> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	ref, whID := pos[0], pos[1]
	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	dataset := webhookDataset(a)
	client := cfg.CloudClient()

	// No toggle route exists (wave-C1 ratification (a)): read the current state,
	// then PUT {active: <flipped>} through the update capability. A failed read
	// short-circuits with its own honest envelope.
	show, serr := client.WebhookShow(cloudCtx(), id, dataset, whID)
	if serr != nil {
		return cloudFail(out, "read webhook", serr)
	}
	if !show.OK {
		code, _ := webhookRespond(out, show, ref)
		return code
	}

	res, uerr := client.WebhookUpdate(cloudCtx(), id, dataset, whID, map[string]any{"active": !webhookActive(show.Data)})
	if uerr != nil {
		return cloudFail(out, "toggle webhook", uerr)
	}
	if code, done := webhookRespond(out, res, ref); done {
		return code
	}
	// Render the RESPONSE body's active / consecutive_failures / disable_reason so
	// the D55 re-enable truth (does turning it back on clear the auto-disable?) is
	// visible in the terminal, not just the dashboard.
	wh := webhookObject(res.Data)
	state := "inactive"
	if active, _ := wh["active"].(bool); active {
		state = "active"
	}
	out.outf("webhook %s is now %s", webhookCell(wh["id"]), state)
	out.outf("  consecutive_failures: %s", webhookCell(wh["consecutive_failures"]))
	out.outf("  disable_reason: %s", webhookCell(wh["disable_reason"]))
	return exitOK
}

func runWebhookRotate(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook rotate <instance> <webhook-id> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, err := cfg.CloudClient().WebhookRotate(cloudCtx(), id, webhookDataset(a), pos[1])
	if err != nil {
		return cloudFail(out, "rotate webhook secret", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	wh := webhookObject(res.Data)
	out.outf("rotated signing secret for webhook %s", webhookCell(wh["id"]))
	secret := webhookSecret(res.Data)
	if strings.TrimSpace(secret) == "" {
		out.outf("(the instance did not return a new secret)")
		return exitOK
	}
	out.outf("")
	out.outf("new secret (shown ONCE — store it now; it will not be shown again):")
	out.outf("  %s", secret)
	return exitOK
}

func runWebhookDeliveries(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook deliveries <instance> <webhook-id> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 2, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, err := cfg.CloudClient().WebhookDeliveries(cloudCtx(), id, webhookDataset(a), pos[1])
	if err != nil {
		return cloudFail(out, "list deliveries", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	renderWebhookDeliveries(out, res.Data)
	return exitOK
}

func runWebhookReplay(out *writer, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook replay <instance> <webhook-id> <event-id> [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 3, usage)
	if !ok {
		return exitUsage
	}
	id, rerr := resolveOpenBarkparkID(cfg, pos[0])
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	whID, eventID := pos[1], pos[2]
	res, err := cfg.CloudClient().WebhookReplay(cloudCtx(), id, webhookDataset(a), whID, eventID)
	if err != nil {
		return cloudFail(out, "replay event", err)
	}
	if code, done := webhookRespond(out, res, pos[0]); done {
		return code
	}
	del := webhookDelivery(res.Data)
	out.outf("replayed event %s to webhook %s", eventID, whID)
	out.outf("  status: %s  code: %s  latency: %s ms  attempts: %s",
		webhookCell(del["status"]), webhookCell(del["last_status_code"]),
		webhookCell(del["last_latency_ms"]), webhookCell(del["attempts"]))
	// A replay is a MANUAL redelivery — allowed even when the webhook is inactive
	// (wave-C1 ratification (d)); say so plainly so the result is never mistaken
	// for the endpoint being live.
	out.outf("note: a replay is delivered even when the webhook is inactive (manual redelivery).")
	return exitOK
}

// ---------------------------------------------------------------------------
// reconcile — re-assert the doc-type filter on the site-autodeploy rows
// ---------------------------------------------------------------------------

// contentWebhookPrefix is the box-side identity of a spawned site's
// content-publish webhook: the control plane names the row
// `site-autodeploy-<site.id>` (Registry.content_webhook_name/1) and that name is
// the ONLY key linking a box row back to its control-plane site. Reconcile reads
// the site id straight out of the name for exactly that reason — matching on the
// URL would re-derive an identity the control plane already publishes.
const contentWebhookPrefix = "site-autodeploy-"

// webhookReconcileRow is one row's verdict. It is both the human line and the
// `-o json` element, so a scripted operator sees precisely what a human saw.
type webhookReconcileRow struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	SiteID       string   `json:"site_id"`
	CurrentTypes []string `json:"current_types"`
	DesiredTypes []string `json:"desired_types,omitempty"`
	// Action is one of: ok (already correct), updated, would-update (--dry-run),
	// skipped (doc_type undeterminable — REPORTED, never guessed), failed (the
	// write was refused).
	Action string `json:"action"`
	Detail string `json:"detail,omitempty"`
}

// runWebhookReconcile re-asserts the DOC-TYPE FILTER on every `site-autodeploy-*`
// endpoint of an instance, through the SAME partial-PUT path `edit` uses.
//
// Why a verb and not a hand-edit: the box treats `types = {}` as MATCH
// EVERYTHING, so a site-autodeploy row with an empty filter rebuilds its site on
// every mutation in a shared dataset. Measured on guerrilla 2026-08-07: 2,310
// deliveries in 6 h across 5 endpoints (77.0/hr/endpoint); with the site's own
// doc_type that is 5.3 — a 93.1% cut, because 90.3% of all writes on that box are
// this repo's `task` ledger. A one-off `bp cloud webhook edit --types` fixes the
// row until the next doc_type change drifts it back, with nothing re-asserting
// it; this verb is the thing that re-asserts it, and it is safe to re-run.
//
// FAIL CLOSED, LOUDLY. The desired filter is the site's OWN doc_type read from
// the control plane (the same value Registry.content_webhook_types/1 sends). A
// row whose site cannot be read, or whose site carries no doc_type, is REPORTED
// AND SKIPPED — never guessed, never quietly passed over — and any skip or
// refused write makes the whole run exit non-zero.
//
// --dry-run is read from BOTH the globals and this verb's own flag set, and that
// is not belt-and-braces: `--dry-run` is a GLOBAL flag (globals.go), so
// parseGlobals lifts it out of the line before the verb ever sees its args —
// a verb reading only `a.bools["dry-run"]` writes on a dry run, and a unit test
// that calls the runner directly (bypassing parseGlobals) reports green while it
// does. The local flag stays declared so the usage line and the help agree, and
// so `--dry-run` keeps working if it is ever de-globalised.
func runWebhookReconcile(out *writer, g globals, cfg *Config, rest []string) int {
	const usage = "bp cloud webhook reconcile <instance> [--dry-run] [--dataset <ds>]"
	a, err := parseHzArgs(rest, []string{"dataset"}, []string{"dry-run"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	pos, ok := webhookPositionals(out, a, 1, usage)
	if !ok {
		return exitUsage
	}
	ref := pos[0]
	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	dataset := webhookDataset(a)
	dryRun := g.dryRun || a.bools["dry-run"]
	client := cfg.CloudClient()

	list, err := client.WebhookList(cloudCtx(), id, dataset)
	if err != nil {
		return cloudFail(out, "list webhooks", err)
	}
	if !list.OK {
		// A failed read is handled by the shared seam in BOTH shapes (envelope
		// verbatim for machines, one honest line for humans) — and crucially it
		// issues no writes: "I could not look" never authorizes a repair.
		code, _ := webhookRespond(out, list, ref)
		return code
	}

	all := webhookRowsOf(list.Data)
	rows := make([]webhookReconcileRow, 0, len(all))
	docTypes := map[string]docTypeLookup{}
	other := 0
	for _, wh := range all {
		name := cellString(wh["name"])
		if !strings.HasPrefix(name, contentWebhookPrefix) {
			// Somebody else's endpoint. Reconcile owns the site-autodeploy rows
			// and nothing else — it must never rewrite a hand-made webhook.
			other++
			continue
		}
		rows = append(rows, reconcileRow(client, id, dataset, wh, name, docTypes, dryRun))
	}

	summary := map[string]int{"updated": 0, "would_update": 0, "ok": 0, "skipped": 0, "failed": 0}
	for _, r := range rows {
		switch r.Action {
		case "updated":
			summary["updated"]++
		case "would-update":
			summary["would_update"]++
		case "ok":
			summary["ok"]++
		case "skipped":
			summary["skipped"]++
		case "failed":
			summary["failed"]++
		}
	}
	code := exitOK
	if summary["skipped"] > 0 || summary["failed"] > 0 {
		code = exitGeneric
	}

	if out.emitStructured(map[string]any{
		"instance":      ref,
		"dataset":       dataset,
		"dry_run":       dryRun,
		"webhooks":      rows,
		"other_rows":    other,
		"summary":       summary,
		"reconciled_ok": code == exitOK,
	}) {
		return code
	}
	renderWebhookReconcile(out, rows, other, summary, dataset, dryRun)
	return code
}

// docTypeLookup is one site's resolved doc_type (or the reason it is unknown),
// memoised so a run reads each site from the control plane at most once.
type docTypeLookup struct {
	docType string
	err     string
}

// reconcileRow decides — and, unless --dry-run, performs — one row's repair.
func reconcileRow(client *cloudclient.Client, id, dataset string, wh map[string]any, name string, cache map[string]docTypeLookup, dryRun bool) webhookReconcileRow {
	whID := cellString(wh["id"])
	siteID := strings.TrimPrefix(name, contentWebhookPrefix)
	row := webhookReconcileRow{ID: whID, Name: name, SiteID: siteID, CurrentTypes: webhookTypes(wh)}

	look, seen := cache[siteID]
	if !seen {
		look = lookupSiteDocType(client, siteID)
		cache[siteID] = look
	}
	// FAIL CLOSED: no readable site, or a site with no doc_type, is reported and
	// skipped. Guessing here would filter a site's real content away.
	if look.err != "" {
		row.Action, row.Detail = "skipped", look.err
		return row
	}
	row.DesiredTypes = []string{look.docType}
	if sameTypes(row.CurrentTypes, row.DesiredTypes) {
		row.Action = "ok"
		return row
	}
	if dryRun {
		row.Action = "would-update"
		return row
	}
	// The SAME partial PUT `edit --types` issues: only `types` enters the body,
	// so name/url/events/active keep their stored values.
	res, err := client.WebhookUpdate(cloudCtx(), id, dataset, whID, map[string]any{"types": row.DesiredTypes})
	if err != nil {
		row.Action, row.Detail = "failed", err.Error()
		return row
	}
	if !res.OK {
		row.Action, row.Detail = "failed", webhookFailureLine(res)
		return row
	}
	row.Action = "updated"
	return row
}

// lookupSiteDocType reads the site's OWN doc_type from the control plane — the
// value its build reads (BARKPARK_DOC_TYPE) and the exact array
// Registry.content_webhook_types/1 would send. Both failure shapes carry a
// reason, because a skip the operator cannot explain is a silent failure.
func lookupSiteDocType(client *cloudclient.Client, siteID string) docTypeLookup {
	if strings.TrimSpace(siteID) == "" {
		return docTypeLookup{err: "webhook name carries no site id after \"" + contentWebhookPrefix + "\" — cannot determine a doc type"}
	}
	site, err := client.GetSpawnSite(cloudCtx(), siteID)
	if err != nil {
		return docTypeLookup{err: "control plane could not read site " + siteID + ": " + err.Error()}
	}
	docType := strings.TrimSpace(site.DocType)
	if docType == "" {
		return docTypeLookup{err: "site " + siteID + " has no doc_type on the control plane — refusing to guess a filter"}
	}
	return docTypeLookup{docType: docType}
}

// renderWebhookReconcile prints the human report: one line per site-autodeploy
// row with its before → after, then a summary. A skip is printed on STDERR as
// well, so a piped run cannot lose the one line that says a row was not fixed.
func renderWebhookReconcile(out *writer, rows []webhookReconcileRow, other int, summary map[string]int, dataset string, dryRun bool) {
	if len(rows) == 0 {
		out.outf("no %s* webhooks in dataset %q — nothing to reconcile", contentWebhookPrefix, dataset)
		if other > 0 {
			out.outf("(%d other webhook(s) left untouched — reconcile only owns the site-autodeploy rows)", other)
		}
		return
	}
	if dryRun {
		out.outf("DRY RUN — nothing will be written.")
	}
	out.outf("reconciling the doc-type filter on %d %s* webhook(s) in dataset %q:", len(rows), contentWebhookPrefix, dataset)
	for _, r := range rows {
		switch r.Action {
		case "ok":
			out.outf("  %s  %s  already correct (types %s)", r.Name, r.ID, typesLabel(r.CurrentTypes))
		case "updated":
			out.outf("  %s  %s  types %s → %s  UPDATED", r.Name, r.ID, typesLabel(r.CurrentTypes), typesLabel(r.DesiredTypes))
		case "would-update":
			out.outf("  %s  %s  types %s → %s  (would update)", r.Name, r.ID, typesLabel(r.CurrentTypes), typesLabel(r.DesiredTypes))
		case "skipped":
			out.outf("  %s  %s  SKIPPED — %s", r.Name, r.ID, r.Detail)
			out.errf("skipped %s: %s", r.Name, r.Detail)
		case "failed":
			out.outf("  %s  %s  FAILED — %s", r.Name, r.ID, r.Detail)
			out.errf("could not update %s: %s", r.Name, r.Detail)
		}
	}
	out.outf("summary: %d updated, %d would update, %d already correct, %d skipped, %d failed",
		summary["updated"], summary["would_update"], summary["ok"], summary["skipped"], summary["failed"])
	if other > 0 {
		out.outf("(%d other webhook(s) left untouched — reconcile only owns the site-autodeploy rows)", other)
	}
	if summary["skipped"] > 0 || summary["failed"] > 0 {
		out.outf("some rows were NOT repaired (see above) — exiting non-zero.")
	}
}

// typesLabel renders a filter array for a human: the empty array is the box's
// MATCH-EVERYTHING sentinel and is labelled as such, because "[]" reads like
// "nothing is delivered" when it means the exact opposite.
func typesLabel(types []string) string {
	if len(types) == 0 {
		return "{} (match everything)"
	}
	return "[" + strings.Join(types, ",") + "]"
}

// webhookRowsOf decodes the {"webhooks":[…]} list payload.
func webhookRowsOf(data json.RawMessage) []map[string]any {
	var body struct {
		Webhooks []map[string]any `json:"webhooks"`
	}
	_ = json.Unmarshal(data, &body)
	return body.Webhooks
}

// webhookTypes reads a row's doc-type filter. A missing/null key and an empty
// array are the same thing on the box (match everything) and both decode to an
// empty slice; a non-string element is kept verbatim so a surprising value is
// visible rather than silently dropped.
func webhookTypes(wh map[string]any) []string {
	raw, _ := wh["types"].([]any)
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		out = append(out, cellString(v))
	}
	return out
}

// sameTypes reports whether the stored filter already IS the desired one, in the
// same order the control plane would write it (a single element today).
func sameTypes(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// webhookFailureLine renders a FAILURE envelope as one line for a per-row report
// (renderWebhookError owns the whole-command path; this one has to fit a row).
func webhookFailureLine(res cloudclient.WebhookProxyResult) string {
	if res.Err == nil {
		return "the instance refused the update"
	}
	if res.Err.Code == "upstream_error" {
		return fmt.Sprintf("upstream_error (instance status %d): %s", res.Err.Status, upstreamDetail(res.Err.Detail))
	}
	return res.Err.Code
}

// ---------------------------------------------------------------------------
// Shared response handling
// ---------------------------------------------------------------------------

// webhookRespond handles the machine-output and honest-degradation paths that
// EVERY verb shares, and reports whether it fully handled the response (done)
// so the caller renders its verb-specific human success only when done==false.
//
//   - json / yaml → the proxy envelope VERBATIM (D4: no reshaping), exit by
//     envelope ok.
//   - a FAILURE envelope on the human path → one honest line (unreachable,
//     capability_unavailable, upstream_error, …), exit by envelope code.
//   - a SUCCESS envelope on the human path → done=false; the caller renders.
func webhookRespond(out *writer, res cloudclient.WebhookProxyResult, ref string) (int, bool) {
	if out.output == "json" || out.output == "yaml" {
		emitWebhookRaw(out, res)
		return webhookExit(res), true
	}
	if !res.OK {
		renderWebhookError(out, res, ref)
		return webhookExit(res), true
	}
	return exitOK, false
}

// emitWebhookRaw writes the envelope for a machine consumer. json is the exact
// proxy bytes — verbatim, key order and all, so the CLI never becomes a second,
// drifting definition of the contract. yaml is a faithful re-encode (yaml
// consumers do not depend on key order).
func emitWebhookRaw(out *writer, res cloudclient.WebhookProxyResult) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(res.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// webhookExit maps a proxy envelope onto the CLI exit scheme. A success is 0; a
// failure maps by code — a missing instance/webhook is not_found (4), an
// upstream 404 relays as not_found, everything else is the generic failure (1).
func webhookExit(res cloudclient.WebhookProxyResult) int {
	if res.OK {
		return exitOK
	}
	if res.Err == nil {
		return exitGeneric
	}
	switch res.Err.Code {
	case "not_found", "no_admin_token":
		return exitNotFound
	case "upstream_error":
		if res.Err.Status == 404 {
			return exitNotFound
		}
		return exitGeneric
	default:
		return exitGeneric
	}
}

// renderWebhookError prints one honest human line for a FAILURE envelope. Each
// proxy failure code (D51) maps to a plain, actionable sentence — never a raw
// exception, never a hang. Written to stderr so stdout stays clean for scripts
// that fall back to parsing it.
func renderWebhookError(out *writer, res cloudclient.WebhookProxyResult, ref string) {
	e := res.Err
	if e == nil {
		out.userErr("webhook request failed")
		return
	}
	switch e.Code {
	case "instance_unreachable":
		out.errf("instance unreachable — %s did not respond; check it is running and try again", ref)
	case "capability_unavailable":
		hint := strings.TrimSpace(e.Hint)
		if hint == "" {
			hint = "update this instance"
		}
		out.errf("this instance is too old for that webhook operation — %s", hint)
	case "upstream_error":
		out.errf("webhook error (instance status %d): %s", e.Status, upstreamDetail(e.Detail))
	case "not_found":
		out.errf("no such instance %q (or it is not in your team)", ref)
	case "not_live":
		out.errf("instance %q is still provisioning — its API is not live yet", ref)
	case "no_admin_token":
		out.errf("instance %q has no stored admin token (a legacy/ip-only provision) — its API cannot be reached", ref)
	case "decrypt_failed":
		out.errf("could not decrypt the instance admin token — the stored credential looks corrupt")
	default:
		out.errf("webhook request failed: %s", e.Code)
	}
}

// upstreamDetail extracts a human message from a relayed instance error body.
// The instance emits {"error":{"code","message",…}}; when that shape is absent
// it may be a bare JSON string or opaque blob — surfaced verbatim rather than
// swallowed.
func upstreamDetail(raw json.RawMessage) string {
	if len(raw) == 0 {
		return "(no detail)"
	}
	// The shared parser, so an upstream envelope whose `details` (or any other
	// field) is shaped unexpectedly still yields its message rather than
	// dropping through to the raw blob below.
	//
	// The upstream's HINT is appended when it sent one: this string is the only
	// thing the operator sees about the instance's refusal, so dropping the
	// server's own remedy leaves them with a fault and no next step.
	if env, ok := apierr.Parse(raw); ok {
		detail := env.Message
		if detail == "" {
			detail = env.Code
		}
		if detail != "" {
			if h := env.HintLine(); h != "" {
				detail += " — " + h
			}
			return detail
		}
	}
	var s string
	if json.Unmarshal(raw, &s) == nil && s != "" {
		return s
	}
	return strings.TrimSpace(string(raw))
}

// ---------------------------------------------------------------------------
// Human table renderers
// ---------------------------------------------------------------------------

// renderWebhookList prints the endpoints as a table, one row each, with a
// computed STATUS cell painted through the statusRole seam: active → ok (green),
// auto-disabled (a disable_reason present) → failed (red), manually off →
// inactive (yellow).
func renderWebhookList(out *writer, data json.RawMessage, dataset string) {
	var body struct {
		Webhooks []map[string]any `json:"webhooks"`
	}
	_ = json.Unmarshal(data, &body)
	if len(body.Webhooks) == 0 {
		out.outf("no webhooks in dataset %q", dataset)
		return
	}
	rows := make([]any, 0, len(body.Webhooks))
	for _, wh := range body.Webhooks {
		rows = append(rows, map[string]any{
			"id":       webhookCell(wh["id"]),
			"name":     webhookCell(wh["name"]),
			"status":   webhookStateToken(wh),
			"url":      webhookCell(wh["url"]),
			"events":   webhookCell(wh["events"]),
			"failures": webhookCell(wh["consecutive_failures"]),
		})
	}
	b, _ := json.Marshal(rows)
	renderTable(out, b)
}

// renderWebhookDeliveries prints the recent deliveries with the STATUS cell
// role-painted (ok → green, failed → red, pending → cyan). status_code /
// last_latency_ms / attempts / last_attempt ride as the data columns; a pending
// row's null code/latency renders as an em dash rather than a blank.
//
// The timestamp column is honestly named: the instance's updated_at is the time
// of the LAST ATTEMPT (the successful one on an ok row, the give-up on a failed
// row) — calling it "delivered_at" would stamp a delivery time onto rows that
// were never delivered. A never-attempted row (attempts 0: updated_at is just
// the enqueue time) dashes the cell instead.
func renderWebhookDeliveries(out *writer, data json.RawMessage) {
	var body struct {
		Deliveries []map[string]any `json:"deliveries"`
	}
	_ = json.Unmarshal(data, &body)
	if len(body.Deliveries) == 0 {
		out.outf("no deliveries yet")
		return
	}
	rows := make([]any, 0, len(body.Deliveries))
	for _, d := range body.Deliveries {
		lastAttempt := "—"
		if attempts, _ := d["attempts"].(float64); attempts > 0 {
			lastAttempt = webhookCell(d["updated_at"])
		}
		rows = append(rows, map[string]any{
			"id":           webhookCell(d["id"]),
			"status":       deliveryStatusToken(cellString(d["status"])),
			"status_code":  webhookCell(d["last_status_code"]),
			"attempts":     webhookCell(d["attempts"]),
			"latency_ms":   webhookCell(d["last_latency_ms"]),
			"last_attempt": lastAttempt,
		})
	}
	b, _ := json.Marshal(rows)
	renderTable(out, b)
}

// webhookStateToken maps an endpoint's active/disable state to a statusRole
// token so the list's STATUS cell colours honestly.
func webhookStateToken(wh map[string]any) string {
	if active, _ := wh["active"].(bool); active {
		return "ok"
	}
	if dr, _ := wh["disable_reason"].(string); strings.TrimSpace(dr) != "" {
		// Auto-disabled after repeated terminal failures — this is a fault, red.
		return "failed"
	}
	// Deliberately switched off — a warning, not a fault. "inactive" is the data
	// model's own word (active:false) and matches toggle's "is now inactive";
	// NOT "suspended", which the fleet vocabulary reserves for a system-imposed
	// instance suspension.
	return "inactive"
}

// deliveryStatusToken maps the instance delivery-status enum
// (pending | ok | failed_giveup) onto a statusRole token so the deliveries table
// paints 2xx=ok (green), a give-up=danger (red), and a not-yet-attempted
// row=info (cyan). An unknown future value passes through uncoloured rather than
// being mis-painted.
func deliveryStatusToken(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "ok":
		return "ok"
	case "pending":
		return "pending"
	case "failed_giveup", "failed":
		return "failed"
	default:
		return status
	}
}

// ---------------------------------------------------------------------------
// Confirm + small decoders
// ---------------------------------------------------------------------------

// webhookConfirmDelete is the delete-tier typed-resource gate (D5 grammar).
// A webhook delete DROPS its delivery history, so a single mutate confirm is not
// enough — the operator types the webhook id (or its URL, when the interactive
// branch fetched it) back. --yes and a non-TTY stdin pass through unprompted, so
// scripts and CI keep working; any mismatch aborts and the caller issues NO
// DELETE. Uses the hzStdin / hzStdinIsTTY seams so tests can drive it.
func webhookConfirmDelete(stdin io.Reader, out *writer, id, url string, yes bool) error {
	if yes {
		return nil
	}
	if !hzStdinIsTTY(stdin) {
		return nil
	}
	accepts := "the webhook id"
	if strings.TrimSpace(url) != "" {
		accepts = "the webhook id or url"
	}
	prompt := fmt.Sprintf("This permanently deletes webhook %q and drops its delivery history. Type %s to confirm:", id, accepts)
	if out.color {
		prompt = "\033[31m" + prompt + "\033[0m"
	}
	fmt.Fprintf(out.stderr, "%s ", prompt)
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && line == "" {
		return fmt.Errorf("aborted — could not read confirmation: %v", err)
	}
	got := strings.TrimRight(line, "\r\n")
	switch {
	case got == id:
		return nil
	case strings.TrimSpace(url) != "" && got == url:
		return nil
	case got == "":
		return fmt.Errorf("aborted — nothing entered (type %q to confirm, or pass --yes to skip the prompt)", id)
	default:
		return fmt.Errorf("aborted — %q does not match webhook %q (pass --yes to skip the prompt)", got, id)
	}
}

// webhookDataset resolves the --dataset flag, defaulting to "production" (the
// instance-API proxy's own default).
func webhookDataset(a *hzArgs) string {
	if d := strings.TrimSpace(a.val("dataset")); d != "" {
		return d
	}
	return "production"
}

// webhookPositionals enforces an exact positional-argument count, emitting the
// shared usage error and returning ok=false on a miss.
func webhookPositionals(out *writer, a *hzArgs, want int, usage string) ([]string, bool) {
	if len(a.pos) != want {
		useError(out, "usage", fmt.Sprintf("want %d argument(s) (usage: %s)", want, usage), exitUsage)
		return nil, false
	}
	return a.pos, true
}

// webhookObject unwraps the {"webhook": {...}} object common to show / create /
// update / rotate success data. A missing key decodes to an empty map so the
// callers never nil-panic.
func webhookObject(data json.RawMessage) map[string]any {
	var body struct {
		Webhook map[string]any `json:"webhook"`
	}
	_ = json.Unmarshal(data, &body)
	if body.Webhook == nil {
		return map[string]any{}
	}
	return body.Webhook
}

// webhookActive reads the endpoint's current active flag from a show payload.
func webhookActive(data json.RawMessage) bool {
	b, _ := webhookObject(data)["active"].(bool)
	return b
}

// webhookURL reads the endpoint URL from a show payload (for the delete prompt).
func webhookURL(data json.RawMessage) string {
	s, _ := webhookObject(data)["url"].(string)
	return s
}

// webhookSecret reads the one-time `secret` a rotate success carries.
func webhookSecret(data json.RawMessage) string {
	var body struct {
		Secret string `json:"secret"`
	}
	_ = json.Unmarshal(data, &body)
	return body.Secret
}

// webhookDelivery unwraps the {"delivery": {...}} object a replay success
// carries.
func webhookDelivery(data json.RawMessage) map[string]any {
	var body struct {
		Delivery map[string]any `json:"delivery"`
	}
	_ = json.Unmarshal(data, &body)
	if body.Delivery == nil {
		return map[string]any{}
	}
	return body.Delivery
}

// webhookCell renders a value for a table cell, showing an em dash for a
// null/blank so a pending row's missing status_code/latency stays scannable.
func webhookCell(v any) string {
	s := cellString(v)
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
}

// printCloudWebhookHelp writes `bp cloud webhook` usage.
func printCloudWebhookHelp(out *writer) {
	const help = `bp cloud webhook — control a managed instance's webhooks from the CLI.

USAGE
  bp cloud webhook <verb> <instance> [args] [--dataset <ds>] [-o json|table]

WHAT IT IS
  the terminal twin of the console's Webhooks panel. Every verb goes through the
  control-plane instance-API proxy authenticated with your CLOUD session token —
  the instance's own admin token never leaves the server. <instance> is a fleet
  name or id (resolved via your fleet list); needs 'bp login'.

VERBS
  list       <instance>                    every webhook in the dataset
  show       <instance> <webhook-id>       one webhook's full config
  create     <instance> <url>              add an endpoint  [--name --events --types]
  edit       <instance> <webhook-id>       change config    [--name --url --events --types]
  rm         <instance> <webhook-id>       delete it + its delivery history [--yes]
  toggle     <instance> <webhook-id>       enable ⇄ disable (PUT {active})
  rotate     <instance> <webhook-id>       new signing secret (shown ONCE)
  deliveries <instance> <webhook-id>       recent delivery attempts
  replay     <instance> <webhook-id> <event-id>   re-deliver one stored event
  reconcile  <instance>                    re-assert the doc-type filter on the
                                           site-autodeploy-* rows  [--dry-run]

FLAGS
  --dataset <ds>   the dataset to scope to (default "production")
  --yes, -y        skip the delete confirmation (scripts)
  --dry-run        (reconcile) print what would change and write NOTHING
  -o json          emit the proxy envelope verbatim (the contract)

NOTES
  edit is a PARTIAL update — only the flags you pass are sent; omitted fields keep
    their stored value. It needs at least one of --name/--url/--events/--types.
  reconcile sets each site-autodeploy-<site-id> endpoint's types to the site's OWN
    doc_type (an empty filter means MATCH EVERYTHING on the box, so an unfiltered
    row rebuilds its site on every write in the dataset). It is idempotent — a
    second run reports "already correct" and writes nothing — and it FAILS CLOSED:
    a site whose doc_type it cannot read is reported, skipped, and exits non-zero.
  rm asks you to type the webhook id (or URL) back — it drops delivery history.
  replay works even when the webhook is inactive (a manual redelivery).
  An unreachable or too-old instance degrades honestly, never hangs.`
	out.outf("%s", help)
}
