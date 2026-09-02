defmodule BarkparkWeb.Studio.DeskSchemaListGrantNarrowingTest do
  @moduledoc """
  The Studio desk's SCHEMA LIST must honour the caller's grant ladder
  (task-8f8a3a2e05146984) — the sibling of the census fix in PR #14079
  (task-c6d2e34c64100678).

  `Structure.build/2` builds `schema_map` from `Content.list_schemas/2` and then
  draws EVERY tier from it: the curated MAIN groups, the generic "Content"
  catch-all, and the Plugins tier. Its opts whitelist was
  `[include_global: true] ++ Keyword.take(opts, [:workspace_id])` — the exact
  shape `census_opts/1` carried before #14079, dropping `:grant_scoped` and
  `:caller_context`. Absence WIDENS: `maybe_scope_schemas_to_grants/2` gates on
  `Keyword.get(opts, :grant_scoped, false)`, so a dropped flag read as "do not
  narrow".

  #14079 narrowed only the …Rest tier, which is census-driven. A type CLAIMED by
  a placed node never appears in …Rest at all, so the census fix cannot reach it:
  a grant-admitted non-member still read back the NAME of every content type
  curated into a placed group. Type-name existence is disclosure — the ruling
  (lead-security-r, 2026-09-02) is that the desk schema list IS grant-narrowed,
  consistent with #14079 (census) and #14445 (analytics aggregates).

  The FIXTURE ISOLATES THE SCHEMA LIST: both types carry a registered schema, so
  both are claimed by the generic "content-types" MAIN group and NEITHER reaches
  the …Rest census. Anything this test catches is the schema read, not the
  already-fixed census.

  The MEMBER arm is the over-reach guard: a member carries no `:grant_scoped`
  flag, so its whole desk must stay byte-identical — asserted as full
  `%Structure.Node{}` struct equality against an unnarrowed control, not as a
  sampled `html =~`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Structure
  alias Barkpark.Tenancy
  alias BarkparkWeb.ScopeHelpers

  @dataset "production"

  # The type the grant COVERS, and the type it does NOT. Deliberately
  # distinctive strings: an `html =~` on "note" would collide with unrelated
  # desk chrome, whereas nothing else in a rendered desk spells these.
  @in_grant_type "grantedMemo"
  @out_of_grant_type "ledgerSecret"

  setup %{conn: conn} do
    ws = create_workspace!("desk-schemas-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "desk-schemas-proj-#{System.unique_integer([:positive])}")

    scope = [workspace_id: ws.id, project_id: proj.id]

    # BOTH types get a registered schema, so BOTH are claimed by the generic
    # "content-types" MAIN group — placed, and therefore invisible to the …Rest
    # census. The only read that can name `@out_of_grant_type` on this desk is
    # `Content.list_schemas/2`.
    {:ok, _} = upsert!(@in_grant_type, "Granted Memo", scope)
    {:ok, _} = upsert!(@out_of_grant_type, "Ledger Secret", scope)

    {:ok, _} = create_document_in!(ws, proj, @in_grant_type, %{"title" => "in"}, @dataset)
    {:ok, _} = create_document_in!(ws, proj, @out_of_grant_type, %{"title" => "out"}, @dataset)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp upsert!(name, title, scope),
    do: Content.upsert_schema(%{"name" => name, "title" => title}, @dataset, scope)

  defp desk_url(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/content-types"

  defp grantee_session(conn) do
    email = "desk-schemas-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp member_session(conn, ws) do
    raw = "desk-schemas-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "desk-schemas-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  # EVERY type name the desk names, at ANY depth of ANY tier — the disclosure
  # surface this row is about. `collect_claimed_types/2` is private, so this
  # walks the built tree the same way.
  defp all_type_names(opts) do
    @dataset
    |> Structure.build(opts)
    |> walk_type_names()
    |> MapSet.new()
  end

  defp walk_type_names(%Structure.Node{type_name: tn, items: items}) do
    names = if is_binary(tn) and tn != "", do: [tn], else: []
    names ++ Enum.flat_map(items || [], &walk_type_names/1)
  end

  defp socket_opts(view), do: ScopeHelpers.scope_opts(:sys.get_state(view.pid).socket)

  describe "GRANTEE — the desk schema list is narrowed to the grant's type rung" do
    setup %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = grantee_session(conn)

      grant =
        bind_grant!(ws, user, %{
          project_id: proj.id,
          dataset: @dataset,
          type: @in_grant_type,
          capabilities: ["read"]
        })

      {:ok, conn: conn, user: user, grant: grant}
    end

    test "the rendered desk does NOT name the out-of-grant placed type",
         %{conn: conn, ws: ws, proj: proj} do
      {:ok, _view, html} = live(conn, desk_url(ws, proj))

      # Sanity: the grantee really is looking at a populated desk and the type
      # the grant DOES cover is present. Without this the refute below could
      # pass on an empty or errored page.
      assert html =~ @in_grant_type,
             "the grant's OWN type must still render — the clamp must not blank the desk"

      refute html =~ @out_of_grant_type,
             "LEAK: the desk named a content type outside the caller's grant"
    end

    test "the socket's own scope opts produce a grant-narrowed schema list",
         %{conn: conn, ws: ws, proj: proj} do
      # Read through the REAL socket seam (not a hand-built keyword list), so
      # the test cannot pass by construction: this is the exact opts list
      # `PaneBuilder` hands `Structure.build/2` on every desk render.
      {:ok, view, _html} = live(conn, desk_url(ws, proj))
      opts = socket_opts(view)

      assert Keyword.get(opts, :grant_scoped) == true,
             "precondition: the grantee socket must carry the Layer-2 flag"

      assert Keyword.get(opts, :caller_context),
             "precondition: the narrowing fails CLOSED without a caller_context"

      names = all_type_names(opts)

      assert MapSet.member?(names, @in_grant_type)
      refute MapSet.member?(names, @out_of_grant_type)
    end

    test "the out-of-grant type is absent from the raw schema catalog read too",
         %{conn: conn, ws: ws, proj: proj} do
      # The tier-agnostic statement of the same fact, one layer down: every
      # tier is drawn from this list, so narrowing it narrows all of them.
      {:ok, view, _html} = live(conn, desk_url(ws, proj))

      catalog =
        @dataset
        |> Content.list_schemas(
          [include_global: true] ++
            Keyword.take(socket_opts(view), [:workspace_id, :grant_scoped, :caller_context])
        )
        |> Enum.map(& &1.name)

      assert @in_grant_type in catalog
      refute @out_of_grant_type in catalog
    end
  end

  describe "MEMBER — the desk is untouched (grants only ADD access)" do
    test "a full workspace member's whole desk is byte-identical to the unnarrowed control",
         %{conn: conn, ws: ws, proj: proj} do
      conn = member_session(conn, ws)

      {:ok, view, html} = live(conn, desk_url(ws, proj))

      assert html =~ @in_grant_type

      assert html =~ @out_of_grant_type,
             "OVER-REACH: the clamp hid a content type from a legitimate member"

      opts = socket_opts(view)

      refute Keyword.has_key?(opts, :grant_scoped),
             "a member must never carry the grant flag — its read stays byte-identical"

      # The unnarrowed control: the same workspace/project scope with no grant
      # keys at all. Full struct equality over the WHOLE tree — every placed
      # tier, every schema node, every id/title/icon — not a sampled `=~`.
      control = Structure.build(@dataset, workspace_id: ws.id, project_id: proj.id)

      assert Structure.build(@dataset, opts) == control,
             "OVER-REACH: a member's desk diverged from the unnarrowed control"

      names = all_type_names(opts)
      assert MapSet.member?(names, @in_grant_type)
      assert MapSet.member?(names, @out_of_grant_type)
    end
  end

  describe "fail-closed" do
    test "the flag with NO caller_context yields an empty catalog, never the whole workspace",
         %{ws: ws} do
      # `scope_schemas_to_grants/3` mirrors `scope_to_grants/3`: a grant-derived
      # caller can never fall through to the whole workspace.
      catalog =
        Content.list_schemas(@dataset,
          include_global: true,
          workspace_id: ws.id,
          grant_scoped: true
        )

      assert catalog == []
    end

    test "a workspace-wide grant (no type rung) still sees the whole catalog", %{
      conn: conn,
      ws: ws
    } do
      {user, _conn} = grantee_session(conn)
      _ = bind_grant!(ws, user, %{capabilities: ["read"]})

      ctx = Barkpark.Content.CallerContext.from_user(user.id)

      names =
        @dataset
        |> Content.list_schemas(
          include_global: true,
          workspace_id: ws.id,
          grant_scoped: true,
          caller_context: ctx
        )
        |> Enum.map(& &1.name)

      assert @in_grant_type in names

      assert @out_of_grant_type in names,
             "a null `type` rung covers everything below it — narrowing it is over-reach"
    end
  end
end
