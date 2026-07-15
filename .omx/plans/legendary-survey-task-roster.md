# Legendary Survey — Task-Focused Roster (24 assignments)

## Outcome and frozen inputs

This roster defines exactly 24 independent, bounded, read-only `epic-surveyor` assignments for the frozen 1,527-Task inventory. It deepens semantic quality evidence without repeating the accepted Wave 01 census or Wave 02 classification.

Frozen sources:

- `.omx/state/legendary-quality-baseline.json`
- Wave 02 frozen Task membership: 1,527 ids, SHA-256 `8418146b0770598d3066a0fbe04870a54a4b177bfc356dcc733d94c6300d5ce8`
- Wave 02 class manifest: SHA-256 `3c98e1418e6ed48bb01ffa12d4ef50510dfa6db986a76be489ca4bcda7e59198`
- Classes: executable 127; goal 62; decision/human gate 43; done/cancelled history 1,157; deferred 133; probe 5
- Cohorts: P0 1; P1 5; P2 32; retire 6; human-review 414; ambiguous multi-signal 82

All ordinal ranges below mean: filter the accepted frozen manifest by the stated selector, sort ascending by stable `doc_id` byte order, then take the inclusive 1-based ordinal interval. A hash or count mismatch is a stop condition, not permission to silently rebase the assignment onto live drift.

## JSON-compatible roster

