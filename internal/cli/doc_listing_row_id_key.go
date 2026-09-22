package cli

// doc_listing_row_id_key.go — the ONE door to the tag vocabulary, made readable
// by the convention the rest of this CLI already uses.
//
// THE DEFECT (task-11f69d777d9d8e87). `bp task create --publish` requires 1..12
// weighted tags and refuses `unknown_tag` for any name that is not a PUBLISHED
// `type:tag` document. Its own help — and this package's publish wall — send the
// caller to `bp doc ls tag --all` for the vocabulary. Those rows are stored
// documents, so under `-o json` they carry `_createdAt, _draft, _id,
// _publishedId, _rev, _type, _updatedAt, title` and NOTHING ELSE. Every other
// row-bearing verb on the task surface keys its rows `doc_id`, and `bp task
// create` itself names tags by a string that reads like an id, so the obvious
// read is
//
//	bp doc ls tag --all -o json | jq -r '.documents[].doc_id'
//
// which prints `null` once per row. A field that is null on every row
// discriminates nothing: the natural next inference is "the registry is empty,
// so a publish is impossible", and it is false — 208 tags were registered on
// guerrilla when this was measured (2026-09-22).
//
// THE VALUE THE WALL ACTUALLY COMPARES AGAINST IS `_id`, NOT `title`. The row
// that filed this defect prescribed `.title` as the usable key. That is wrong,
// and measurably so: of the 208 published `type:tag` documents on guerrilla,
// 52 carry a title that is NOT a legal tag name (`^[a-z0-9-]+$`) — `epic-wave-
// paper` is titled "Epic Wave Paper", `macos` is titled "macOS" — and 2
// (`identity`, `onboarding`) carry no title at all. A caller who followed
// `.title` would be refused by the label spine's shape check on 52 tags and by
// a nil read on 2 more. `fetchRegisteredTags` in tasks_publish_wall.go reads
// `_id`, and the server's own registry (content/tag_registry.ex) resolves a tag
// by `_id`. So `_id` IS the accepted string, 208/208.
//
// THE FIX IS THE ZERO-COST ONE: emit the SAME string under the key the rest of
// the CLI already uses. `doc_id` mirrors `_id` verbatim — draft prefix included,
// because `drafts.foo` is what `bp doc get` resolves for that row — so the jq
// path a caller carries across from `bp task ls` now answers, and it answers
// with a string `--publish` accepts.
//
// AND THE LISTING NOW DECLARES HOW MANY ROWS IT HELD. The `--all` walk stitches
// its pages into `{key: rows}` and drops every sibling the server sent, `count`
// first among them (run.go paginatedAllWalk) — so the ONE mode whose premise is
// "this is the whole population" was the one mode that stated no population.
// `count` is re-attached here when it is absent, never overwritten when the
// server sent one. It is the second half of the same defect: it lets a caller
// whose jq path came back empty tell "I read the wrong key" from "the registry
// is empty".
//
// SCOPE. Only commands whose rows list_envelope_help.go has VERIFIED to be
// stored documents keyed `_id` — doc.ls and doc.query. `search.query` shares the
// `documents` envelope key and does NOT share its id field (its hits are
// projections keyed `id`), and it is excluded for exactly that reason: mirroring
// a field a row does not carry would manufacture the null this file exists to
// remove.

import (
	"encoding/json"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// docListingRowIDKey is the name the mirrored id is emitted under. It is
// `doc_id` because that is what task.ls / task.ready already call a row's id
// (commandListEnvelopes), and the whole defect is a caller generalising that
// convention and reading null.
const docListingRowIDKey = "doc_id"

// docListingRowCountKey is the top-level row count. Same spelling the server's
// own single-page envelope uses (query_controller.ex emits count/documents/
// hasMore/limit/offset), so a caller reads one key whether the answer came from
// one page or from a stitched `--all` walk.
const docListingRowCountKey = "count"

// docListingMirrorsID reports whether cmd's rows are stored documents keyed
// `_id` — the only rows for which mirroring is a statement of fact rather than
// a guess. Driven off commandListEnvelopes so this cannot drift away from what
// `--help` promises and listEnvelopeDrift checks.
func docListingMirrorsID(cmd manifest.Command) bool {
	env, ok := commandListEnvelopes[cmd.ID]
	return ok && env.Key == "documents" && env.IDField == "_id"
}

// enrichDocListingRows returns payload with `doc_id` mirrored onto every row
// that carries a non-empty string `_id`, and with a top-level `count` when the
// envelope carries none.
//
// It is TOTAL and CONSERVATIVE: any payload it cannot read as a
// `{"documents":[ {…}, … ]}` envelope comes back byte-identical, and a row that
// already carries `doc_id` is left exactly as the server sent it. A renderer
// that corrupts the body it was asked to annotate would be a worse bug than the
// one this closes, so every failure path returns the input unchanged.
func enrichDocListingRows(cmd manifest.Command, payload []byte) []byte {
	if !docListingMirrorsID(cmd) {
		return payload
	}
	var env map[string]json.RawMessage
	if err := json.Unmarshal(payload, &env); err != nil {
		return payload
	}
	rawRows, ok := env["documents"]
	if !ok {
		return payload
	}
	var rows []json.RawMessage
	if err := json.Unmarshal(rawRows, &rows); err != nil {
		// `"documents": null` is the honest empty page some paths emit; it is
		// not a list and there is nothing to mirror onto.
		return payload
	}

	mirrored := false
	for i, row := range rows {
		enriched, did := mirrorRowID(row)
		if did {
			rows[i] = enriched
			mirrored = true
		}
	}
	_, hasCount := env[docListingRowCountKey]
	if !mirrored && hasCount {
		return payload
	}
	if !hasCount {
		count, err := json.Marshal(len(rows))
		if err != nil {
			return payload
		}
		env[docListingRowCountKey] = json.RawMessage(count)
	}
	if mirrored {
		stitched, err := json.Marshal(rows)
		if err != nil {
			return payload
		}
		env["documents"] = json.RawMessage(stitched)
	}
	out, err := json.Marshal(env)
	if err != nil {
		return payload
	}
	return out
}

// mirrorRowID copies a row's `_id` to `doc_id`. The second return is false when
// nothing was written — the row is not an object, carries no usable `_id`, or
// already carries a `doc_id` of its own (which the server owns and this must
// never overwrite).
func mirrorRowID(row json.RawMessage) (json.RawMessage, bool) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(row, &obj); err != nil {
		return row, false
	}
	if _, already := obj[docListingRowIDKey]; already {
		return row, false
	}
	rawID, present := obj["_id"]
	if !present {
		return row, false
	}
	var id string
	if err := json.Unmarshal(rawID, &id); err != nil || id == "" {
		return row, false
	}
	obj[docListingRowIDKey] = rawID
	out, err := json.Marshal(obj)
	if err != nil {
		return row, false
	}
	return out, true
}
