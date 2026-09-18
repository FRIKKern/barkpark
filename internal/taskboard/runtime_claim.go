package taskboard

import (
	"fmt"
	"regexp"
	"strings"
)

// Runtime-claim audit: the false-done class where a row's own proof is of the
// WRONG KIND for the property it asserts.
//
// The specimen (tlv-bl-events-actor-attribution, 2026-09-18) is the whole
// class in one row. Its criterion asserts a property of the RUNNING ledger —
// "a task.closed / task.claimed event carries the actor attribution" — and it
// is stamped met=true on evidence that is entirely repo-side: a merged PR, a
// `git grep` on origin/main showing the symbol, a green `mix test`. Every one
// of those statements is TRUE. The row is still false-done, because two live
// probes against production today return the property absent: the per-doc
// event stream's key union over 152 events is exactly
// [at doc_id event id rev], and every one of 16 document revisions answers
// actor_kind/actor_id/actor_label/actor_user_id null.
//
// The general rule the specimen instantiates:
//
//	CODE PRESENCE DOES NOT ENTAIL RUNTIME PRESENCE.
//
// A symbol on origin/main, a green test, an ancestor commit — none of them say
// the deployed system emits the thing. Between the merge and the observation
// sit a deploy, a migration, a feature flag, a serializer that drops unknown
// keys, and a release build that never loaded the module. Each of those has its
// own filed row in this ledger.
//
// WHAT THIS DETECTOR DOES AND DOES NOT CLAIM
//
// It does NOT evaluate the criterion. It cannot run an arbitrary sentence of
// English against production, and a detector that pretended to would be the
// same failure one level up. What it decides — mechanically, from the row
// alone, with no network call and no judgment — is a property of the EVIDENCE:
//
//	this criterion asserts something only the running system can answer,
//	and the proof attached to it is entirely repo-side.
//
// That verdict is UNMEASURED-AT-RUNTIME, never "false". The row may well be
// fine; what is established is that nothing on it establishes that. Acting on
// the verdict means running the probe, one row at a time — which is why the
// command emits the ids and refuses to summarise them away, and why no code
// here flips any row's state.
//
// It is a PREDICATE, not an enumeration. A hand-listed set of specimens is a
// snapshot that is wrong the moment the next row closes; the vocabularies below
// are rules that keep classifying rows nobody has read.
//

// RuntimeVerdict is the classification of ONE criterion.
type RuntimeVerdict int

const (
	// VerdictNotRuntime — the criterion asserts nothing the running system
	// has to answer. A repo-local claim ("the module is deleted", "the doc
	// says X") is fully proved by repo-side evidence, so this detector has
	// no opinion on it. The common case, and correctly silent.
	VerdictNotRuntime RuntimeVerdict = iota
	// VerdictLiveProbed — a runtime claim whose evidence cites an actual
	// observation of a running system (a curl, a response body, a status
	// code, a named host). Not a guarantee the probe was honest — evidence is
	// prose a worker wrote — but the row at least claims the right KIND of
	// proof, so it is out of the suspect class.
	VerdictLiveProbed
	// VerdictUnmeasured — the finding. A runtime claim, stamped met, proved
	// only by code presence. The property is UNMEASURED: this says nothing
	// about whether it holds.
	VerdictUnmeasured
	// VerdictNoEvidence — a runtime claim stamped met with no evidence text
	// at all. Reported separately because it is a different defect (the
	// server refuses that flip, so a read-back that finds one has found a
	// write that did not land as asked) and must not be quietly folded into
	// the Unmeasured count.
	VerdictNoEvidence
)

func (v RuntimeVerdict) String() string {
	switch v {
	case VerdictLiveProbed:
		return "live-probed"
	case VerdictUnmeasured:
		return "UNMEASURED-AT-RUNTIME"
	case VerdictNoEvidence:
		return "MET-WITHOUT-EVIDENCE"
	default:
		return "not-a-runtime-claim"
	}
}

// ── vocabularies ───────────────────────────────────────────────────────────
//
// Three word lists, each doing one job. They are deliberately CONSERVATIVE in
// the direction that costs least: a missed runtime claim is a row this
// detector stays quiet about, while a false one puts a clean row on a human's
// adjudication list. Under-calling is the cheaper error, so every pattern here
// has to name a system surface, not merely sound technical.

