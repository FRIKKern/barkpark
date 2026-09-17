<!-- doc-tier: agent | canonical-for: security-gates | budget: 2500tok -->
# Security gates (Sobelow + mix_audit)

> The policy of record for the two Elixir security gates in
> `.github/workflows/security.yml`, and for the `Security gate` aggregator they
> hang under. Split out of [merge-gates.md](merge-gates.md) when that page hit
> its byte ceiling; the gate roster, the required-context reading and the
> blocking/advisory distinction all still live there.

`.github/workflows/security.yml` (filed by `task-a41fc4590b2c2eb1`) adds two
Elixir security gates, path-triggered on `api/**`:

9. **`sobelow` job** — Phoenix-aware static analysis (XSS.Raw / SendResp,
   SQL injection, unsafe `String.to_atom`, missing CSRF/CSP, hardcoded secrets,
   `binary_to_term`, directory traversal…). **Advisory** (`continue-on-error:
   true`) because the reviewed baseline is not drained — see the amended flip
   verdict below. What *is* unstable is the
   **line number**, which is inside the hash: a pure renumber invalidates every
   waiver in the file. That is a reason to migrate waivers to AST-bound inline
   annotations, not a reason to stay advisory.
   `mix sobelow --skip --exit Low` reads the reviewed `api/.sobelow-skips`
   baseline and reds on a fresh unskipped finding. CI also runs a pinned
   Elixir 1.18.1/OTP27 reconcile in the only safe order: `--clear-skip`, then
   `--mark-skip-all`; it uploads the regenerated baseline and diff as an
   artifact for human review. CI never auto-commits it, and a developer-box
   regeneration must never be committed. After review, a separate change may
   update the tracked baseline. The fresh-finding guard plants a non-controller
   `String.to_atom` call and requires Sobelow to exit 1, preventing blanket
   suppression while the job remains advisory.

   **Flip verdict 2026-07-21 — STAY ADVISORY**, and **amended 2026-07-28 (D139)**
   because the precondition as first written was unsatisfiable. History: [merge-gates-history.md](merge-gates-history.md#the-sobelow-flip-precondition-as-first-written).

   **Live count — RE-DERIVE, never quote.** The count is drained by every
   annotation wave, so any number written here is stale on arrival. Run:

   ```
   $ grep -c '^[A-Za-z]' api/.sobelow-skips
   $ grep '^[A-Za-z]' api/.sobelow-skips | sed 's/:.*//' | sort | uniq -c | sort -rn
   ```

   History: [merge-gates-history.md](merge-gates-history.md#sobelow-baseline-and-floor-derivations-2026-07-28-onward).

   **Amended precondition — the floor is 9, not 0.** The flip is gated on the
   baseline holding **ONLY entries that provably cannot carry an inline
   `# sobelow_skip` annotation**, enumerated by type and count. The floor is a
   property of sobelow 0.14.1's architecture, not of the baseline's size: it is
   **9** today, out of the baseline that
   `grep -c '^[A-Za-z]' api/.sobelow-skips` prints — **35** rows read at
   a333e4b58 on 2026-09-11, a dated snapshot and not a live fact — in two
   mechanical classes.
   Derive both numbers rather than quoting this paragraph; it has already gone
   stale once by being quoted instead of re-derived:

   | Class | Count | Entries | Why no annotation can ever reach it |
   |---|---|---|---|
   | `Sobelow.Config.*` | **7** | 6 `Config.CSRF` + 1 `Config.HTTPS` (`config/prod.exs:0`) | Config findings are produced outside the `def_funs |> combine_skips()` pipeline, so `@sobelow_skip` is never consulted; `config/prod.exs:0` has no function to annotate at all. |
   | `.heex` `XSS.Raw` | **2** | `layouts/bulldocs.html.heex:95`, `layouts/quiz.html.heex:21` | `Parse.get_meta_template_funs/1` bypasses the reader that rewrites `# sobelow_skip` into `@sobelow_skip`, so a template's source never sees the substitution. |

   The `.heex` line numbers are part of each row's fingerprint, so read them off
   `api/.sobelow-skips`, never from memory — this table has carried a wrong one.

   The third `XSS.Raw` entry (`controllers/error_html.ex:25`) is a normal `.ex`
   function and **is** annotatable — it is not part of the floor. Re-evaluate
   the flip when the baseline contains nothing but those 9; do not re-evaluate
   on "reaches 0", which cannot happen.

   **The floor holds only while the findings still exist.** It is a count of
   *unannotatable* findings, not of *unfixable* ones — fixing the underlying
   code removes a row from the floor. Re-derive the floor from
   `api/.sobelow-skips` after any such fix; it is never a constant.

   **Topology: the S4 objection is DEAD as of wave 10 — one blocker remains.**
   This entry used to conclude "no `security.yml` check can be required", on two
   successive arguments that are both now retired. The first rested on "`main`
   has no branch protection" — **false since 2026-07-28**: protection is live
   with `enforce_admins: true` and the tracked file carries `"enforced": true`.
   (Trap worth keeping: `gh api …/rulesets` → `[]` is a TRUE reading that
   produces the WRONG conclusion, because this repo's protection is not a
   ruleset.) The second rested on **S4**, and wave 10 paid it:

   - `security.yml` **no longer carries a workflow-level `paths:` key** on either
     trigger, so it renders a check run on every head. Path decisions moved to
     JOB level behind an always-running `changes` dispatcher — the elixir.yml /
     console-harness.yml shim, transplanted. A job skipped by a job-level `if:`
     still publishes a `skipped` check run, and GitHub counts `skipped` as
     satisfying a required context.
   - The registrable name is **`Security gate`**: unmatrixed, `if: always()`, and
     it ASSERTS over every upstream result rather than echoing them.
   - `sobelow` IS in that aggregator's `needs`, and is judged on
     `needs.sobelow.outputs.verdict`, **never on its `.result`**. The
     measurement behind the older rule stands: a `continue-on-error: true` job
     that exits 1 concludes FAILURE and renders a RED check run while
     `needs.<job>.result` reads `success` — byte-identical to a genuine pass,
     and undecomposable. What was wrong was the conclusion drawn from it, that
     no aggregation was possible: `continue-on-error` launders a job's RESULT
     and does not touch its OUTPUTS, so the `scripts/run-instrument.sh` verdict
     channel the other three jobs already publish on carries Sobelow intact.
     Until 2026-09-17 it did not, and a fresh finding therefore reached no
     rollup at all — one advisory, unaggregated, unrequired check run was the
     whole signal. `scripts/security-gate-shape.test.sh` now enforces a
     predicate rather than a ban: a continue-on-error job in `needs` must
     declare `outputs.verdict` (bound to a step that exists), the aggregator
     must bind that verdict, and it must bind that job's `.result` nowhere.
     An EMPTY verdict on a DISPATCHED job is CANNOT READ and reds. Main's
     standing findings stay neutral via the `main-red-breaker`, so only a
     head-introduced finding travels.
   - **The remaining blocker is not topology, and it is no longer a live red
     either — it is that `mix-audit` reads a LIVE advisory database.** History: [merge-gates-history.md](merge-gates-history.md#the-mix-audit-blocker-retracted). The standing ground is forward-looking: a CVE published
     tomorrow reds `Security gate` on every open PR with no change to this repo,
     a permanently correct red no PR can clear, which is what branch protection
     must never pin. Registering it needs its own wave — a written policy for
     who clears a fleet-wide advisory red, plus a fresh
     `scripts/registration-deadlock-sweep.sh` — not a silent promotion by the
     next regeneration.

   Flipping `continue-on-error: true` → `false` on `sobelow` remains a separate
   decision: it would move the job onto the ordinary `decide` roster and make
   its red fail the job outright, rather than only its verdict travel.

   **Sobelow's greenness therefore is not a branch-protection concern — it is
   still a real one.** A permanently-red regression gate cannot report a
   regression: while it is red for residue, a genuinely new insecure pattern is
   indistinguishable from an old one. That is the reason to drain it, and the
   only honest one.

   History: [merge-gates-history.md](merge-gates-history.md#provenance-d75-is-a-dangling-citation).

10. **`mix-audit` job** — dependency CVE scan (`mix deps.audit`, the `mix_audit`
    dep) over `mix.lock`. **Blocking** (no `continue-on-error`). The 8
    pre-existing CVEs were remediated by a version bump (task-726cab56d9a84551),
    NOT by accepting them: mint 1.7.1→1.9.1 (×4 advisories), postgrex
    0.22.0→0.22.3, phoenix 1.8.5→1.8.9, decimal 2.3.0→3.1.1 (the last needed
    ecto 3.13.5→3.13.6 + ex_json_schema 0.11.2→0.11.5 to relax decimal to
    `~> 3.0`). The 8th — **esaml GHSA-4g2h-vm7x-747c** (XXE, local-file
    disclosure/SSRF) — has **no upstream fix** (every release ≤ 4.6.0 is
    affected), so it is the single `--ignore-advisory-ids GHSA-4g2h-vm7x-747c`
    suppression in the audit step, justified because OTP 27+ neutralises the XXE
    (xmerl disables external entities by default) and both CI (OTP 27.0) and
    prod run OTP 27+. Every OTHER CVE must be fixed by a bump — never ignored.
    Protective proof: `mix deps.audit` exits 1 on the pre-bump lock and on any
    new CVE; drop the esaml id the moment upstream ships a patch. To suppress
    additional accepted advisories, mix_audit also takes `--ignore-file <path>`
    (advisory IDs, one per line).

Both deps are `only: [:dev, :test], runtime: false` in `api/mix.exs` — analysis
tooling that never ships in the release.
