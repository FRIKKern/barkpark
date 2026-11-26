defmodule BarkparkWeb.Studio.StudioLeaveRegateTest do
  @moduledoc """
  Studio's leave question over a held field, when an access grant changes
  while it is open (#28937 review, B1 and S1). Leave runs the press it asked
  about through every `handle_event` hook again (`LeaveAsk.hooks/3`), so a
  revoked grant refuses it as it refuses the same press made now; Stay and
  Leave themselves pass LiveScope's gates, so the question can always close.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Auth, Content, Repo}
  alias Barkpark.Access.Grant
  alias Barkpark.Tenancy.Quota
  alias BarkparkWeb.ObjectRichText

  @dataset "production"
  @dialog "#studio-leave-dialog"

  defp schema!(type, opts) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset,
        opts
      )
  end

  defp doc!(type, id, notes, opts) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "T0", "content" => %{"notes" => notes}},
        @dataset,
        opts
      )
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp posts(view, notes) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[notes]"],
      "doc" => %{"title" => "T0", "notes" => notes},
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp hold(a, b) do
    ObjectRichText.inside(a, fn -> posts(b, "one twB three") end, fn ->
      posts(a, "one twA three")
    end)

    assert has_element?(a, ~s([data-test-id="doc-conflict-banner"]))
    a
  end

  defp count(type),
    do: Repo.aggregate(from(d in Content.Document, where: d.type == ^type), :count)

  # A grantee with a project-wide write grant (`broad`) and a doc write grant
  # on kept-doc (`narrow`), as write_gate_grant_refresh_test sets up. A holds
  # a field on kept-doc against B, an admin token on the same doc.
  describe "a grant that changes under the open question" do
    setup %{conn: conn} do
      ws = create_workspace!("rev37-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "rev37-proj")
      Barkpark.SharingFixtures.clear_shares!()
      opts = [workspace_id: ws.id, project_id: proj.id]
      schema!("post", opts)
      doc!("post", "kept-doc", "one two three", opts)

      email = "rev37-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
      {:ok, raw} = Accounts.create_user_session_token(user)

      {:ok, grantor} =
        %Auth.ApiToken{}
        |> Auth.ApiToken.changeset(%{
          token_hash: Auth.ApiToken.hash_token("rev37-grantor-" <> Ecto.UUID.generate()),
          label: "rev37-grantor",
          dataset: "test",
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, grantor.id, "admin")

      bind = fn over ->
        {:ok, g} =
          %Grant{}
          |> Grant.changeset(
            Map.merge(
              %{
                grantor_id: grantor.id,
                grantee_email: user.email,
                grantee_user_id: user.id,
                claimed_at: DateTime.utc_now(),
                workspace_id: ws.id,
                capabilities: ["read"],
                link_token_hash: "hash-" <> Ecto.UUID.generate()
              },
              over
            )
          )
          |> Repo.insert()

        g
      end

      bind.(%{capabilities: ["read"]})
      broad = bind.(%{project_id: proj.id, capabilities: ["read", "write"]})

      narrow =
        bind.(%{
          project_id: proj.id,
          dataset: @dataset,
          type: "post",
          doc_id: "kept-doc",
          capabilities: ["read", "write"]
        })

      raw_b = "rev37gb-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw_b, "rev37gb", @dataset, ~w(read write admin), ws.id)

      root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

      {:ok,
       conn_a: Plug.Test.init_test_session(conn, %{"user_session" => raw}),
       conn_b: Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw_b}),
       broad: broad,
       narrow: narrow,
       grantor: grantor,
       ws: ws,
       doc: "#{root}/post/kept-doc"}
    end

    defp asked(c) do
      a = hold(open(c.conn_a, c.doc), open(c.conn_b, c.doc))
      n0 = count("post")
      render_click(a, "new-document", %{"type" => "post"})
      assert has_element?(a, @dialog)
      assert count("post") == n0
      {a, n0}
    end

    defp leave(a),
      do: a |> element(~s(#{@dialog} button[phx-click="desk-leave-go"])) |> render_click()

    test "Leave on new-document makes exactly one document, and asks nothing again", c do
      {a, n0} = asked(c)
      leave(a)
      assert count("post") == n0 + 1
      refute has_element?(a, @dialog)
      assert assigns(a).studio_leave == nil
    end

    test "the project write grant revoked under the question: Leave is refused, nothing made",
         c do
      {a, n0} = asked(c)
      assert {:ok, _} = Access.revoke(c.broad.id, c.grantor)
      _ = :sys.get_state(a.pid)

      html = leave(a)
      assert count("post") == n0
      assert html =~ "outside your access grant"
    end

    test "every write grant revoked under the question: Stay still closes it", c do
      {a, _n0} = asked(c)
      assert {:ok, _} = Access.revoke(c.broad.id, c.grantor)
      assert {:ok, _} = Access.revoke(c.narrow.id, c.grantor)
      _ = :sys.get_state(a.pid)

      html = render_click(a, "desk-leave-stay", %{})
      refute has_element?(a, @dialog)
      refute html =~ "outside your access grant"
    end

    test "every write grant revoked with a field held: a link held back still asks", c do
      a = hold(open(c.conn_a, c.doc), open(c.conn_b, c.doc))
      assert {:ok, _} = Access.revoke(c.broad.id, c.grantor)
      assert {:ok, _} = Access.revoke(c.narrow.id, c.grantor)
      _ = :sys.get_state(a.pid)

      html = render_click(a, "studio-leave", %{"href" => "/papers", "kind" => ""})
      assert has_element?(a, ~s|#{@dialog} a[data-desk-leave-go][href="/papers"]|)
      refute html =~ "outside your access grant"
    end

    test "room for one more document: Leave makes it once; the quota counts one create", c do
      {a, n0} = asked(c)
      ws = Barkpark.Tenancy.get_workspace_by_id(c.ws.id)
      {:ok, _} = Quota.set_quota(ws, Quota.usage(ws.id) + 1)

      leave(a)
      assert count("post") == n0 + 1
      refute Quota.room_for?(Barkpark.Tenancy.get_workspace_by_id(c.ws.id), 1)
    end
  end
end
