defmodule BarkparkWeb.PaperViewerTest do
  @moduledoc """
  Edit-on-the-link slice 1 (task-0c242c8dc61f6b13, epic task-a19eeb215f653529):
  the paper reader learns WHO is viewing and derives a fail-closed `can_edit?`.

  Every case mounts the REAL reader route and reads the LiveView's assigns off
  the live process (`:sys.get_state/1`, the precedent
  `studio_update_banner_test.exs` uses), because slice 1 ships no UI: the
  assigns ARE the deliverable, and the anonymous render must stay byte-identical.

  Principal matrix (acceptance criterion 0):

    | arrives with                         | @viewer.kind | @can_edit? |
    |--------------------------------------|--------------|------------|
    | nothing                              | :anonymous   | false      |
    | api_token, Default member, write     | :token       | true       |
    | api_token, Default member, read only | :token       | false      |
    | api_token, write but OTHER workspace | :token       | false      |
    | user_session, Default member         | :user        | true       |
    | user_session, no membership          | :user        | false      |
    | ?share= item link (scoped reader)    | :share       | false      |

  `async: false` — the shares registry and the Default scope are process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Sharing.Links
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.PaperViewer

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()
    slug = "paper-viewer-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: ~s(<section id="block-1"><h1>Viewer probe</h1></section>),
          event_type: "plan-written"
        })
      )

    %{conn: conn, slug: slug, paper: paper, default_ws: default_ws, default_proj: default_proj}
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp user_session!(conn, memberships) do
    email = "viewer-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- memberships do
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  describe "anonymous" do
    test "mounts as :anonymous with can_edit? false and the render unchanged", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "Viewer probe"
      assert html =~ ~s(id="paper-sentinel")
      # The verdict never leaks into the anonymous page. Asserted on what the
      # reader would actually EMIT for a writable viewer (slice 2's edit bar and
      # its toggle event) rather than on the substring "can_edit": the shared
      # bulldocs layout now carries an inline-script COMMENT naming `@can_edit?`
      # beside the editor-asset tags it gates, so the bare substring is no longer
      # evidence of a leak.
      refute html =~ ~s(id="paper-edit-bar")
      refute html =~ "paper-toggle-edit"

      assigns = assigns_of(view)
      assert assigns.viewer == PaperViewer.anonymous()
      assert assigns.can_edit? == false
      assert assigns.current_user == nil
      assert assigns.api_token == nil
    end

    test "an unverifiable session token is anonymous, never an error", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(as_token(conn, "no-such-token-anywhere"), "/papers/#{slug}")

      assert assigns_of(view).viewer == PaperViewer.anonymous()
      assert assigns_of(view).can_edit? == false
      # An unverifiable string is never echoed back as the raw credential.
      assert assigns_of(view).api_token_raw == ""
    end
  end

  describe "api token in the session" do
    test "a Default member holding write may edit", %{conn: conn, slug: slug} do
      raw = "pv-writer-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "pv writer", @dataset, ["read", "write"])

      {:ok, view, _html} = live(as_token(conn, raw), "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :token, id: id} = assigns.viewer
      assert id == token.id
      assert assigns.api_token.id == token.id
      # Slice 2 needs the RAW credential the browser presented (the editor's
      # `data-token=` bridges); only ever set for a token that VERIFIED.
      assert assigns.api_token_raw == raw
      assert assigns.can_edit? == true
    end

    test "a Default member holding only read is identified but may not edit", %{
      conn: conn,
      slug: slug
    } do
      raw = "pv-reader-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "pv reader", @dataset, ["read"])

      {:ok, view, _html} = live(as_token(conn, raw), "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :token, id: id} = assigns.viewer
      assert id == token.id
      assert assigns.can_edit? == false
    end

    test "write in ANOTHER workspace grants nothing on a Default paper", %{
      conn: conn,
      slug: slug
    } do
      other = create_workspace!()
      raw = "pv-other-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "pv other", @dataset, ["read", "write"], other.id)

      {:ok, view, _html} = live(as_token(conn, raw), "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :token} = assigns.viewer
      assert assigns.can_edit? == false
    end
  end

  describe "account session" do
    test "a Default member may edit and is the :user viewer", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      {user, conn} = user_session!(conn, [{default_ws, "member"}])

      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :user, id: id, label: label} = assigns.viewer
      assert id == user.id
      assert label == user.email
      assert assigns.current_user.id == user.id
      assert assigns.can_edit? == true
    end

    test "a user with no membership is identified but may not edit", %{conn: conn, slug: slug} do
      {user, conn} = user_session!(conn, [])

      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :user, id: id} = assigns.viewer
      assert id == user.id
      assert assigns.can_edit? == false
    end

    test "the account wins the viewer summary when both credentials are present", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      raw = "pv-both-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "pv both", @dataset, ["read"])
      {user, conn} = user_session!(conn, [{default_ws, "member"}])
      conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      assigns = assigns_of(view)
      assert %{kind: :user, id: id} = assigns.viewer
      assert id == user.id
      # The read-only token does not veto the member's write: either credential
      # authorizing :write on the paper's workspace suffices.
      assert assigns.can_edit? == true
    end
  end

  describe "share link on the scoped reader" do
    test "an item link mounts as a :share viewer that may not edit", %{conn: conn} do
      ws = create_workspace!()
      proj = create_project!(ws)
      slug = "pv-shared-#{System.unique_integer([:positive])}"

      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "title" => "Shared probe",
            "blocks" => [
              %{
                "id" => "b1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Shared probe body"}]
              }
            ],
            "workspace_id" => ws.id,
            "project_id" => proj.id
          })
        )

      {:ok, {raw, link}} =
        Links.create(%{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: slug,
          access: "read"
        })

      {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}?share=#{raw}")

      assert html =~ "Shared probe"

      assigns = assigns_of(view)
      # Slice 3 (task-8ac4f3918da1c433) widened the item arm with the LINK's
      # own access level and the resource it binds; a `read` link still grades
      # `access: :read` and still cannot edit.
      assert assigns.viewer == %{
               kind: :share,
               grant: :item,
               id: link.id,
               access: :read,
               ref_id: slug,
               workspace_id: ws.id
             }

      assert assigns.can_edit? == false
      assert assigns.current_user == nil
      assert assigns.api_token == nil
    end
  end

  describe "share link bound to ANOTHER slug" do
    test "never reaches the reader: the dead render is denied before any hook runs", %{
      conn: conn
    } do
      ws = create_workspace!()
      proj = create_project!(ws)
      granted = "pv-granted-#{System.unique_integer([:positive])}"
      sibling = "pv-sibling-#{System.unique_integer([:positive])}"

      for slug <- [granted, sibling] do
        {:ok, _} =
          Content.upsert_paper(
            Barkpark.LabelFixtures.paper_attrs(%{
              "slug" => slug,
              "title" => slug,
              "blocks" => [
                %{
                  "id" => "b1",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "body of #{slug}"}]
                }
              ],
              "workspace_id" => ws.id,
              "project_id" => proj.id
            })
          )
      end

      {:ok, {raw, _link}} =
        Links.create(%{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: granted,
          access: "read"
        })

      # Positive control: the bound slug mounts as a :share viewer.
      {:ok, view, _html} =
        live(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/#{granted}?share=#{raw}")

      assert %{kind: :share, grant: :item} = assigns_of(view).viewer
      assert assigns_of(view).can_edit? == false

      # The sibling slug with the same token is refused at the dead render
      # (RequireShareScope → membership deny), so no viewer, no edit, ever.
      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/#{sibling}?share=#{raw}")
      assert conn.status == 403
    end
  end

  describe "can_edit?/2 is fail-closed on every unknown shape" do
    test "nil workspace, empty assigns, and non-principal values all deny" do
      assert PaperViewer.can_edit?(%{}, nil) == false
      assert PaperViewer.can_edit?(%{}, "not-a-workspace-id") == false
      assert PaperViewer.can_edit?(%{current_user: :bogus, api_token: "raw"}, "x") == false
      assert PaperViewer.can_edit?(nil, "x") == false
    end
  end
end
