defmodule BarkparkWeb.Studio.DeskCensusGrantNarrowingTest do
  @moduledoc """
  The Studio desk's …Rest census must honour the caller's grant ladder
  (task-c6d2e34c64100678).

  `Barkpark.Structure.build/2` closes the desk with a `…Rest` tier listing every
  document type in scope that no placed pane claimed, rendered `type (N)`. It is
  fed by `Barkpark.Content.Analytics.type_census/2`, which — unlike every other
  document read in `Content.Query.base_query/4` — used to hand-roll its query and
  read exactly ONE opt (`:workspace_id`). No `maybe_scope_to_grants/2`.

  `LiveScope.authorize_read/4` admits a signed-in NON-MEMBER on its grant arm, so
  a grantee scoped to one project + one type mounted the desk and read back the
  NAMES of every document type in the WHOLE workspace plus the COUNT of each — a
  map of everything the grant did not cover, and its size. Existence and volume,
  not content; that is exactly what these tests pin.

  TWO independent causes had to be fixed together, or the leak survived:

    1. `Structure.census_opts/1` stripped `:grant_scoped` + `:caller_context`
       before the call, so the flag never arrived.
    2. `Analytics.type_census/2` read no key but `:workspace_id`, so the flag
       would have been ignored even if it had.

  The MEMBER arm below is the over-reach guard: grants only ever ADD access, and
  a member carries no `:grant_scoped` flag, so a member's census must stay
  byte-identical — a clamp that hides a member's types is a worse bug than the
  leak it closed.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Structure
  alias Barkpark.Tenancy
  alias BarkparkWeb.ScopeHelpers

  @dataset "production"

  # The type the grant COVERS, and the type it does NOT. Deliberately distinctive
  # strings: an `html =~` on "note" would collide with unrelated desk chrome,
  # whereas nothing else in a rendered desk spells these.
  @in_grant_type "grantedMemo"
  @out_of_grant_type "ledgerSecret"

  setup %{conn: conn} do
    ws = create_workspace!("desk-census-ws")
    proj = create_project!(ws, "desk-census-proj")

    # In-grant: one doc of the granted type, inside the granted project+dataset.
    {:ok, _} = create_document_in!(ws, proj, @in_grant_type, %{"title" => "in"}, @dataset)

    # Out-of-grant: a DIFFERENT type, same workspace+project+dataset, so the ONLY
    # thing separating it from the caller is the grant's `type` rung. Nothing
    # about the dataset or the workspace scope can hide it — only grant narrowing.
    {:ok, _} = create_document_in!(ws, proj, @out_of_grant_type, %{"title" => "out"}, @dataset)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp rest_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/rest"

  defp grantee_session(conn) do
    email = "desk-census-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp member_session(conn, ws) do
    raw = "desk-census-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "desk-census-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  # Every `…Rest` row title in a tree built with `opts`. `rest_child_node/3`
  # renders each as "type (N)", so this IS the disclosed pair — name and volume.
  defp rest_titles(opts) do
    tree = Structure.build(@dataset, opts)

    case Enum.find(tree.items, &(&1.id == "rest")) do
      nil -> []
      node -> Enum.map(node.items || [], & &1.title)
    end
  end

  describe "GRANTEE — the census is narrowed to the grant ladder" do
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

    test "the rendered …Rest desk does NOT name the out-of-grant type or its count",
         %{conn: conn, ws: ws, proj: proj} do
      {:ok, _view, html} = live(conn, rest_url(ws, proj))

      # Sanity: the grantee really is looking at the …Rest pane, and the type the
      # grant DOES cover is present with its honest count. Without this the
      # refute below could pass on an empty/500 page.
      assert html =~ "#{@in_grant_type} (1)",
             "the grant's OWN type must still render — the clamp must not blank the desk"

      refute html =~ @out_of_grant_type,
             "LEAK: the desk named a document type outside the caller's grant"
    end

    test "the socket's own scope opts produce a grant-narrowed census",
         %{conn: conn, ws: ws, proj: proj} do
      # Read through the REAL socket seam (not a hand-built keyword list), so the
      # test cannot pass by construction: this is the exact opts list
      # `PaneBuilder` hands `Structure.build/2` on every desk render.
      {:ok, view, _html} = live(conn, rest_url(ws, proj))
      opts = ScopeHelpers.scope_opts(:sys.get_state(view.pid).socket)

      assert Keyword.get(opts, :grant_scoped) == true,
             "precondition: the grantee socket must carry the Layer-2 flag"

      titles = rest_titles(opts)

      assert "#{@in_grant_type} (1)" in titles
      refute "#{@out_of_grant_type} (1)" in titles
      refute Enum.any?(titles, &String.starts_with?(&1, @out_of_grant_type))
    end
  end

  describe "MEMBER — the census is untouched (grants only ADD access)" do
    test "a full workspace member still sees EVERY type and count", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      conn = member_session(conn, ws)

      {:ok, view, html} = live(conn, rest_url(ws, proj))

      assert html =~ "#{@in_grant_type} (1)"

      assert html =~ "#{@out_of_grant_type} (1)",
             "OVER-REACH: the clamp hid a type from a legitimate member"

      opts = ScopeHelpers.scope_opts(:sys.get_state(view.pid).socket)

      refute Keyword.has_key?(opts, :grant_scoped),
             "a member must never carry the grant flag — its read stays byte-identical"

      titles = rest_titles(opts)
      assert "#{@in_grant_type} (1)" in titles
      assert "#{@out_of_grant_type} (1)" in titles
    end
  end
end
