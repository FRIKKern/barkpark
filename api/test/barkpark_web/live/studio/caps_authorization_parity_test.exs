defmodule BarkparkWeb.Studio.CapsAuthorizationParityTest do
  @moduledoc """
  arpss-w10 — THE THREE-ORACLE PARITY TABLE for `BarkparkWeb.Studio.Caps`, and
  the ratchet that converts an ASSERTED equivalence into an ENFORCED one.

  ## Why this file exists

  `Caps` is a deliberate PERFORMANCE fork of the workspace-authorization
  decision: `derive/1` used to ask `Tenancy.Auth.authorize/3` three times per
  principal and now loads ONE membership row and composes the decision itself
  from `Tenancy.Auth`'s lower-level predicates. Its docstring asserted the
  recomposed answer was "byte-identical", citing pds-w43 / PDS-D634. D634
  authorises the PERFORMANCE claim ONLY — three byte-identical `Repo.one`s
  collapsed to one. The DECISION equivalence was never asserted anywhere and
  NOTHING verified it: a phantom warrant on an authorization path, the exact
  shape the tenancy-totality wave caught in this same subsystem.

  This file is the verification. Every cell below drives BOTH decision paths and
  carries a **DECLARED VERDICT**. The engine RE-DERIVES the verdict from the
  observed values and asserts it equals the declared label — so a wrong label is
  a failure, not a comment. Blanket agreement is not merely unwritten here, it is
  UNWRITABLE: the `:admin` column has THREE mutually inconsistent oracle
  pairings, all run-proven (see the DECLARED DIVERGENCES section).

  ## The three oracles

    1. `Tenancy.Auth.authorize/3` — the declared chokepoint for :read/:write.
    2. THE CAPS COMPOSITION AS ACTUALLY REACHED, which is a FORKED PAIR and is
       therefore driven TWICE, separately: `Caps.derive/1`'s map AND
       `Caps.admin?/1`. `Handlers.Shares` and `Handlers.ItemShare` re-check with
       `Caps.admin?/1`, so the documented "defense in depth" is a SECOND CALL TO
       THE SAME FORK — a derive-only fix would leave the deepest path open. The
       `forked_pair` axis asserts the two agree on every row.
    3. `Tenancy.Auth.workspace_admin?/2` — `@canonical
       capability:workspace-admin-authority`, the declared oracle for the
       `:admin` column (charter D22).

  ## DECLARED DIVERGENCES — the three inconsistent pairings, and the ruling

  The Studio `:admin` column tracks WORKSPACE-SCOPED SEAT AUTHORITY, spelled
  `role_permits?(membership_role, ws_id, :admin)`. That is NEITHER canonical
  verbatim, deliberately — both canonicals are wrong in OPPOSITE directions:

    * `authorize/3`'s token arm is `member? AND permits?`, which leaves the
      barkpark-23yi/fsko cell ADMITTING (a global-admin token holding a plain
      `member` row in workspace B is a Studio admin of B). Tracking it would be
      a fix that does not fix. Cell `token/foreign-member+perms[admin]`.
    * `workspace_admin?/2` WAS a literal `~w(owner admin)` NAME list, which
      DENIED a custom role carrying `action: "admin"` whom `authorize/3`
      admits. RULED (team-lead 2026-09-02) and FIXED in
      `arpss-w10-bl-workspace-admin-denies-custom-role-admin`: the predicate now
      also honours a WORKSPACE-SCOPED custom role whose stored permission rows
      carry `admin`, resolved through the same `granted_actions/3`. Cells
      `user/custom-role-admin` and `token/custom-role-admin+perms[admin]` moved
      `:real_divergent` -> `:equivalent`; they are the CONVERGENCE witnesses now,
      and they red if that fix is reverted.
    * And `workspace_admin?/2` ADMITS where the other two deny, on a read-only
      -perms token holding an `admin` ROLE row. Cell `token/admin-role+perms[read]`.

  ## Verdict vocabulary, and the HARD RULE

    * `:equivalent` — the two oracles reach the same outcome.
    * `:benign_divergent` — they differ but cannot change an authorization
      outcome (one DENIES where the other RAISES: both refuse). Every such label
      MUST name a guard, and that guard MUST carry its own assertion IN THIS
      FILE — a cross-file pin defeats the grep that makes the rule enforceable.
      The `GUARD:`-prefixed tests below are those pins, and
      `every BENIGN-DIVERGENT label names a guard that is asserted in THIS file`
      fails if a label ever names one that is not there.
    * `:real_divergent` — one admits, the other refuses.

  HARD RULE, enforced by `assert_hard_rule!/3` and not overridable: **caps
  ADMITS + either canonical REFUSES ⇒ `:real_divergent`, no `:benign_divergent`
  available.** A `:benign_divergent` label on a cell where caps admits is a
  structural defect and this file reds on it.

  ## PR #12616 and the malformed/nil rows (charter D33)

  #12616 ("make Tenancy.Auth fail closed on malformed ids via one membership/2
  seam") has **MERGED — `state: MERGED`, `mergedAt: 2026-08-19T16:30:50Z**
  (`gh pr view 12616 --json state,mergedAt`). It was OPEN when this file was
  written; the `:refuses` predicates below exist precisely so that its merge
  would not red this table, and on the columns written that way it did not.

  MERGE-ORDER NOTE, so the next reader does not re-derive it: this file landed
  in #12695 at 15:17:48Z and #12616 merged at 16:30:50Z, but #12616's BRANCH was
  cut before this file existed, so #12616's own CI never ran it. Both PRs were
  green alone and `main` was red on the pair — a stale-base green. The cell
  re-declarations recorded here are the reconciliation.

  #12616 flips the canonical column from RAISE to DENY at the shared
  `membership/2` seam, via a `Repo.uuid_or_nil/1` normalisation that answers
  `nil` (no row, so nothing to admit) instead of raising. Consequently:

    * the MALFORMED-workspace rows assert a `:refuses` predicate (deny OR raise)
      on every column, which absorbed the narrowing unchanged — they are the
      only cells still declaring a `[:equivalent, :benign_divergent]` PAIR;
    * the NIL-workspace row asserts the caps `:admin` DENY **directly** — the
      arpss-w10 fix removed that column's #12616 sensitivity entirely, because
      the seat rule has no workspace to read and denies before any Repo touch;
    * the cells that named a verdict of `:benign_divergent` on the STRENGTH of
      the canonical raising (`principal/unrecognised-map`,
      `principal/callercontext-in-api-token-assign`, `principal/token-id-nil`,
      `workspace/nil+token[admin]`) now observe DENY on both sides and are
      re-declared `:equivalent`. Every one of those moves TIGHTENS the pin:
      `:equivalent` demands the two oracles reach the SAME outcome, where
      `:benign_divergent` accepted two DIFFERENT refusals. None of them relaxes
      a refusal into an admit, and no cell moved off `:real_divergent`.

  Two cells DID later move off `:real_divergent`, and not from #12616:
  `user/custom-role-admin` and `token/custom-role-admin+perms[admin]` are
  `:equivalent` since
  `arpss-w10-bl-workspace-admin-denies-custom-role-admin` made
  `workspace_admin?/2` honour a workspace-scoped custom role's `admin` action.
  That IS a refusal relaxed into an admit — a deliberate, RULED widening of the
  admin seat to a role the tenant defined, recorded here rather than absorbed
  silently. The two D9 divergences it must not touch stay `:real_divergent`:
  `token/foreign-member+perms[admin]` (global perms, plain `member` row) and
  `token/admin-role+perms[read]`.

  Exception modules, where any are named: `Ecto.Query.CastError` for a
  non-castable BINARY id and `FunctionClauseError` for a nil / non-binary one.
  `Ecto.CastError` NEVER fires on this path and asserting it would be vacuous.

  A `benign_guard` is RETAINED on cells that have moved to `:equivalent`. The
  rule below is one-directional — a `:benign_divergent` label REQUIRES a guard;
  a guard is not forbidden elsewhere — and those guards still pin the CAPS-SIDE
  refusal, which is the load-bearing half and is not supplied by any canonical
  narrowing.

  ## Fixture traps this file is built against (each a proven vacuous-green generator)

    * `Barkpark.Auth.create_token/5` AUTO-CREATES a membership in the token's
      HOME workspace with a PERMS-DERIVED role, so an `["admin"]` token is a
      role-`admin` member there and every oracle agrees. The divergent cells
      therefore use a SECOND, FOREIGN workspace with an explicit row.
    * `Tenancy.Auth.create_membership/4` defaults `principal_type` to
      `"api_token"`. Every USER row here passes `"user"` explicitly; a mis-typed
      row makes the whole user axis vacuously green.
    * `workspace_admin?/2` with a BARE user id is silently FALSE (`membership/2`'s
      raw-binary clause hardcodes `principal_type == "api_token"`). Every row
      passes the STRUCT. Filed as
      `arpss-w10-bl-workspace-admin-bare-user-id-silent-false`.
    * A CUSTOM role is only attachable when a `Tenancy.Role` row exists for the
      workspace (`Auth.valid_role_names/1` widens the changeset's
      `validate_inclusion`). Each custom-role cell states that precondition in
      its own builder, not in prose.

  `async: false` — the cost section attaches node-global telemetry.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TAuth
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @repo_query_event [:barkpark, :repo, :query]
  @ops 200

  # Re-checked 2026-08-19 after the merge. See the @moduledoc's #12616 section.
  @pr_12616_state "MERGED (mergedAt: 2026-08-19T16:30:50Z)"

  # ── THE TABLE ───────────────────────────────────────────────────────────────
  #
  # Columns per row:
  #   authorize        — %{read:, write:, admin:} of :admit | :deny | :refuses
  #   caps             — %{read:, write:, admin:} of :admit | :deny | :refuses
  #   admin_fn         — Caps.admin?/1: :admit | :deny | :refuses
  #   workspace_admin  — Tenancy.Auth.workspace_admin?/2: :admit | :deny | :refuses
  #   verdicts         — %{read:, write:, admin_vs_authorize:, admin_vs_ws_admin:}
  #   benign_guard     — REQUIRED whenever any verdict is :benign_divergent;
  #                      names a `GUARD: …` test in THIS file.
  #
  # `:refuses` is the #12616-stable predicate: satisfied by :deny OR a raise.

  @table [
    # ── USER axis. The user arms are byte-UNCHANGED by arpss-w10: both
    # `account_admin_from/3` and `account_admin?/2` already spelled the seat
    # rule, so these rows are equivalent BY SHARED CODE, not by coincidence.
    %{
      id: "user/absent",
      summary: "a signed-in non-member is denied everywhere",
      build: :user_absent,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: Tenancy.Auth.membership/2 returns nil ⇒ both paths deny"
    },
    %{
      id: "user/member",
      summary: "role `member` reads and writes but is not a tenant admin",
      build: :user_member,
      authorize: %{read: :admit, write: :admit, admin: :deny},
      caps: %{read: :admit, write: :admit, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: both reach Tenancy.Auth.role_permits?/3 on the same row"
    },
    %{
      id: "user/admin",
      summary: "role `admin` is a tenant admin on all three oracles",
      build: :user_admin,
      authorize: %{read: :admit, write: :admit, admin: :admit},
      caps: %{read: :admit, write: :admit, admin: :admit},
      admin_fn: :admit,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: role_permits?/3; `admin` is in workspace_admin?/2's ~w(owner admin)"
    },
    %{
      id: "user/owner",
      summary: "role `owner` is a tenant admin on all three oracles",
      build: :user_owner,
      authorize: %{read: :admit, write: :admit, admin: :admit},
      caps: %{read: :admit, write: :admit, admin: :admit},
      admin_fn: :admit,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: role_permits?/3; `owner` is in workspace_admin?/2's ~w(owner admin)"
    },
    %{
      id: "user/custom-role-admin",
      summary:
        "PAIRING 2 — a custom role carrying action=admin: caps, authorize/3 AND " <>
          "workspace_admin?/2 all ADMIT (converged)",
      build: :user_custom_admin,
      authorize: %{read: :admit, write: :deny, admin: :admit},
      caps: %{read: :admit, write: :deny, admin: :admit},
      admin_fn: :admit,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note:
        "PRECONDITION: a Tenancy.Role `superviewer` + RolePermission rows read/admin exist " <>
          "for this workspace, or create_membership/4 rejects the role. " <>
          "WAS :real_divergent — workspace_admin?/2 hardcoded ~w(owner admin) and could not " <>
          "see a data-driven admin action. CONVERGED by " <>
          "arpss-w10-bl-workspace-admin-denies-custom-role-admin (RULED 2026-09-02): the " <>
          "predicate now ORs the built-in name list with a WORKSPACE-SCOPED custom role's " <>
          "stored admin action, via the same granted_actions/3 the chokepoint uses. Revert " <>
          "that and this cell reds."
    },

    # ── TOKEN axis. This is the arm arpss-w10 moved.
    %{
      id: "token/member+perms[read,write]",
      summary: "an ordinary read/write token member",
      build: :token_member_rw,
      authorize: %{read: :admit, write: :admit, admin: :deny},
      caps: %{read: :admit, write: :admit, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: Tenancy.Auth.permits?/2 over the same loaded row"
    },
    %{
      id: "token/member+perms[]",
      summary: "an empty permissions array denies every action",
      build: :token_member_none,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: permits?/2 — membership alone confers nothing on a token"
    },
    %{
      id: "token/member+perms[public-read]",
      summary: "`public-read` is a READ perm (@read_perms) but not write and not admin",
      build: :token_member_publicread,
      authorize: %{read: :admit, write: :deny, admin: :deny},
      caps: %{read: :admit, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note: "shared code: permits?/2 over @read_perms ~w(read admin public-read)"
    },
    %{
      id: "token/owner-role+perms[admin]",
      summary:
        "THE LEGITIMATE ADMIN TOKEN — global admin perms AND an owner seat here. " <>
          "The positive control for the arpss-w10 fix: it must NOT lock this operator out.",
      build: :token_owner_admin,
      authorize: %{read: :admit, write: :admit, admin: :admit},
      caps: %{read: :admit, write: :admit, admin: :admit},
      admin_fn: :admit,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note:
        "This is the shape a token's OWN home workspace has by construction " <>
          "(create_token/5 mints a perms-derived `admin` role there), so the normal " <>
          "operator keeps the Shares panel."
    },
    %{
      id: "token/foreign-member+perms[admin]",
      summary:
        "PAIRING 1 — THE barkpark-23yi/fsko CELL. A global-admin token holding a plain " <>
          "`member` row in a FOREIGN workspace. Pre-arpss-w10 caps ADMITTED admin here.",
      build: :token_foreign_member_admin,
      authorize: %{read: :admit, write: :admit, admin: :admit},
      caps: %{read: :admit, write: :admit, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :real_divergent,
        admin_vs_ws_admin: :equivalent
      },
      note:
        "THE RULING (charter D22). The declared oracle for :admin is workspace_admin?/2, " <>
          "which caps now matches. authorize/3's disagreement is in the DENY direction and " <>
          "is D9-ratified — its token arm is `member? AND permits?`, which is the very " <>
          "cross-tenant shape barkpark-23yi/fsko fixed elsewhere. NOT a finding against " <>
          "this file; recorded so a future reader cannot mistake it for drift. " <>
          "Before arpss-w10 caps read :admit here on BOTH derive/1 and admin?/1."
    },
    %{
      id: "token/no-membership+perms[admin]",
      summary:
        "a global-admin token with NO membership row at all. Pre-arpss-w10 caps ADMITTED " <>
          "admin on a workspace it had no seat in whatsoever.",
      build: :token_no_row_admin,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :deny,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note:
        "All three oracles now agree. Before arpss-w10 this was a decision-layer " <>
          "REAL-DIVERGENT-ADMIT on both caps answers."
    },
    %{
      id: "token/admin-role+perms[read]",
      summary:
        "PAIRING 3 — a read-only-perms token holding an `admin` ROLE row: " <>
          "workspace_admin?/2 ADMITS while authorize/3 and BOTH caps answers deny",
      build: :token_admin_role_readonly,
      authorize: %{read: :admit, write: :deny, admin: :deny},
      caps: %{read: :admit, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :real_divergent
      },
      note:
        "workspace_admin?/2 reads the ROLE COLUMN ONLY and never consults permissions[]. " <>
          "caps keeps `token_admin?/1` as the FIRST conjunct, so it denies with the token's " <>
          "own perms — the SAFE direction, and it agrees with authorize/3."
    },
    %{
      id: "token/custom-role-admin+perms[admin]",
      summary:
        "PAIRING 2, token side — an admin-perms token holding a CUSTOM role carrying " <>
          "action=admin: caps, authorize/3 AND workspace_admin?/2 all ADMIT (converged)",
      build: :token_custom_admin,
      authorize: %{read: :admit, write: :admit, admin: :admit},
      caps: %{read: :admit, write: :admit, admin: :admit},
      admin_fn: :admit,
      workspace_admin: :admit,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      note:
        "PRECONDITION: a Tenancy.Role `tokadmin` + RolePermission rows read/write/admin " <>
          "exist for this workspace. THIS is why the arpss-w10 fix spelled the seat rule as " <>
          "role_permits?/3 and not as workspace_admin?/2's name list. The name list is no " <>
          "longer the whole rule: converged by " <>
          "arpss-w10-bl-workspace-admin-denies-custom-role-admin. NOTE the admit here is the " <>
          "custom ROLE's admin action, NOT the token's global permissions[] — charter D9 " <>
          "still denies that shape (cell token/foreign-member+perms[admin], untouched)."
    },

    # ── PRINCIPAL-SHAPE axis.
    %{
      id: "principal/unrecognised-map",
      summary: "a bare map in the :api_token assign: both paths deny, neither raises",
      build: :principal_unrecognised,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :refuses,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      benign_guard: "caps.ex loadable_principal?/1 denies an unrecognised principal shape",
      note:
        "caps denies via loadable_principal?/1's catch-all; authorize/3 denies via its own " <>
          "catch-all clause. workspace_admin?/2 USED TO refuse by raising (no clause for a " <>
          "bare map), which made this column deny-vs-raise, i.e. :benign_divergent. #12616 " <>
          "merged and routed it through the `membership/2` seam, which now answers `nil` " <>
          "rather than raising, so workspace_admin?/2 DENIES and the column is :equivalent. " <>
          "That is a TIGHTENING: same refusal on both sides instead of two different " <>
          "refusals. The named guard is retained — it still pins the caps-side denial that " <>
          "keeps this shape off the Repo, independently of how the canonical refuses."
    },
    %{
      id: "principal/callercontext-in-api-token-assign",
      summary:
        "a %CallerContext{} misplaced in the :api_token assign — both paths deny " <>
          "(arpss-w10 also removed a KeyError crash here)",
      build: :principal_caller_context,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :refuses,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      benign_guard: "caps.ex loadable_principal?/1 denies an unrecognised principal shape",
      note:
        "#12616 merged: workspace_admin?/2 no longer RAISES on this shape, it DENIES via the " <>
          "`membership/2` seam, so admin_vs_ws_admin tightened from :benign_divergent " <>
          "(deny-vs-raise) to :equivalent (both deny). The named guard is retained: it pins " <>
          "the caps-side denial, which is what this cell is really about. " <>
          "REACHABILITY: a CallerContext is assigned to :caller_context, never to :api_token " <>
          "(live_scope.ex), and every writer of :api_token routes through " <>
          "Auth.verify_token/1 (live_auth.ex) — both pinned SOURCE-LEVEL below. The RUNTIME " <>
          "mount proof is slice 2 (arpss-w10-caps-mount-reachability-ratchet), a second and " <>
          "independent pin this file does not lean on. " <>
          "BEFORE arpss-w10 caps.derive/1 RAISED KeyError here (token_admin?/1's over-loose " <>
          "`%_{}` head reached Barkpark.Auth.has_permission?/2); routing the token arm " <>
          "through the LOADED ROWS removed the crash and it now fails closed."
    },
    %{
      id: "principal/token-id-nil",
      summary: "an %ApiToken{id: nil} with admin perms: every oracle DENIES (#12616 merged)",
      build: :principal_token_nil_id,
      authorize: %{read: :refuses, write: :refuses, admin: :refuses},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :refuses,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      benign_guard: "caps.ex is_binary(id) guards keep a nil-id token off the Repo",
      note:
        "authorize/3 USED TO raise FunctionClauseError here (membership/2 had no clause for " <>
          "a nil principal id), so all four columns were deny-vs-raise, i.e. " <>
          ":benign_divergent. #12616 MERGED and narrowed that raise to a DENY at the " <>
          "`membership/2` seam, so all four are now :equivalent — a TIGHTENING, since both " <>
          "sides now give the SAME refusal rather than two different ones. The canonical " <>
          "columns stay on the :refuses predicate deliberately: it is satisfied by the deny " <>
          "observed today AND by the historical raise, so it does not re-red if that seam " <>
          "moves again. caps denies WITHOUT touching the Repo either way, never admits. " <>
          "The named guard is retained — it pins that no-Repo-touch denial, which no " <>
          "canonical narrowing can supply."
    },

    # ── WORKSPACE axis.
    %{
      id: "workspace/nil+token[admin]",
      summary:
        "an unresolved workspace: the seat rule has no workspace to read, so caps DENIES " <>
          "admin DIRECTLY (this row is #12616-INSENSITIVE by construction)",
      build: :workspace_nil_token_admin,
      authorize: %{read: :deny, write: :deny, admin: :deny},
      caps: %{read: :deny, write: :deny, admin: :deny},
      admin_fn: :deny,
      workspace_admin: :refuses,
      verdicts: %{
        read: :equivalent,
        write: :equivalent,
        admin_vs_authorize: :equivalent,
        admin_vs_ws_admin: :equivalent
      },
      benign_guard: "caps.ex denies a nil workspace without a Repo touch",
      note:
        "arpss-w10 OVERTURNS the former moduledoc claim that the token arm 'still answers " <>
          "on a socket whose workspace is unresolved' — pre-fix BOTH caps answers read " <>
          ":admit here while authorize/3 denied and workspace_admin?/2 raised. Costs nothing " <>
          "reachable: :scoped_studio always mounts a resolved %Workspace{}, and the flat " <>
          "/studio/* chrome routes never derive caps. Does NOT close " <>
          "task-46e7d44068e7185e (that ruling is about a nil workspace_id COLUMN, not a nil " <>
          "argument position). #12616 MERGED: workspace_admin?/2 now DENIES on a nil " <>
          "workspace instead of raising, so admin_vs_ws_admin tightened from " <>
          ":benign_divergent (deny-vs-raise) to :equivalent (both deny). The caps :admin " <>
          "column itself is unmoved — it was #12616-INSENSITIVE by construction, as the " <>
          "summary says, and the named guard still pins that no-Repo-touch denial."
    },
    %{
      id: "workspace/malformed+token[admin]",
      summary: "a non-castable workspace id: every oracle REFUSES (#12616 narrows raise→deny)",
      build: :workspace_malformed_token_admin,
      authorize: %{read: :refuses, write: :refuses, admin: :refuses},
      caps: %{read: :refuses, write: :refuses, admin: :refuses},
      admin_fn: :refuses,
      workspace_admin: :refuses,
      verdicts: %{
        read: [:equivalent, :benign_divergent],
        write: [:equivalent, :benign_divergent],
        admin_vs_authorize: [:equivalent, :benign_divergent],
        admin_vs_ws_admin: [:equivalent, :benign_divergent]
      },
      benign_guard: "caps.ex and Tenancy.Auth refuse a malformed workspace id at the SAME seam",
      note:
        "Today all four columns raise Ecto.Query.CastError at the SAME seam " <>
          "(Tenancy.Auth.membership/2's Repo.one), so the observed verdict is :equivalent. " <>
          "#12616 narrows every one of them to a DENY; if the two sides flip in the same " <>
          "commit it stays :equivalent, and if they flip apart it becomes deny-vs-raise, " <>
          "i.e. :benign_divergent. THE ONLY CELLS IN THIS TABLE DECLARING A PAIR, and the " <>
          "reason is named: a test that reds when a colleague merges their PR is a defect, " <>
          "not rigour. The pair is closed under refusal — :real_divergent is NOT in it, so " <>
          "an ADMIT appearing here still reds. Ecto.CastError never fires on this path."
    },
    %{
      id: "workspace/malformed+user",
      summary: "the same, on the USER arm",
      build: :workspace_malformed_user,
      authorize: %{read: :refuses, write: :refuses, admin: :refuses},
      caps: %{read: :refuses, write: :refuses, admin: :refuses},
      admin_fn: :refuses,
      workspace_admin: :refuses,
      verdicts: %{
        read: [:equivalent, :benign_divergent],
        write: [:equivalent, :benign_divergent],
        admin_vs_authorize: [:equivalent, :benign_divergent],
        admin_vs_ws_admin: [:equivalent, :benign_divergent]
      },
      benign_guard: "caps.ex and Tenancy.Auth refuse a malformed workspace id at the SAME seam",
      note: "Same seam, same #12616 narrowing, same closed-under-refusal pair."
    }
  ]

  setup do
    {ws, proj} = ensure_default_scope!()
    {:ok, default_ws: ws, default_proj: proj}
  end

  # ── the generated cells ─────────────────────────────────────────────────────

  describe "three-oracle parity table (#{length(@table)} cells)" do
    for spec <- @table do
      @cell spec

      test "CELL #{spec.id} — #{spec.summary}", ctx do
        check_cell(@cell, ctx)
      end
    end
  end

  test "every cell DECLARES both forked caps answers, and no cell declares them apart" do
    # NOTE ON WHAT THIS TEST IS: it checks the DECLARED table, not the running
    # code. The RUNTIME driving of both forks is in `check_cell/2`, which calls
    # `Caps.derive/1` and `Caps.admin?/1` as two separate observations on every
    # cell and asserts each against its own declared column — so "a test that
    # calls one path twice" is not the shape here. This row exists to stop the
    # TABLE from silently losing its `admin_fn` column: derive/1's :admin key
    # and admin?/1 are separate code paths and the shares/item-share handlers
    # call the SECOND one, so a table that declared only the first would leave
    # the deepest path unpinned.
    disagreeing =
      Enum.filter(@table, fn spec -> spec.caps.admin != spec.admin_fn end)

    assert disagreeing == [],
           "cells declaring derive/1.admin ≠ admin?/1: #{inspect(Enum.map(disagreeing, & &1.id))}"

    # And it is not vacuous: every cell declares an admin_fn column at all.
    assert Enum.all?(@table, &Map.has_key?(&1, :admin_fn))
    assert length(@table) >= 19
  end

  test "every BENIGN-DIVERGENT label names a guard that is asserted in THIS file" do
    source = File.read!(__ENV__.file)

    named =
      @table
      |> Enum.filter(fn spec ->
        spec.verdicts
        |> Map.values()
        |> Enum.flat_map(&List.wrap/1)
        |> Enum.any?(&(&1 == :benign_divergent))
      end)
      |> Enum.map(fn spec ->
        assert Map.get(spec, :benign_guard),
               "cell #{spec.id} declares :benign_divergent with no :benign_guard"

        {spec.id, spec.benign_guard}
      end)

    # There ARE benign cells — a vacuously-empty list would make this test a
    # no-op, which is exactly the shape this wave exists to kill.
    refute named == []

    for {cell_id, guard} <- named do
      assert source =~ ~s(test "GUARD: #{guard}"),
             "cell #{cell_id} names guard #{inspect(guard)} but no `GUARD: …` test in this " <>
               "file asserts it"
    end
  end

  test "no cell where caps ADMITS and a canonical REFUSES is labelled BENIGN" do
    # The HARD RULE, checked over the DECLARED table itself (the per-cell engine
    # checks it again over OBSERVED values).
    for spec <- @table do
      if spec.caps.admin == :admit or spec.admin_fn == :admit do
        for {key, canon} <- [
              {:admin_vs_authorize, spec.authorize.admin},
              {:admin_vs_ws_admin, spec.workspace_admin}
            ] do
          if canon != :admit do
            assert List.wrap(spec.verdicts[key]) == [:real_divergent],
                   "cell #{spec.id}: caps ADMITS admin, #{key} canonical does not, " <>
                     "label is #{inspect(spec.verdicts[key])} — HARD RULE says :real_divergent"
          end
        end
      end
    end
  end

  # ── GUARD pins for every BENIGN-DIVERGENT label ─────────────────────────────

  test "GUARD: caps.ex denies a nil workspace without a Repo touch", %{default_proj: proj} do
    {:ok, token} = mint_token(["admin"])
    sock = socket(nil, proj, %{api_token: token})

    # The guard is `load_memberships/2`'s `when is_binary(ws_id)` clause plus
    # `token_admin_seat?/2`'s `is_binary(ws_id)` guard: no rows, no seat, deny —
    # and zero queries, which is what "without a Repo touch" means.
    assert meter("GUARD nil workspace — derive/1", 20, fn -> Caps.derive(sock) end) == 0
    assert meter("GUARD nil workspace — admin?/1", 20, fn -> Caps.admin?(sock) end) == 0
    assert Caps.derive(sock) == %{read: false, write: false, admin: false}
    refute Caps.admin?(sock)

    # And the guard is LOAD-BEARING: the canonical does NOT answer cleanly on the
    # same argument — today it raises FunctionClauseError, and #12616 narrows
    # that to a deny. Either way it never ADMITS, which is the stable claim.
    assert refuses?(fn -> TAuth.workspace_admin?(token, nil) end)
    assert refuses?(fn -> TAuth.authorize(token, nil, :admin) end)
  end

  test "GUARD: caps.ex is_binary(id) guards keep a nil-id token off the Repo", %{
    default_ws: ws,
    default_proj: proj
  } do
    token = %Barkpark.Auth.ApiToken{id: nil, permissions: ["admin"]}
    sock = socket(ws, proj, %{api_token: token})

    assert Caps.derive(sock) == %{read: false, write: false, admin: false}
    refute Caps.admin?(sock)

    # LOAD-BEARING, and this is the M7 mutation's target: without
    # `loadable_principal?/1`'s `is_binary(id)` the nil id reaches
    # `Tenancy.Auth.membership/2`, which today has no clause for it and raises
    # FunctionClauseError. #12616 narrows that to a nil, so the STABLE claim is
    # "never a membership row", not "always this exception".
    assert no_membership?(fn -> TAuth.membership(token, ws.id) end)
    assert refuses?(fn -> TAuth.authorize(token, ws.id, :admin) end)
  end

  # nil or a raise — never a row. #12616-stable.
  defp no_membership?(fun) do
    case observe(fun) do
      nil -> true
      {:raised, _} -> true
      _row -> false
    end
  end

  test "GUARD: caps.ex loadable_principal?/1 denies an unrecognised principal shape", %{
    default_ws: ws,
    default_proj: proj
  } do
    for principal <- [%{foo: :bar}, caller_context()] do
      sock = socket(ws, proj, %{api_token: principal})
      assert Caps.derive(sock) == %{read: false, write: false, admin: false}
      refute Caps.admin?(sock)
    end

    # LOAD-BEARING: without the guard these shapes reach `membership/2`, which
    # has no clause for either. Asserted as "never a row" so the pin survives
    # #12616's narrowing.
    assert no_membership?(fn -> TAuth.membership(%{foo: :bar}, ws.id) end)
    assert no_membership?(fn -> TAuth.membership(caller_context(), ws.id) end)
  end

  test "GUARD: caps.ex and Tenancy.Auth refuse a malformed workspace id at the SAME seam", %{
    default_proj: proj
  } do
    {:ok, token} = mint_token(["admin"])
    bad = "not-a-uuid"
    sock = socket(%{id: bad}, proj, %{api_token: token})

    # The seam is `Tenancy.Auth.membership/2`'s `Repo.one` — the SAME call both
    # sides make. caps holds no malformed-id guard of its own here, and that is
    # the point: it inherits the canonical's refusal rather than forking one.
    # #12616 narrows the raise to a deny at that one seam, for both sides at once.
    assert refuses?(fn -> TAuth.membership(token, bad) end)
    assert refuses?(fn -> TAuth.authorize(token, bad, :read) end)
    assert refuses?(fn -> Caps.derive(sock) end)
    assert refuses?(fn -> Caps.admin?(sock) end)
    assert refuses?(fn -> TAuth.workspace_admin?(token, bad) end)

    # `Ecto.CastError` NEVER fires on this path — asserting it POSITIVELY would
    # be vacuous today AND would red the moment #12616 turns the raise into a
    # deny. So this asserts the NEGATIVE, which is stable both sides of that
    # merge: whatever refuses here, it is not `Ecto.CastError`.
    refute observe(fn -> TAuth.membership(token, bad) end) == {:raised, Ecto.CastError}
    refute observe(fn -> Caps.derive(sock) end) == {:raised, Ecto.CastError}
  end

  # A refusal is a DENY or a RAISE — never an admit. This is the #12616-stable
  # predicate the malformed rows are written against.
  #
  # `nil` IS a refusal, and its clause is LOAD-BEARING rather than defensive:
  # this helper is pointed at `Tenancy.Auth.membership/2`, which answers with a
  # ROW-OR-NIL rather than a decision atom. Before #12616 that call RAISED on a
  # malformed id and the raise clause absorbed it; #12616's `uuid_or_nil/1` seam
  # made it return `nil` instead — no row, so nothing can be admitted. Omitting
  # this clause is what turned the very narrowing this predicate exists to
  # tolerate into a `CaseClauseError`, i.e. the helper crashed on precisely the
  # #12616 outcome it was written to be immune to.
  defp refuses?(fun) do
    case observe(fun) do
      :admit -> false
      :deny -> true
      nil -> true
      {:raised, _} -> true
      %{read: r, write: w, admin: a} -> not (r or w or a)
    end
  end

  # ── SOURCE-LEVEL reachability pins for the CallerContext cell ───────────────
  #
  # The BENIGN label on `principal/callercontext-in-api-token-assign` rests on
  # "a CallerContext never lands in the :api_token assign". These two tests pin
  # that in the SOURCE of the two modules that write the assign. The runtime
  # mount proof is slice 2's job (arpss-w10-caps-mount-reachability-ratchet);
  # this file does not lean on it.

  test "PIN: LiveScope.authorize_read/4's %ApiToken{} branch returns `err` with no fallthrough" do
    source = File.read!("lib/barkpark_web/live_scope.ex")

    assert source =~
             ~r/case socket\.assigns\[:api_token\] do\s*\n\s*%Barkpark\.Auth\.ApiToken\{\}/,
           "authorize_read/4 no longer matches on %ApiToken{} — re-derive the CallerContext cell"

    # A CallerContext rides its OWN assign.
    assert source =~ ":caller_context"
  end

  test "PIN: every writer of the :api_token assign in LiveAuth routes through verify_token/1" do
    source = File.read!("lib/barkpark_web/live_auth.ex")

    writers =
      source
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ ~r/assign\(.*:api_token,/ or &1 =~ ~r/assign\(socket, :api_token/))

    refute writers == []

    # Every non-nil write is of a value produced by Auth.verify_token/1 — either
    # directly bound in a `with` in the same clause, or the `api_token ->` head
    # of a case over such a value. A write of a literal other shape would show
    # up here as a value this assertion cannot account for.
    for line <- writers do
      assert line =~ ~r/:api_token,\s*(nil|api_token)\)/ or line =~ ~r/:api_token, api_token\)/,
             "unaccounted :api_token writer: #{String.trim(line)}"
    end

    assert source =~ "Auth.verify_token(token)"
  end

  # ── COST: PDS-D634's one-load property, preserved and quoted ────────────────
  #
  # The meter is the process-scoped one from pds_w43_caps_derive_cost_test.exs
  # (an UNSCOPED :telemetry.attach/4 is NODE-global and over-counted 800 as 806).
  # That file is the standing ratchet and is byte-untouched by this slice; these
  # rows are the arpss-w10-specific ones it does not carry.

  test "CONTROL n=0: the meter reads ZERO queries when nothing runs", %{
    default_ws: ws,
    default_proj: proj
  } do
    {:ok, token} = mint_token(["admin"])
    sock = socket(ws, proj, %{api_token: token})

    # If this row is non-zero, every other cost row in this file is worthless.
    assert meter("CONTROL n=0 (admin token socket, derive NOT called)", 0, fn ->
             Caps.derive(sock)
           end) == 0
  end

  test "derive/1 on an ADMIN-PERMISSIONED token socket stays at 1.0 q/op — the fix was FREE" do
    ws = workspace!("w10-cost-admin")
    proj = nil
    {:ok, token} = mint_token(["admin"])
    {:ok, _} = TAuth.create_membership(ws.id, token.id, "admin", "api_token")
    sock = socket(ws, proj, %{api_token: token})

    assert Caps.derive(sock) == %{read: true, write: true, admin: true}

    # THE ROW THAT PROVES THE FIX WAS FREE. The seat is read off the row
    # `load_memberships/2` already holds; `Tenancy.Auth.member?/2` would have
    # cost a second Repo.one (measured 1.0 → 2.0 q/op) and is forbidden here.
    queries =
      meter("derive/1 — ADMIN-permissioned TOKEN socket", @ops, fn -> Caps.derive(sock) end)

    assert queries == 1 * @ops
  end

  test "admin?/1 cost is 0.0 read-only / 1.0 built-in-role admin / 2.0 custom-role admin" do
    ws = workspace!("w10-cost-adminfn")

    # (a) read-only token: token_admin?/1 is the FIRST conjunct and
    #     short-circuits, so the seat is never loaded. 0.0 — UNCHANGED by the fix.
    {:ok, ro} = mint_token(["read"])
    {:ok, _} = TAuth.create_membership(ws.id, ro.id, "admin", "api_token")
    ro_sock = socket(ws, nil, %{api_token: ro})
    refute Caps.admin?(ro_sock)

    assert meter("admin?/1 — READ-ONLY token (short-circuits)", @ops, fn ->
             Caps.admin?(ro_sock)
           end) ==
             0

    # (b) admin perms + BUILT-IN role: 0 → 1 (one membership_role/2 Repo.one;
    #     role_permits?/3 resolves a built-in name from the compiled-in map).
    {:ok, builtin} = mint_token(["admin"])
    {:ok, _} = TAuth.create_membership(ws.id, builtin.id, "admin", "api_token")
    builtin_sock = socket(ws, nil, %{api_token: builtin})
    assert Caps.admin?(builtin_sock)

    assert meter("admin?/1 — ADMIN token, BUILT-IN role", @ops, fn ->
             Caps.admin?(builtin_sock)
           end) ==
             1 * @ops

    # (c) admin perms + CUSTOM role: 0 → 2 (membership_role/2, then
    #     role_permits?/3's role_permissions Repo.all for a non-built-in name).
    ws2 = workspace!("w10-cost-adminfn-custom")
    custom_role!(ws2.id, "tokadmin", ["read", "write", "admin"])
    {:ok, custom} = mint_token(["admin"])
    {:ok, _} = TAuth.create_membership(ws2.id, custom.id, "tokadmin", "api_token")
    custom_sock = socket(ws2, nil, %{api_token: custom})
    assert Caps.admin?(custom_sock)

    assert meter("admin?/1 — ADMIN token, CUSTOM role", @ops, fn -> Caps.admin?(custom_sock) end) ==
             2 * @ops
  end

  test "PR #12616's state is re-checked and recorded in the @moduledoc" do
    source = File.read!(__ENV__.file)
    [_head, moduledoc | _rest] = String.split(source, ~s("""))

    assert collapse(moduledoc) =~ "MERGED — `state: MERGED`, `mergedAt: 2026-08-19T16:30:50Z"
    assert @pr_12616_state == "MERGED (mergedAt: 2026-08-19T16:30:50Z)"
  end

  # ── the engine ──────────────────────────────────────────────────────────────

  defp check_cell(spec, ctx) do
    {principal, ws, ws_id} = build(spec.build, ctx)
    sock = socket(ws, ctx[:default_proj], principal_assign(principal))

    # ORACLE 1 — Tenancy.Auth.authorize/3, per action.
    authorize =
      Map.new([:read, :write, :admin], fn action ->
        {action, observe(fn -> TAuth.authorize(principal, ws_id, action) end)}
      end)

    # ORACLE 2 — the caps composition AS REACHED. Both forks, separately.
    derived = observe(fn -> Caps.derive(sock) end)

    caps =
      Map.new([:read, :write, :admin], fn action ->
        {action,
         case derived do
           {:raised, _} = r -> r
           map -> outcome(Map.fetch!(map, action))
         end}
      end)

    admin_fn = observe(fn -> Caps.admin?(sock) end)

    # ORACLE 3 — the declared canonical for the :admin column.
    ws_admin = observe(fn -> TAuth.workspace_admin?(principal, ws_id) end)

    # 1. The declared VALUES hold.
    for action <- [:read, :write, :admin] do
      assert_value!(spec.id, "authorize/3 #{action}", spec.authorize[action], authorize[action])
      assert_value!(spec.id, "Caps.derive/1 #{action}", spec.caps[action], caps[action])
    end

    assert_value!(spec.id, "Caps.admin?/1", spec.admin_fn, admin_fn)
    assert_value!(spec.id, "Tenancy.Auth.workspace_admin?/2", spec.workspace_admin, ws_admin)

    # 2. The FORKED PAIR agrees (or the cell declared otherwise, which no cell
    #    does — see the table-level test).
    assert class(caps.admin) == class(admin_fn),
           "cell #{spec.id}: FORKED PAIR disagrees — derive/1.admin=#{inspect(caps.admin)} " <>
             "vs admin?/1=#{inspect(admin_fn)}. The shares handlers call admin?/1, so a " <>
             "derive-only answer leaves the deepest path open."

    # 3. The DECLARED VERDICT is re-derived from the OBSERVED values and must
    #    match. This is what makes the label enforceable rather than decorative.
    assert_verdict!(spec, :read, caps.read, authorize.read)
    assert_verdict!(spec, :write, caps.write, authorize.write)
    assert_verdict!(spec, :admin_vs_authorize, caps.admin, authorize.admin)
    assert_verdict!(spec, :admin_vs_ws_admin, caps.admin, ws_admin)

    # 4. THE HARD RULE, over OBSERVED values.
    assert_hard_rule!(spec, caps.admin, authorize.admin, :admin_vs_authorize)
    assert_hard_rule!(spec, caps.admin, ws_admin, :admin_vs_ws_admin)
    assert_hard_rule!(spec, admin_fn, authorize.admin, :admin_vs_authorize)
    assert_hard_rule!(spec, admin_fn, ws_admin, :admin_vs_ws_admin)
  end

  # `:refuses` is the #12616-stable predicate: satisfied by a deny OR a raise.
  defp assert_value!(cell, label, :refuses, observed) do
    assert observed == :deny or match?({:raised, _}, observed),
           "cell #{cell}: #{label} declared :refuses (deny OR raise, #12616-stable) " <>
             "but observed #{inspect(observed)}"
  end

  defp assert_value!(cell, label, declared, observed) do
    assert declared == observed,
           "cell #{cell}: #{label} declared #{inspect(declared)} but observed " <>
             "#{inspect(observed)}"
  end

  # A declared verdict is normally ONE atom. The two malformed-workspace rows
  # declare a PAIR — see their notes: #12616 narrows raise→deny at the shared
  # `membership/2` seam, and pinning a single label there would red on a
  # colleague's merge. Every other cell is pinned to exactly one label.
  defp assert_verdict!(spec, key, caps_val, canon_val) do
    computed = verdict(caps_val, canon_val)

    assert computed in declared(spec, key),
           "cell #{spec.id}: #{key} is DECLARED #{inspect(spec.verdicts[key])} but the " <>
             "observed values (caps=#{inspect(caps_val)}, canonical=#{inspect(canon_val)}) " <>
             "derive #{inspect(computed)}"
  end

  defp declared(spec, key), do: List.wrap(spec.verdicts[key])

  defp assert_hard_rule!(spec, caps_val, canon_val, key) do
    if class(caps_val) == :admit and class(canon_val) != :admit do
      assert declared(spec, key) == [:real_divergent],
             "cell #{spec.id}: HARD RULE — caps ADMITS and the #{key} canonical does not " <>
               "(#{inspect(canon_val)}); the only available label is :real_divergent, not " <>
               "#{inspect(spec.verdicts[key])}"
    end
  end

  # EQUIVALENT when the outcome KINDS match exactly (both admit, both deny, or
  # both raise). BENIGN-DIVERGENT when they differ but BOTH refuse — i.e. one
  # DENIES where the other RAISES; a crash and a denial are both refusals, so no
  # authorization outcome can change, but they are NOT the same answer and the
  # label must carry a guard. REAL-DIVERGENT when one admits and the other does
  # not — exactly the HARD RULE's shape.
  defp verdict(caps_val, canon_val) do
    cond do
      class(caps_val) == class(canon_val) -> :equivalent
      admit?(caps_val) or admit?(canon_val) -> :real_divergent
      true -> :benign_divergent
    end
  end

  defp class(:admit), do: :admit
  defp class(:deny), do: :deny
  defp class({:raised, _}), do: :raise

  defp admit?(value), do: class(value) == :admit

  defp observe(fun) do
    outcome(fun.())
  rescue
    e -> {:raised, e.__struct__}
  end

  defp outcome(:ok), do: :admit
  defp outcome({:error, :forbidden}), do: :deny
  defp outcome(true), do: :admit
  defp outcome(false), do: :deny
  defp outcome(other), do: other

  defp principal_assign(%Barkpark.Accounts.User{} = user), do: %{current_user: user}
  defp principal_assign(other), do: %{api_token: other}

  # ── the world ───────────────────────────────────────────────────────────────

  defp build(:user_absent, _ctx) do
    ws = workspace!("w10-user-absent")
    {user!(), ws, ws.id}
  end

  defp build(:user_member, _ctx), do: user_row("w10-user-member", "member")
  defp build(:user_admin, _ctx), do: user_row("w10-user-admin", "admin")
  defp build(:user_owner, _ctx), do: user_row("w10-user-owner", "owner")

  defp build(:user_custom_admin, _ctx) do
    ws = workspace!("w10-user-custom")
    # PRECONDITION, stated as code: the Role must exist or create_membership/4
    # rejects it with `role: {"is invalid", enum: ["owner","admin","member"]}`.
    custom_role!(ws.id, "superviewer", ["read", "admin"])
    user = user!()
    {:ok, m} = TAuth.create_membership(ws.id, user.id, "superviewer", "user")
    assert m.role == "superviewer" and m.principal_type == "user"
    {user, ws, ws.id}
  end

  defp build(:token_member_rw, _ctx), do: token_row("w10-tok-rw", ["read", "write"], "member")
  defp build(:token_member_none, _ctx), do: token_row("w10-tok-none", [], "member")

  defp build(:token_member_publicread, _ctx),
    do: token_row("w10-tok-pubread", ["public-read"], "member")

  defp build(:token_owner_admin, _ctx), do: token_row("w10-tok-owner", ["admin"], "owner")

  defp build(:token_foreign_member_admin, _ctx),
    # THE barkpark-23yi CELL. A SECOND, FOREIGN workspace is mandatory: the
    # token's HOME workspace membership is minted by create_token/5 with a
    # perms-derived `admin` role, where every oracle agrees and the divergence
    # is invisible.
    do: token_row("w10-tok-23yi", ["admin"], "member")

  defp build(:token_no_row_admin, _ctx) do
    ws = workspace!("w10-tok-norow")
    {:ok, token} = mint_token(["admin"])
    assert TAuth.membership(token, ws.id) == nil
    {token, ws, ws.id}
  end

  defp build(:token_admin_role_readonly, _ctx),
    do: token_row("w10-tok-adminrole-ro", ["read"], "admin")

  defp build(:token_custom_admin, _ctx) do
    ws = workspace!("w10-tok-custom")
    custom_role!(ws.id, "tokadmin", ["read", "write", "admin"])
    {:ok, token} = mint_token(["admin"])
    {:ok, m} = TAuth.create_membership(ws.id, token.id, "tokadmin", "api_token")
    assert m.role == "tokadmin"
    {token, ws, ws.id}
  end

  defp build(:principal_unrecognised, ctx), do: {%{foo: :bar}, ctx.default_ws, ctx.default_ws.id}

  defp build(:principal_caller_context, ctx),
    do: {caller_context(), ctx.default_ws, ctx.default_ws.id}

  defp build(:principal_token_nil_id, ctx),
    do:
      {%Barkpark.Auth.ApiToken{id: nil, permissions: ["admin"]}, ctx.default_ws,
       ctx.default_ws.id}

  defp build(:workspace_nil_token_admin, _ctx) do
    {:ok, token} = mint_token(["admin"])
    {token, nil, nil}
  end

  defp build(:workspace_malformed_token_admin, _ctx) do
    {:ok, token} = mint_token(["admin"])
    {token, %{id: "not-a-uuid"}, "not-a-uuid"}
  end

  defp build(:workspace_malformed_user, _ctx),
    do: {user!(), %{id: "not-a-uuid"}, "not-a-uuid"}

  # A user row. `"user"` is passed EXPLICITLY: create_membership/4 defaults
  # principal_type to "api_token", and a mis-typed row makes membership(%User{},
  # ws) nil while workspace_admin?(user.id, ws) reads true off it — vacuously
  # green across the whole user axis.
  defp user_row(slug, role) do
    ws = workspace!(slug)
    user = user!()
    {:ok, m} = TAuth.create_membership(ws.id, user.id, role, "user")
    assert m.role == role and m.principal_type == "user"
    {user, ws, ws.id}
  end

  # A token row in a FOREIGN workspace with an EXPLICIT role. Asserting the role
  # back is the guard against fixture drift silently collapsing a divergent cell.
  defp token_row(slug, perms, role) do
    ws = workspace!(slug)
    {:ok, token} = mint_token(perms)
    {:ok, m} = TAuth.create_membership(ws.id, token.id, role, "api_token")
    assert m.role == role and m.principal_type == "api_token"
    refute ws.id == token.workspace_id
    {token, ws, ws.id}
  end

  defp workspace!(slug) do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        name: slug
      })

    ws
  end

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "w10-parity-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp mint_token(perms),
    do:
      Barkpark.Auth.create_token(
        "w10-parity-token-#{System.unique_integer([:positive])}",
        "w10 parity",
        @dataset,
        perms
      )

  defp custom_role!(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn action ->
      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: action})
        )
    end)

    role
  end

  defp caller_context,
    do: %Barkpark.Content.CallerContext{
      principal_type: :user,
      user_id: Ecto.UUID.generate(),
      grants: []
    }

  # A bare socket carrying exactly the assigns the two caps answers read.
  # Deliberately NOT a mounted LiveView: this is the DECISION layer, one derive
  # per cell. (Spelled as in pds_w43_caps_derive_cost_test.exs, deliberately not
  # extracted — that file is a standing ratchet this slice must not touch.)
  defp socket(ws, proj, assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            current_workspace: ws,
            current_project: proj,
            dataset: @dataset,
            api_token: nil,
            current_user: nil
          },
          assigns
        )
    }
  end

  # ── the meter (process-scoped; see pds_w43_caps_derive_cost_test.exs) ────────

  defp meter(label, n, fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, _metadata, %{owner: owner, counter: counter} ->
          # The handler runs IN the querying process. A node-global attach
          # otherwise counts every other process's queries too (800 read as 806).
          if self() == owner, do: :counters.add(counter, 1, 1)
        end,
        %{owner: owner, counter: counter}
      )

    wall_before = System.monotonic_time(:microsecond)

    try do
      Enum.each(1..n//1, fn _ -> fun.() end)
    after
      :telemetry.detach(handler_id)
    end

    wall_us = System.monotonic_time(:microsecond) - wall_before
    queries = :counters.get(counter, 1)
    per_op = if n > 0, do: Float.round(queries / n, 3), else: 0.0

    IO.puts("""

    ── arpss-w10 Caps cost ────────────────────────────────────────────────────
    #{label}
      ops                : #{n}
      repo queries       : #{queries}   (ASSERTED)
      queries / op       : #{:erlang.float_to_binary(per_op, decimals: 3)}   (ASSERTED)
      wall               : #{Float.round(wall_us / 1000, 2)} ms   (PRINTED ONLY — never asserted)
    """)

    queries
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")
end
