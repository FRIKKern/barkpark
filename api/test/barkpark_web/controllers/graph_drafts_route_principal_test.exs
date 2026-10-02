defmodule BarkparkWeb.GraphDraftsRoutePrincipalTest do
  @moduledoc """
  THE ROUTE'S PRINCIPAL — the coverage that actually protects the drafts-graph
  dangling pass today (task-9e6bed14ef7ef81a).

  ## What this suite proves, and what it deliberately does not

  `Content.Query.resolvable_doc_ids/4` — the BATCHED doc_id resolver behind
  `GET /v1/graph/:id?drafts=true` — stacks two row clamps:
  `maybe_scope_to_owner/4` (the owner ACL) and `maybe_scope_to_grants/2` (grant
  row-narrowing). Its sibling suite
  `Barkpark.Content.ResolvableDocIdsScopeTest` proves BOTH clamps at the
  FUNCTION layer and reds under their deletion.

  Neither clamp is reachable THROUGH THIS ROUTE, and that is a property of the
  pipelines, not of any fixture. The route at `router.ex` sits in
  `scope "/v1"` / `pipe_through([:api, :require_token])`; neither pipeline
  mounts a plug that assigns `:caller_context` or `:grant_scoped_read`, so
  `CallerContext.from_conn/1` falls through to `from_token/1` and EVERY caller
  arrives as `principal_type: :api_token` — the one principal
  `Content.Scope.scope_to_owner/2` deliberately exempts — with `:grant_scoped`
  absent from the read opts.

  So a fixture-driven "foreign doc is absent from the response" test on this
  route CANNOT red under either clamp's deletion: the clamp is a no-op before
  the fixture is even read. Writing one anyway is the vacuity this suite exists
  to replace. What is testable, and what the invariant actually rests on, is
  the PRINCIPAL ITSELF:

    * ARM 1 (live probe) — a real request through the real router leaves
      `:caller_context` and `:grant_scoped_read` unassigned, and the context
      `ScopeHelpers.scope_opts/1` derives from that conn is `:api_token` with
      no `:grant_scoped` flag.
    * ARM 2 (consequence) — that derived context makes both clamps INERT, with
      a control showing a non-admin `:user` context and a `grant_scoped: true`
      opts list each DO narrow the same query. Without the control the
      equality assertions would pass for any query at all.
    * ARM 3 (pipeline ratchet) — derived from the router SOURCE, not from a
      list: the set of `BarkparkWeb.*` modules that assign `:caller_context` or
      `:grant_scoped_read` is computed by scanning `lib/barkpark_web/**`, and
      the plugs of the pipelines this route pipes through must not intersect
      it. Add `OptionalUserSession`, `RequireUserSession`, `ResolveWorkspace`
      or `AssignGrantScope` to `:api` or `:require_token` and this reds — which
      is the signal that the clamps just became live on this route and the
      function-layer suite's fixtures now need a route-layer twin.

  ## The asymmetry ARM 3 is really guarding (read before "fixing" the red)

  `Content.Edges.resolvable_targets/3` splits its work: TYPED targets go
  through `resolvable_doc_ids/4` (both clamps); UNTYPED targets go through the
  private `untyped_resolvable/3`, which applies `scope_to_dataset` +
  `scope_to_workspace_or_global` and NO owner or grant clamp. Today that
  asymmetry discloses nothing, because the only principal on this chain is
  exempt from both clamps anyway. The moment this suite reds, the two arms stop
  agreeing and the untyped one is the leak.
  """

  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Content.{CallerContext, Document, Scope}
  alias BarkparkWeb.ScopeHelpers

  @read_token "barkpark-test-graph-route-principal-read"
  @dataset "production"

  @router_src "lib/barkpark_web/router.ex"
  @web_glob "lib/barkpark_web/**/*.ex"
  @graph_show_route ~s|get("/graph/:id", TasksController, :graph_show)|

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    # A PLAIN read token: principal_type :api_token, is_admin FALSE. The sharp
    # case — it is exempted by the `:api_token` clause of scope_to_owner/2, not
    # by the admin clause above it.
    {:ok, _} = Auth.create_token(@read_token, "graph-route-principal", @dataset, ["read"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A real request through the real router, returning the CONN so its assigns
  # can be read. A 200 is asserted so the arms below cannot pass on a conn that
  # never reached the controller.
  defp drafts_graph_conn(conn, scope) do
    doc_id = uniq("route-principal")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "route principal root", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset)

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> @read_token)
      |> get("/v1/graph/#{doc_id}?drafts=true")

    assert resp.status == 200,
           "the drafts-graph route did not serve (got #{resp.status}): #{resp.resp_body}"

    resp
  end

  describe "ARM 1 — the principal a request on GET /v1/graph/:id?drafts=true actually carries" do
    test "no session or grant door: :caller_context and :grant_scoped_read are unassigned",
         %{conn: conn, scope: scope} do
      resp = drafts_graph_conn(conn, scope)

      assert resp.assigns[:api_token] != nil,
             "RequireToken did not assign :api_token — the fixture is not exercising the route"

      assert resp.assigns[:caller_context] == nil,
             "a plug on this route now assigns :caller_context — the owner clamp in " <>
               "resolvable_doc_ids/4 may have become reachable; see the moduledoc"

      assert resp.assigns[:grant_scoped_read] == nil,
             "a plug on this route now assigns :grant_scoped_read — the grant clamp in " <>
               "resolvable_doc_ids/4 may have become reachable; see the moduledoc"
    end

    test "the derived read opts are :api_token with no :grant_scoped flag",
         %{conn: conn, scope: scope} do
      resp = drafts_graph_conn(conn, scope)
      opts = ScopeHelpers.scope_opts(resp)

      assert %CallerContext{principal_type: :api_token, is_admin: false} =
               Keyword.fetch!(opts, :caller_context)

      assert Keyword.get(opts, :grant_scoped) == nil
    end
  end

  describe "ARM 2 — that principal makes both resolvable_doc_ids/4 clamps inert" do
    test "scope_to_owner/2 is a no-op for the route's context, and NOT for a :user context",
         %{conn: conn, scope: scope} do
      resp = drafts_graph_conn(conn, scope)
      ctx = resp |> ScopeHelpers.scope_opts() |> Keyword.fetch!(:caller_context)
      q = from(d in Document)

      assert Scope.scope_to_owner(q, ctx) == q,
             "the owner clamp NARROWED for the route's own principal — the clamp is live " <>
               "on this route and needs route-layer fixture coverage"

      # CONTROL: the same call with a non-admin :user context DOES narrow, so
      # the equality above is a statement about the principal, not about the
      # function being inert for everyone.
      user_ctx = CallerContext.from_user(Ecto.UUID.generate())
      refute Scope.scope_to_owner(q, user_ctx) == q
    end

    test "maybe_scope_to_grants/2 is a no-op for the route's opts, and NOT with the flag",
         %{conn: conn, scope: scope} do
      resp = drafts_graph_conn(conn, scope)
      opts = ScopeHelpers.scope_opts(resp)
      q = from(d in Document)

      assert Scope.maybe_scope_to_grants(q, opts) == q,
             "the grant clamp NARROWED for the route's own opts — :grant_scoped is now " <>
               "reaching this route and needs route-layer fixture coverage"

      # CONTROL: the identical opts plus the flag DO narrow.
      refute Scope.maybe_scope_to_grants(q, Keyword.put(opts, :grant_scoped, true)) == q
    end
  end

  describe "ARM 3 — pipeline ratchet, derived from the router source" do
    test "no pipeline on this route mounts a :caller_context / :grant_scoped_read assigner" do
      lines = router_lines()
      forbidden = principal_assigning_modules()

      # Non-vacuity 1: the detector found real assigners to look for.
      assert MapSet.size(forbidden) >= 3,
             "the assigner scan found #{MapSet.size(forbidden)} modules — the regex or the " <>
               "glob has drifted and this test would pass against any router"

      pipelines = graph_show_pipelines(lines)
      assert pipelines != [], "could not read the pipe_through for #{@graph_show_route}"

      plugs = pipelines |> Enum.flat_map(&pipeline_plugs(lines, &1)) |> MapSet.new()

      # Non-vacuity 2: the pipelines really resolved to plugs.
      assert MapSet.size(plugs) >= 5,
             "parsed only #{MapSet.size(plugs)} plugs from #{inspect(pipelines)} — the " <>
               "pipeline parser has drifted"

      offenders = MapSet.intersection(plugs, forbidden)

      assert MapSet.size(offenders) == 0,
             "GET /v1/graph/:id?drafts=true now pipes through " <>
               "#{inspect(MapSet.to_list(offenders))}, which assigns :caller_context or " <>
               ":grant_scoped_read. The owner/grant clamps in resolvable_doc_ids/4 may now " <>
               "be REACHABLE from this route — and Content.Edges.untyped_resolvable/3, its " <>
               "untyped sibling, carries NEITHER clamp. Read this module's doc before " <>
               "relaxing this assertion."
    end

    test "CONTROL: some other pipeline in this router DOES mount one, so the detector can fire" do
      lines = router_lines()
      forbidden = principal_assigning_modules()
      on_route = graph_show_pipelines(lines) |> MapSet.new()

      firing =
        lines
        |> all_pipeline_names()
        |> Enum.reject(&MapSet.member?(on_route, &1))
        |> Enum.filter(fn name ->
          lines
          |> pipeline_plugs(name)
          |> MapSet.new()
          |> MapSet.intersection(forbidden)
          |> MapSet.size()
          |> Kernel.>(0)
        end)

      refute firing == [],
             "NO pipeline in this router mounts a :caller_context / :grant_scoped_read " <>
               "assigner — the intersection in the test above would be empty for any input"
    end
  end

  # ── router-source readers (a predicate over the source, never a hand list) ──

  defp router_lines, do: @router_src |> File.read!() |> String.split("\n")

  defp graph_show_pipelines(lines) do
    case Enum.find_index(lines, &String.contains?(&1, @graph_show_route)) do
      nil ->
        []

      idx ->
        lines
        |> Enum.take(idx)
        |> Enum.reverse()
        |> Enum.find(&String.contains?(&1, "pipe_through"))
        |> case do
          nil -> []
          line -> Regex.scan(~r/:([a-z_0-9]+)/, line) |> Enum.map(fn [_, n] -> n end)
        end
    end
  end

  defp all_pipeline_names(lines) do
    Enum.flat_map(lines, fn l ->
      case Regex.run(~r/^\s*pipeline :([a-z_0-9]+) do\s*$/, l) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end

  defp pipeline_plugs(lines, name) do
    case Enum.find_index(lines, &(String.trim(&1) == "pipeline :#{name} do")) do
      nil ->
        []

      start ->
        lines
        |> Enum.drop(start + 1)
        |> Enum.take_while(&(String.trim(&1) != "end"))
        |> Enum.flat_map(fn l ->
          case Regex.run(~r/^\s*plug\((BarkparkWeb[A-Za-z0-9_.]*)\)/, l) do
            [_, mod] -> [mod]
            _ -> []
          end
        end)
    end
  end

  # Every BarkparkWeb module whose SOURCE assigns :caller_context or
  # :grant_scoped_read. A PREDICATE over the tree, not an enumeration: a new
  # assigner joins the forbidden set the moment it is written.
  defp principal_assigning_modules do
    @web_glob
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      src = File.read!(path)

      if Regex.match?(
           ~r/assign\((?:[a-z_]+,\s*)?:(?:caller_context|grant_scoped_read)\b/,
           src
         ) do
        case Regex.run(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m, src) do
          [_, mod] -> [mod]
          _ -> []
        end
      else
        []
      end
    end)
    |> MapSet.new()
  end
end
