package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcp_bridge.go — the generic capabilities→MCP bridge (charter decisions 7,8):
// the manifest IS the MCP server. registerBridgeTools walks every manifest
// Command and, under `--tools all`, exposes each as one MCP tool named
// bp_<noun>_<verb> whose inputSchema is auto-derived from the command's Args and
// Flags. A tool's handler translates the MCP arguments object back into the CLI
// positional+flag tail and hands it to execManifestCommand (run.go, the same
// dispatch seam the curated task tools ride) — so ArgLocation inference
// (path/query/body), --set typing, MutationOp/SetKey wrapping, auth, and body
// serialization all ride the EXISTING run.go builder unchanged. The bridge
// re-implements none of that; it only shapes tool metadata and rebuilds the
// tail. Results follow charter decision 9: the raw response JSON as one text
// content block, IsError on HTTP >= 400 OR an unreadable 2xx receipt
// (mcpRunFor, mcp_tasks.go — cmd.Writes tells it whether to run the write or
// read discriminator).
//
// Opt-in rationale: Cursor hard-caps 40 MCP tools across ALL enabled servers and
// silently drops the excess, while a live guerrilla manifest is ~107 commands.
// So `--tools all` is deliberate, and the curated eight (mcp_tasks.go) stay the
// default. Where the curated overlay already covers a command, the bridge
// SHADOWS its twin (see bridgeShadowedIDs) so the same capability is not exposed
// twice under two names.

// bridgeShadowedIDs is the set of manifest command IDs the curated overlay
// (mcp_tasks.go) already exposes under a hand-tuned name, so the bridge must NOT
// also generate a bp_<noun>_<verb> twin for them. The seven queue/read/close/
// prime/stamp/pulse verbs the curated eight cover are shadowed:
//
//   - task.ready  → curated task_ready
//   - task.next   → curated task_next  (atomic queue-claim)
//   - task.get    → curated task_show
//   - task.close  → curated task_close (epoch-CAS)
//   - task.prime  → curated task_prime (one-call rehydration)
//   - task.stamp  → curated task_stamp (mid-claim criterion evidence)
//   - task.pulse  → curated task_pulse (now-line + lease renewal)
//
// task.claim is NOT shadowed: the curated task_next is the ATOMIC queue-claim,
// whereas task.claim claims a SPECIFIC id — a distinct capability, so
// bp_task_claim generates. doc.create is likewise not covered by the curated
// eight and generates as bp_doc_create. (task_create has no manifest verb at all,
// so there is no twin to shadow.)
//
// This set is kept here next to the bridge because the bridge is what consults
// it; it is the single source of truth the curated registration in mcp_tasks.go
// must stay in sync with (charter: keep the shadowed-ID set adjacent to curated
// registration so the two never drift).
//
// MCP access parity = `--tools all`. The airdrop-grants `access` verbs
// (access.grant/ls/show/revoke/claim/mine) are NOT curated and are NOT shadowed
// here, so the bridge generates bp_access_grant/ls/show/revoke/claim/mine as
// soon as the manifest carries them — full grant-lifecycle parity over MCP under
// `bp mcp serve --tools all`. The DEFAULT `--tools tasks` toolset is curated by
// design (Cursor hard-caps 40 MCP tools), so the default surface omitting the
// access tools is intentional, not a gap. TestBridgeAccessParity pins both facts
// so a future shadow-set edit or verb rename reds the guard.
// Never-double-expose extends to chat (herd charter D75h): the curated chat
// session tools (mcp_chat.go — hardcoded, NOT manifest-backed, because chat.*
// is existence-hidden at write tier) cover three chat verbs under hand-tuned
// names, so a manifest that DOES carry them (a future admin-tier projection, or
// the D36 tier remap) must not generate bp_chat_* twins:
//
//   - chat.create_session → curated chat_spawn_session
//   - chat.send_message   → curated chat_send
//   - chat.get_session    → curated chat_read_tail
//
// chat_wait_for_state composes over the fleet SSE — no manifest twin exists, so
// it has no shadow entry.
var bridgeShadowedIDs = map[string]bool{
	"task.ready":          true,
	"task.next":           true,
	"task.get":            true,
	"task.close":          true,
	"task.prime":          true,
	"task.stamp":          true,
	"task.pulse":          true,
	"chat.create_session": true,
	"chat.send_message":   true,
	"chat.get_session":    true,
}

// registerBridgeTools walks m.Commands and registers one MCP tool per command
// (skipping the curated-shadowed IDs) on srv. It is the whole of the
// `--tools all` surface: pure over the manifest, so a new plugin command becomes
// an MCP tool with zero code change here. g and ctx are captured by each tool's
// handler and forwarded to execManifestCommand at call time.
func registerBridgeTools(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) error {
	return registerBridgeToolsFiltered(srv, g, ctx, m, nil)
}