```json
{
  "schema_version": 1,
  "roster_id": "legendary-survey-task-quality-v1",
  "agent_type": "epic-surveyor",
  "assignment_count": 24,
  "read_only": true,
  "baseline": {
    "task_count": 1527,
    "membership_sha256": "8418146b0770598d3066a0fbe04870a54a4b177bfc356dcc733d94c6300d5ce8",
    "classification_sha256": "3c98e1418e6ed48bb01ffa12d4ef50510dfa6db986a76be489ca4bcda7e59198"
  },
  "common_inputs": [
    "CLAUDE.md and the Legendary Cycle phase/fleet/scale contracts",
    ".omx/state/legendary-quality-baseline.json",
    "accepted Wave 02 frozen membership, classification, cohort, and Cn manifests",
    "raw Task pages from bp doc query task --perspective raw --count --limit 1000 --offset 0 -o json and --offset 1000"
  ],
  "common_deliverable": "Exact ids; commands/probes and decisive output; found/not_found/partial per check; facts separated from inference; cohort counts; defects ranked by severity; recommended Verify/Experiment shard; zero mutations.",
  "assignments": [
    {
      "id": "LS-TASK-01",
      "title": "Executable Tasks 001-064 — criteria and runnable-gate quality",
      "scope": "First 64 of 127 executable Tasks; audit whether criteria are observable, bounded, non-circular, and backed by a runnable gate or explicit human proof.",
      "deterministic_membership": {"class": "executable", "ordinals": "1-64", "expected": 64},
      "probes": ["read raw description, criteria, brief, code_refs and claim/lifecycle", "classify each criterion as command-backed, observable-human, vague, or absent", "record command existence without executing mutating commands"],
      "validation": "64 unique ids; no id outside executable manifest; per-id criterion and gate verdict; subtotal=64.",
      "risks": ["command text may be stale or destructive; inspect only", "mechanical completeness can overstate semantic readiness"],
      "stop_condition": "Stop on manifest hash/count drift, duplicate ids, or any required mutation."
    },
    {
      "id": "LS-TASK-02",
      "title": "Executable Tasks 065-127 — dependency, blocker, and readiness truth",
      "scope": "Remaining 63 executable Tasks; audit dependency edges, blocker truth, claim readiness, placement, and whether the next action is cold-startable.",
      "deterministic_membership": {"class": "executable", "ordinals": "65-127", "expected": 63},
      "probes": ["compare depends_on/blocked_by ids with raw Task inventory", "check lifecycle and claim consistency", "rate cold-startability from description, brief, files, and gates"],
      "validation": "63 unique ids; LS-TASK-01 union LS-TASK-02 equals all 127 executable ids with overlap=0.",
      "risks": ["dependency absence is not automatically a defect", "live claims may drift after the frozen snapshot"],
      "stop_condition": "Stop if frozen ownership cannot be reconstructed exactly or live state is substituted for frozen truth."
    },
    {
      "id": "LS-TASK-03",
      "title": "Goal Tasks 001-031 — outcome, metric, and child decomposition",
      "scope": "First 31 of 62 goal Tasks; audit outcome clarity, measurable success, child coverage, and whether the goal is improperly executable as one unit.",
      "deterministic_membership": {"class": "goal", "ordinals": "1-31", "expected": 31},
      "probes": ["trace parent/children and child_count", "compare goal criteria with aggregate child outcomes", "flag implementation detail that belongs in child Tasks"],
      "validation": "31 unique goal ids with outcome/metric/decomposition verdicts and exact child counts.",
      "risks": ["missing children can be intentional for newly opened goals"],
      "stop_condition": "Stop if parent-child reads cannot be reconciled to the frozen membership."
    },
    {
      "id": "LS-TASK-04",
      "title": "Goal Tasks 032-062 — stop conditions and phase truth",
      "scope": "Remaining 31 goal Tasks; audit terminal conditions, phase labels, evidence aggregation, and lifecycle truth.",
      "deterministic_membership": {"class": "goal", "ordinals": "32-62", "expected": 31},
      "probes": ["compare acceptance criteria with child completion state", "inspect phase/proj labels and Paper links", "identify goals closed without aggregate evidence or left open after terminal evidence"],
      "validation": "31 unique ids; LS-TASK-03 union LS-TASK-04 equals all 62 goal ids with overlap=0.",
      "risks": ["child completion alone may not satisfy a goal-level outcome"],
      "stop_condition": "Stop on unresolved membership mismatch; carry live-state differences as drift."
    },
    {
      "id": "LS-TASK-05",
      "title": "Decision/human gates 001-022 — authority and decision inputs",
      "scope": "First 22 of 43 decision or human-gate Tasks; audit named decider, authority boundary, options, required inputs, and explicit irreversible action.",
      "deterministic_membership": {"class": "decision_or_human_gate", "ordinals": "1-22", "expected": 22},
      "probes": ["extract owner/decider and decision requested", "verify options and consequences are present", "separate credential/production authority from ordinary work"],
      "validation": "22 unique ids, each with authority/options/input verdicts.",
      "risks": ["implicit organizational authority cannot be inferred as fact"],
      "stop_condition": "Stop rather than invent an owner, option, or decision deadline."
    },
    {
      "id": "LS-TASK-06",
      "title": "Decision/human gates 023-043 — auditability and resumption",
      "scope": "Remaining 21 decision or human-gate Tasks; audit response capture, expiry, resumption trigger, and downstream handoff.",
      "deterministic_membership": {"class": "decision_or_human_gate", "ordinals": "23-43", "expected": 21},
      "probes": ["check whether a decision result has a durable field/evidence link", "identify stale gates whose decision is already observable", "verify named next owner and resumption rule"],
      "validation": "21 unique ids; LS-TASK-05 union LS-TASK-06 equals all 43 decision/human-gate ids with overlap=0.",
      "risks": ["absence of a response in Task content does not prove no external decision occurred"],
      "stop_condition": "Stop if evidence would require private/external systems not available to the survey."
    },
    {
      "id": "LS-TASK-07",
      "title": "Done/cancelled history 0001-0290 — closure reason truth",
      "scope": "First 290 of 1,157 historical Tasks; audit lifecycle, criteria state, close/cancel reason, and contradictory active claims.",
      "deterministic_membership": {"class": "done_or_cancelled_history", "ordinals": "1-290", "expected": 290},
      "probes": ["cross-tab lifecycle against criteria met state", "inspect close_reason/cancel rationale", "flag active claims or blockers on terminal Tasks"],
      "validation": "290 unique historical ids; exact contradiction counts by lifecycle.",
      "risks": ["older Tasks may predate current fields"],
      "stop_condition": "Stop if terminal lifecycle cannot be read from frozen raw documents."
    },
    {
      "id": "LS-TASK-08",
      "title": "Done/cancelled history 0291-0579 — evidence and code provenance",
      "scope": "Next 289 historical Tasks; audit result evidence, code_refs, branch/commit truth, and Paper linkage.",
      "deterministic_membership": {"class": "done_or_cancelled_history", "ordinals": "291-579", "expected": 289},
      "probes": ["validate commit-shaped refs locally when present", "check evidence links are non-empty and plausibly resolvable", "distinguish no-code outcomes from missing provenance"],
      "validation": "289 unique ids; evidence states found/not_found/partial with false-positive controls.",
      "risks": ["garbage-collected branches do not invalidate reachable commits", "historical no-code Tasks may need no commit"],
      "stop_condition": "Stop before network or repository mutation; report unverifiable external refs as partial."
    },
    {
      "id": "LS-TASK-09",
      "title": "Done/cancelled history 0580-0868 — semantic usefulness after closure",
      "scope": "Next 289 historical Tasks; audit whether title, description, criteria, and result preserve enough context for future readers.",
      "deterministic_membership": {"class": "done_or_cancelled_history", "ordinals": "580-868", "expected": 289},
      "probes": ["rate standalone comprehensibility without live chat context", "check result explains what changed and limitations", "identify duplicate/superseded artifacts without treating brevity alone as low quality"],
      "validation": "289 unique ids; class-aware usefulness rating and exact rationale category per id.",
      "risks": ["semantic ratings require explicit evidence quotes/paraphrases, not length heuristics"],
      "stop_condition": "Stop if a rating cannot be justified from durable Task content."
    },
    {
      "id": "LS-TASK-10",
      "title": "Done/cancelled history 0869-1157 — stale structure and retention value",
      "scope": "Final 289 historical Tasks; audit parent/placement validity, stale blocker/dependency edges, duplicate history, and retain/archive value.",
      "deterministic_membership": {"class": "done_or_cancelled_history", "ordinals": "869-1157", "expected": 289},
      "probes": ["resolve parent/dependency ids against frozen inventory", "group obvious duplicate/superseded artifacts by evidence", "recommend retain, annotate, or human-review; never mutate"],
      "validation": "289 unique ids; LS-TASK-07..10 union equals all 1,157 history ids with pairwise overlap=0.",
      "risks": ["similar titles are insufficient proof of duplication"],
      "stop_condition": "Stop if deduplication would rely on inference without shared evidence."
    },
    {
      "id": "LS-TASK-11",
      "title": "Deferred Tasks 001-067 — rationale and reactivation triggers",
      "scope": "First 67 of 133 deferred Tasks; audit explicit deferral reason, owner, condition, expiry, and reactivation signal.",
      "deterministic_membership": {"class": "deferred", "ordinals": "1-67", "expected": 67},
      "probes": ["extract reason and trigger", "distinguish intentional backlog from abandoned executable work", "check lifecycle/priority consistency"],
      "validation": "67 unique ids with reason/trigger/owner verdicts.",
      "risks": ["no date is acceptable when a concrete event trigger exists"],
      "stop_condition": "Stop rather than infer product priority from age alone."
    },
    {
      "id": "LS-TASK-12",
      "title": "Deferred Tasks 068-133 — dependency and placement quality",
      "scope": "Remaining 66 deferred Tasks; audit dependency truth, parent/project placement, labels, priority, and recoverability.",
      "deterministic_membership": {"class": "deferred", "ordinals": "68-133", "expected": 66},
      "probes": ["resolve blockers/dependencies", "check project/phase placement", "rate cold-start recoverability when trigger fires"],
      "validation": "66 unique ids; LS-TASK-11 union LS-TASK-12 equals all 133 deferred ids with overlap=0.",
      "risks": ["a missing dependency field can be valid for policy deferrals"],
      "stop_condition": "Stop on membership drift or unavailable parent/dependency evidence."
    },
    {
      "id": "LS-TASK-13",
      "title": "Probe class — exhaustive retirement safety review",
      "scope": "All five accepted probe-class Tasks; determine retain-as-fixture, quarantine, or retire recommendation with preservation evidence.",
      "deterministic_membership": {"class": "probe", "ordinals": "1-5", "expected": 5},
      "probes": ["identify whether each probe has continuing fixture/audit value", "trace references from parent/Paper/code", "specify reversible retirement evidence without executing it"],
      "validation": "Exactly five unique probe ids and one evidence-backed disposition recommendation per id.",
      "risks": ["probe-looking Tasks may be durable regression fixtures"],
      "stop_condition": "Stop if reference reachability is partial; recommend human review instead of retirement."
    },
    {
      "id": "LS-TASK-14",
      "title": "P0 repair cohort — single critical Task proof packet",
      "scope": "The one accepted P0 Task; reproduce every severity signal and assemble a non-mutating proof packet for Verify.",
      "deterministic_membership": {"cohort": "p0", "expected": 1, "sha256": "edc81318db5b00e96e56da931cc98a5902c0c821a31bb1caf9ad784d74c30964"},
      "probes": ["recompute class-aware hard gates", "check lifecycle/claim/criteria/placement/evidence contradictions", "name minimal safe repair decision and proof commands"],
      "validation": "Exactly one frozen id; all P0 signals reproduced or explicitly refuted.",
      "risks": ["P0 inference is not final product truth"],
      "stop_condition": "Stop if cohort hash differs or repair requires production mutation."
    },
    {
      "id": "LS-TASK-15",
      "title": "P1 repair cohort — semantic authoring requirements",
      "scope": "All five accepted P1 Tasks; determine which gaps are mechanical and which require subject-matter authoring.",
      "deterministic_membership": {"cohort": "p1", "expected": 5, "sha256": "ad2a8b7afd217a1978b482b4a09c24f732e5893dac96a53ec090d347216190bc"},
      "probes": ["audit title/description/criteria/brief/placement/labels", "draft field-level repair requirements without writing content", "identify required human decisions"],
      "validation": "Five unique ids; every missing/weak field labeled mechanical, semantic, authority-gated, or no-change.",
      "risks": ["auto-generated prose can fabricate product intent"],
      "stop_condition": "Stop when semantic truth is unavailable; emit an authoring question, not guessed content."
    },
    {
      "id": "LS-TASK-16",
      "title": "P2 repair cohort 01-16 — metadata and placement repairability",
      "scope": "First 16 of 32 P2 Tasks; audit deterministic repairs for labels, placement, priority, and structurally missing brief fields.",
      "deterministic_membership": {"cohort": "p2", "ordinals": "1-16", "expected": 16, "cohort_sha256": "854d301d2b23a89c277d599f5f9cdc50b20c52a5228017196363cc9bb00dc0d6"},
      "probes": ["derive candidate metadata only from parent/project evidence", "check whether brief scaffolding can preserve existing authored text", "identify idempotence keys for later experiment"],
      "validation": "16 unique P2 ids and field-level safe/unsafe repair matrix.",
      "risks": ["parent metadata propagation may be semantically wrong"],
      "stop_condition": "Stop if a proposed mechanical repair changes intent or lifecycle."
    },
    {
      "id": "LS-TASK-17",
      "title": "P2 repair cohort 17-32 — criteria and evidence repairability",
      "scope": "Remaining 16 P2 Tasks; audit whether criteria/evidence gaps can be recovered from durable results, code refs, or linked Papers.",
      "deterministic_membership": {"cohort": "p2", "ordinals": "17-32", "expected": 16, "cohort_sha256": "854d301d2b23a89c277d599f5f9cdc50b20c52a5228017196363cc9bb00dc0d6"},
      "probes": ["trace durable evidence links", "separate reconstructable facts from new authoring", "define no-fabrication guardrails"],
      "validation": "16 unique ids; LS-TASK-16 union LS-TASK-17 equals all 32 P2 ids with overlap=0.",
      "risks": ["post-hoc criteria can falsely rewrite history"],
      "stop_condition": "Stop if repair would assert evidence not already durable."
    },
    {
      "id": "LS-TASK-18",
      "title": "Retire cohort — six-item reference and preservation audit",
      "scope": "All six accepted retire candidates; independently test reference reachability, audit value, and reversibility. Intentional paired overlap with LS-TASK-13 is allowed only for probe ids also in retire.",
      "deterministic_membership": {"cohort": "retire", "expected": 6, "sha256": "dbd79be113fac59b403468776e28b01607aa5a8b092139bfaf73a863c21d3927"},
      "probes": ["trace parents, dependencies, Papers, and code refs", "record preservation/export needs", "recommend retain, quarantine, or retire with confidence"],
      "validation": "Six unique ids; overlap with primary class assignments explicitly reported; no deletion or mutation.",
      "risks": ["reference search can miss external consumers"],
      "stop_condition": "Stop and require human review on any unresolved consumer or audit obligation."
    },
    {
      "id": "LS-TASK-19",
      "title": "Human-review cohort 001-138 — class disagreement calibration",
      "scope": "First 138 of 414 human-review Tasks; independently rate class and quality using frozen rubric, emphasizing multi-signal disagreement.",
      "deterministic_membership": {"cohort": "human_review", "ordinals": "1-138", "expected": 138, "cohort_sha256": "d8d847d2c1a1cebb5f7357a5d2282f80b58522f115105489bcd9404df1bf646b"},
      "probes": ["record primary and alternate class with evidence", "rate hard gates separately from weighted score", "flag rubric ambiguity"],
      "validation": "138 unique ids, dual-class verdict where applicable, exact disagreement matrix.",
      "risks": ["single-rater judgment is calibration input, not final truth"],
      "stop_condition": "Stop rather than force a class when evidence supports a tie."
    },
    {
      "id": "LS-TASK-20",
      "title": "Human-review cohort 139-276 — lifecycle-sensitive semantics",
      "scope": "Middle 138 human-review Tasks; calibrate class-aware quality against lifecycle, distinguishing active intent from historical record.",
      "deterministic_membership": {"cohort": "human_review", "ordinals": "139-276", "expected": 138, "cohort_sha256": "d8d847d2c1a1cebb5f7357a5d2282f80b58522f115105489bcd9404df1bf646b"},
      "probes": ["apply lifecycle-specific hard gates", "identify cases where Cn/7 penalizes valid history or rewards hollow active work", "record adjudication evidence"],
      "validation": "138 unique ids and lifecycle-by-rating disagreement table.",
      "risks": ["uniform rubrics can misgrade historical or decision Tasks"],
      "stop_condition": "Stop if rubric application requires changing the accepted class rules mid-shard."
    },
    {
      "id": "LS-TASK-21",
      "title": "Human-review cohort 277-414 — evidence provenance and final calibration set",
      "scope": "Final 138 human-review Tasks; audit evidence provenance and nominate a balanced calibration fixture set for Verify/Experiment.",
      "deterministic_membership": {"cohort": "human_review", "ordinals": "277-414", "expected": 138, "cohort_sha256": "d8d847d2c1a1cebb5f7357a5d2282f80b58522f115105489bcd9404df1bf646b"},
      "probes": ["trace result/code/Paper evidence", "select fixtures across classes, lifecycles, and disagreement modes", "record why each fixture is representative"],
      "validation": "138 unique ids; LS-TASK-19..21 union equals all 414 human-review ids with pairwise overlap=0.",
      "risks": ["fixture cherry-picking can bias later experiments"],
      "stop_condition": "Stop if the proposed fixture set lacks every accepted class and material lifecycle."
    },
    {
      "id": "LS-TASK-22",
      "title": "Active placement and label gaps — exact paired-cohort audit",
      "scope": "Audit the accepted active-placement gap cohort (84) and active-label gap cohort (224). Their intersection is permitted and must be measured, not deduplicated silently.",
      "deterministic_membership": {"selectors": [{"active_gap": "placement", "expected": 84}, {"active_gap": "labels", "expected": 224}], "overlap": "explicitly paired; report intersection"},
      "probes": ["derive intended project/phase only from durable parents/Papers", "test label vocabulary consistency", "separate missing metadata from incorrect metadata"],
      "validation": "Placement subtotal=84; labels subtotal=224; intersection and union computed exactly; every id tied to its selector(s).",
      "risks": ["live active membership can drift", "metadata inference can encode wrong priority"],
      "stop_condition": "Stop if either accepted subtotal cannot be reproduced from the frozen manifest."
    },
    {
      "id": "LS-TASK-23",
      "title": "Semantic criteria and evidence-truth control sample",
      "scope": "Audit all 59 accepted active Tasks missing criteria plus an exact 60-Task control: the first 60 stable ids among active Tasks with criteria present. Compare absence against semantic weakness and evidence provenance.",
      "deterministic_membership": {"groups": [{"selector": "active AND criteria_missing", "expected": 59}, {"selector": "active AND criteria_present", "ordinals": "1-60", "expected": 60}], "overlap": 0},
      "probes": ["rate whether present criteria are testable and outcome-linked", "trace proof/evidence sources", "compare Cn mechanical presence with semantic quality"],
      "validation": "59 missing + 60 controls =119 unique ids; no cross-group overlap; matched class/lifecycle distribution reported as limitation if imbalanced.",
      "risks": ["ordinal control may not be statistically representative", "criteria presence does not prove truth"],
      "stop_condition": "Stop if fewer than 60 frozen active criteria-present Tasks exist or if evidence would require mutation."
    },
    {
      "id": "LS-TASK-24",
      "title": "All 82 ambiguous multi-signal Tasks — Cn disagreement adjudication",
      "scope": "Exhaustively double-rate the accepted 82 ambiguous multi-signal Tasks against class-aware quality and fixed Cn/7; produce calibration inputs, not final product truth.",
      "deterministic_membership": {"cohort": "ambiguous_multi_signal", "expected": 82, "sha256": "6d881ded0e83311be75afc0a0432f31652070c37a2697a0fec64ddea23bdc4b3"},
      "probes": ["compute Cn/7 mechanically", "independently score class-aware rubric and hard gates", "record direction/magnitude/cause of disagreement and evidence confidence"],
      "validation": "82 unique ids; two scores plus hard-gate verdict per id; exact disagreement distribution and unresolved ties.",
      "risks": ["class-aware ratings remain inference until independent Verify adjudication"],
      "stop_condition": "Stop on cohort hash mismatch or when a score lacks a cited durable fact."
    }
  ]
}
```

