defmodule Barkpark.Content.ResolvableDocIdsScopeTest do
  @moduledoc """
  The two row clamps on `Content.Query.resolvable_doc_ids/4` — the BATCHED
  doc_id resolver behind the drafts-graph dangling pass (task-9e6bed14ef7ef81a).

  ## WHICH LAYER THIS PROVES, AND WHICH IT DOES NOT

  It proves the FUNCTION. `resolvable_doc_ids/4` stacks
  `scope_to_dataset -> scope_to_workspace_or_global -> maybe_scope_to_owner ->
  maybe_scope_to_grants`, and before this suite existed the last two stages had
  ZERO coverage anywhere: deleting either line from the pipeline left every
  drafts-graph fixture green (findings F1/F2 on the row), because those
  fixtures put the foreign document in ANOTHER WORKSPACE and the workspace
  clause dropped it first. Each test here differs from its in-scope twin on
  EXACTLY ONE axis — `owner_id` for the owner arm, grant coverage for the grant
  arm — so it is the named clamp, and nothing above it, that does the work.

  It does NOT prove the ROUTE. `GET /v1/graph/:id?drafts=true` is the only
  caller chain `resolvable_doc_ids/4` has (`Content.Edges.resolvable_targets/3`
  <- `Content.Graph.build_drafts_index/1`, entered only from
  `traverse/2`'s `:drafts` arm), and on that route NEITHER clamp can fire: the
  route pipes through `[:api, :require_token]`, no plug there assigns
  `:caller_context` or `:grant_scoped_read`, so every caller is
  `principal_type: :api_token` — exempted by `Scope.scope_to_owner/2` — with
  `:grant_scoped` absent. A route-level fixture asserting a foreign doc_id's
  absence would therefore pass with the clamp DELETED, which is why this suite
  builds its caller contexts by hand and says so here instead of claiming route
  coverage it does not have.

  That is a statement about the clamps' present reach, not an argument that
  route coverage is unnecessary. `BarkparkWeb.GraphDraftsRoutePrincipalTest`
  holds the other half: it pins the route's principal from the router source,
  so the day a pipeline change puts a `:user`-bearing or grant-scoped caller on
  this route, it reds and the fixtures below need a route-layer twin.

  Two things that twin would have to face, and this suite cannot:

    * `Content.Edges.untyped_resolvable/3` — the UNTYPED arm of the same
      `resolvable_targets/3` split — applies `scope_to_dataset` +
      `scope_to_workspace_or_global` and NEITHER clamp. A wikilink with no
      `refType` therefore discloses existence past the clauses proven below.
    * `Content.Graph.build_drafts_index/1` reads the drafts corpus through
      `Query.corpus_query/3`, a separate pipeline from this one.

  ## MUTATION PROOF

  Delete `|> maybe_scope_to_owner(type, dataset, opts)` from
  `resolvable_doc_ids/4` → the owner arm reds. Delete
  `|> maybe_scope_to_grants(opts)` → the grant arm reds. Restore either → green.
  Both runs are quoted on the PR.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Query}

  @dataset "rdi_scope_test"
  @owned_type "rdi_secret_note"
  @open_type "rdi_post"
  @password "hello world!hello world!"

  setup do
    {ws, project} = ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @owned_type,
          "title" => "RDI Secret Note",
          "owner_scoped" => true,
          "visibility" => "public",
          "fields" => []
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @open_type, "title" => "RDI Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    %{ws: ws, project: project}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PUBLISHED doc in (ws, project, @dataset). `resolvable_doc_ids/4` matches
  # `d.doc_id in ^ids` exactly, so the row must be the published one, not the
  # `drafts.` twin `create_document/4` writes on its own.
  defp published_doc!(ws, project, type, doc_id) do
    {:ok, _} =
      create_document_in!(ws, project, type, %{"_id" => doc_id, "title" => doc_id}, @dataset)

    {:ok, _} = Content.publish_document(doc_id, type, @dataset)
    doc_id
  end

  defp own!(doc_id, user_id) do
    {1, _} =
      Repo.update_all(from(d in Document, where: d.doc_id == ^doc_id), set: [owner_id: user_id])

    doc_id
  end

  defp scope_opts(ws, project, extra),
    do: [workspace_id: ws.id, project_id: project.id] ++ extra

  # ════════════════════════════════════════════════════════════════════════
  # maybe_scope_to_owner — the owner ACL on the batched path
  # ════════════════════════════════════════════════════════════════════════

  describe "maybe_scope_to_owner/4 on resolvable_doc_ids/4" do
    setup %{ws: ws, project: project} do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()

      mine = ws |> published_doc!(project, @owned_type, uniq("rdi-owner-mine")) |> own!(user_a)

      # SAME workspace, SAME project, SAME dataset, SAME type, SAME published
      # state. The ONLY difference from `mine` is owner_id — so nothing above
      # `maybe_scope_to_owner/4` in the pipeline can account for its absence.
      theirs =
        ws |> published_doc!(project, @owned_type, uniq("rdi-owner-theirs")) |> own!(user_b)

      %{user_a: user_a, mine: mine, theirs: theirs}
    end

    test "a non-admin :user never learns of a same-workspace doc under another owner",
         %{ws: ws, project: project, user_a: user_a, mine: mine, theirs: theirs} do
      opts =
        scope_opts(ws, project, caller_context: CallerContext.from_user(user_a))

      resolved = Query.resolvable_doc_ids([mine, theirs], @owned_type, @dataset, opts)

      # Non-vacuity: the fixture IS reachable for this caller, so the refute
      # below is the owner clause and not a broken workspace/dataset scope.
      assert MapSet.member?(resolved, mine)

      refute MapSet.member?(resolved, theirs),
             "resolvable_doc_ids/4 disclosed another owner's doc_id — the " <>
               "maybe_scope_to_owner/4 clamp is gone from the batched pipeline"
    end

    test "CONTROL: the same two docs differ ONLY in owner_id — an api_token sees both",
         %{ws: ws, project: project, mine: mine, theirs: theirs} do
      opts =
        scope_opts(ws, project,
          caller_context: %CallerContext{principal_type: :api_token, token_id: "rdi-tok"}
        )

      resolved = Query.resolvable_doc_ids([mine, theirs], @owned_type, @dataset, opts)

      assert MapSet.member?(resolved, mine)

      assert MapSet.member?(resolved, theirs),
             "the foreign-owner doc is unreachable even for an exempt principal — the " <>
               "fixture differs on more than owner_id and the test above proves nothing"
    end

    test "an anonymous caller sees neither owned doc",
         %{ws: ws, project: project, mine: mine, theirs: theirs} do
      opts = scope_opts(ws, project, caller_context: CallerContext.anonymous())

      resolved = Query.resolvable_doc_ids([mine, theirs], @owned_type, @dataset, opts)

      assert MapSet.size(resolved) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # maybe_scope_to_grants — grant row-narrowing on the batched path
  # ════════════════════════════════════════════════════════════════════════

  describe "maybe_scope_to_grants/2 on resolvable_doc_ids/4" do
    setup %{ws: ws, project: project} do
      covered = published_doc!(ws, project, @open_type, uniq("rdi-grant-covered"))

      # SAME workspace, project, dataset, type and published state as `covered`.
      # The ONLY difference is that the grant's doc_id rung names `covered`.
      uncovered = published_doc!(ws, project, @open_type, uniq("rdi-grant-uncovered"))

      email = "rdi-grantee-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: @password})

      bind_grant!(ws, user, %{
        project_id: project.id,
        dataset: @dataset,
        type: @open_type,
        doc_id: covered,
        capabilities: ["read"]
      })

      ctx = CallerContext.from_user(user.id)

      # Non-vacuous: the grant actually loaded. Without it every grant_scoped
      # read fails closed for the WRONG reason and the refute below is free.
      assert length(ctx.grants) == 1

      %{ctx: ctx, covered: covered, uncovered: uncovered}
    end

    test "a grant_scoped caller never learns of a doc_id outside its grant ladder",
         %{ws: ws, project: project, ctx: ctx, covered: covered, uncovered: uncovered} do
      opts = scope_opts(ws, project, caller_context: ctx, grant_scoped: true)

      resolved = Query.resolvable_doc_ids([covered, uncovered], @open_type, @dataset, opts)

      assert MapSet.member?(resolved, covered)

      refute MapSet.member?(resolved, uncovered),
             "resolvable_doc_ids/4 disclosed a doc_id outside the caller's grant ladder — " <>
               "the maybe_scope_to_grants/2 clamp is gone from the batched pipeline"
    end

    test "CONTROL: the flag is the sole cause — without it the same caller sees both",
         %{ws: ws, project: project, ctx: ctx, covered: covered, uncovered: uncovered} do
      opts = scope_opts(ws, project, caller_context: ctx)

      resolved = Query.resolvable_doc_ids([covered, uncovered], @open_type, @dataset, opts)

      assert MapSet.member?(resolved, covered)

      assert MapSet.member?(resolved, uncovered),
             "the uncovered doc is unreachable even without grant_scoped — the fixture " <>
               "differs on more than grant coverage and the test above proves nothing"
    end

    test "fail-closed: grant_scoped with no caller_context resolves nothing",
         %{ws: ws, project: project, covered: covered, uncovered: uncovered} do
      opts = scope_opts(ws, project, grant_scoped: true)

      assert Query.resolvable_doc_ids([covered, uncovered], @open_type, @dataset, opts)
             |> MapSet.size() == 0
    end
  end
end