// registerBridgeToolsFiltered is registerBridgeTools with an optional noun
// allowlist — the `--tools <noun,noun>` subset surface (D24 knob 3, Go half). A
// nil/empty `nouns` means NO filter (the full `--tools all` surface); a non-empty
// `nouns` restricts registration to commands whose Command.Noun is in the set,
// skipping every other noun with a second `continue` BESIDE the curated-shadowed
// skip. Both skips stay live under a subset: the shadow skip is inert for a
// connector noun (no curated twin exists) but keeps `never-double-expose` honest
// for a task-noun subset (`--tools task` whose verbs are all curated → zero). An
// unknown noun matches nothing → zero tools, the honest 0-install surface.
//
// This filters whatever nouns the target MANIFEST declares. github/linear are
// Catalog connector providers, not bp manifest nouns — this flag is NOT itself
// the transport by which a cloud agent reaches those services (that is the
// in-sandbox MCP wiring); it only scopes which manifest nouns the bridge exposes.
func registerBridgeToolsFiltered(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest, nouns []string) error {
	allow := nounAllowSet(nouns)
	for i := range m.Commands {
		cmd := m.Commands[i] // capture by value per iteration for the closure
		if bridgeShadowedIDs[cmd.ID] {
			continue
		}
		if allow != nil && !allow[cmd.Noun] {
			continue
		}
		if err := registerOneBridgeTool(srv, g, ctx, m, cmd); err != nil {
			return err
		}
	}
	return nil
}

// registerOneBridgeTool registers exactly one manifest command as a generic
// bp_<noun>_<verb> bridge tool. Factored out of registerBridgeToolsFiltered so
// the ID-keyed chat allowlist (registerChatBridgeTools) produces tools that are
// byte-identical in name, description, schema and annotations to the ones
// `--tools all` produces — one generator, so the two surfaces can never drift.
func registerOneBridgeTool(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command) error {
	schema, err := json.Marshal(bridgeInputSchema(cmd))
	if err != nil {
		return fmt.Errorf("derive schema for %s: %w", cmd.ID, err)
	}
	srv.AddTool(&mcp.Tool{
		Name:        bridgeToolName(cmd),
		Description: cmd.Summary,
		InputSchema: json.RawMessage(schema),
		Annotations: bridgeAnnotations(cmd),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var args map[string]any
		if err := decodeMCPArgs(req, &args); err != nil {
			return mcpArgError(err), nil
		}
		tail := buildCommandTail(cmd, args)
		// Bridge tools inherit the manifest's agent-default view generically
		// (agentViewGlobals, run.go): a command declaring
		// views.default_for_agents gets ?view= with zero per-tool code here —
		// the manifest stays the moat.
		status, body, rerr := execManifestCommand(agentViewGlobals(g, cmd), ctx, m, cmd, tail)
		return mcpRunFor(status, body, rerr, cmd.Writes), nil
	})
	return nil
}

// nounAllowSet turns a noun subset into a lookup set, or nil when the subset is
// empty — the distinction registerBridgeToolsFiltered reads as "no filter" (nil)
// vs "only these nouns" (a non-nil set). parseToolsSelector never yields an empty
// subset (it rejects empty tokens and requires at least one noun), so a non-nil
// set always carries at least one entry.
func nounAllowSet(nouns []string) map[string]bool {
	if len(nouns) == 0 {
		return nil
	}
	set := make(map[string]bool, len(nouns))
	for _, n := range nouns {
		set[n] = true
	}
	return set
}

// bridgeAnnotations derives the MCP behaviour hints for a generated tool
// straight from the manifest's cmd.Writes bit — the one honest signal the bridge
// already sees. A non-writing command is ReadOnlyHint:true (safe to call for
// information; the SDK marshals readOnlyHint only when true, so read tools carry
// the positive hint). A writing command is ReadOnlyHint:false + DestructiveHint
// explicitly true: the manifest cannot tell an additive create from a
// destructive update, so the conservative hint is "may modify" — a client that
// gates on destructiveHint then prompts before the call. IdempotentHint and
// OpenWorldHint are left unset: the manifest carries no signal for either, and a
// wrong hint is worse than an absent one (both default sensibly SDK-side).
func bridgeAnnotations(cmd manifest.Command) *mcp.ToolAnnotations {
	if cmd.Writes {
		return &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)}
	}
	return &mcp.ToolAnnotations{ReadOnlyHint: true}
}

// bridgeToolName renders the MCP tool name for a command: bp_<noun>_<verb> with
// any character outside [A-Za-z0-9_] folded to '_' so a hyphenated noun like
// "ticket-key" yields a valid tool name (bp_ticket_key_mint) — MCP clients key
// tools by this string and the safe common denominator is underscores, matching
// the curated task_* names.
func bridgeToolName(cmd manifest.Command) string {
	return "bp_" + sanitizeToolSegment(cmd.Noun) + "_" + sanitizeToolSegment(cmd.Verb)
}

