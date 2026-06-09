# M0 CLI Contract — Sign-off

> **Verdict: ON-PLAN WITH CORRECTIONS.**
> **Status: M0 CONTRACT FROZEN — ready for Wave 2 implementation.**

## What sign-off means in THIS project's context

Barkpark is run by a **solo operator plus agent teams** — not a room of five human
leads who each initial a summit page. There is no committee gate to clear. The
equivalent rigor here is a **multi-perspective adversarial review**: the conformance
audit examined the M0 CLI contract across **five independent source perspectives**
and reconciled every divergence against **live code**. That cross-perspective
adversarial pass *is* the M0 summit sign-off for this project.

The five source perspectives reviewed:

1. **handbook** — `~/.artifacts/make_cli_handbook_paper.py` (the published CLI handbook: §2 noun/verb surface, §3 auth tiers, §29 exit codes).
2. **original-plan** — `~/.artifacts/make_cli_plan_paper.py`.
3. **build-plan** — `~/.artifacts/make_cli_buildplan_paper.py`.
4. **supporting-trio** — `make_cli_guide_paper.py`, `make_cli_reference_paper.py`, `make_cli_cheatsheet_paper.py`.
5. **code-reality** — `api/lib/barkpark_web/router.ex` and the controllers/error emitters (`Barkpark.Content.Errors`, tasks/intents/plugin-settings controllers).

Plus **live-code verification** of the router's auth pipelines and the real error
envelope shapes, so no contract claim rests on a paper alone.

## The five findings + resolution

| # | Finding | Resolution |
|---|---|---|
| 1 | `docs/cli/cli-commands-callback.md` reported as missing. | **STALE finding.** The file exists and defines the `cli_commands/0` / `resolve_cli_commands/2` plugin callback and the `cli_command()` return shape (bound to `manifest.schema.json` `commands[]`). No action needed — the audit's "missing file" note was against an earlier tree state. |
| 2 | Exit-code scheme conflated validation and conflict (the table had `5 = conflict`, dropping the handbook's `5 = validation`). | **Resolved as an additive superset.** `docs/cli/error-exit-table.md` now matches the handbook (§29) EXACTLY for `0–5` (0 success · 1 other/network/timeout + unknown/no-code fallback · 2 usage/unknown command · 3 auth · 4 not-found · **5 validation**) and ADDS `6` conflict (rev_mismatch / precondition_failed / conflict / bare-string `halted`), `7` rate-limited (honor `Retry-After`), `8` server (internal_error / 5xx). Every detail-table row was re-mapped accordingly. The "CLI maps `error.code`, never re-derives from HTTP status" rule is retained. **Residual: user-veto noted** — the additive split (6/7/8) is a deliberate superset of the handbook; if the operator prefers the handbook's flatter scheme it can be vetoed, but the default ships as the superset. |
| 3 | Fixtures incomplete — `core-manifest.json` listed a phantom `meta` noun and only a partial core surface, with no existence-hiding golden. | **Resolved.** `core-manifest.json` is now the FULL-ACCESS fresh-install fixture: admin caller, plugins OFF, all **eight** canonical nouns (doc, schema, media, search, workspace, task, webhook, plugin — `task` is plugin-contributed, `source: "plugin:tasks"`; there is no `rail` noun) with representative commands. The `meta` noun was removed; `whoami` is documented as a CLI built-in over `GET /v1/meta` + the manifest's caller `auth_tier`, not a manifest command. Project verbs fold under `workspace`. New `core-manifest-anon.json` is the EXISTENCE-HIDING golden: anonymous (`auth_tier:"none"`) read-only projection — diffing anon vs admin proves admin names don't leak. |
| 4 | Schema had no version-gating affordance. | **Resolved, fully additive.** `manifest.schema.json` gained optional `server.api_version` + `server.min_cli` (name/version/base_url stay required) and optional `command.source` + `command.since` (NOT added to the command `required` list). `additionalProperties:false` is preserved on structural objects; growth axes (noun/verb/id/plugin names, arg/flag types) stay unconstrained. Existing manifests still validate. Both fixtures carry `server.api_version` + `server.min_cli` and `source:"core"` on every command. |
| 5 | No durable sign-off record. | **This document.** Records the verdict, the five-perspective method, and the resolutions, and freezes the contract. |

## Referenced files (real, in-tree)

- `docs/cli/error-exit-table.md` — error-code ↔ exit-code table (finding #2).
- `docs/cli/manifest.schema.json` — the frozen superset manifest schema (finding #4).
- `docs/cli/fixtures/core-manifest.json` — full-access fresh-install fixture, 8 nouns (finding #3).
- `docs/cli/fixtures/core-manifest-anon.json` — anon existence-hiding fixture (finding #3).
- `docs/cli/cli-commands-callback.md` — plugin `cli_commands/0` callback contract (finding #1).
- `docs/cli/m0-decisions.md` — the M0 decisions ledger this sign-off finalizes.

Both fixtures validate against the updated `manifest.schema.json` (jsonschema 4.25.1);
the schema itself is well-formed Draft 2020-12.

---

**M0 CONTRACT FROZEN — ready for Wave 2 implementation.**