## Acceptance and verification checklist

- Exactly 24 unique assignment ids, all prefixed `LS-TASK-` and all intended for typed `epic-surveyor` execution.
- All assignments are read-only; no Task, Paper, repository, claim, lifecycle, or production mutation is permitted.
- Primary class shards LS-TASK-01..13 cover `127 + 62 + 43 + 1,157 + 133 + 5 = 1,527` frozen Tasks exactly once.
- Primary ordinal intervals have no gaps or overlap within a class.
- Secondary cohort assignments LS-TASK-14..24 intentionally revisit only named repair/calibration axes; overlap is declared and measured.
- P0/P1/P2/retire/human-review/ambiguous cohort hashes match the accepted Wave 02 baseline before work starts.
- Each result reports exact ids and counts, commands/probes, decisive output, found/not_found/partial, facts versus inference, risks, and a named Verify/Experiment follow-up.
- Any baseline/hash/count drift is reported separately and stops the affected shard; no assignment silently changes its membership.
- The roster does not repeat Wave 01 inventory/rubric discovery or Wave 02 census/classification as its outcome; those artifacts are frozen inputs.
- Completion requires 24 unique evidence-bearing durable results. Retries, duplicate prompts, failed dispatcher fragments, untyped workers, and leader synthesis do not count toward the Legendary Survey fleet.

## Risks and handoff

- The accepted cohort manifests must remain retrievable by exact hash; without them, ordinal shards are not dispatchable.
- Semantic ratings are survey evidence, not permission to mutate Tasks or final product truth.
- LS-TASK-19..24 should feed independent Verify calibration and the later experiment fixture selection.
- Global batching of this 24-assignment roster into the combined 54-assignment fleet belongs to the leader/global-roster lane; this artifact preserves unique ids and explicit overlap policy for integration.