// runtimeSurfacePatterns match a criterion that names a surface only a RUNNING
// system exposes: an HTTP route, a CLI invocation, an emitted event, a
// rendered page. Naming the surface is the test — not the verb, because
// "returns" describes a Go function just as happily as an endpoint.
var runtimeSurfacePatterns = []*regexp.Regexp{
	// An HTTP method + path, or a versioned API path on its own.
	regexp.MustCompile(`(?i)\b(get|post|put|patch|delete)\s+/\S`),
	regexp.MustCompile(`(?i)(^|[^\w/])/v\d+/\w`),
	// A shell invocation of the product's own CLI.
	regexp.MustCompile(`(?i)\bbp\s+[a-z][a-z-]+\b`),
	regexp.MustCompile("(?i)`bp\\s"),
	// Emitted/served artifacts: events, responses, payloads on the wire.
	regexp.MustCompile(`(?i)\b(emitted|emits|the\s+event\s+stream|event\s+carries|response\s+body|the\s+endpoint|the\s+api\s+returns|served\s+html|the\s+running|in\s+production|deployed)\b`),
}

// liveProbePatterns match evidence that cites an OBSERVATION of a running
// system: a request actually issued, a body actually read, a host actually
// named. This is the vocabulary that moves a runtime claim out of the suspect
// class.
var liveProbePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bcurl\b`),
	regexp.MustCompile(`(?i)https?://`),
	regexp.MustCompile(`(?i)\b(against|on)\s+(production|prod|the\s+live|staging)\b`),
	regexp.MustCompile(`(?i)\blive\s+(probe|read|request|response|call|ledger)\b`),
	regexp.MustCompile(`(?i)\bhttp\s+(2|3|4|5)\d\d\b`),
	regexp.MustCompile(`(?i)\bstatus\.json\b`),
	regexp.MustCompile(`(?i)\bthe\s+server\s+(answered|returned|responded)\b`),
	regexp.MustCompile(`(?i)\bresponse\s+body\s+(was|carried|held|shows)\b`),
}

// codePresencePatterns match evidence that proves only that the CODE exists:
// a merge, an ancestry check, a grep, a test run. Requiring at least one of
// these is what keeps the suspect class to rows whose proof is affirmatively
// repo-side, rather than sweeping in every criterion whose evidence prose the
// other two lists happen not to recognise. An unrecognised evidence style is
// UNCLASSIFIED and stays out of the finding.
var codePresencePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bPR\s*#\d+`),
	regexp.MustCompile(`(?i)\bmerged\b`),
	regexp.MustCompile(`(?i)\bancestor\s+of\b`),
	regexp.MustCompile(`(?i)\borigin/main\b`),
	regexp.MustCompile(`(?i)\bgit\s+(grep|show|log|diff|merge-base)\b`),
	regexp.MustCompile(`(?i)\b(mix|go|npm|pnpm|node)\s+test\b`),
	regexp.MustCompile(`(?i)\b\d+\s+tests?,\s*\d+\s+failures?\b`),
	regexp.MustCompile(`(?i)\b(the\s+)?(test|suite|gate)s?\s+(is|are|was|were)?\s*green\b`),
	regexp.MustCompile(`(?i)\b[\w./-]+\.(ex|exs|go|js|ts|tsx|heex|md)\b`),
}

func anyMatch(pats []*regexp.Regexp, s string) bool {
	for _, p := range pats {
		if p.MatchString(s) {
			return true
		}
	}
	return false
}

// AssertsRuntimeProperty reports whether a criterion sentence claims something
// only the running system can answer.
func AssertsRuntimeProperty(criterion string) bool {
	return anyMatch(runtimeSurfacePatterns, criterion)
}

// EvidenceCitesLiveProbe reports whether evidence prose cites an observation of
// a running system.
func EvidenceCitesLiveProbe(evidence string) bool {
	return anyMatch(liveProbePatterns, evidence)
}

// EvidenceCitesCodePresence reports whether evidence prose cites repo-side
// proof — a merge, an ancestry check, a grep, a test run, a source path.
func EvidenceCitesCodePresence(evidence string) bool {
	return anyMatch(codePresencePatterns, evidence)
}

// ClassifyCriterion is the predicate. It takes one criterion exactly as the
// ledger stores it and returns the verdict, with no network call and no
// knowledge of which row it came from.
//
// An UNMET criterion is never classified: an unmet criterion asserts nothing
// yet, and the whole class under audit is rows whose claims are SEALED.
func ClassifyCriterion(item CriterionItem) RuntimeVerdict {
	if !item.Met {
		return VerdictNotRuntime
	}
	if !AssertsRuntimeProperty(item.Criterion) {
		return VerdictNotRuntime
	}
	ev := strings.TrimSpace(item.Evidence)
	if ev == "" {
		return VerdictNoEvidence
	}
	if EvidenceCitesLiveProbe(ev) {
		return VerdictLiveProbed
	}
	if EvidenceCitesCodePresence(ev) {
		return VerdictUnmeasured
	}
	// Evidence in a style none of the three vocabularies recognises. Claiming
	// it is repo-side would be inventing a reading; the row stays out of the
	// finding.
	return VerdictNotRuntime
}

