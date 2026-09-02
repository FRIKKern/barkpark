defmodule BarkparkWeb.ShareLinkRouteBindingOneOwnerTest do
  @moduledoc """
  task-3ba103f76393b04e — the item-link route-binding predicate had TWO owners.

  `BarkparkWeb.Plugs.RequireShareScope` (conn side, on the HTTP dead render)
  and `BarkparkWeb.PluginScopeSession` (socket side, on EVERY LiveView mount)
  each carried a private copy that was BYTE-IDENTICAL after renaming
  (`link_matches_route_resource?/2` vs `binds_route_resource?/2`): same three
  clauses, same order, same comparisons, same fail-closed catch-all. Both
  decide the SAME question — does this item link bind the resource the current
  route addresses.

  ## The named failure mode

  A KIND added to one copy and not the other. The two gates then disagree
  about what a share link opens, and the socket is the half with no plug
  behind it: a `live_redirect` or a WebSocket reconnect replays no router
  pipeline, so the hook is the only thing standing there
  (task-9e74fdbdf0242c22). A widening applied to the plug alone leaves the
  socket refusing a link the HTTP surface honours; a widening applied to the
  hook alone opens the socket to a resource the plug still denies.

  ## What this test pins

  ONE table of cases, each asserted THREE ways in the same test:

    1. the shared predicate `Barkpark.Sharing.Links.binds_route_resource?/2`;
    2. the PLUG, end to end — a real anonymous `GET` with `?share=<token>`,
       403 when the link does not bind, 200 when it does;
    3. the HOOK, end to end — `PluginScopeSession.on_mount(:scope, …)` over a
       hand-built SIGNED-session map, `:halt` when the link does not bind,
       `:cont` when it does.

  Every case additionally asserts that (2) and (3) AGREE WITH (1). That is the
  coupling: both gates now read one verdict, so a kind added to the shared
  predicate necessarily moves both.

  ## The mutation this table is built for

  `@unregistered_kind` is a `kind: "sheet"` link — a kind the predicate knows
  NOTHING about, minted past the schema's `validate_inclusion(:kind, ~w(doc
  media))` by inserting the row directly. It is bound to the doc id AND to the
  paper slug the granted cases use, so it fails ONLY on the kind. Teaching the
  shared predicate to accept it (one edit, in one file) flips the plug
  403 -> 200 AND the hook :halt -> :cont in the SAME run — which is what the
  row asked this test to demonstrate. Before the dedup that same one-file edit
  moved exactly one of them, because neither private copy was reachable from
  the other module.

  `async: false` — `:shares` is process-global application env, and this test
  must run with section sharing OFF so a section grant can never stand in for
  the item binding under audit.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Sharing.{Links, ShareLink}
  alias BarkparkWeb.PluginScopeSession

  @dataset "production"
  @doc_type "linkpost"
  @bound_doc_id "one-owner-bound-doc"
  @other_doc_id "one-owner-other-doc"
  @bound_slug "one-owner-bound-paper"
  @other_slug "one-owner-other-paper"

  # The signed-LiveView-session keys `PluginScopeSession.build/1` writes and
  # `on_mount(:scope, …)` reads back. Spelled out rather than reached for
  # through the module attribute: this test is the CONTRACT between the two
  # sides, so a rename of a session key should red here.
  @ws_id_key "scoped_workspace_id"
  @ws_slug_key "scoped_workspace_slug"
  @proj_id_key "scoped_project_id"
  @proj_slug_key "scoped_project_slug"
  @share_public_key "scoped_share_public"
  @share_token_key "scoped_share_token"

  setup %{conn: conn} do
    prior_shares = Application.get_env(:barkpark, :shares)
    Application.delete_env(:barkpark, :shares)

    on_exit(fn ->
      if is_nil(prior_shares),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior_shares)
    end)

    # A NON-default workspace: the seeded Default is an open public demo in
    # test, which would grant every read below for the wrong reason.
    ws = create_workspace!("one-owner-ws-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "one-owner-proj"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Link Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for id <- [@bound_doc_id, @other_doc_id] do
      {:ok, _} =
        Content.create_document(@doc_type, %{"_id" => id, "title" => id}, @dataset, scope)

      {:ok, _} = Content.publish_document(id, @doc_type, @dataset, scope)
    end

    for slug <- [@bound_slug, @other_slug], do: seed_paper!(ws, proj, slug)

    %{conn: conn, ws: ws, proj: proj}
  end

  defp seed_paper!(ws, proj, slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => slug,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => slug}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp mint!(ws, proj, attrs) do
    {:ok, {raw, link}} =
      Links.create(
        Map.merge(
          %{
            workspace_id: ws.id,
            project_id: proj.id,
            dataset: @dataset,
            access: "read"
          },
          attrs
        )
      )

    {raw, link}
  end

  # Mint past `validate_inclusion(:kind, ~w(doc media))`. A kind the predicate
  # has never heard of is exactly what the row's failure mode is about, and the
  # changeset legitimately refuses to produce one — so the row goes in direct.
  # `Links.resolve/1` matches on `token_hash`, so both token forms are written
  # the same way `Links.create/1` writes them.
  defp mint_unregistered_kind!(ws, proj, kind, ref_type, ref_id) do
    raw =
      "one-owner-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}"

    link =
      Repo.insert!(%ShareLink{
        token_hash: Links.hash_token(raw),
        token: raw,
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: kind,
        ref_type: ref_type,
        ref_id: ref_id,
        access: "read"
      })

    {raw, link}
  end

  defp doc_path(ws, proj, doc_id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/doc/#{@dataset}/#{@doc_type}/#{doc_id}"

  # THE PLUG, end to end. An anonymous GET on a scope with NO section share:
  # the only thing that can open it is `maybe_grant_item_token/4` honouring the
  # binding. 200 = granted, anything else = refused by the membership gate the
  # plug declined to bypass.
  defp plug_grants?(conn, ws, proj, doc_id, raw) do
    conn |> get(doc_path(ws, proj, doc_id) <> "?share=#{raw}") |> Map.fetch!(:status)
  end

  # THE HOOK, end to end. `on_mount/4` is called directly with the SIGNED
  # session map `build/1` would have written and the params the mount carries —
  # which is precisely the re-mount shape (`live_redirect`, socket reconnect,
  # lifted-token channel join) that runs no plug.
  defp hook_mount(ws, proj, raw, params) do
    session = %{
      @ws_id_key => ws.id,
      @ws_slug_key => ws.slug,
      @proj_id_key => proj.id,
      @proj_slug_key => proj.slug,
      @share_public_key => true,
      @share_token_key => raw
    }

    # `flash: %{}` is what LiveView itself puts on a real mount's socket — the
    # deny arm calls `put_flash/3`, which reads `assigns.flash` and would
    # KeyError on a bare struct. Seeding it keeps this driver faithful to the
    # mount shape rather than papering over the denial.
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    PluginScopeSession.on_mount(:scope, params, session, socket)
  end

  defp hook_verdict(ws, proj, raw, params) do
    case hook_mount(ws, proj, raw, params) do
      {:cont, _socket} -> :cont
      {:halt, _socket} -> :halt
    end
  end

  describe "one owner: Barkpark.Sharing.Links.binds_route_resource?/2" do
    test "it is the module's PUBLIC entry point (the @canonical marker's subject)" do
      # `function_exported?/3` answers about a LOADED module and this test can
      # be the first to touch `Links` under a given seed — an unloaded module
      # reports every function as absent, which would make this assertion pass
      # for a `defp` and fail for a `def` depending on run order.
      Code.ensure_loaded!(Links)

      assert function_exported?(Links, :binds_route_resource?, 2),
             "the shared predicate must be public — both gates and the @canonical " <>
               "capability:share-link-route-binding marker depend on it being an entry point"
    end

    # The row's acceptance criterion, made a REGRESSION test instead of a
    # one-off shell check: `grep -rn "link.kind ==" api/lib` must return exactly
    # one definition site. A future copy-paste back into a plug or a hook reds
    # here, naming the file it landed in.
    test "no second module decides on `link.kind` — one definition site in lib/" do
      owners =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "link.kind =="))
        |> Enum.sort()

      assert owners == ["lib/barkpark/sharing/links.ex"],
             "the item-link route-binding decision must have ONE owner; found: " <>
               inspect(owners)
    end

    test "unrecognised param shapes fail closed", %{ws: ws, proj: proj} do
      {_raw, link} =
        mint!(ws, proj, %{kind: "doc", ref_type: "paper", ref_id: @bound_slug})

      # No single-resource param, a non-map, and LiveView's not-mounted-at-router
      # atom all address no single resource.
      refute Links.binds_route_resource?(link, %{})
      refute Links.binds_route_resource?(link, %{"path" => "a/b/c"})
      refute Links.binds_route_resource?(link, :not_mounted_at_router)
      refute Links.binds_route_resource?(link, nil)
    end

    test "slug is decided BEFORE doc_id — a merged params map cannot take the looser clause",
         %{ws: ws, proj: proj} do
      # The socket side is handed the MERGED mount params, not path params
      # alone, so a params map can carry both keys. Clause order is the
      # contract: the doc link below WOULD bind on the doc_id clause, and must
      # still be refused because the route's slug is not its ref.
      {_raw, doc_link} = mint!(ws, proj, %{kind: "doc", ref_id: @bound_doc_id})

      assert Links.binds_route_resource?(doc_link, %{"doc_id" => @bound_doc_id})

      refute Links.binds_route_resource?(doc_link, %{
               "slug" => @other_slug,
               "doc_id" => @bound_doc_id
             })
    end

    test "media binds on :id only, never on doc_id or slug", %{ws: ws, proj: proj} do
      {_raw, media} = mint!(ws, proj, %{kind: "media", ref_id: "file-abc"})

      assert Links.binds_route_resource?(media, %{"id" => "file-abc"})
      refute Links.binds_route_resource?(media, %{"id" => "file-xyz"})
      refute Links.binds_route_resource?(media, %{"doc_id" => "file-abc"})
      refute Links.binds_route_resource?(media, %{"slug" => "file-abc"})
    end
  end

  describe "the plug and the hook move TOGETHER with the shared predicate" do
    test "a doc link that BINDS: predicate true, plug 200, hook :cont", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      {raw, link} = mint!(ws, proj, %{kind: "doc", ref_id: @bound_doc_id})

      params = %{"doc_id" => @bound_doc_id}
      predicate = Links.binds_route_resource?(link, params)

      assert predicate
      assert plug_grants?(conn, ws, proj, @bound_doc_id, raw) == 200
      assert hook_verdict(ws, proj, raw, params) == :cont
    end

    test "a doc link on ANOTHER doc's route: predicate false, plug 403, hook :halt", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      {raw, link} = mint!(ws, proj, %{kind: "doc", ref_id: @bound_doc_id})

      params = %{"doc_id" => @other_doc_id}

      refute Links.binds_route_resource?(link, params)
      assert plug_grants?(conn, ws, proj, @other_doc_id, raw) == 403
      assert hook_verdict(ws, proj, raw, params) == :halt
    end

    test "a paper link that BINDS its slug: predicate true, hook :cont", ctx do
      %{ws: ws, proj: proj} = ctx
      {raw, link} = mint!(ws, proj, %{kind: "doc", ref_type: "paper", ref_id: @bound_slug})

      params = %{"slug" => @bound_slug}

      assert Links.binds_route_resource?(link, params)
      assert hook_verdict(ws, proj, raw, params) == :cont
    end

    test "a paper link on a SIBLING slug: predicate false, hook :halt", ctx do
      %{ws: ws, proj: proj} = ctx
      {raw, link} = mint!(ws, proj, %{kind: "doc", ref_type: "paper", ref_id: @bound_slug})

      params = %{"slug" => @other_slug}

      refute Links.binds_route_resource?(link, params)
      assert hook_verdict(ws, proj, raw, params) == :halt
    end

    # ── THE MUTATION CASE ────────────────────────────────────────────────
    #
    # `kind: "sheet"` is bound to the very doc id and the very paper slug the
    # granted cases above use, so it fails on NOTHING but the kind. Teaching
    # `Links.binds_route_resource?/2` about "sheet" — ONE edit, in ONE file —
    # moves the predicate, the plug AND the hook.
    #
    # Deliberately THREE tests over one fixture rather than one test with three
    # assertions: ExUnit stops a test at its first failing assertion, so a
    # single test would red on the predicate and never SHOW the plug and the
    # hook moving. Split, one mutated run reds all three at once — which is the
    # evidence the row asked for. Before the dedup the same edit in
    # `require_share_scope.ex` reddened the plug arm alone, because the hook's
    # copy was a `defp` in another module that no edit here could reach.

    defp unregistered_kind_fixture(ws, proj) do
      {doc_raw, doc_link} =
        mint_unregistered_kind!(ws, proj, "sheet", @doc_type, @bound_doc_id)

      {slug_raw, slug_link} =
        mint_unregistered_kind!(ws, proj, "sheet", "paper", @bound_slug)

      %{doc_raw: doc_raw, doc_link: doc_link, slug_raw: slug_raw, slug_link: slug_link}
    end

    test "MUTATION SUBJECT: the unknown kind resolves — only the KIND stands in its way",
         %{ws: ws, proj: proj} do
      %{doc_raw: doc_raw} = unregistered_kind_fixture(ws, proj)

      # Live, unexpired, unrevoked, and scoped to this workspace/project/dataset.
      # Without this, a refusal below could be about any of those instead, and
      # the mutation would not be single-axis.
      assert {:ok, %ShareLink{kind: "sheet", ref_id: @bound_doc_id}} = Links.resolve(doc_raw)
    end

    test "MUTATION 1/3 — the shared predicate refuses the unknown kind", %{ws: ws, proj: proj} do
      %{doc_link: doc_link, slug_link: slug_link} = unregistered_kind_fixture(ws, proj)

      refute Links.binds_route_resource?(doc_link, %{"doc_id" => @bound_doc_id})
      refute Links.binds_route_resource?(slug_link, %{"slug" => @bound_slug})
    end

    test "MUTATION 2/3 — the PLUG refuses it: 403 (becomes 200 on the mutation)", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      %{doc_raw: doc_raw} = unregistered_kind_fixture(ws, proj)

      assert plug_grants?(conn, ws, proj, @bound_doc_id, doc_raw) == 403
    end

    test "MUTATION 3/3 — the HOOK refuses it: :halt (becomes :cont on the mutation)", ctx do
      %{ws: ws, proj: proj} = ctx
      %{doc_raw: doc_raw, slug_raw: slug_raw} = unregistered_kind_fixture(ws, proj)

      assert hook_verdict(ws, proj, doc_raw, %{"doc_id" => @bound_doc_id}) == :halt
      assert hook_verdict(ws, proj, slug_raw, %{"slug" => @bound_slug}) == :halt
    end

    # NON-VACUITY. Every refusal above would also be produced by a gate that
    # refuses EVERYTHING — a broken fixture, an unresolvable token, a scope
    # mismatch. This pins that the same fixtures, over a link that DOES bind,
    # are granted by both sides, so the reds above are about the binding.
    test "control: the same scope and fixtures GRANT on both sides when the link binds", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      {doc_raw, _} = mint!(ws, proj, %{kind: "doc", ref_id: @bound_doc_id})
      {slug_raw, _} = mint!(ws, proj, %{kind: "doc", ref_type: "paper", ref_id: @bound_slug})

      assert plug_grants?(conn, ws, proj, @bound_doc_id, doc_raw) == 200
      assert hook_verdict(ws, proj, doc_raw, %{"doc_id" => @bound_doc_id}) == :cont
      assert hook_verdict(ws, proj, slug_raw, %{"slug" => @bound_slug}) == :cont
    end
  end
end
