<!-- doc-tier: cold | canonical-for: legendary-paper-verify-26-evidence | budget: 1800tok -->
# Verify 26 — immutable release-capture provenance

Verdict: contract `proven`; live successful capture `carried`. The complete scoped release gate, Wave revision, candidate UUID, role, and deployment digest tuple is required. Wave revision or mutable Paper revision alone cannot establish candidate-bound provenance. No valid live tuple is currently discoverable.

The live census checked 5,236 tasks and all 667 published Papers; neither corpus contains a release-pin object. Twelve Paper Cycle-ledger blocks reduce to six canonical Cycle scopes. All six Cycles exist and expose Wave revisions, but none contains a discoverable release object. Another 76 task-derived Cycle probes found two existing Cycles and 74 structured misses, still with no candidate authority.

The production route is deployed: a syntactically complete tuple against the current Wave reached the controller and returned exit 4 with structured `release Paper candidate not found`. This proves route, authentication, and tuple parsing, not live success.

Pinned source completed an end-to-end local immutable-source capture using the canonical fixture:

- format `cycle-release-headless-capture-v1`;
- CLI, task-board, and TUI reader artifacts all contain candidate proof;
- binary digest `fd75be76…141`, parser `fa7b8678…b66`, raw source `4f5d5f91…0aba`, and the 64-character deployment digest all match independent calculation;
- exact profiles are CLI `120xunbounded/evergreen-dark/none`, task board `120xunbounded/task-board-dark/ansi256`, and TUI `120xunbounded;measure=100/evergreen-dark/ansi256`;
- accepted response includes content-bound ETag plus matching gate, Wave, candidate, and role headers.

Negative paths fail closed. Missing deployment digest, candidate flag/URL drift, and partial query pins all exit 2 before acceptance. Focused capture, release-source, canonical-pin, missing-header, task-board reference, and scope-drift tests pass.

The server resolves only an open scoped gate with the reserved revision, then selects candidate by target revision and role and requires UUID/content-digest equality. Client validation rejects origin/scope redirects, requires all response headers and envelope pins, and binds ETag to content digest. Server activation supplies its configured deployment digest and verifies returned provenance against its challenge.

A standalone `bp paper capture` only records the caller-supplied deployment digest; it cannot independently prove that digest identifies the deployed server/binary. Strong deployment proof requires server-owned activation. Response headers are validated during fetch but omitted from standalone JSON; server-owned HTTP captures preserve them separately.

ExUnit could not run because API deps/build artifacts were absent; server conclusions use source and hostile-test trace plus executable Go probes. No live gate was staged or activated, and no repository/Barkpark state was mutated. Temporary evidence was trashed at `f4817bccc9394c51dd19666970992c29e6b71593`.
