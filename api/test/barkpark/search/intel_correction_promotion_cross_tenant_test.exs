defmodule Barkpark.Search.IntelCorrectionPromotionCrossTenantTest do
  @moduledoc """
  Fail-before protective test for the LAST unscoped read in
  `Barkpark.Search.Intelligence` — the auto-promotion gate.

  ## The leak

  `Intelligence` fences EVERY `search_intel_events` read through `scope_ws/2`
  (crystals, merge patterns, `insights.topQueries`, `suggestions.{recent,
  popular,nohits}`) — the module's own ruling on that helper is explicit:

  > intel roll-ups have no shared layer, so a tenant must never see
  > NULL-workspace rows folded into its own counts.

  `count_distinct_correction_sessions/4` was the one read that never got it. It
  counted `COUNT(DISTINCT session_key)` over `(surface, scope, query_normalized,
  object_id)` alone — four values that are ALL caller-supplied and identical
  across tenants (`"production"` is the universally-seeded scope slug). Its
  caller, `do_record_correction/4`, already holds `workspace_id` and hands it to
  `synonym_exists?/5` and `promote_correction/5` on the very next lines.

  Two consequences, and the second is a WRITE:

    1. The count is echoed verbatim to the caller as `distinct_sessions`
       (`POST /v1/data/search/:dataset/correction` renders it as
       `distinctSessions`), so an ANONYMOUS caller reads another tenant's
       correction volume.
    2. `distinct >= 2` IS the auto-promotion gate. Another workspace's
       corrections therefore satisfy THIS workspace's threshold, writing an
       `alt_correction` synonym into a tenant's live search config off a single
       local signal.

  ## The colliding fixture

  Both workspaces record the SAME `(surface, scope, from, to)` correction —
  `("documents", "production", "helo", "hello")`. Nothing but `workspace_id`
  separates the two tenants' rows, so a broken fence cannot return the same
  numbers as a correct one:

    * workspace B: 2 distinct sessions -> B legitimately promotes (asserted, so
      the machinery under test is proven to RUN before anything is claimed about
      workspace A).
    * workspace A: 1 session, and that is A's ENTIRE history.

  ## RED before / GREEN after

    * RED (no `scope_ws`): A's count is 3 (its own + B's two), so
      `distinct_sessions == 3` and `promoted == true` — a synonym A never earned
      lands in A's config.
    * GREEN (`|> scope_ws(workspace_id)`): A's count is 1,
      `promoted == false`, and A's synonym list stays empty.

  ## Seed discipline

  Both workspaces get DISTINCT NON-NIL ids (`create_workspace!/0`), never
  nil/Default — `scope_ws(nil)` maps to the `:shared_only` sentinel
  (`workspace_id IS NULL`), so a nil-contrast seed would green on the UNFIXED
  tree. The per-workspace synonym uniqueness index
  (`search_synonyms_workspace_unique_idx`, partial on `workspace_id IS NOT
  NULL`) means B's row cannot block A's promote — the `refute promoted` below
  fails for the fence, never for a constraint.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Search.{Intelligence, Synonyms}

  @surface "documents"
  # The universally-seeded slug — isolation MUST come from workspace_id, not the
  # dataset leaf (both tenants resolve the same scope string).
  @scope "production"
  @from "helo"
  @to "hello"

  defp correct(ws_id, session_key) do
    Intelligence.record_correction(
      @surface,
      @scope,
      %{"from" => @from, "to" => @to},
      workspace_id: ws_id,
      session_key: session_key,
      actor_key: "client:web",
      source: "web"
    )
  end

  defp synonyms_for(ws_id) do
    @surface
    |> Synonyms.list(@scope, ws_id)
    |> Enum.filter(&(&1.from == @from and &1.to == @to))
  end

  test "workspace-B corrections do NOT count toward workspace-A's promotion gate" do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # ── workspace B: two DISTINCT sessions, the same correction ──────────────
    {:ok, b1} = correct(ws_b.id, "b-session-1")
    assert b1.status == :recorded, "workspace B's first correction was not recorded"
    assert b1.distinct_sessions == 1
    refute b1.promoted, "one session must not reach the 2-session threshold"

    {:ok, b2} = correct(ws_b.id, "b-session-2")
    assert b2.status == :recorded, "workspace B's second correction was not recorded"

    # SUBJECT EXISTS: the promotion machinery genuinely RAN and wrote a row for
    # B. Without this, every assertion about A below could pass on a build where
    # promotion is disabled outright.
    assert b2.distinct_sessions == 2
    assert b2.promoted, "workspace B earned its own promotion (2 distinct sessions)"
    assert [_] = synonyms_for(ws_b.id)

    # ── workspace A: ONE session, the SAME (surface, scope, from, to) ────────
    {:ok, a1} = correct(ws_a.id, "a-session-1")
    assert a1.status == :recorded, "workspace A's correction was not recorded"

    # The echoed counter: A's own history is ONE session. Unfenced this is 3
    # (A's one + B's two) and leaks B's correction volume to A over an
    # anonymous-reachable endpoint.
    assert a1.distinct_sessions == 1,
           "workspace A's correction count folded in another tenant's sessions"

    # The write consequence: A never reached the threshold on its own signal.
    refute a1.promoted,
           "workspace B's corrections promoted a synonym into workspace A's config"

    assert synonyms_for(ws_a.id) == [],
           "a synonym workspace A never earned was written into its search config"
  end
end