// RuntimeFinding is one sealed runtime claim that nothing on its row measured.
type RuntimeFinding struct {
	DocID     string
	Index     int // position in content.acceptance_criteria
	Criterion string
	Verdict   RuntimeVerdict
	ClosedBy  string
}

// Ref is the stable citation for one criterion: "<bare doc id>#<index>".
func (f RuntimeFinding) Ref() string { return fmt.Sprintf("%s#%d", f.DocID, f.Index) }

// RuntimeClaimFindings walks TERMINAL rows and returns every sealed criterion
// the predicate classes as unmeasured-at-runtime or met-without-evidence,
// in (doc id, index) order.
//
// Non-terminal rows are skipped: a live row's criteria are still being worked,
// and "nobody re-checked" is not yet a defect on a row nobody has finished.
// @canonical capability:runtime-claim-audit aka:false-done-detector,code-presence-is-not-runtime-presence,unverified-at-runtime
func RuntimeClaimFindings(details []TaskDetail) []RuntimeFinding {
	var out []RuntimeFinding
	for _, d := range details {
		if !IsTerminalLifecycle(d.Lifecycle) {
			continue
		}
		for i, item := range d.CriteriaItems {
			v := ClassifyCriterion(withEvidence(d, i, item))
			if v == VerdictUnmeasured || v == VerdictNoEvidence {
				out = append(out, RuntimeFinding{
					DocID:     BareID(d.DocID),
					Index:     i,
					Criterion: item.Criterion,
					Verdict:   v,
					ClosedBy:  d.ClosedBy,
				})
			}
		}
	}
	return out
}

// withEvidence fills a criterion's evidence from the index-aligned
// TaskDetail.Evidence slice when the item itself carries none. The two are
// populated by different decode paths and either may be the one that holds the
// text; reading only CriterionItem.Evidence made every row in a fixture look
// evidence-free.
func withEvidence(d TaskDetail, i int, item CriterionItem) CriterionItem {
	if strings.TrimSpace(item.Evidence) == "" && i < len(d.Evidence) {
		item.Evidence = d.Evidence[i]
	}
	return item
}

// ── the control ────────────────────────────────────────────────────────────

// RuntimeClaimRows projects terminal rows onto ControlEnrichment's input, one
// EnrichmentRow per SEALED criterion.
//
// The finding under control is "sealed runtime claims are proved without a
// live probe more often than sealed repo-local claims are". The confound is
// the same one the close_reason control names: the closing worker. A worker
// who never cites a probe on anything manufactures exactly this enrichment in
// whichever class they happened to close most, and the marginal ratio cannot
// see it.
//
// Missing = the evidence cites no live probe. Note what this makes the
// baseline class: repo-local claims, for which a live probe is not merely
// absent but IRRELEVANT. That asymmetry is the finding's weakness and is
// precisely why it is routed through the control instead of quoted raw.
func RuntimeClaimRows(details []TaskDetail) []EnrichmentRow {
	out := make([]EnrichmentRow, 0, len(details))
	for _, d := range details {
		if !IsTerminalLifecycle(d.Lifecycle) {
			continue
		}
		for i, item := range d.CriteriaItems {
			item = withEvidence(d, i, item)
			if !item.Met {
				continue
			}
			class := ClassRepoLocalClaim
			if AssertsRuntimeProperty(item.Criterion) {
				class = ClassRuntimeClaim
			}
			out = append(out, EnrichmentRow{
				ID:      fmt.Sprintf("%s#%d", BareID(d.DocID), i),
				Class:   class,
				Stratum: ClosingStratum(d.ClosedBy),
				Missing: !EvidenceCitesLiveProbe(item.Evidence),
			})
		}
	}
	return out
}

// Class names for the runtime-claim control.
const (
	// ClassRuntimeClaim — a sealed criterion asserting a property only the
	// running system can answer.
	ClassRuntimeClaim = "runtime"
	// ClassRepoLocalClaim — a sealed criterion fully provable from the repo.
	ClassRepoLocalClaim = "repo-local"
)
