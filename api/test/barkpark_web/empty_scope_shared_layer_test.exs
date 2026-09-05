defmodule BarkparkWeb.EmptyScopeSharedLayerTest do
  @moduledoc """
  An EMPTY scope must mean the SHARED LAYER, never every tenant
  (task-3e2a70930c6df723).

  ## The defect

  `AssignDefaultScope` passes the conn through untouched when nothing is seeded
  at slug "default". `ScopeHelpers.scope_opts/1` then omits `:workspace_id`
  entirely, and `Content.Scope.scope_to_workspace_or_global/3`'s nil arm returns
  the query UNTOUCHED. Every flat read then answers from every tenant's rows.

  ## Why the producer alone could not fix it

  `scope_opts/1` only PRODUCES opts; `Content.Scope` DECIDES. Today an absent
  `:workspace_id` conflates two genuinely different intents:

    1. a request arrived and the routing layer resolved no tenant  -> shared layer only
    2. an internal caller deliberately wants everything            -> keep reading everything

  One value, two meanings, and the permissive one wins for both. The `:shared_only`
  sentinel separates them: only a REQUEST can produce it, so internal callers that
  pass `nil` (Media.list_files/1, preview.ex, the media_test.exs assertions) are
  untouched by construction.

  ## Coverage claim, stated honestly

  Three doors below are proven EMPIRICALLY (fail-first arms). Five more —
  backlinks, related, tag_browse, tag_docs, structure — are covered BY
  CONSTRUCTION: each routes its `scope_opts(conn)` into a helper whose nil arm is
  permissive, so the sentinel reaches them through the same seam. They have no
  black-box arm here, and the PR says so rather than implying otherwise.

  `counts/:ds` is the RESOLVED NEGATIVE: it already uses the fail-closed
  `Scope.scope_to_workspace/3` (`scope.ex:118` -> `where(query, false)`), which is
  why it never leaked. It must STAY not-a-door — that arm is what catches a fix
  that over-reaches.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Scope
  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Tenancy.Workspace
  alias BarkparkWeb.ScopeHelpers

  import Barkpark.TenancyFixtures

  @ds "test"
  @marker "TENANT-A-ONLY-MARKER"
  @shared_marker "SHARED-LAYER-ROW"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    ws_a = create_workspace!("esl-a")
    proj_a = create_project!(ws_a, "esl-a-p")

    {:ok, _} =
      Content.create_document("post", %{"_id" => "esl-a-doc", "title" => @marker}, @ds,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      Content.publish_document("esl-a-doc", "post", @ds,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # A pre-tenancy row: workspace_id IS NULL. The shared layer an unscoped
    # caller SHOULD still see — this is what keeps a legacy install working.
    {:ok, _} =
      Content.create_document("post", %{"_id" => "esl-shared", "title" => @shared_marker}, @ds)

    {:ok, _} = Content.publish_document("esl-shared", "post", @ds)

    # WriteScope stamps an unscoped write with the seeded Default, so the rows
    # above are NOT null-workspace yet. Null them explicitly — the pre-tenancy
    # shape this arm exists to protect is `workspace_id IS NULL`, and a fixture
    # that merely omits the scope produces a Default-owned row instead.
    {_, _} =
      Repo.update_all(
        from(d in Document, where: like(d.doc_id, ^"%esl-shared")),
        set: [workspace_id: nil, project_id: nil]
      )

    raw = "esl-#{System.unique_integer([:positive])}"
    {:ok, unbound} = Auth.create_token(raw, "esl", "test", ["read", "write", "admin"])

    # THE PROBE TOKEN MUST CARRY NO WORKSPACE BINDING, and saying so takes a
    # write: `create_token/4` silently binds to the seeded Default Workspace
    # when one exists (auth.ex — "when `workspace_id` is `nil` the token falls
    # back to the seeded Default Workspace"), and one exists here because the
    # fixtures above ran first.
    #
    # `vacate!/0` below only RENAMES the default workspace's slug. The row, and
    # this token's binding to it, survive — so a bound token still resolves a
    # tenant through `Plugs.DeriveWorkspaceFromToken` and the request is NOT the
    # unresolved one these arms exist to test. Nulling the column is the same
    # move the shared-layer rows above already make, and for the same reason:
    # the shape under test is the PRE-TENANCY one, and a fixture that merely
    # omits the scope gets a Default-owned row (or here, a Default-bound token)
    # instead.
    #
    # Before task-28c3f7f0987d6e85 nothing read a token's workspace on the flat
    # pipeline, so a bound token was indistinguishable from an unbound one and
    # this write was unnecessary. It is necessary now, and its absence is what
    # made these arms go red on that change — the fixture drifted out from under
    # them, the invariant did not move.
    {1, _} =
      Repo.update_all(
        from(t in Barkpark.Auth.ApiToken, where: t.id == ^unbound.id),
        set: [workspace_id: nil]
      )

    # A SECOND token, deliberately bound to workspace A, for the derivation arm
    # below. It is the control that proves the arms above are about resolution
    # and not about tokens in general.
    bound_raw = "esl-bound-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(bound_raw, "esl-bound", "test", ["read"], ws_a.id)

    {:ok, ws_a: ws_a, raw: raw, bound_raw: bound_raw}
  end

  defp vacate! do
    Repo.update_all(from(w in Workspace, where: w.slug == ^"default"),
      set: [slug: "vacated-#{System.unique_integer([:positive])}"]
    )
  end

  defp seat! do
    case Tenancy.get_default_workspace() do
      nil ->
        w = create_workspace!("default")
        _ = create_project!(w, "default")
        w

      w ->
        w
    end
  end

  defp fetch(raw, path) do
    r = get(put_req_header(scoped_conn(), "authorization", "Bearer " <> raw), path)
    {r.status, if(is_binary(r.resp_body), do: r.resp_body, else: inspect(r.resp_body))}
  end

  # ── the behaviour change, tested at the point of change ─────────────────────

  describe "scope_opts/1 — the producer" do
    test "emits the :shared_only sentinel when the routing layer resolved no workspace" do
      opts = ScopeHelpers.scope_opts(%Plug.Conn{assigns: %{}})

      assert Keyword.get(opts, :workspace_id) == :shared_only,
             "an unresolved request must SAY so; omitting the key is what made " <>
               "'no tenant' indistinguishable from 'every tenant'"
    end

    test "a resolved workspace is passed through unchanged", %{ws_a: ws_a} do
      opts = ScopeHelpers.scope_opts(%Plug.Conn{assigns: %{current_workspace: ws_a}})
      assert Keyword.get(opts, :workspace_id) == ws_a.id
    end
  end

  describe "Content.Scope — the interpreter" do
    test ":shared_only means the shared layer in every request-reachable arm" do
      for fun <- [
            :scope_to_workspace,
            :scope_to_workspace_or_global,
            :scope_to_workspace_including_global
          ] do
        q = apply(Scope, fun, [Document, :shared_only, nil])
        ids = q |> Repo.all() |> Enum.map(& &1.doc_id)

        refute "esl-a-doc" in ids,
               "#{fun}/3 leaked a workspace-owned row to a :shared_only caller"

        assert "esl-shared" in ids,
               "#{fun}/3 dropped the shared layer — a legacy install loses its content"
      end
    end

    test "nil is UNTOUCHED — internal global readers keep reading everything" do
      ids =
        Scope.scope_to_workspace_or_global(Document, nil, nil)
        |> Repo.all()
        |> Enum.map(& &1.doc_id)

      assert "esl-a-doc" in ids,
             "nil must stay the explicit-global read; narrowing it breaks " <>
               "Media.list_files/1, preview.ex and media_test.exs"
    end
  end

  # ── the three doors proven empirically ──────────────────────────────────────

  describe "PROVEN DOORS — anonymous read with the Default seat vacant" do
    setup do
      vacate!()
      refute Tenancy.get_default_workspace()
      :ok
    end

    test "query/:ds/:type does not return another tenant's document", %{raw: raw} do
      {_s, b} = fetch(raw, "/v1/data/query/#{@ds}/post")
      refute b =~ @marker, "query/:ds/:type leaked a workspace-owned row"
      assert b =~ @shared_marker, "query/:ds/:type dropped the shared layer"
    end

    test "doc/:ds/:type/:id does not resolve another tenant's document", %{raw: raw} do
      {_s, b} = fetch(raw, "/v1/data/doc/#{@ds}/post/esl-a-doc")
      refute b =~ @marker, "doc/:ds/:type/:id leaked a workspace-owned row"
    end

    # THE DERIVATION PATH IS THE OTHER WAY IN (task-28c3f7f0987d6e85). Since
    # `Plugs.DeriveWorkspaceFromToken` joined the `:api` pipeline, a request can
    # resolve a tenant with NO Default seat and NO path slugs — from the token
    # alone. That is a second route to `scope_opts/1`, and it must land on the
    # token's OWN workspace, never on another tenant's rows and never on the
    # permissive read the sentinel exists to prevent.
    test "a token BOUND to A reads A's own rows, and only those", %{bound_raw: bound_raw} do
      {_s, b} = fetch(bound_raw, "/v1/data/query/#{@ds}/post")

      assert b =~ @marker,
             "a token bound to workspace A must read A's own row — the derivation " <>
               "resolved no tenant, or resolved the wrong one"

      refute b =~ @shared_marker,
             "a token bound to a REAL workspace read the shared layer too; if this " <>
               "flips, decide it deliberately rather than by accident — it widens " <>
               "every tenant-scoped flat read to the pre-tenancy rows"
    end

    # search/:ds is absent from THIS file, and the reason above it used to give
    # was WRONG. It read `maybe_put_opt/3` at :55 — which belongs to
    # `search_local/2`, the loopback-gated fast path behind `RequireLoopback` —
    # and attributed it to `search/2`. The public `search/2` never reads
    # `params["workspace_id"]` at all; it has always built its tenancy the shared
    # way, `] ++ scope_opts(conn)`. So search WAS this class, the census that
    # disagreed with that reading was the correct instrument, and the sentinel
    # DID reach it — it was fixed here, silently and untested, by this very PR.
    #
    # The missing test now exists: `controllers/search_scope_shared_layer_test.exs`
    # holds the seat-vacant arm (plus an instrument self-test and the separate
    # caller-supplied-`?workspace_id=` arm). Reverting `put_workspace_scope/3`'s
    # `:sentinel` clause reds 2 of its 3 tests. Kept THERE rather than moved
    # here so the search read path is covered next to the controller it guards.
  end

  # ── the resolved negative: must STAY not-a-door ─────────────────────────────

  describe "RESOLVED NEGATIVE — counts was never a door and must not become one" do
    test "counts/:ds still refuses another tenant's rows, seat vacant or not", %{raw: raw} do
      vacate!()
      {s1, b1} = fetch(raw, "/v1/data/counts/#{@ds}")
      seat!()
      {s2, b2} = fetch(raw, "/v1/data/counts/#{@ds}")

      assert s1 == 200 and s2 == 200
      refute b1 =~ @marker
      refute b2 =~ @marker
    end
  end

  # ── the write path must not be handed an atom ───────────────────────────────

  describe "write path" do
    # SUPERSEDED, deliberately (task-6fa023cdabdc5f6a, ruled on main 2026-09-05).
    #
    # This arm used to assert that an unscoped WRITE still succeeded — it only
    # pinned that the `:shared_only` atom was not stamped into `workspace_id`
    # (which would be an Ecto cast error, a 500). PR #12899 left writes alone on
    # purpose: it was a read-path row. The ruling answers the write question —
    # INFER-WHEN-UNAMBIGUOUS, REFUSE-WHEN-AMBIGUOUS, never log-only — so the
    # write no longer lands in the seeded Default.
    #
    # The ORIGINAL property is not dropped, it is strengthened: the sentinel
    # still never reaches the stamp, and now it cannot reach a ROW either. The
    # refusal is the TYPED atom, which is exactly the evidence the old assertion
    # was reaching for — a cast crash would surface as an `Ecto.ChangeError`,
    # not as `{:error, :workspace_scope_required}`.
    test "an unscoped write by an UNATTRIBUTABLE caller is refused, never stamped" do
      vacate!()
      opts = ScopeHelpers.scope_opts(%Plug.Conn{assigns: %{}})

      assert Keyword.get(opts, :workspace_id) == :shared_only,
             "the fixture is not exercising the sentinel — this arm would be vacuous"

      # Bound first, asserted on a BOOLEAN: `assert pattern = expr, "msg"` raises
      # MatchError before assert/2 ever sees the message
      # (scripts/unreachable-assert-message-check.sh).
      result = Content.create_document("post", %{"_id" => "esl-write", "title" => "W"}, @ds, opts)

      assert result == {:error, :workspace_scope_required},
             "an unscoped write from a principal that names no workspace must be a " <>
               "NAMED refusal, never a silent write into the seeded Default — got " <>
               inspect(result)

      refute Repo.get_by(Document, doc_id: "drafts.esl-write") ||
               Repo.get_by(Document, doc_id: "esl-write"),
             "a REFUSED write must leave no row at all"
    end

    test "an unscoped write by a caller that can mean ONE workspace lands THERE" do
      vacate!()
      ws_a = Repo.get_by(Workspace, slug: "esl-a")

      {:ok, token} =
        %Barkpark.Auth.ApiToken{}
        |> Barkpark.Auth.ApiToken.changeset(%{
          token_hash:
            Barkpark.Auth.ApiToken.hash_token("esl-infer-#{System.unique_integer([:positive])}"),
          label: "esl-infer",
          dataset: @ds,
          permissions: ["read", "write"],
          workspace_id: nil
        })
        |> Repo.insert()

      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_a.id, token.id, "member", "api_token")

      opts =
        ScopeHelpers.scope_opts(%Plug.Conn{
          assigns: %{api_token: %{id: token.id, permissions: ["read", "write"]}}
        })

      assert {:ok, doc} =
               Content.create_document("post", %{"_id" => "esl-infer", "title" => "I"}, @ds, opts)

      row = Repo.get_by(Document, doc_id: doc.doc_id)

      assert row.workspace_id == ws_a.id,
             "the ONE workspace the token can mean must be inferred — not the Default seat"
    end
  end

  # ── instrument self-test: keep the census honest ────────────────────────────

  describe "INSTRUMENT SELF-TEST" do
    test "the fixtures are visible to the surfaces that assert on them", %{raw: raw} do
      # With workspace A IN the default seat, every door arm above must be able
      # to SEE A's row. If it cannot, those arms are absence-shaped and prove
      # nothing — this is the check that stops this suite rotting into a green
      # that means nothing.
      #
      # This reaches A through `AssignDefaultScope` (A now HOLDS the "default"
      # slug), which is only possible because the probe token carries no
      # workspace binding — see the setup. A bound token would resolve its own
      # workspace first and this arm would go blind, which is exactly how it
      # reddened on task-28c3f7f0987d6e85 before the fixture was repaired.
      vacate!()
      ws_a = Repo.get_by(Workspace, slug: "esl-a")

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^ws_a.id), set: [slug: "default"])

      {_s, b} = fetch(raw, "/v1/data/query/#{@ds}/post")

      assert b =~ @marker,
             "INSTRUMENT BLIND: the door arms cannot see A's row even when A IS the " <>
               "default seat, so their refutations are about the fixture, not the code"
    end
  end
end
