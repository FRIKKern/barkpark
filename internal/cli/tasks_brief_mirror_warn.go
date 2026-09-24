package cli

import (
	"encoding/json"
	"fmt"
	"strings"
)

// tasks_brief_mirror_warn.go — THE READ-TIME HALF OF A RULING THAT DECLINED TO
// WRITE (task-909ce143996407e3, out of the ruling on task-b73c140509c1e901).
//
// A task document carries `description` and `acceptance_criteria` — the
// authoritative fields — and a `brief` PortableDoc that MIRRORS both into
// blocks a TUI can render. The server re-derives that mirror on every write
// (api/lib/barkpark/tasks/brief_mirror.ex, live since PR #16279), so the class
// is CLOSED at the inflow. What it did not do is repair the rows written
// before it: measured 2026-09-17 over 9,112 published task docs, 1,761
// TERMINAL rows carry a brief whose blocks disagree with their own fields
// (1,611 purpose-copy, 150 criteria-list — 94 by count, 56 by text). Terminal
// rows are never written again, so that residue is FROZEN: the 164 filed on
// 2026-09-08 had fallen by exactly ZERO nine days later.
//
// The ruling was LEAVE THEM. Rewriting 1,761 published production rows is the
// owner's call, not a reader's, and a write would stamp today's normalisation
// onto a historical record. But the ruling accepts a hazard: an auditor opening
// one of those rows meets `brief` FIRST, and on those rows it is a false record
// of what the row asked. This file pays that hazard at the READER instead — it
// says so, on stderr, and touches nothing.
//
// WHEN IT FIRES, AND WHY NOT MORE OFTEN. A warning on 1,761 rows an operator
// cannot fix is noise, and noise gets muted. So it is keyed on the SINGLE-
// DOCUMENT envelope — `bp task get <id>` and the claim/stage receipts that
// return one doc — never on `bp task ls` / `ready`, which render many rows the
// reader did not ask about. One row is in the reader's hands at a time, and the
// line is about THAT row's brief, which they are about to read. It is emitted
// in every output mode on stderr, beside emitStrandedClaim and
// emitArrearsClaim, so stdout stays one parseable document.
//
// THE REMEDY LINE DIFFERS BY LIFECYCLE, because the two populations are not the
// same problem. On a LIVE row the divergence is actionable — any write
// re-derives the mirror — so the line says so. On a TERMINAL row it is not, and
// the line says READ THE FIELD, DO NOT REWRITE THE ROW, naming the ruling.
// A remedy an operator cannot perform is the thing that trains people to mute a
// channel.
//
// ==========================================================================
// WHICH STRIP RULE THIS WARNING USES, AND WHY IT MATTERS
// ==========================================================================
//
// purpose-copy derives from `description` with the markdown delimiters **, __
// and ` removed and the result trimmed. THE TWO SITES DISAGREE ON HOW:
//
//   - THE GO COMPOSER (ensureTaskPortableBrief, tasks_create_cmd.go) makes ONE
//     non-overlapping left-to-right pass considering all three patterns at once.
//   - THE SERVER MIRROR (brief_mirror.ex strip_markdown/1) reduces
//     String.replace/3 over the three patterns — three passes, each rescanning
//     the previous pass's output — so `foo_**_bar` strips to `foobar` where the
//     composer gives `foo__bar`.
//
// THAT IS PAST TENSE AS OF task-b641646addba4bdf. The server now strips in ONE
// pass too — :binary.replace(text, @stripped, "", [:global]) — and agrees with
// the composer on all 1,313 rows of the shared corpus
// (testdata/brief_strip_corpus.json), where the reducing form missed 19. The
// cross-language arm that keeps it that way is the ExUnit half,
// api/test/barkpark/tasks/brief_mirror_strip_corpus_test.exs, reading THIS
// SAME FILE.
//
// THIS WARNING'S CANONICAL RULE IS THE ONE PASS. Three reasons, all argued at
// length in tasks_brief_strip_parity_test.go: the server declared the composer
// as its contract and was the side that broke it; the composer is upstream
// (CLI writes, server re-derives); and rescanning destroys literal characters
// that only became adjacent when a delimiter was removed, which a mirror whose
// whole job is not to rewrite prose must never do.
//
// THE LEGACY TOLERANCE IS GONE, deliberately and on the tripwire's own
// instructions (tasks_brief_strip_server_pin_test.go, now deleted with it).
// While the server rescanned, a brief matching only the three-pass output was a
// FAITHFUL mirror and warning on it would have been the warning lying on
// exactly the rows that provoked the finding. Now nothing produces that text,
// so a row carrying it is a stale record like any other and says so. Measured
// 2026-09-17 over all 9,119 published task documents, the class holds exactly
// ONE row — task-8ba550b59141bccb itself — which is why removing the tolerance
// costs one newly-warning row and not a channel nobody reads. It is in the
// fixture below, now asserted LOUD.
//
// The verdicts above are a SPLIT, not a total. A uniform verdict across a
// population is the signature of a broken comparator, and this family has
// already produced three of those (one answering 20/20 DIVERGENT, one 20/20
// EMPTY_PURPOSE from reading the span key as `text` when it is `value`, one
// 8,475/8,475 NO_BLOCK from reading `doc query --fields` output, which returns
// fields at TOP LEVEL, as if it nested them under `content`). Both shapes are
// read here for that reason.

