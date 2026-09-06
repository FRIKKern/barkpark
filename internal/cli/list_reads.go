package cli

import (
	"bytes"
	"encoding/json"
)

// listReadCommands names every NON-PAGINATED core read whose HTTP-200 body is a
// LIST envelope. It exists because refuseUnreadableDefaultPage's predicate used
// to open `if !cmd.Paginated || cmd.Writes { return 0, false }`, and
// `paginated: true` is carried by only 7 of the 61 core reads
// (api/lib/barkpark/plugins/capabilities.ex, defp core_commands). The other 54
// reads were outside the wave-28 fence BY CONSTRUCTION — `bp webhook ls`
// against a proxy that answers HTTP 200 with `{}` printed nothing and exited 0,
// which a human reads as "this dataset has no webhooks" and a script
// (`if [ -z "$(bp webhook ls)" ]; then create; fi`) acts on.
//
// WHY A SET AND NOT A BLANKET `if cmd.Writes` WIDENING. The fence's
// readability test is extractListRows: "does this body carry a row array". Of
// the 54 non-paginated reads, 23 are single-OBJECT reads — doc.get renders
// `{"result":{"_id":…}}`, auth.me a flat map of scalars, data.counts a
// `type => count` map. envelopeRows deliberately refuses list treatment for a
// payload carrying `_id`, so extractListRows returns the "" sentinel for every
// one of them and a blanket widening would refuse 23 HONEST reads on their
// happy path. The population is split, so the fence is too.
//
// HOW THIS SET WAS DERIVED, AND HOW IT STAYS TRUE. Every id below was resolved
// through api/lib/barkpark_web/router.ex to its controller action and the
// action's success render was read: webhook_controller.ex renders
// `%{webhooks: …}`, schema_controller.ex `%{schemas: …}`,
// tasks_controller.ex `%{orphans: …}`, and so on.
// TestEveryNonPaginatedCoreReadIsClassified re-derives the whole population
// from the API source and fails on any read that is in neither this map nor the
// test's objectReadCommands table, so a new verb cannot land unclassified and
// this set cannot silently drift into a stale allowlist.
//
// NOT COVERED HERE, ON PURPOSE: plugin-contributed commands (the onixedit /
// bulldocs / sheets cli.ex blocks). They stay behind screenUnpaginatedRead's
// transport-lie screen only — onixedit.export streams ONIX XML through this
// same dispatch, and a list fence keyed on a JSON row array has nothing true to
// say about it.
var listReadCommands = map[string]bool{
	"access.ls":             true, // access_controller.ex  -> grants
	"access.mine":           true, // access_controller.ex  -> grants
	"app_token.ls":          true, // app_token_controller.ex -> tokens
	"chat.list_sessions":    true, // chat_controller.ex    -> sessions
	"dataset.stats":         true, // analytics_controller.ex -> types
	"doc.backlinks":         true, // query_controller.ex   -> result.backlinks
	"doc.history":           true, // history_controller.ex  -> revisions
	"doc.related":           true, // query_controller.ex   -> result.related
	"graph.corpus":          true, // tasks_controller.ex  -> nodes
	"graph.dangling":        true, // tasks_controller.ex  -> dangling
	"graph.orphans":         true, // tasks_controller.ex  -> orphans
	"graph.show":            true, // tasks_controller.ex  -> nodes
	"graph.tasks":           true, // tasks_controller.ex  -> tasks
	"media.search-synonyms": true, // v1/media_controller.ex -> result (bare array)
	"paper.access":          true, // paper_access_controller.ex -> access
	"plugin.ls":             true, // plugins_controller.ex  -> plugins
	"schema.ls":             true, // schema_controller.ex   -> schemas
	"search.synonyms":       true, // search_controller.ex  -> result (bare array)
	"secret.ls":             true, // secret_controller.ex   -> secrets
	"secret.scoped-ls":      true, // secret_controller.ex   -> secrets (scoped twin)
	"share.link-ls":         true, // share_link_controller.ex -> links
	"share.ls":              true, // share_controller.ex   -> shares
	"share.token-ls":        true, // share_controller.ex   -> tokens
	"tag.browse":            true, // query_controller.ex   -> result.tags
	"tag.docs":              true, // query_controller.ex   -> result.documents
	"webhook.deliveries":    true, // webhook_controller.ex  -> deliveries
	"webhook.ls":            true, // webhook_controller.ex  -> webhooks
	"workspace.dataset-ls":  true, // workspace_controller.ex -> datasets
	"workspace.ls":          true, // workspace_controller.ex -> workspaces
	"workspace.project-ls":  true, // workspace_controller.ex -> projects
}

// carriesRowArray reports whether a 2xx body is SHAPED like a list answer: a
// bare JSON array, or a JSON object with at least one top-level key whose value
// is a JSON array.
//
// IT IS DELIBERATELY WEAKER THAN extractListRows, AND THAT IS THE WHOLE POINT.
// extractListRows matches only the keys in listEnvelopeKeys (table.go), which
// is safe for the 7 `paginated: true` commands because
// TestPaginatedCommandsUseKnownEnvelopeKeys proves every one of their keys is
// recorded there. It is NOT safe for the set above: 9 of those 31 answer under
// a key listEnvelopeKeys has never heard of — `sessions`, `types`, `nodes`,
// `dangling`, `orphans`, `tasks`, `links`, `datasets` — and search.synonyms /
// media.search-synonyms answer with a BARE ARRAY once unwrapResult strips their
// `result` wrapper. Judging those with the strict key test would refuse an
// honest, populated read; judging them by shape refuses only what carries no
// rows at all: `{}`, `null`, `{"count":0}`, a scalar, a plaintext banner, a
// proxy page.
//
// A `null` value under an otherwise-right key (`{"webhooks":null}`) is NOT a row
// array — json.Unmarshal accepts null into a slice — so the first non-space byte
// must be '[' before the value counts.
func carriesRowArray(payload []byte) bool {
	trimmed := bytes.TrimSpace(payload)
	if len(trimmed) == 0 {
		return false
	}
	if trimmed[0] == '[' {
		var rows []json.RawMessage
		return json.Unmarshal(trimmed, &rows) == nil
	}
	var env map[string]json.RawMessage
	if json.Unmarshal(trimmed, &env) != nil {
		return false
	}
	for _, raw := range env {
		value := bytes.TrimSpace(raw)
		if len(value) == 0 || value[0] != '[' {
			continue
		}
		var rows []json.RawMessage
		if json.Unmarshal(value, &rows) == nil {
			return true
		}
	}
	return false
}
