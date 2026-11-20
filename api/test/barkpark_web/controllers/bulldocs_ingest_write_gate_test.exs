defmodule BarkparkWeb.BulldocsIngestWriteGateTest do
  @moduledoc """
  Every action of the Paper ingest controller that writes runs the write-scope
  gate, and finds and stores rows only inside the scope the gate approved.

  The class: the actions are read from the router (every route whose plug is
  `BulldocsIngestController`, on the plugin path and the `/v1/paperflow`
  alias). Each route is sent a token pinned to workspace A that names the
  default workspace. The actions the gate refuses must be exactly the router's
  actions less `scope_free_actions/0`, a count above 0, and the scope-free
  probes store nothing.

  Then, for each writing action (the table below must cover the router's):

    * a pinned token naming another workspace, either way, or another
      workspace's project is refused and changes nothing;
    * a pinned token naming nothing writes in its own workspace;
    * a token with no home workspace, naming nothing, writes in its one seat
      (the default, or A). Seated in the default and A, it writes in the
      default for the actions in `WriteGate.seat_default_actions/0` and is
      refused for the others. Seated in two other workspaces, or none, it is
      refused with the workspaces it may name and the command that pins a
      token. It creates and updates the same way.
    * a token seated only in A never changes the default workspace's row at
      the same slug, and a sync of a copy pulled from there is refused with a
      reason, never answered as an update.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, LabelFixtures, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.{Document, MutationEvent, Papers}
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.Plugins.Bulldocs.Web.WriteGate
  alias BarkparkWeb.BulldocsIngestController

  @ds "production"

  # The writing actions this file covers; a test below holds it equal to the
  # router's writing actions.
  @actions [
    :ingest,
    :create,
    :sync,
    :apply_op,
    :propose,
    :ingest_session,
    :apply_session_op,
    :append_session_event,
    :touch_session_conversation
  ]

  setup do
    ws_a = create_workspace!()
    project_a = create_project!(ws_a, "default")
    home = Tenancy.get_default_workspace()
    ws_other = create_workspace!()

    %{
      other: %{ws: ws_other, project: create_project!(ws_other, "default")},
      a: %{ws: ws_a, project: project_a, token: pinned!(ws_a)},
      home: %{ws: home, project: Tenancy.get_default_project(), token: pinned!(home)}
    }
  end

  # ── tokens ─────────────────────────────────────────────────────────────

  defp raw, do: "write-gate-#{System.unique_integer([:positive])}"

  defp pinned!(ws) do
    raw = raw()
    {:ok, _} = Auth.create_token(raw, "write gate", @ds, ["read", "write", "admin"], ws.id)
    raw
  end

  # A token with no home workspace, seated as a member in `seats`.
  defp homeless!(seats) do
    raw = raw()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "write gate homeless",
        dataset: @ds,
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    for ws <- seats do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    end

    raw
  end

  # ── requests ───────────────────────────────────────────────────────────

  # One rate bucket per request, so the matrix never meets the limiter.
  defp send_as(verb, path, token, body) do
    conn =
      scoped_conn()
      |> Plug.Conn.put_private(:barkpark_rate_limit_scope, raw())
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    if verb == :get, do: get(conn, path, body), else: post(conn, path, body)
  end

  defp error(resp) do
    case Jason.decode(resp.resp_body || "") do
      {:ok, %{"error" => %{} = error}} -> error
      _ -> %{}
    end
  end

  # ── what a write leaves behind ─────────────────────────────────────────

  defp rows(slug, ws_id \\ :any) do
    query =
      from d in Document,
        where: d.doc_id in ^[slug, "drafts." <> slug],
        order_by: [d.doc_id, d.workspace_id],
        select: {d.doc_id, d.workspace_id, d.project_id, d.content, d.updated_at}

    query = if ws_id == :any, do: query, else: from(d in query, where: d.workspace_id == ^ws_id)
    Repo.all(query)
  end

  defp trace(slug) do
    events = from(e in MutationEvent, where: e.doc_id in ^[slug, "drafts." <> slug])
    %{rows: rows(slug), events: Repo.aggregate(events, :count), jobs: jobs()}
  end

  defp jobs, do: Repo.aggregate(Oban.Job, :count)

  defp scopes(slug), do: for({_id, ws, proj, _c, _u} <- rows(slug), uniq: true, do: {ws, proj})

  # ── bodies ─────────────────────────────────────────────────────────────

  defp para(id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => id}]}

  defp blocks(slug, extra) do
    [%{"id" => "h-1", "type" => "heading", "level" => 1, "text" => "Gate " <> slug}, para("p-1")] ++
      extra
  end

  defp paper_body(slug, extra \\ []),
    do: LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => blocks(slug, extra)})

  defp session_body(slug, extra \\ []),
    do: %{"slug" => slug, "title" => "Session " <> slug, "blocks" => blocks(slug, extra)}

  defp published(slug, ws_id) do
    Repo.one(
      from d in Document,
        where: d.doc_id == ^slug and d.type == "paper" and d.workspace_id == ^ws_id
    )
  end

  # The working copy a pull of the Paper in `ws_id` gives, with one block more.
  defp pulled(slug, ws_id) do
    paper = published(slug, ws_id)
    {:ok, rev} = Papers.op_rev(paper)
    blocks = paper.content["blocks"] ++ [para("p-sync")]
    {Bpml.print_paper(Papers.bpml_paper_map(paper, blocks)), to_string(rev)}
  end

  # A fresh copy, as `bp paper new` pushes it: rev 0.
  defp fresh(slug) do
    body = paper_body(slug)
    doc = %Document{doc_id: slug, type: "paper", title: "Gate " <> slug}

    %{
      "bpml" => Bpml.print_paper(Papers.bpml_paper_map(doc, body["blocks"], body)),
      "baseRev" => "0"
    }
  end

  defp op(id), do: %{"op" => "insert-after", "afterId" => "p-1", "block" => para(id)}

  # {path, row it writes to, create body or nil, update body}. The update body
  # gets the slug and the workspace whose row it updates.
  defp write(:ingest),
    do: {"/papers", :paper, &paper_body/1, fn s, _ -> paper_body(s, [para("p-up")]) end}

  defp write(:create), do: {"/papers/:slug/create", :paper, &paper_body/1, nil}

  defp write(:sync) do
    {"/papers/:slug/sync", :paper, &fresh/1,
     fn s, ws ->
       {bpml, rev} = pulled(s, ws)
       %{"bpml" => bpml, "baseRev" => rev}
     end}
  end

  defp write(:apply_op), do: {"/papers/:slug/ops", :paper, nil, fn _, _ -> op("p-op") end}

  defp write(:propose) do
    {"/papers/:slug/proposals", :paper, nil,
     fn s, _ -> %{"ops" => [op("p-prop")], "source" => %{"doc_id" => s, "agent" => "gate"}} end}
  end

  defp write(:ingest_session),
    do: {"/sessions", :session, &session_body/1, fn s, _ -> session_body(s, [para("p-up")]) end}

  defp write(:apply_session_op),
    do: {"/sessions/:slug/ops", :session, nil, fn _, _ -> op("p-sop") end}

  defp write(:append_session_event),
    do:
      {"/sessions/:slug/events", :session, nil, fn _, _ -> %{"kind" => "note", "note" => "g"} end}

  defp write(:touch_session_conversation) do
    {"/sessions/:slug/conversations", :session, nil,
     fn _, _ -> %{"conversation" => "gate-conversation"} end}
  end

  defp route_path(action, slug),
    do: "/v1/plugins/bulldocs" <> String.replace(elem(write(action), 0), ":slug", slug)

  # The row an update writes to, put in `tenant`'s workspace by its own token.
  defp seed!(action, slug, tenant) do
    {kind_path, body} =
      case elem(write(action), 1) do
        :paper -> {"/papers", paper_body(slug)}
        :session -> {"/sessions", session_body(slug)}
      end

    resp = send_as(:post, "/v1/plugins/bulldocs" <> kind_path, tenant.token, body)
    assert resp.status in 200..201, resp.resp_body
    assert scopes(slug) |> Enum.member?({tenant.ws.id, tenant.project.id})
  end

  # Every way an action can write: a create, an update of a seeded row, or both.
  defp modes(action) do
    {_path, _kind, create, update} = write(action)
    for {mode, body} <- [create: create, update: update], body, do: mode
  end

  # Sends `action` in `mode` for a fresh slug; seeds the updated row in `seat`.
  defp attempt(action, mode, token, seat, named \\ %{}) do
    {_path, _kind, create, update} = write(action)
    slug = "write-gate-#{action}-#{mode}-#{System.unique_integer([:positive])}"
    if mode == :update, do: seed!(action, slug, seat)
    body = if mode == :create, do: create.(slug), else: update.(slug, seat.ws.id)
    before = trace(slug)
    {slug, before, send_as(:post, route_path(action, slug), token, Map.merge(body, named))}
  end

  # ── the class, read from the router ────────────────────────────────────

  defp router_routes,
    do: for(%{plug: BulldocsIngestController} = r <- BarkparkWeb.Router.__routes__(), do: r)

  defp writing_actions do
    actions = router_routes() |> Enum.map(& &1.plug_opts) |> Enum.uniq()
    actions -- BulldocsIngestController.scope_free_actions()
  end

  test "the router's ingest actions are refused by the gate unless they store nothing", c do
    routes = router_routes()
    actions = routes |> Enum.map(& &1.plug_opts) |> Enum.uniq()
    free = BulldocsIngestController.scope_free_actions()
    assert free -- actions == [], "scope-free names with no route: #{inspect(free -- actions)}"

    documents = Repo.aggregate(Document, :count)
    named = %{"workspace" => c.home.ws.slug}

    probed =
      for route <- routes do
        slug = "write-gate-probe-#{System.unique_integer([:positive])}"
        resp = send_as(route.verb, String.replace(route.path, ":slug", slug), c.a.token, named)
        {route.plug_opts, route.path, error(resp)["code"] == "workspace_scope_conflict"}
      end

    gated = for {action, _path, true} <- probed, uniq: true, do: action
    ungated = for {action, path, false} <- probed, action not in free, do: {action, path}

    assert ungated == [], "writing routes the gate lets through: #{inspect(ungated)}"

    assert writing_actions() != [] and Enum.sort(gated) == Enum.sort(writing_actions()),
           "#{length(gated)} actions refused; the router names #{length(writing_actions())} " <>
             "writing actions (#{length(actions)} in all, #{length(free)} scope-free)"

    assert Repo.aggregate(Document, :count) == documents, "a probe stored a row"
  end

  test "this file covers exactly the router's writing actions" do
    assert Enum.sort(@actions) == Enum.sort(writing_actions())
    assert WriteGate.seat_default_actions() -- writing_actions() == []
  end

  # ── per writing action ─────────────────────────────────────────────────

  for action <- @actions do
    describe "#{action}" do
      @action action

      test "a pinned token naming another workspace or its project is refused, changing nothing",
           c do
        for mode <- modes(@action),
            {token, named, code} <- [
              {c.a.token, %{"workspace" => c.home.ws.slug}, "workspace_scope_conflict"},
              {c.home.token, %{"workspace" => c.a.ws.slug}, "workspace_scope_conflict"},
              {c.a.token, %{"workspace_id" => c.a.ws.id, "project_id" => c.home.project.id},
               "project_scope_conflict"}
            ] do
          {slug, before, resp} = attempt(@action, mode, token, c.a, named)
          assert {resp.status, error(resp)["code"]} == {422, code}, "#{mode}: #{resp.resp_body}"
          assert trace(slug) == before, "#{mode} #{code} changed a row, event or job"
        end
      end

      test "a pinned token naming nothing writes in its own workspace", c do
        for mode <- modes(@action) do
          {slug, before, resp} = attempt(@action, mode, c.a.token, c.a)
          assert resp.status in 200..201, "#{mode}: #{resp.resp_body}"
          refute trace(slug) == before
          assert scopes(slug) == [{c.a.ws.id, c.a.project.id}], "#{mode}"
        end
      end

      test "a token with no home writes in its one seat: the default, or A", c do
        for mode <- modes(@action), seat <- [c.home, c.a] do
          {slug, before, resp} = attempt(@action, mode, homeless!([seat.ws]), seat)
          assert resp.status in 200..201, "#{mode} #{seat.ws.slug}: #{resp.resp_body}"
          refute trace(slug) == before
          assert scopes(slug) == [{seat.ws.id, seat.project.id}], "#{mode} #{seat.ws.slug}"
        end
      end

      test "a token with no home seated in the default and in A follows the action's rule", c do
        for mode <- modes(@action) do
          {slug, before, resp} = attempt(@action, mode, homeless!([c.a.ws, c.home.ws]), c.home)

          if @action in WriteGate.seat_default_actions() do
            assert resp.status in 200..201, "#{mode}: #{resp.resp_body}"
            assert scopes(slug) == [{c.home.ws.id, c.home.project.id}], "#{mode}"
          else
            assert {resp.status, error(resp)["code"]} == {422, "workspace_scope_required"}
            assert trace(slug) == before
          end
        end
      end

      test "a token with no home seated in two other workspaces, or none, is refused", c do
        for mode <- modes(@action), seats <- [[c.a.ws, c.other.ws], []] do
          {slug, before, resp} = attempt(@action, mode, homeless!(seats), c.a)
          err = error(resp)
          assert {resp.status, err["code"]} == {422, "workspace_scope_required"}, resp.resp_body
          assert Enum.sort(err["details"]["workspaces"]) == Enum.sort(Enum.map(seats, & &1.slug))
          assert trace(slug) == before

          assert err["hint"] =~
                   "bp -s <server> -w <workspace> -p <project> token create <label> " <>
                     "--permissions read,write"
        end
      end

      test "a token seated only in A never changes the default workspace's row", c do
        slug = "write-gate-#{@action}-isolated-#{System.unique_integer([:positive])}"
        seed!(@action, slug, c.home)
        in_default = rows(slug, c.home.ws.id)
        {_path, _kind, create, update} = write(@action)
        body = if update, do: update.(slug, c.home.ws.id), else: create.(slug)

        resp = send_as(:post, route_path(@action, slug), homeless!([c.a.ws]), body)

        assert rows(slug, c.home.ws.id) == in_default, resp.resp_body
        others = scopes(slug) -- [{c.home.ws.id, c.home.project.id}]
        assert others in [[], [{c.a.ws.id, c.a.project.id}]], resp.resp_body
      end

      test "a token seated only in A updates A's row, not the default's at the same slug", c do
        if :update in modes(@action) do
          slug = "write-gate-#{@action}-both-#{System.unique_integer([:positive])}"
          seed!(@action, slug, c.home)
          seed!(@action, slug, c.a)
          {in_default, in_a} = {rows(slug, c.home.ws.id), rows(slug, c.a.ws.id)}
          {_path, _kind, _create, update} = write(@action)

          resp =
            send_as(
              :post,
              route_path(@action, slug),
              homeless!([c.a.ws]),
              update.(slug, c.a.ws.id)
            )

          assert resp.status in 200..201, resp.resp_body
          assert rows(slug, c.home.ws.id) == in_default
          refute rows(slug, c.a.ws.id) == in_a
        end
      end
    end
  end

  test "a sync of a copy pulled from a workspace the token does not write is refused", c do
    slug = "write-gate-stranded-#{System.unique_integer([:positive])}"
    seed!(:sync, slug, c.home)
    {bpml, rev} = pulled(slug, c.home.ws.id)
    assert rev != "0"
    before = trace(slug)

    resp =
      send_as(:post, route_path(:sync, slug), homeless!([c.a.ws]), %{
        "bpml" => bpml,
        "baseRev" => rev
      })

    err = error(resp)
    assert {resp.status, err["code"]} == {409, "paper_not_in_scope"}, resp.resp_body
    assert err["message"] =~ "anchored on rev #{rev}"
    assert err["hint"] =~ "bp paper new"
    assert trace(slug) == before
  end
end
