defmodule BarkparkWeb.Live.ScopeDatasetBoundTokenTest do
  @moduledoc """
  task-37c54570e2e2a278: a token bound to one dataset stays on it in the
  Studio socket.

  `ResolveWorkspace` refuses a dataset-bound token on any other dataset, but
  plugs run for the page load only. `LiveScope` admits the socket at mount and
  on every scope-changing live patch, so it must refuse the same way.

  Each refusal has a control on the token's own dataset, so a redirect cannot
  come from a broken fixture.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}

  @own "bound-own"
  @other "bound-other"
  @own_title "OWN-DATASET-DOC"
  @other_title "OTHER-DATASET-DOC"

  setup %{conn: conn} do
    ws = create_workspace!("ds-bound-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")

    for {ds, title} <- [{@own, @own_title}, {@other, @other_title}] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Posts",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds,
          workspace_id: ws.id,
          project_id: proj.id
        )

      create_document_in!(ws, proj, "post", %{"title" => title}, ds)
    end

    {:ok, conn: conn, ws: ws, base: "/w/#{ws.slug}/p/default/d"}
  end

  defp token_conn(conn, ws, opts) do
    raw = "ds-bound-tok-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "ds-bound", @own, ["read", "write", "admin"], ws.id, opts)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp bound_conn(conn, ws), do: token_conn(conn, ws, dataset_bound: true)

  defp drill_posts(view) do
    render_click(view, "select", %{"pane" => "0", "id" => "post"})
    render(view)
  end

  defp assert_refused({:error, {:redirect, %{to: to}}}), do: assert(to =~ "/login")
  defp assert_refused({:error, {:live_redirect, %{to: to}}}), do: assert(to =~ "/login")

  describe "a dataset-bound token" do
    test "reads its own dataset (control)", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(bound_conn(conn, ws), "#{base}/#{@own}/studio")

      assert drill_posts(view) =~ @own_title
    end

    test "is refused the other dataset on a page load (the plug)", ctx do
      conn = get(bound_conn(ctx.conn, ctx.ws), "#{ctx.base}/#{@other}/studio")

      assert conn.status == 403
      refute conn.resp_body =~ @other_title
    end

    test "is refused a live patch to the other dataset", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(bound_conn(conn, ws), "#{base}/#{@own}/studio")

      assert_refused(render_patch(view, "#{base}/#{@other}/studio"))
    end

    test "is refused switch-dataset to the other dataset", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(bound_conn(conn, ws), "#{base}/#{@own}/studio")

      render_click(view, "switch-dataset", %{"dataset" => @other})

      assert_redirect(view, "/login")
    end

    # A live navigation mounts again over the socket, with no page load. The
    # test client cannot finish one in this session (an allowed token gets a
    # redirect with no target), so this proves only that the mount hook itself
    # refuses and sends the socket to sign-in.
    test "is refused a live navigation that mounts on the other dataset", ctx do
      {:ok, view, _} = live(bound_conn(ctx.conn, ctx.ws), "#{ctx.base}/#{@own}/studio")

      assert_refused(live_redirect(view, to: "#{ctx.base}/#{@other}/studio/post"))
    end

    test "is refused a live patch to the other dataset on the desk slice", ctx do
      {:ok, view, _} = live(bound_conn(ctx.conn, ctx.ws), "#{ctx.base}/#{@own}/studio/_desk")

      assert_refused(render_patch(view, "#{ctx.base}/#{@other}/studio/_desk/post"))
    end
  end

  describe "an unbound token (control)" do
    test "still moves between datasets by live patch", %{conn: conn, ws: ws, base: base} do
      {:ok, view, _} = live(token_conn(conn, ws, []), "#{base}/#{@own}/studio")

      render_patch(view, "#{base}/#{@other}/studio")

      assert drill_posts(view) =~ @other_title
    end
  end
end