func sanitizeToolSegment(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

// bridgeInputSchema derives a JSON Schema 2020-12 object from a command's Args
// and Flags. One property per Arg (required iff Arg.Required) and per Flag
// (never required — flags are optional by definition); the property description
// is the Arg/Flag Summary. Type mapping mirrors the charter: manifest "int" →
// "integer", everything else → "string"; a repeatable flag → an array of
// strings. Placement (path/query/body) is intentionally NOT encoded — that is
// runtime inference the run.go builder owns; the schema only names inputs.
func bridgeInputSchema(cmd manifest.Command) map[string]any {
	properties := map[string]any{}
	var required []string

	for _, a := range cmd.Args {
		properties[a.Name] = scalarProperty(a.Type, a.Summary)
		if a.Required {
			required = append(required, a.Name)
		}
	}
	for _, f := range cmd.Flags {
		if f.Repeatable {
			properties[f.Name] = map[string]any{
				"type":        "array",
				"items":       map[string]any{"type": "string"},
				"description": f.Summary,
			}
			continue
		}
		properties[f.Name] = scalarProperty(f.Type, f.Summary)
		// Flags are never required.
	}

	schema := map[string]any{
		"$schema":    "https://json-schema.org/draft/2020-12/schema",
		"type":       "object",
		"properties": properties,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// scalarProperty renders a single non-repeatable property: manifest "int" →
// integer, everything else (string/slug/file/bool/…) → string, with the summary
// as the description.
func scalarProperty(manifestType, summary string) map[string]any {
	jsonType := "string"
	if manifestType == "int" {
		jsonType = "integer"
	}
	prop := map[string]any{"type": jsonType}
	if summary != "" {
		prop["description"] = summary
	}
	return prop
}

// buildCommandTail reconstructs the CLI positional+flag tail from an MCP
// arguments object, exactly as a human would type it — so execManifestCommand
// (which drives the same run.go path splitArgs/bindArgs/BuildURL/applyQuery/
// buildBody use) places each value in path, query, or body identically to CLI
// dispatch. Positionals are emitted in Args order; an omitted optional arg that
// precedes a provided one is filled with "" so positional binding stays aligned
// (buildBody/applyQuery skip empty values, so the placeholder is inert).
// Non-string scalars are stringified with fmt.Sprint (observed_epoch already
// rides the wire as a string; the server coerces via fetch_int). Flags follow:
// a bool flag emits a bare --name when truthy (never a value — splitArgs rejects
// an inline value on a bool); a repeatable flag repeats --name per array
// element; every other flag emits --name <value>.
func buildCommandTail(cmd manifest.Command, args map[string]any) []string {
	tail := []string{}

	// Positionals: emit up to the highest-index arg the caller actually supplied,
	// filling gaps with "" so binding stays positionally aligned.
	last := -1
	for i, a := range cmd.Args {
		if _, ok := args[a.Name]; ok {
			last = i
		}
	}
	for i := 0; i <= last; i++ {
		if v, ok := args[cmd.Args[i].Name]; ok {
			tail = append(tail, stringifyArg(v))
		} else {
			tail = append(tail, "")
		}
	}

	// Flags, in manifest order for deterministic output.
	for _, f := range cmd.Flags {
		v, ok := args[f.Name]
		if !ok {
			continue
		}
		if f.Type == "bool" {
			if isTruthy(v) {
				tail = append(tail, "--"+f.Name)
			}
			continue
		}
		if f.Repeatable {
			for _, elem := range asSlice(v) {
				tail = append(tail, "--"+f.Name, stringifyArg(elem))
			}
			continue
		}
		tail = append(tail, "--"+f.Name, stringifyArg(v))
	}
	return tail
}

// stringifyArg renders an MCP JSON scalar as the CLI token the manifest builder
// expects. Strings pass through verbatim; every other scalar (JSON number, bool)
// is fmt.Sprint'd — matching how the CLI already carries e.g. observed_epoch as
// a string the server coerces.
func stringifyArg(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

// asSlice normalises a repeatable-flag value into a slice: a JSON array is
// spread element-per-element; a lone scalar is wrapped so a client that passes a
// single value instead of a one-element array still works.
func asSlice(v any) []any {
	if arr, ok := v.([]any); ok {
		return arr
	}
	return []any{v}
}

// isTruthy decides whether a bool-flag value should emit its --name. A real JSON
// bool is honoured directly; a stringified "true"/"1" (a client that sent the
// string form of the string-typed schema) also counts.
func isTruthy(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}

// chatBridgeToolIDs is the CURATED, hand-reviewed manifest-command allowlist of
// the `--tools chat` toolset (task-scc-bl-mcp-chat-toolset, charter D64): the
// document and search verbs a Studio chat agent genuinely works with, on top of
// the curated task tools (mcp_tasks.go) and the curated chat session tools
// (mcp_chat.go). The Studio loopback used to spawn `--tools all` — every one of
// the live manifest's ~107 commands — because the default `--tools tasks` set
// carries no search and no document verbs; `chat` is that missing middle,
// intentionally frozen.
//
// It is an explicit list of command IDs, NOT a noun filter, and that is the
// whole point: `--tools doc,search` (a noun subset, nounAllowSet) would silently
// ADOPT every new doc.* / search.* verb a future plugin or migration adds, so
// the advertised chat surface would grow without anyone reviewing it. Keyed by
// ID, a newly added manifest command is invisible to `chat` until a human edits
// THIS list and its pin (TestChatToolsetIsAnIDAllowlist).
//
// The order of THIS slice is registration order and reading order for a human —
// it is NOT an advertised property, and the pin does not cover it. The MCP SDK
// stores tools in a map keyed by name and serves tools/list from
// slices.Sorted(maps.Keys(...)) (go-sdk mcp/features.go: "the spec never
// mentions an ordering for the List calls, so what it calls a \"list\" is
// actually a set"), so reversing this slice changes nothing a client can see.
// TestChatToolsetAdvertisesExactlyTheCuratedSet asserts that name-sorted wire
// order explicitly: if a future SDK ever preserves insertion order, that
// assertion reds and this set pin must become an order pin.
//
// Deliberately absent: everything else. No admin/auth/token verbs, no plugin
// nouns (github, sheets, tickets, onix, media, grip, pulse…), no dataset or
// workspace administration, no doc DELETE. An operator who wants those asks for
// them explicitly with `--tools all` or a noun subset.
var chatBridgeToolIDs = []string{
	"search.query", // find anything by text — the read verb `tasks` lacks
	"doc.ls",       // list documents of a type (the other half of finding)
	"doc.get",      // read one document
	"doc.create",   // author a new document
	"doc.mutate",   // patch an existing document
	"doc.publish",  // promote a draft to published
}

// registerChatBridgeTools registers the chatBridgeToolIDs commands on srv as
// generic bridge tools, in chatBridgeToolIDs order, and reports which of them
// the manifest could NOT back (`missing`, in the same order). Registration
// order is what the ERROR and stderr text is ordered by; it is not the order a
// client sees, because tools/list is name-sorted by the SDK (see
// chatBridgeToolIDs).
//
// ONE documented policy for an unavailable backing verb, and it is chosen by the
// caller's transport, exactly as the curated task tools already are:
//
//   - stdio (bestEffort == false): NOTHING is registered and every missing ID is
//     returned, so buildMCPServer can refuse to start. A stdio server is launched
//     per client with the operator's own credential, so a manifest that cannot
//     back the reviewed set is a real misconfiguration, and a tool that 404s
//     every call is worse than a clear startup error. The lookup pass runs BEFORE
//     the first AddTool — the same batch-first invariant registerTaskTools holds
//     — so a refusal leaves nothing half-registered on srv.
//   - --http (bestEffort == true): what the manifest DOES back is registered and
//     the missing IDs are returned for ONE loud stderr line. An --http server
//     holds no ambient credential (charter D18), so its startup manifest is the
//     ANONYMOUS /v1/capabilities projection; failing fast there turns a useful
//     bridge into a systemd crash loop (see mcpToolsetTasksBestEffort).
//
// Either way the omission is never silent and never partial-by-accident, and no
// byte of it reaches os.Stdout — diagnostics are stderr-only (decision 4),
// because stdout IS the JSON-RPC stream.
func registerChatBridgeTools(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest, bestEffort bool) (missing []string, err error) {
	// Pass 1 — resolve every allowlisted ID against the manifest. No AddTool yet.
	byID := make(map[string]manifest.Command, len(m.Commands))
	for i := range m.Commands {
		byID[m.Commands[i].ID] = m.Commands[i]
	}
	found := make([]manifest.Command, 0, len(chatBridgeToolIDs))
	for _, id := range chatBridgeToolIDs {
		cmd, ok := byID[id]
		if !ok {
			missing = append(missing, id)
			continue
		}
		found = append(found, cmd)
	}
	if len(missing) > 0 && !bestEffort {
		// Fail-fast policy: register nothing, let the caller refuse startup.
		return missing, nil
	}

	// Pass 2 — register, in allowlist order.
	for _, cmd := range found {
		if err := registerOneBridgeTool(srv, g, ctx, m, cmd); err != nil {
			return missing, err
		}
	}
	return missing, nil
}
