{
  "run_id": "grip-20260819-required-checks-generate-quoted-on-key-and-coe-forms",
  "subject_area": "CI gate-wiring + spec-generator integrity wave — [quoted-on-plant-rerun] verifier",
  "base": "origin/main bf499f54b6 (scripts/required-checks-generate.sh byte-identical to the surveyor's gen.sh copy: 1049 lines, diff empty)",
  "harness": "hermetic mktemp workflow tree + fixture-dir check-run corpus, driven through scripts/required-checks-generate.sh --workflows/--fixture-dir/--no-merge/--explain. No network for the generator itself; no repo tree mutated.",
  "recipes": [
    {
      "subject": "PLANT 6 REPRODUCED — a workflow whose trigger key is written \"on\": (quoted) makes its pull_request paths filter invisible to build_workflow_index's awk, so S4 PATHS-FILTERED never fires and the paths-filtered job is EMITTED AS A REQUIRED CONTEXT at exit 0. Root cause: scripts/required-checks-generate.sh:299 `/^on:/ { inon = 1; next }` — a byte-anchored regex on an unquoted key.",
      "verdict": "CONFIRMED, independently reproduced from a clean temp tree. Severity HELD at 'deadlock waiting to happen' — GitHub Actions ACCEPTS the quoted key (proven live, below), so this is not parser fragility over an impossible input.",
      "derived_level": "L1 for the generator behaviour (ran it); L1 for GitHub acceptance (a real public workflow with \"on\": has completed/success runs on both push and pull_request).",
      "rerun": "bash /Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ba5f66f9-9370-4639-ae79-5f38bb0e7fe1/scratchpad/bench3.sh",
      "quoted_output": [
        "=== CONTROL: paths-filtered, plain 'on:' ===",
        "  exclude  Filtered gate  — S4 PATHS-FILTERED: f.yml only runs on matching paths, so on other PRs this name is ABSENT — a required absent context never reports",
        "SPEC: (empty)",
        "=== PLANT 6: same workflow, QUOTED \"on\": key ===",
        "  keep     Filtered gate  (f.yml job 'f')",
        "SPEC: [\"Filtered gate\"]"
      ],
      "github_acceptance_proof": {
        "schema": "curl -sL https://json.schemastore.org/github-workflow.json -> required: ['on','jobs'], additionalProperties: false. The schema demands a key literally named \"on\"; the quoted YAML form produces exactly that string key.",
        "yaml_semantics": "python3 -c \"import yaml; print(list(yaml.safe_load('on:\\n  a: 1\\n').keys()), list(yaml.safe_load('\\\"on\\\":\\n  a: 1\\n').keys()))\" -> [True] vs ['on']. Under YAML 1.1 (PyYAML, yamllint's truthy rule) a BARE on: resolves to the boolean True, so strict-YAML tooling actively pushes authors toward the quoted form.",
        "live_specimen": "gh api repos/sous-chefs/docker/contents/.github/workflows/ci.yml | base64 -d -> literal `\"on\":` at top level; gh api repos/sous-chefs/docker/actions/workflows/ci.yml/runs -> ci | push | completed/success | 2026-08-13, ci | pull_request | completed/success | 2026-08-12.",
        "prevalence": "gh api search/code q='\"\\\"on\\\":\" path:.github/workflows extension:yml' -> total_count 21632 public files."
      },
      "second_order": "The same ^on: anchor appears a second time at scripts/required-checks-generate.sh:499 in workflow_has_head_trigger(). With a quoted key that function returns 'no head trigger', so the operator hint for an unrendered name becomes the FALSE sentence 'PULL_REQUEST-ONLY: it can never render on a branch head, so only the merge can carry it' for a workflow that does have push:.",
      "repo_status": "ZERO live instances. `git grep -n '\"on\":' origin/main -- .github/workflows` returns nothing; `git log --all -S'\"on\":' -- .github/workflows` returns no commit. No yamllint/.yamllint config in the tree, so nothing in THIS repo currently pushes an author to quote. Latent, not live."
    },
    {
      "subject": "PLANT 4c/4d REPRODUCED — continue-on-error written as 'true' (quoted scalar) or as ${{ github.event_name == 'pull_request' }} is invisible to the byte-literal matcher at scripts/required-checks-generate.sh (`$0 ~ /^    continue-on-error: *true/`), so S2 ADVISORY never fires and the advisory job is EMITTED AS REQUIRED at exit 0 — putting one context on the required list that generate.sh:1033's own stated invariant says must be excluded.",
      "verdict": "CONFIRMED, independently reproduced. Canonical `continue-on-error: true` control correctly excludes, proving the clause works and the gap is purely in the accepted spelling.",
      "derived_level": "L1 (ran it).",
      "rerun": "bash /Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ba5f66f9-9370-4639-ae79-5f38bb0e7fe1/scratchpad/bench2.sh",
      "quoted_output": [
        "=== 4c-ISOLATED: quoted 'true', NOT subsumed ===",
        "  keep     Advisory gate  (a.yml job 'adv')",
        "SPEC: [\"Advisory gate\"]",
        "=== 4d: continue-on-error: ${{ expr }} (evaluates true on PRs) ===",
        "  keep     Advisory gate  (a.yml job 'adv')",
        "SPEC: [\"Advisory gate\"]",
        "=== 4e: continue-on-error: true (canonical) — control ===",
        "  exclude  Advisory gate  — S2 ADVISORY: a.yml job 'adv' carries continue-on-error:true — needs.<job>.result reads success even when it failed",
        "SPEC: (empty)"
      ],
      "indent_note": "The regex is also anchored at exactly 4 spaces, so a job-level key at any other indentation, and every STEP-level continue-on-error (6+ spaces), is structurally invisible to it."
    },
    {
      "subject": "NEW, found while re-running: scripts/required-checks-generate.sh:286 globs only \"$WORKFLOW_DIR\"/*.yml. GitHub Actions equally accepts .yaml, and the repo's own sibling guard scripts/never-cancel-main-check.sh:96 globs BOTH (glob.glob('*.yml') + glob.glob('*.yaml')) — so the omission is inconsistent by the repo's own standard, not a judgement call.",
      "verdict": "REAL but FAIL-SAFE, and MIS-DIAGNOSED. All-.yaml tree fails LOUD ('FAIL: the workflow index is empty — the parser is broken, not the repo'). A MIXED tree does not over-promote: the .yaml job's context is excluded — but with a factually FALSE reason.",
      "derived_level": "L1 (ran both shapes).",
      "rerun": "see quoted_output; reproduce by copying gen from `git show origin/main:scripts/required-checks-generate.sh` into a temp dir and driving it against a temp workflow dir containing one r.yml and one y.yaml, with a fixture check-run corpus naming both jobs",
      "quoted_output": [
        "ALL-.yaml tree: 'FAIL: the workflow index is empty — the parser is broken, not the repo' (loud, correct)",
        "MIXED tree r.yml + y.yaml: '  keep     Real gate  (r.yml job 'r')' / '  exclude  Yaml gate  — S0 UNMAPPED: no job in <dir> publishes this name — it cannot be traced to source'",
        "SPEC: [\"Real gate\"]  EXCLUSIONS: [\"Yaml gate\"]"
      ],
      "why_low": "Under-specification (a real gate silently never becomes required) plus a false exclusion reason that would send the next operator hunting a renamed job. Not an over-promotion hole. Repo has zero .yaml workflows today (`ls .github/workflows/*.yaml` -> no matches)."
    },
    {
      "subject": "The existing harness NEVER plants any of these forms.",
      "verdict": "CONFIRMED by counting in scripts/required-checks.test.sh (3437 lines): quoted-scalar continue-on-error = 0 occurrences, ${{ }} continue-on-error = 0, top-level quoted \"on\": = 0. Its only continue-on-error fixture (line 168) is the canonical `true`. Its real-tree copies at lines 508/2657/3050/3372 all use `cp \"$REPO_ROOT\"/.github/workflows/*.yml`, so a .yaml would be invisible to the suite too.",
      "derived_level": "L4 (git show of origin/main + grep -c).",
      "rerun": "git show origin/main:scripts/required-checks.test.sh | grep -c \"continue-on-error: *'\"; git show origin/main:scripts/required-checks.test.sh | grep -c 'continue-on-error: *\\${{'; git show origin/main:scripts/required-checks.test.sh | grep -c '^ *\"on\":'",
      "deliverable": "Three new clauses in scripts/required-checks.test.sh — not a spec regeneration, since all three defects are latent with zero live instances on main."
    }
  ]
}