// briefMirrorDivergence is one row whose mirrored blocks disagree with the
// fields they mirror. Every field is read from the server's own response.
type briefMirrorDivergence struct {
	DocID    string
	Status   string
	Terminal bool
	// Blocks names the divergent block ids in document order, each with the
	// field it should have mirrored.
	Blocks []string
}

// briefMirrorTerminalStatuses are the lifecycles a row never leaves. On these
// the residue is frozen and the remedy is "read the field", not "write the row".
var briefMirrorTerminalStatuses = map[string]bool{"done": true, "cancelled": true}

// briefPurposeStripOnePass is THE canonical purpose-copy normaliser, and this
// is the one site that owns it: ensureTaskPortableBrief composes with it and
// this warning compares against it, so the writer and the reader cannot drift.
// strings.NewReplacer makes ONE non-overlapping left-to-right pass considering
// all three patterns at once — see this file's header for why that is the
// correct side, and tasks_brief_strip_parity_test.go for the proof.
func briefPurposeStripOnePass(s string) string {
	return strings.TrimSpace(strings.NewReplacer("**", "", "__", "", "`", "").Replace(s))
}

// briefMirrorCriterionTexts is resync_criteria/2's rule, exactly: the criterion
// texts in order, String.trim ONLY — NO markdown stripping on this surface —
// blanks and non-string entries dropped.
func briefMirrorCriterionTexts(criteria []briefMirrorCriterion) []string {
	out := []string{}
	for _, c := range criteria {
		if c.Criterion == nil {
			continue
		}
		if t := strings.TrimSpace(*c.Criterion); t != "" {
			out = append(out, t)
		}
	}
	return out
}

type briefMirrorCriterion struct {
	Criterion *string `json:"criterion"`
}

// briefMirrorDoc is the subset of a task document both envelope shapes carry.
// Description is a POINTER on purpose: the mirror leaves purpose-copy alone
// when the document carries no `description` key at all, and absence is not the
// same as an empty description.
type briefMirrorDoc struct {
	DocID              string                  `json:"doc_id"`
	ID                 string                  `json:"_id"`
	LifecycleStatus    string                  `json:"lifecycle_status"`
	Description        *string                 `json:"description"`
	AcceptanceCriteria *[]briefMirrorCriterion `json:"acceptance_criteria"`
	Brief              *struct {
		Version json.RawMessage `json:"version"`
		Blocks  []struct {
			ID      string `json:"id"`
			Content []struct {
				// THE SPAN KEY IS `value`, NOT `text`. A comparator on this
				// family was ruled void for reading `text` and answering
				// EMPTY_PURPOSE on every row it saw.
				Value *string `json:"value"`
			} `json:"content"`
			Items *[]string `json:"items"`
		} `json:"blocks"`
	} `json:"brief"`
}

// briefMirrorDivergenceFrom decodes the divergence out of a response envelope.
// It walks the nested `{"doc": …}` shape that `bp task get` returns, the
// `{"result": …}` wrapper, and the FLAT shape `bp doc query --fields` returns,
// because reading one of those as the other is how the previous comparators on
// this family produced uniform verdicts.
func briefMirrorDivergenceFrom(body []byte) (briefMirrorDivergence, bool) {
	for _, candidate := range briefMirrorDocsIn(body) {
		if d, ok := briefMirrorDivergenceOf(candidate); ok {
			return d, true
		}
	}
	return briefMirrorDivergence{}, false
}

func briefMirrorDocsIn(body []byte) []briefMirrorDoc {
	var docs []briefMirrorDoc
	for _, raw := range [][]byte{body, unwrapResult(body)} {
		var nested struct {
			Doc *struct {
				DocID           string          `json:"doc_id"`
				LifecycleStatus string          `json:"lifecycle_status"`
				Content         *briefMirrorDoc `json:"content"`
			} `json:"doc"`
		}
		if json.Unmarshal(raw, &nested) == nil && nested.Doc != nil && nested.Doc.Content != nil {
			d := *nested.Doc.Content
			if strings.TrimSpace(d.DocID) == "" {
				d.DocID = nested.Doc.DocID
			}
			if strings.TrimSpace(d.LifecycleStatus) == "" {
				d.LifecycleStatus = nested.Doc.LifecycleStatus
			}
			docs = append(docs, d)
		}
		var flat briefMirrorDoc
		if json.Unmarshal(raw, &flat) == nil && flat.Brief != nil {
			docs = append(docs, flat)
		}
	}
	return docs
}

// briefMirrorDivergenceOf applies the two mirror rules. It reports false unless
// at least one block is present, comparable, AND disagrees with its field under
// BOTH strip rules.
func briefMirrorDivergenceOf(d briefMirrorDoc) (briefMirrorDivergence, bool) {
	if d.Brief == nil {
		return briefMirrorDivergence{}, false
	}
	id := strings.TrimSpace(d.DocID)
	if id == "" {
		id = strings.TrimSpace(d.ID)
	}
	if id == "" {
		return briefMirrorDivergence{}, false
	}
	status := strings.TrimSpace(d.LifecycleStatus)
	div := briefMirrorDivergence{DocID: id, Status: status, Terminal: briefMirrorTerminalStatuses[status]}

	for _, block := range d.Brief.Blocks {
		switch strings.TrimSpace(block.ID) {
		case "purpose-copy":
			// The mirror leaves the block alone when the document carries no
			// `description`; so does this.
			if d.Description == nil || len(block.Content) == 0 || block.Content[0].Value == nil {
				continue
			}
			got := *block.Content[0].Value
			want := briefPurposeStripOnePass(*d.Description)
			// An empty stripped description is STUB territory
			// (task-23c70e97c90809c6, ruling B: the stub stays). The composer
			// substitutes auto-copy there, so the block legitimately says
			// something the description does not, and comparing is a
			// manufactured finding.
			if want == "" {
				continue
			}
			if got == want {
				continue
			}
			div.Blocks = append(div.Blocks, "purpose-copy (mirrors `description`)")
		case "criteria-list":
			// resync_criteria/2 leaves the block untouched when
			// `acceptance_criteria` is absent or not a list.
			if d.AcceptanceCriteria == nil || block.Items == nil {
				continue
			}
			if briefMirrorItemsEqual(*block.Items, briefMirrorCriterionTexts(*d.AcceptanceCriteria)) {
				continue
			}
			div.Blocks = append(div.Blocks, "criteria-list (mirrors `acceptance_criteria[].criterion`)")
		}
	}
	if len(div.Blocks) == 0 {
		return briefMirrorDivergence{}, false
	}
	return div, true
}

func briefMirrorItemsEqual(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// briefMirrorWarnLines renders the notice: which blocks lie, which field to
// read instead, and a remedy that differs by lifecycle because the two
// populations are not the same problem.
func briefMirrorWarnLines(d briefMirrorDivergence) []string {
	lines := []string{
		fmt.Sprintf("bp: BRIEF DOES NOT MATCH THE ROW — %s carries a `brief` whose %s %s what it mirrors. The AUTHORITATIVE text is the field, never the block; the brief is a rendering of it.",
			d.DocID,
			strings.Join(d.Blocks, " and "),
			map[bool]string{true: "disagree with", false: "disagrees with"}[len(d.Blocks) > 1]),
	}
	if d.Terminal {
		lines = append(lines,
			fmt.Sprintf("  this row is %s, so the divergence is FROZEN HISTORICAL RESIDUE and is NOT yours to repair. 1,761 terminal rows carry it (measured 2026-09-17); the ruling on task-b73c140509c1e901 deliberately LEFT them rather than rewrite published production rows. Read `description` / `acceptance_criteria` and move on — do NOT write the row to re-derive the mirror.", d.Status))
	} else {
		lines = append(lines,
			fmt.Sprintf("  this row is %s, so the mirror is SELF-HEALING: the server re-derives both blocks on the next write to this document (PR #16279). Nothing needs doing beyond reading the field; a no-op write of `description` to its own current value repairs it if you want the brief right now.", d.Status))
	}
	return lines
}

// emitBriefMirrorWarning prints the notice for a 2xx whose SINGLE document
// carries a divergent mirror. Called from runCommand's post-2xx hook beside
// emitArrearsClaim. stderr in every output mode, so `-o json` stays one
// byte-identical document.
func emitBriefMirrorWarning(out *writer, respBody []byte) {
	if d, ok := briefMirrorDivergenceFrom(respBody); ok {
		for _, line := range briefMirrorWarnLines(d) {
			out.errf("%s", line)
		}
	}
}
